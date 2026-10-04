import SwiftUI
import AppKit
import ServiceManagement

enum Spacing {
    static let edge: CGFloat = 24
    static let panel: CGFloat = 16
    static let gap: CGFloat = 8
}
@MainActor final class AppModel: ObservableObject {
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published var status = "ローカル履歴を確認中"
    @Published var codexCount = 0
    @Published var claudeCount = 0
    @Published var busy = false
    @Published var errorMessage: String?
    private let loginStatusProvider: () -> SMAppService.Status
    private let loginRegister: () throws -> Void
    private let openLoginSettings: () -> Void
    private let collectMetadata: () -> Collection
    private let calendar = LocalCalendar()
    private var refreshTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    init(startBackgroundTasks: Bool = true,
         collectMetadata: @escaping () -> Collection = { Metadata.collect() },
         loginStatusProvider: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         loginRegister: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         openLoginSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }) {
        self.collectMetadata = collectMetadata; self.loginStatusProvider = loginStatusProvider
        self.loginRegister = loginRegister; self.openLoginSettings = openLoginSettings
        loginStatus = loginStatusProvider()
        guard startBackgroundTasks else { return }
        do { try calendar.start() } catch { errorMessage = "127.0.0.1:\(LocalCalendar.port) で待ち受けできません" }
        refresh()
        periodicTask = Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(300)); refresh() } }
    }
    var icon: String { busy ? "arrow.triangle.2.circlepath" : errorMessage != nil ? "exclamationmark.triangle" : "calendar" }
    func refresh() {
        guard !busy else { return }
        busy = true
        let collector = collectMetadata
        refreshTask = Task {
            let result = await Task.detached(priority: .utility) { collector() }.value
            busy = false
            calendar.update(result.snapshot)
            codexCount = result.snapshot.sessions.filter { $0.tool == "Codex" }.count
            claudeCount = result.snapshot.sessions.filter { $0.tool == "Claude" }.count
            errorMessage = result.failures > 0 ? "一部の履歴を読み取れませんでした" : nil
            status = "Claude \(claudeCount)件・Codex \(codexCount)件"
        }
    }
    func waitForRefreshForTesting() async { await refreshTask?.value }
    func openCalendar() { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(LocalCalendar.port)")!) }
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
            Label("Session Calendar", systemImage: "calendar").font(.headline)
            Text(model.status).font(.callout)
            if let error = model.errorMessage { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Button("カレンダーを開く") { model.openCalendar() }.buttonStyle(.borderedProminent)
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
        .padding(Spacing.edge).frame(width: 360)
    }
    private var moreMenu: some View {
        Menu {
            Button("履歴を再読取") { model.refresh() }.disabled(model.busy)
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
