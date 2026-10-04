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
    private static func instant(_ value: Any?) -> (date: Date, text: String)? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(\.(\d+))?)?(Z|[+-]\d{2}:?\d{2})$"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func component(_ index: Int, default defaultValue: Int? = nil) -> Int? {
            guard let range = Range(match.range(at: index), in: text) else { return defaultValue }
            return Int(text[range])
        }
        guard let year = component(1), (1...9999).contains(year),
              let month = component(2), (1...12).contains(month),
              let day = component(3), (1...31).contains(day),
              let hour = component(4), (0...24).contains(hour),
              let minute = component(5), (0...59).contains(minute),
              let second = component(6, default: 0), (0...59).contains(second) else { return nil }
        let fraction = match.range(at: 7).location == NSNotFound ? "" : String(text[Range(match.range(at: 7), in: text)!])
        let fractionDigits = match.range(at: 8).location == NSNotFound ? nil : String(text[Range(match.range(at: 8), in: text)!])
        guard hour != 24 || (minute == 0 && second == 0 && (fractionDigits == nil || fractionDigits!.allSatisfy { $0 == "0" })) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var wallTime = DateComponents()
        wallTime.calendar = calendar; wallTime.timeZone = calendar.timeZone
        wallTime.year = year; wallTime.month = month; wallTime.day = day
        wallTime.hour = hour == 24 ? 0 : hour; wallTime.minute = minute; wallTime.second = second
        guard let checked = calendar.date(from: wallTime) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: checked)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day,
              roundTrip.hour == (hour == 24 ? 0 : hour), roundTrip.minute == minute, roundTrip.second == second else { return nil }
        var normalized = text
        if hour == 24 {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: checked) else { return nil }
            let next = calendar.dateComponents([.year, .month, .day], from: tomorrow)
            guard let year = next.year, let month = next.month, let day = next.day,
                  let zoneRange = Range(match.range(at: 9), in: text) else { return nil }
            let zone = String(text[zoneRange])
            normalized = String(format: "%04d-%02d-%02dT00:%02d:%02d%@%@", year, month, day, minute, second, fraction, zone)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        if let date = fractional.date(from: normalized) ?? ordinary.date(from: normalized) { return (date, text) }
        return nil
    }
    static func projectLabel(_ path: String) -> String {
        let name = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "不明"
        return String(name.prefix(200))
    }
    static func prepared(_ snapshot: Snapshot, includeTitles: Bool) -> Snapshot {
        Snapshot(sessions: snapshot.sessions.map { row in
            var s = row; s.project = projectLabel(s.project); s.end = nil
            s.title = includeTitles ? String(s.title.prefix(300)) : "\(s.tool) セッション \(s.id.prefix(8))"
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
                    var id = file.deletingPathExtension().lastPathComponent, start: (date: Date, text: String)?, last: (date: Date, text: String)?, project = "", title = ""
                    if tool == "Codex" {
                        guard let r = try lines.next(), r["type"] as? String == "session_meta", let p = r["payload"] as? [String: Any] else { continue }
                        id = p["id"] as? String ?? p["session_id"] as? String ?? id
                        start = instant(p["timestamp"] as? String ?? r["timestamp"])
                        project = p["cwd"] as? String ?? ""
                        title = names[id]?["thread_name"] as? String ?? ""
                        last = instant(names[id]?["updated_at"])
                    } else {
                        while let r = try lines.next() {
                            if r["isSidechain"] as? Bool == true { continue }
                            id = r["sessionId"] as? String ?? id; project = r["cwd"] as? String ?? project
                            if ["user", "assistant"].contains(r["type"] as? String ?? ""), let parsed = instant(r["timestamp"]) {
                                if start == nil || parsed.date < start!.date { start = parsed }
                                if last == nil || parsed.date > last!.date { last = parsed }
                            }
                            if r["type"] as? String == "custom-title" { title = r["customTitle"] as? String ?? title }
                        }
                    }
                    if let start {
                        rows[tool + ":" + id] = SessionRecord(id: id, tool: tool, start: start.text, last_activity: last?.text, project: projectLabel(project), title: title.isEmpty ? "\(tool) セッション \(id.prefix(8))" : title)
                    }
                } catch { failures += 1 }
            }
        }
        return Collection(snapshot: Snapshot(sessions: rows.values.sorted { (instant($0.start)?.date ?? .distantPast) > (instant($1.start)?.date ?? .distantPast) }), failures: failures)
    }
}
