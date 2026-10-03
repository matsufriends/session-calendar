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
    @Published var tokenInput = ""
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
    private let tokenProvider: () -> String?
    private let transport: ((URLRequest) async throws -> (Data, URLResponse))?
    init(defaults: UserDefaults = .standard, startBackgroundTasks: Bool = true,
         collectMetadata: @escaping () -> Collection = { Metadata.collect() },
         tokenProvider: @escaping () -> String? = { Credential.load() },
         transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) {
        self.defaults = defaults; self.collectMetadata = collectMetadata
        self.tokenProvider = tokenProvider; self.transport = transport
        enabled = defaults.bool(forKey: "syncEnabled"); includeTitles = defaults.bool(forKey: "includeTitles")
        endpoint = defaults.string(forKey: "syncEndpoint") ?? ""; draftEndpoint = endpoint
        lastSync = defaults.object(forKey: "lastSync") as? Date; lastCount = defaults.integer(forKey: "lastCount")
        if !startBackgroundTasks { return }
        Task { await collect(); if enabled { syncNow() } }
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
        guard Self.syncURL(endpoint) != nil else { errorMessage = "同期先URLが未設定です"; showSettings = true; return }
        enabled = true; defaults.set(true, forKey: "syncEnabled"); syncNow()
    }
    func beginSettings() { pause(); draftEndpoint = endpoint; showSettings = true }
    func saveConnection() {
        guard Self.syncURL(draftEndpoint) != nil else { errorMessage = "HTTPSの /api/sync URLを指定してください"; return }
        guard tokenInput.count >= 32 else { errorMessage = "同期トークンは32文字以上必要です"; return }
        do {
            try Credential.save(tokenInput); tokenInput = ""; endpoint = draftEndpoint; defaults.set(endpoint, forKey: "syncEndpoint")
            digest = nil; errorMessage = nil; pause(); showSettings = false
        } catch { errorMessage = "キーチェーンへ保存できませんでした" }
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
        guard let url = Self.syncURL(endpoint), let token = tokenProvider(), token.count >= 32 else { errorMessage = "同期先・キーチェーンのトークンを確認してください"; status = "接続設定が必要"; return }
        do {
            let prepared = Metadata.prepared(snapshot, includeTitles: includeTitles)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let body = try encoder.encode(prepared)
            guard body.count <= 2 * 1024 * 1024, prepared.sessions.count <= 20000 else { errorMessage = "履歴が同期上限を超えています"; status = "送信失敗"; return }
            let nextDigest = Data(SHA256.hash(data: body))
            if nextDigest == digest { status = "変更なし・同期待機中"; return }
            status = "\(prepared.sessions.count)件を送信中"
            var request = URLRequest(url: url); request.httpMethod = "PUT"; request.httpBody = body; request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await (transport != nil ? transport!(request) : session.data(for: request))
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["ok"] as? Bool == true, json["count"] as? Int == prepared.sessions.count else { errorMessage = "サーバーが送信を受け付けませんでした"; status = "送信失敗"; return }
            digest = nextDigest; lastSync = Date(); lastCount = prepared.sessions.count
            defaults.set(lastSync, forKey: "lastSync"); defaults.set(lastCount, forKey: "lastCount")
            status = "送信完了・同期待機中"
        } catch is CancellationError { status = "送信は一時停止中" }
        catch { errorMessage = "通信に失敗しました。次回に再試行します"; status = "送信失敗" }
    }
    func openLocalCalendar() {
        do { try calendar.start(); NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(LocalCalendar.port)")!) }
        catch { errorMessage = "ローカルカレンダーを起動できませんでした" }
    }
    func openWebCalendar() {
        guard let url = Self.syncURL(endpoint), let host = url.host else { return }
        var components = URLComponents(); components.scheme = "https"; components.host = host; components.port = url.port
        if let web = components.url { NSWorkspace.shared.open(web) }
    }
    func registerLogin() {
        do { try SMAppService.mainApp.register() }
        catch { errorMessage = "ログイン時の起動を登録できませんでした" }
    }
}
@main struct SessionCalendarApp: App {
    @StateObject private var model: AppModel
    init() {
        if CommandLine.arguments.contains("--self-test") { BundleSelfTest.run() }
        _model = StateObject(wrappedValue: AppModel())
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
                else { Button("同期を有効にする") { model.enable() }.buttonStyle(.borderedProminent) }
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
                    SecureField("同期専用トークン", text: $model.tokenInput).textFieldStyle(.roundedBorder)
                    Button("接続設定をキーチェーンに保存") { model.saveConnection() }
                }
            }
            Divider()
            HStack {
                Menu("起動設定") {
                    Button("ログイン時に起動を登録") { model.registerLogin() }
                    Button("ログイン時に起動を解除") { do { try SMAppService.mainApp.unregister() } catch { model.errorMessage = "起動設定を解除できませんでした" } }
                }
                Spacer()
                Button("終了") { model.pause(); NSApplication.shared.terminate(nil) }
            }
        }.padding(Spacing.edge).frame(width: 400)
    }
}
