import Foundation

struct SessionRecord: Codable, Equatable {
    var id: String
    var tool: String
    var start: String
    var last_activity: String?
    var end: String? = nil
    var project: String
    var title: String
    enum CodingKeys: String, CodingKey { case id, tool, start, last_activity, end, project, title }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(tool, forKey: .tool); try c.encode(start, forKey: .start)
        if let last_activity { try c.encode(last_activity, forKey: .last_activity) } else { try c.encodeNil(forKey: .last_activity) }
        try c.encodeNil(forKey: .end); try c.encode(project, forKey: .project); try c.encode(title, forKey: .title)
    }
}
struct Snapshot: Codable {
    var sessions: [SessionRecord]
    var timezone = "Asia/Tokyo"
}
struct Collection {
    var snapshot: Snapshot
    var failures: Int
}
// Reads one line at a time; no conversation text is retained in the result.
final class JSONLines {
    private let handle: FileHandle
    private var buffer = Data()
    private var finished = false
    init(_ url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }
    func next() throws -> [String: Any]? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                let result = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                buffer.removeSubrange(...newline)
                if let result { return result }
                continue
            }
            if finished {
                if buffer.isEmpty { return nil }
                let line = buffer; buffer.removeAll()
                return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            }
            if let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty { buffer.append(chunk) }
            else { finished = true }
            if buffer.count > 32 * 1024 * 1024 { throw CocoaError(.fileReadTooLarge) }
        }
    }
}
enum Metadata {
    static func normalizedTitle(_ title: String) -> String {
        let cleaned = String(title.unicodeScalars.map { $0.value <= 0x1f ? " " : String($0) }.joined())
        var result = "", length = 0
        for character in cleaned {
            let units = character.utf16.count
            guard length + units <= 300 else { break }
            result.append(character); length += units
        }
        return result.isEmpty ? "無題" : result
    }
    static func projectLabel(_ path: String) -> String {
        let name = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "不明"
        return String(name.prefix(200))
    }
    static func prepared(_ snapshot: Snapshot, includeTitles: Bool) -> Snapshot {
        Snapshot(sessions: snapshot.sessions.map { row in
            var s = row; s.project = projectLabel(s.project); s.end = nil
            s.title = includeTitles ? normalizedTitle(s.title) : "\(s.tool) セッション \(s.id.prefix(8))"
            return s
        })
    }
    static func collect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Collection {
        var names: [String: [String: Any]] = [:], rows: [String: SessionRecord] = [:], failures = 0
        let index = home.appendingPathComponent(".codex/session_index.jsonl")
        if FileManager.default.fileExists(atPath: index.path) {
            do { let lines = try JSONLines(index); while let r = try lines.next() { if let id = r["id"] as? String { names[id] = r } } }
            catch { failures += 1 }
        }
        for (tool, relative) in [("Codex", ".codex/sessions"), ("Claude", ".claude/projects")] {
            let base = home.appendingPathComponent(relative)
            if !FileManager.default.fileExists(atPath: base.path) { continue }
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in failures += 1; return true }) else { failures += 1; continue }
            for case let file as URL in files where file.pathExtension == "jsonl" {
                if file.pathComponents.contains("subagents") { continue }
                do {
                    let lines = try JSONLines(file)
                    var id = file.deletingPathExtension().lastPathComponent, start: String?, last: String?, project = "", title = ""
                    if tool == "Codex" {
                        guard let r = try lines.next(), r["type"] as? String == "session_meta", let p = r["payload"] as? [String: Any] else { continue }
                        id = p["id"] as? String ?? p["session_id"] as? String ?? id
                        start = p["timestamp"] as? String ?? r["timestamp"] as? String
                        project = p["cwd"] as? String ?? ""
                        title = names[id]?["thread_name"] as? String ?? ""
                        last = names[id]?["updated_at"] as? String
                    } else {
                        while let r = try lines.next() {
                            if r["isSidechain"] as? Bool == true { continue }
                            id = r["sessionId"] as? String ?? id; project = r["cwd"] as? String ?? project
                            if ["user", "assistant"].contains(r["type"] as? String ?? ""), let ts = r["timestamp"] as? String {
                                start = min(start ?? ts, ts); last = max(last ?? ts, ts)
                            }
                            if r["type"] as? String == "custom-title" { title = r["customTitle"] as? String ?? title }
                        }
                    }
                    if let start {
                        rows[tool + ":" + id] = SessionRecord(id: id, tool: tool, start: start, last_activity: last, project: projectLabel(project), title: title.isEmpty ? "\(tool) セッション \(id.prefix(8))" : title)
                    }
                } catch { failures += 1 }
            }
        }
        return Collection(snapshot: Snapshot(sessions: rows.values.sorted { $0.start > $1.start }), failures: failures)
    }
}
