import Foundation

/// Lists Codex threads hosted in the cloud (ChatGPT desktop "Long-lived" host), which never reach ~/.codex.
// ponytail: unofficial endpoint and handshake copied from the ChatGPT desktop app; expect breakage when the app changes.
enum CodexCloud {
    static let endpoint = URL(string: "wss://codex-cloud-backend.chatgpt.com/")!
    /// nil means the cloud list could not be read (signed out, network, or protocol change).
    static func threads(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> [SessionRecord]? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".codex/auth.json")),
              let tokens = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, let account = tokens["account_id"] as? String else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue(["codex-app-server", "codex-client.desktop", "openai-bearer." + token].joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue("codex", forHTTPHeaderField: "X-OpenAI-Product-Sku")
        request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        do {
            _ = try await call(socket, id: 0, method: "initialize", params: ["clientInfo": ["name": "session-calendar", "title": NSNull(), "version": "0"]])
            try await socket.send(.string(#"{"method":"initialized"}"#))
            var rows: [SessionRecord] = [], cursor: Any = NSNull(), id = 1
            repeat {
                let result = try await call(socket, id: id, method: "thread/list", params: ["limit": 100, "archived": false, "cursor": cursor])
                id += 1
                rows += (result["data"] as? [[String: Any]] ?? []).compactMap(record)
                cursor = result["nextCursor"] as? String ?? NSNull()
            } while cursor is String && id < 50
            return rows
        } catch { return nil }
    }
    /// User work only: ChatGPT task threads ("aeon" roots and their children); skips automatic "dreaming" memory runs.
    static func record(_ thread: [String: Any]) -> SessionRecord? {
        guard let id = thread["id"] as? String, let created = thread["createdAt"] as? Double,
              ["aeon", "aeon_child"].contains(thread["threadSource"] as? String ?? "") else { return nil }
        let iso = ISO8601DateFormatter()
        let updated = (thread["updatedAt"] as? Double).map { iso.string(from: Date(timeIntervalSince1970: $0)) }
        let title = [thread["name"], thread["preview"]].lazy.compactMap { Metadata.promptTitle($0) }.first ?? "作業名不明"
        return SessionRecord(id: id, tool: "Codex", start: iso.string(from: Date(timeIntervalSince1970: created)), last_activity: updated,
                             project: Metadata.projectLabel(thread["cwd"] as? String ?? ""), title: Metadata.normalizedTitle(title))
    }
    private static func call(_ socket: URLSessionWebSocketTask, id: Int, method: String, params: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["method": method, "id": id, "params": params])
        try await socket.send(.string(String(decoding: body, as: UTF8.self)))
        while true {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["id"] as? Int == id else { continue }
            guard let result = json["result"] as? [String: Any] else { throw URLError(.badServerResponse) }
            return result
        }
    }
}
