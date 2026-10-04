import SwiftUI
import AppKit
import CryptoKit
import ServiceManagement

enum Spacing {
    static let edge: CGFloat = 24
    static let panel: CGFloat = 16
    static let gap: CGFloat = 8
    static let section: CGFloat = 20
}
@MainActor final class AppModel: ObservableObject {
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    private let loginStatusProvider: () -> SMAppService.Status
    private let loginRegister: () throws -> Void
    private let openLoginSettings: () -> Void
    @Published var status = "ローカル履歴を確認中"
    @Published var codexCount = 0
    @Published var claudeCount = 0
    @Published var enabled: Bool = false
    @Published var endpoint: String = ""
    @Published var draftEndpoint: String = ""
    @Published var viewerEndpoint: String = ""
    @Published var draftViewerEndpoint: String = ""
    @Published var showSettings = false
    @Published var busy = false
    @Published var lastSync: Date? = nil
    @Published var lastCount: Int = 0
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?
    private var initialReadTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var digest: Data?
    private var snapshot = Snapshot(sessions: [])
    private var collectionGeneration: UInt64 = 0
    private let calendar = LocalCalendar()
    private let noRedirect = NoRedirect()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: noRedirect, delegateQueue: nil)
    private let defaults: UserDefaults
    private let collectMetadata: () -> Collection
    private var residentKey: P256.Signing.PrivateKey?
    private let keyAuthorizer: () -> P256.Signing.PrivateKey?
    private let keyProvider: () -> P256.Signing.PrivateKey?
    private let transport: ((URLRequest) async throws -> (Data, URLResponse))?
    init(defaults: UserDefaults = .standard, startBackgroundTasks: Bool = true,
         collectMetadata: @escaping () -> Collection = { Metadata.collect() },
         keyProvider: @escaping () -> P256.Signing.PrivateKey? = { Credential.load() },
         keyAuthorizer: @escaping () -> P256.Signing.PrivateKey? = { Credential.loadForUserInitiatedProbe() },
         transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
         loginStatusProvider: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         loginRegister: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         openLoginSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }) {
        self.loginStatusProvider = loginStatusProvider; self.loginRegister = loginRegister
        self.openLoginSettings = openLoginSettings
        loginStatus = loginStatusProvider()
        self.defaults = defaults; self.collectMetadata = collectMetadata
        self.keyProvider = keyProvider; self.keyAuthorizer = keyAuthorizer; self.transport = transport
        enabled = defaults.bool(forKey: "syncEnabled")
        endpoint = defaults.string(forKey: "syncEndpoint") ?? ""; draftEndpoint = endpoint
        viewerEndpoint = defaults.string(forKey: "viewerEndpoint") ?? ""; draftViewerEndpoint = viewerEndpoint
        lastSync = defaults.object(forKey: "lastSync") as? Date; lastCount = defaults.integer(forKey: "lastCount")
        if startBackgroundTasks { startBackgroundWork() }
    }
    func startBackgroundWork() {
        guard initialReadTask == nil else { return }
        let initialGeneration = beginCollection()
        initialReadTask = Task {
            guard await collect(generation: initialGeneration), !Task.isCancelled else { return }
            if enabled {
                if let key=residentKey ?? keyProvider() { residentKey=key; syncNow() }
                else { status="鍵を確認して同期を開始してください" }
            }
        }
        periodicTask = Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(300)); if enabled { syncNow() } } }
    }
    static func syncURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.path == "/api/sync", url.query == nil, url.fragment == nil else { return nil }
        return url
    }
    static func viewerURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
    var icon: String { busy ? "arrow.triangle.2.circlepath" : (errorMessage != nil ? "exclamationmark.icloud" : enabled ? "checkmark.icloud" : "pause.circle") }
    var dateLabel: String {
        guard let lastSync else { return "未送信" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP"); formatter.timeZone = TimeZone(identifier: "Asia/Tokyo"); formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.string(from: lastSync)
    }
    private func beginCollection() -> UInt64 {
        collectionGeneration &+= 1
        return collectionGeneration
    }
    @discardableResult private func collect(generation: UInt64) async -> Bool {
        let collector = collectMetadata
        let result = await Task.detached(priority: .utility) { collector() }.value
        guard generation == collectionGeneration else { return false }
        guard result.failures == 0 else {
            errorMessage = "一部の履歴を読み取れません。直前に表示したsnapshotを保持しています"
            status = "読取失敗"
            return false
        }
        return apply(result)
    }
    @discardableResult private func apply(_ result: Collection) -> Bool {
        snapshot = result.snapshot
        codexCount = snapshot.sessions.filter { $0.tool == "Codex" }.count
        claudeCount = snapshot.sessions.filter { $0.tool == "Claude" }.count
        calendar.update(snapshot)
        if result.failures > 0 { errorMessage = "一部の履歴を読み取れません。送信を中止しました"; status = "読取失敗"; return false }
        status = enabled ? "同期待機中" : "送信は一時停止中"
        return true
    }
    func refresh() {
        guard !busy else { return }
        let generation = beginCollection()
        refreshTask = Task { _ = await collect(generation: generation) }
    }
    func waitForRefreshForTesting() async { await refreshTask?.value }
    func waitForInitialReadForTesting() async { await initialReadTask?.value }
    func pause() { _ = beginCollection(); enabled = false; defaults.set(false, forKey: "syncEnabled"); task?.cancel(); status = "送信は一時停止中" }
    func enable() {
        guard let url=Self.syncURL(endpoint) else { errorMessage="同期先URLが未設定です";showSettings=true;return }
        guard !busy else { return }
        let generation = beginCollection()
        busy=true;errorMessage=nil;status="Keychainの確認を待っています"
        task=Task {
            defer { busy=false }
            guard !Task.isCancelled else { return }
            let authorizer=keyAuthorizer
            let key: P256.Signing.PrivateKey?
            if let cached=residentKey { key=cached }
            else { key=await Task.detached { authorizer() }.value }
            guard let key,!Task.isCancelled else { status="鍵の利用を許可できませんでした";return }
            do {
                status="snapshotを変更せず接続を確認中"
                try await SyncHandshake.verify(url:url,key:key,transport:{ request in
                    try await (self.transport != nil ? self.transport!(request) : self.session.data(for:request))
                })
                try Task.checkCancellation()
                fputs("resident: non-mutating signed handshake verified; key retained in process\n",stderr)
                residentKey=key;digest=nil;enabled=true;defaults.set(true,forKey:"syncEnabled")
                await transmit(generation: generation)
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                enabled=false;defaults.set(false,forKey:"syncEnabled");status="接続確認に失敗しました";errorMessage="署名付き接続確認が完了していません" }
        }
    }
    func shutdown() { task?.cancel(); periodicTask?.cancel(); residentKey=nil; enabled=false }
    func beginSettings() { pause(); draftEndpoint = endpoint; draftViewerEndpoint = viewerEndpoint; showSettings = true }
    func saveConnection() {
        guard Self.syncURL(draftEndpoint) != nil else { errorMessage = "HTTPSの /api/sync URLを指定してください"; return }
        guard draftViewerEndpoint.isEmpty || Self.viewerURL(draftViewerEndpoint) != nil else { errorMessage = "閲覧URLはHTTPSで指定してください"; return }
        endpoint = draftEndpoint; defaults.set(endpoint, forKey: "syncEndpoint")
        viewerEndpoint = draftViewerEndpoint; defaults.set(viewerEndpoint, forKey: "viewerEndpoint")
        digest = nil; errorMessage = nil; pause(); showSettings = false
    }
    func syncNow() {
        guard enabled, !busy else { return }
        let generation = beginCollection()
        busy = true
        task = Task { await transmit(generation: generation) }
    }
    func waitForSyncForTesting() async { await task?.value }
    private func transmit(generation: UInt64) async {
        busy = true; errorMessage = nil
        defer { busy = false }
        guard await collect(generation: generation), generation == collectionGeneration, enabled, !Task.isCancelled else { return }
        guard let url = Self.syncURL(endpoint), let key = residentKey else { errorMessage = "同期先・キーチェーンの署名鍵を確認してください"; status = "接続設定が必要"; return }
        do {
            let prepared = Metadata.prepared(snapshot, includeTitles: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let body = try encoder.encode(prepared)
            guard body.count <= 2 * 1024 * 1024, prepared.sessions.count <= 20000 else { errorMessage = "履歴が同期上限を超えています"; status = "送信失敗"; return }
            let nextDigest = Data(SHA256.hash(data: body))
            if nextDigest == digest { status = "変更なし・同期待機中"; return }
            status = "\(prepared.sessions.count)件を送信中"
            var request = URLRequest(url: url); request.httpMethod = "PUT"; request.httpBody = body; request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type"); try Credential.sign(&request, body: body, key: key)
            let (data, response) = try await (transport != nil ? transport!(request) : session.data(for: request))
            try Task.checkCancellation()
            guard generation == collectionGeneration else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["ok"] as? Bool == true, json["count"] as? Int == prepared.sessions.count else { errorMessage = "サーバーが送信を受け付けませんでした"; status = "送信失敗"; return }
            digest = nextDigest; lastSync = Date(); lastCount = prepared.sessions.count
            defaults.set(lastSync, forKey: "lastSync"); defaults.set(lastCount, forKey: "lastCount")
            status = "送信完了・同期待機中"
            fputs("resident: metadata accepted count=\(lastCount); 5-minute sync active\n",stderr)
        } catch is CancellationError { status = "送信は一時停止中" }
        catch { errorMessage = "通信に失敗しました。次回に再試行します"; status = "送信失敗" }
    }
    func openLocalCalendar() {
        do { try calendar.start(); NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(LocalCalendar.port)")!) }
        catch { errorMessage = "ローカルカレンダーを起動できませんでした" }
    }
    func openWebCalendar() {
        guard let url = Self.viewerURL(viewerEndpoint) else { return }
        NSWorkspace.shared.open(url)
    }
    func refreshLoginStatus() { loginStatus = loginStatusProvider() }
    var loginLabel: String {
        switch loginStatus {
        case .enabled: return "ログイン時に起動：オン"
        case .requiresApproval: return "ログイン時に起動：承認待ち"
        case .notFound: return "ログイン時に起動：利用不可"
        case .notRegistered: return "ログイン時に起動：オフ"
        @unknown default: return "ログイン時に起動：不明"
        }
    }
    func registerLogin() {
        refreshLoginStatus()
        if loginStatus == .enabled { return }
        if loginStatus == .requiresApproval { openLoginSettings(); return }
        do {
            try loginRegister(); refreshLoginStatus()
            if loginStatus == .requiresApproval { openLoginSettings() }
        } catch { refreshLoginStatus(); errorMessage = "ログイン時の起動を登録できませんでした" }
    }
}
@main struct SessionCalendarApp: App {
    @StateObject private var model: AppModel
    @StateObject private var updater = Updater()
    init() {
        if CommandLine.arguments.contains("--provision-key") {
            DispatchQueue.global().asyncAfter(deadline: .now()+15) { fputs("Keychain provisioning exceeded 15s; no prompt was accepted\n",stderr); exit(2) }
            do { print(try Credential.provision()); exit(0) }
            catch { fputs("Keychain provisioning failed without interaction: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--self-test") { BundleSelfTest.run() }
        _model = StateObject(wrappedValue: AppModel())
    }
    var body: some Scene {
        MenuBarExtra("Session Calendar", systemImage: model.icon) { Dashboard(model: model, updater: updater) }.menuBarExtraStyle(.window)
    }
}
@MainActor struct Dashboard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.panel) {
            Label("Session Calendar", systemImage: model.icon).font(.headline)
            Text(model.status).font(.callout).accessibilityIdentifier("sync-status")
            if let error = model.errorMessage { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: Spacing.gap) {
                if model.enabled { Button("同期を停止") { model.pause() } }
                else { Button("同期を開始") { model.enable() }.buttonStyle(.borderedProminent) }
                Button("カレンダー") { model.openLocalCalendar() }
                Button("Web") { model.openWebCalendar() }.disabled(AppModel.viewerURL(model.viewerEndpoint) == nil)
            }
            if model.showSettings {
                VStack(alignment: .leading, spacing: Spacing.gap) {
                    TextField("同期先 https://<host>/api/sync", text: $model.draftEndpoint).textFieldStyle(.roundedBorder).accessibilityLabel("同期先URL")
                    TextField("閲覧 https://<host>/", text: $model.draftViewerEndpoint).textFieldStyle(.roundedBorder).accessibilityLabel("閲覧URL")
                    Button("同期先を保存") { model.saveConnection() }
                }
            }
            Divider()
            HStack {
                updateControls
                Spacer()
                Text("ver \(Updater.version)").font(.caption).foregroundStyle(.secondary)
                moreMenu
                Button("終了") { NSApp.terminate(nil) }
            }
        }
        .onAppear { model.refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshLoginStatus() }
        .padding(Spacing.edge).frame(width: 360)
    }
    // ponytail: 頻度の低い操作はすべてここへ退避。常時表示が必要になったら本体へ戻す
    private var moreMenu: some View {
        Menu {
            Button("今すぐ同期") { model.syncNow() }.disabled(!model.enabled || model.busy)
            Button("履歴を再読取") { model.refresh() }.disabled(model.busy)
            Button("接続設定") { model.beginSettings() }
            Divider()
            Button(model.loginLabel) { model.registerLogin() }.disabled(model.loginStatus == .enabled)
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("その他")
    }
    @ViewBuilder private var updateControls: some View {
        switch updater.state {
        case .idle:
            Button("更新を確認") { Task { await updater.check() } }
        case .checking:
            Text("更新を確認中…").font(.caption)
        case .available(let tag):
            Button("最新へ更新") { Task { await updater.update() } }.help(tag)
        case .upToDate:
            Button("最新版です ↻") { Task { await updater.check() } }.help("更新を確認")
        case .updating:
            Text("更新中…").font(.caption)
        case .updated:
            Button("再起動して適用") { updater.restart() }
        case .failed(let message):
            Button("確認失敗・再試行") { Task { await updater.check() } }
                .foregroundStyle(.red).help(message).accessibilityHint(message)
        }
    }
}
