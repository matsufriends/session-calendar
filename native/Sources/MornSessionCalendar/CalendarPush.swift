import Foundation
import CryptoKit

/// Optional upload of the merged sessions to a self-hosted viewer (e.g. MornUsage /calendar).
/// Enabled only when ~/.config/morn-session-calendar/push.json exists: {"url": "https://.../api/sessions/push", "token": "..."}.
enum CalendarPush {
    struct Target { let url: URL; let token: String }
    static func target(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Target? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".config/morn-session-calendar/push.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = (json["url"] as? String).flatMap(URL.init(string:)), url.scheme == "https",
              let token = json["token"] as? String, !token.isEmpty else { return nil }
        return Target(url: url, token: token)
    }
    static func body(_ sessions: [SessionRecord]) -> Data? { try? JSONEncoder().encode(Snapshot(sessions: sessions)) }
    static func digest(_ body: Data) -> Data { Data(SHA256.hash(data: body)) }
    static func send(_ body: Data, to target: Target) async -> Bool {
        var request = URLRequest(url: target.url, timeoutInterval: 30)
        request.httpMethod = "PUT"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + target.token, forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
