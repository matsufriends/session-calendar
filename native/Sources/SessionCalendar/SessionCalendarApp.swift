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
    @Published var status = "ローカル履歴を確認中"
    @Published var codexCount = 0
    @Published var claudeCount = 0
    @Published var enabled: Bool = false
    @Published var includeTitles: Bool = false
    @Published var endpoint: String = ""
    @Published var draftEndpoint: String = ""
    @Published var viewerEndpoint: String = "https://session-calendar.matsufriends.com/"
    @Published var showSettings = false
    @Published var busy = false
    @Published var lastSync: Date? = nil
    @Published var lastCount: Int = 0
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?
    private var digest: Data?
    private var snapshot = Snapshot(sessions: [])
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
         transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) {
        self.defaults = defaults; self.collectMetadata = collectMetadata
        self.keyProvider = keyProvider; self.keyAuthorizer = keyAuthorizer; self.transport = transport
        enabled = defaults.bool(forKey: "syncEnabled"); includeTitles = defaults.bool(forKey: "includeTitles")
        endpoint = defaults.string(forKey: "syncEndpoint") ?? ""; draftEndpoint = endpoint
        viewerEndpoint = defaults.string(forKey: "viewerEndpoint") ?? "https://session-calendar.matsufriends.com/"
        lastSync = defaults.object(forKey: "lastSync") as? Date; lastCount = defaults.integer(forKey: "lastCount")
        if !startBackgroundTasks { return }
        Task {
            await collect()
            if enabled {
                if let key=keyProvider() { residentKey=key; syncNow() }
                else { enabled=false; defaults.set(false,forKey:"syncEnabled"); status="鍵を確認して同期を開始してください" }
            }
        }
        Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(300)); if enabled { syncNow() } } }
    }
    static func syncURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.path == "/api/sync", url.query == nil, url.fragment == nil else { return nil }
        return url
    }
    var icon: String { busy ? "arrow.triangle.2.circlepath" : (errorMessage != nil ? "exclamationmark.icloud" : enabled ? "checkmark.icloud" : "pause.circle") }
    var dateLabel: String {
        guard let lastSync else { return "未送信" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP"); formatter.timeZone = TimeZone(identifier: "Asia/Tokyo"); formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.string(from: lastSync)
    }
    @discardableResult private func collect() async -> Bool {
        let collector = collectMetadata
        let result = await Task.detached(priority: .utility) { collector() }.value
        snapshot = result.snapshot
        codexCount = snapshot.sessions.filter { $0.tool == "Codex" }.count
        claudeCount = snapshot.sessions.filter { $0.tool == "Claude" }.count
        calendar.update(snapshot)
        if result.failures > 0 { errorMessage = "一部の履歴を読み取れません。送信を中止しました"; status = "読取失敗"; return false }
        status = enabled ? "同期待機中" : "送信は一時停止中"
        return true
    }
    func refresh() { Task { _ = await collect() } }
    func pause() { enabled = false; defaults.set(false, forKey: "syncEnabled"); task?.cancel(); status = "送信は一時停止中" }
    func enable() {
        guard let url=Self.syncURL(endpoint) else { errorMessage="同期先URLが未設定です";showSettings=true;return }
        guard !busy else { return }
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
                status="空データで接続を確認中"
                try await SyncHandshake.verify(url:url,key:key,transport:{ request in
                    try await (self.transport != nil ? self.transport!(request) : self.session.data(for:request))
                })
                try Task.checkCancellation()
                fputs("resident: empty signature handshake verified; key retained in process\n",stderr)
                residentKey=key;digest=nil;enabled=true;defaults.set(true,forKey:"syncEnabled")
                await transmit()
            } catch { enabled=false;defaults.set(false,forKey:"syncEnabled");status="接続確認に失敗しました";errorMessage="空データの認証確認が完了していません" }
        }
    }
    func shutdown() { task?.cancel(); residentKey=nil }
    func beginSettings() { pause(); draftEndpoint = endpoint; showSettings = true }
    func saveConnection() {
        guard Self.syncURL(draftEndpoint) != nil else { errorMessage = "HTTPSの /api/sync URLを指定してください"; return }
        endpoint = draftEndpoint; defaults.set(endpoint, forKey: "syncEndpoint")
        digest = nil; errorMessage = nil; pause(); showSettings = false
    }
    func titlesChanged() { defaults.set(includeTitles, forKey: "includeTitles"); digest = nil; pause() }
    func syncNow() {
        guard enabled, !busy else { return }
        busy = true
        task = Task { await transmit() }
    }
    func waitForSyncForTesting() async { await task?.value }
    private func transmit() async {
        busy = true; errorMessage = nil
        defer { busy = false }
        guard await collect(), enabled, !Task.isCancelled else { return }
        guard let url = Self.syncURL(endpoint), let key = residentKey else { errorMessage = "同期先・キーチェーンの署名鍵を確認してください"; status = "接続設定が必要"; return }
        do {
            let prepared = Metadata.prepared(snapshot, includeTitles: includeTitles)
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
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["ok"] as? Bool == true, json["count"] as? Int == prepared.sessions.count else { errorMessage = "サーバーが送信を受け付けませんでした"; status = "送信失敗"; return }
            digest = nextDigest; lastSync = Date(); lastCount = prepared.sessions.count
            defaults.set(lastSync, forKey: "lastSync"); defaults.set(lastCount, forKey: "lastCount")
            status = "送信完了・同期待機中"
            fputs("resident: metadata accepted count=\(lastCount); 5-minute sync active; titles=\(includeTitles)\n",stderr)
        } catch is CancellationError { status = "送信は一時停止中" }
        catch { errorMessage = "通信に失敗しました。次回に再試行します"; status = "送信失敗" }
    }
    func openLocalCalendar() {
        do { try calendar.start(); NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(LocalCalendar.port)")!) }
        catch { errorMessage = "ローカルカレンダーを起動できませんでした" }
    }
    func openWebCalendar() {
        guard let url=URL(string:viewerEndpoint),url.scheme=="https",url.user==nil,url.password==nil else { return }
        NSWorkspace.shared.open(url)
    }
    func registerLogin() {
        if SMAppService.mainApp.status == .enabled { return }
        do { try SMAppService.mainApp.register() }
        catch { errorMessage = "ログイン時の起動を登録できませんでした" }
    }
}
@main struct SessionCalendarApp: App {
    @StateObject private var model: AppModel
    init() {
        if CommandLine.arguments.contains("--enable-login-startup") {
            do {
                let before=SMAppService.mainApp.status
                if before == .notRegistered || before == .notFound { try SMAppService.mainApp.register() }
                let after=SMAppService.mainApp.status
                print("{\"login_status_before\":\(before.rawValue),\"login_status_after\":\(after.rawValue),\"unregister_called\":false}")
                exit(after == .enabled ? 0 : 2)
            } catch { fputs("Login registration failed: \(error)\n",stderr);exit(1) }
        }
        if CommandLine.arguments.contains("--authorize-empty-sync") { EmptySyncProbe.run(allowKeychainPrompt: true) }
        if CommandLine.arguments.contains("--probe-empty-sync") { EmptySyncProbe.run() }
        if CommandLine.arguments.contains("--provision-key") {
            DispatchQueue.global().asyncAfter(deadline: .now()+15) { fputs("Keychain provisioning exceeded 15s; no prompt was accepted\n",stderr); exit(2) }
            do { print(try Credential.provision()); exit(0) }
            catch { fputs("Keychain provisioning failed without interaction: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--self-test") { BundleSelfTest.run() }
        let resident=AppModel()
        _model = StateObject(wrappedValue: resident)
        if CommandLine.arguments.contains("--start-resident-sync") { resident.enable() }
    }
    var body: some Scene {
        MenuBarExtra("Session Calendar", systemImage: model.icon) { Dashboard(model: model) }.menuBarExtraStyle(.window)
    }
}
struct Dashboard: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.panel) {
            Label("Session Calendar", systemImage: model.icon).font(.headline)
            Text(model.status).font(.callout).accessibilityIdentifier("sync-status")
            HStack(spacing: Spacing.section) {
                Label("Claude \(model.claudeCount)件", systemImage: "c.circle")
                Label("Codex \(model.codexCount)件", systemImage: "terminal")
            }.font(.caption)
            Grid(alignment: .leading, horizontalSpacing: Spacing.panel, verticalSpacing: Spacing.gap) {
                GridRow { Text("最終送信").foregroundStyle(.secondary); Text(model.dateLabel).monospacedDigit() }
                GridRow { Text("送信件数").foregroundStyle(.secondary); Text("\(model.lastCount)件") }
                GridRow { Text("送信間隔").foregroundStyle(.secondary); Text("5分・変更時") }
                GridRow { Text("送信先").foregroundStyle(.secondary); Text(AppModel.syncURL(model.endpoint)?.host ?? "未設定").lineLimit(2) }
            }.font(.caption)
            if let error = model.errorMessage { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: Spacing.gap) {
                if model.enabled { Button("送信を一時停止") { model.pause() } }
                else { Button("接続を確認して同期を開始") { model.enable() }.buttonStyle(.borderedProminent) }
                Button("今すぐ同期") { model.syncNow() }.disabled(!model.enabled || model.busy)
            }
            Toggle("タイトルも送信する", isOn: $model.includeTitles).onChange(of: model.includeTitles) { model.titlesChanged() }
            Divider()
            HStack(spacing: Spacing.gap) {
                Button("ローカルカレンダー") { model.openLocalCalendar() }
                Button("Webカレンダー") { model.openWebCalendar() }.disabled(AppModel.syncURL(model.endpoint) == nil)
            }
            HStack(spacing: Spacing.gap) {
                Button("履歴を再読取") { model.refresh() }.disabled(model.busy)
                Button("接続設定") { model.beginSettings() }
            }
            if model.showSettings {
                VStack(alignment: .leading, spacing: Spacing.gap) {
                    TextField("https://<host>/api/sync", text: $model.draftEndpoint).textFieldStyle(.roundedBorder).accessibilityLabel("同期先URL")
                    Button("同期先を保存") { model.saveConnection() }
                }
            }
            Divider()
            HStack {
                Menu("起動設定") {
                    Button("ログイン時に起動を登録") { model.registerLogin() }
                }
                Spacer()
                Button("終了") { model.shutdown(); NSApplication.shared.terminate(nil) }
            }
        }.padding(Spacing.edge).frame(width: 400)
    }
}
