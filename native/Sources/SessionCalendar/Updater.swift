import AppKit

@MainActor
final class Updater: ObservableObject {
    enum State {
        case idle, checking, upToDate, available(String), updating, updated, failed(String)
    }
    @Published private(set) var state: State = .idle
    init(state: State = .idle) { self.state = state }
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開発版"
    private static let cask = "tsukumistudio/tap/session-calendar"
    private static let appPath = "/Applications/SessionCalendar.app"

    static func parseVersion(_ raw: String) -> [Int]? {
        let text = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    static func isNewer(latestTag: String, current: String) -> Bool {
        guard let latest = parseVersion(latestTag), let current = parseVersion(current) else { return false }
        for index in 0..<max(latest.count, current.count) {
            let lhs = index < latest.count ? latest[index] : 0
            let rhs = index < current.count ? current[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    func check() async {
        if case .checking = state { return }
        if case .updating = state { return }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/matsufriends/session-calendar/releases/latest")!)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("SessionCalendar", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 404 { state = .failed("公開リリースはまだありません"); return }
            guard http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  Self.parseVersion(tag) != nil, Self.parseVersion(Self.version) != nil
            else { throw URLError(.badServerResponse) }
            state = Self.isNewer(latestTag: tag, current: Self.version) ? .available(tag) : .upToDate
        } catch { state = .failed("更新を確認できませんでした。通信状態を確認してください。") }
    }

    func update() async {
        guard case .available(let target) = state else { return }
        guard Bundle.main.bundlePath == Self.appPath,
              let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            state = .failed("Homebrew版を /Applications にインストールしてください。")
            return
        }
        state = .updating
        do {
            try await Self.run(brew, ["list", "--cask", Self.cask])
            try await Self.run(brew, ["update"])
            try await Self.run(brew, ["upgrade", "--cask", Self.cask])
            let plist = URL(fileURLWithPath: Self.appPath).appendingPathComponent("Contents/Info.plist")
            let data = try Data(contentsOf: plist)
            let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            guard let installed = info?["CFBundleShortVersionString"] as? String,
                  Self.isNewer(latestTag: installed, current: Self.version),
                  !Self.isNewer(latestTag: target, current: installed) else {
                state = .failed("Homebrewにはまだ更新が届いていません。後ほど再確認してください。")
                return
            }
            state = .updated
        } catch { state = .failed("更新に失敗しました。Homebrewの状態を確認してください。") }
    }

    // Output goes to /dev/null: no pipe buffer can block a long brew update.
    static func run(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            process.terminationHandler = { task in
                if task.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: NSError(domain: "Homebrew", code: Int(task.terminationStatus))) }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    func restart() {
        guard case .updated = state else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open /Applications/SessionCalendar.app"]
        do { try process.run(); NSApp.terminate(nil) }
        catch { state = .failed("手動でアプリを再起動してください。") }
    }
}
