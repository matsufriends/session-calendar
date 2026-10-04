import XCTest
@testable import SessionCalendar
final class MetadataTests: XCTestCase {
    func testTitleNormalizationFixtures() throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "title-normalization", withExtension: "json", subdirectory: "Fixtures"))
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [[String: Any]])
        for fixture in fixtures {
            func expanded(_ value: Any) throws -> String {
                if let string = value as? String { return string }
                let parts = try XCTUnwrap(value as? [String: Any])
                let repeated = try XCTUnwrap(parts["repeat"] as? String)
                let count = try XCTUnwrap(parts["count"] as? Int)
                return String(repeating: repeated, count: count) + (parts["suffix"] as? String ?? "")
            }
            let input = try expanded(XCTUnwrap(fixture["input"]))
            let expected = try expanded(XCTUnwrap(fixture["expected"]))
            let title = Metadata.normalizedTitle(input)
            XCTAssertEqual(title, expected, fixture["name"] as? String ?? "fixture")
            XCTAssertLessThanOrEqual(title.utf16.count, 300)
            XCTAssertFalse(title.unicodeScalars.contains { $0.value <= 0x1f })
        }
    }
    func testBothSourcesWithArtificialMetadataOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent(".codex/sessions")
        let claude = root.appendingPathComponent(".claude/projects/example")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let meta = "{\"type\":\"session_meta\",\"timestamp\":\"2026-10-03T01:00:00Z\",\"payload\":{\"id\":\"codex-fixture\",\"cwd\":\"/tmp/Example\"}}\n"
        try Data(meta.utf8).write(to: codex.appendingPathComponent("fixture.jsonl"))
        let rows = "{\"type\":\"user\",\"sessionId\":\"claude-fixture\",\"timestamp\":\"2026-10-03T02:00:00Z\",\"cwd\":\"/tmp/Example\",\"message\":\"never expose\"}\n{\"type\":\"assistant\",\"timestamp\":\"2026-10-03T03:00:00Z\"}\n"
        try Data(rows.utf8).write(to: claude.appendingPathComponent("fixture.jsonl"))
        let result = Metadata.collect(home: root)
        XCTAssertEqual(result.failures, 0); XCTAssertEqual(result.snapshot.sessions.count, 2)
        XCTAssertEqual(Set(result.snapshot.sessions.map(\.tool)), Set(["Codex","Claude"]))
        XCTAssertEqual(result.snapshot.sessions.first?.last_activity, "2026-10-03T03:00:00Z")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result.snapshot), as: UTF8.self).contains("never expose"))
    }
    func testSharedDateFixtureUsesInstantsAndSkipsOnlyInvalidStart() throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "session-dates", withExtension: "json", subdirectory: "Fixtures"))
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        let cases = try XCTUnwrap(fixture["sessions"] as? [[String: Any]])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent(".claude/projects/fixture")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        for item in cases {
            let id = try XCTUnwrap(item["id"] as? String)
            let events = try XCTUnwrap(item["events"] as? [[String: Any]])
            let lines = try events.map { event -> String in
                var row = event
                row["sessionId"] = id
                row["cwd"] = "/tmp/fixture"
                row["message"] = "private body"
                let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                return String(decoding: data, as: UTF8.self)
            }.joined(separator: "\n") + "\n"
            try Data(lines.utf8).write(to: claude.appendingPathComponent("\(id).jsonl"))
        }
        let result = Metadata.collect(home: root)
        let rows = Dictionary(uniqueKeysWithValues: result.snapshot.sessions.map { ($0.id, $0) })
        XCTAssertEqual(Set(rows.keys), Set(cases.compactMap { $0["expected_start"] is NSNull ? nil : $0["id"] as? String }))
        for item in cases where !(item["expected_start"] is NSNull) {
            let id = try XCTUnwrap(item["id"] as? String)
            let row = try XCTUnwrap(rows[id])
            XCTAssertEqual(row.start, item["expected_start"] as? String)
            XCTAssertEqual(row.last_activity, item["expected_last_activity"] as? String)
        }
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result.snapshot), as: UTF8.self).contains("private body"))
    }
    func testCodexPayloadJSONNullFallsBackToOuterTimestamp() throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "session-dates", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let metadata = try XCTUnwrap(fixture["codex_timestamp_fallback"] as? [String: Any])
        let record = try XCTUnwrap(metadata["record"] as? [String: Any])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let line = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self) + "\n"
        try Data(line.utf8).write(to: codex.appendingPathComponent("fixture.jsonl"))
        let result = Metadata.collect(home: root)
        XCTAssertEqual(result.snapshot.sessions.first?.start, metadata["expected_start"] as? String)
    }
    func testUnnamedSessionsUsePromptAndAutomationIsSkipped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent(".codex/sessions"), claude = root.appendingPathComponent(".claude/projects/example")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        func meta(_ id: String, _ source: String) -> String { "{\"type\":\"session_meta\",\"timestamp\":\"2026-10-03T01:00:00Z\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/tmp/Example\",\"source\":\(source)}}\n" }
        let user = { (text: String) in "{\"timestamp\":\"2026-10-03T01:00:01Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"\(text)\"}]}}\n" }
        try Data((meta("cli", "\"cli\"") + user("# AGENTS.md instructions") + user("<environment_context>") + user("画面を直して\\n詳細") + "{\"timestamp\":\"2026-10-03T02:30:00Z\",\"type\":\"event_msg\",\"payload\":{}}\n").utf8).write(to: codex.appendingPathComponent("cli.jsonl"))
        try Data(meta("exec", "\"exec\"").utf8).write(to: codex.appendingPathComponent("exec.jsonl"))
        try Data(meta("sub", "{\"subagent\":{}}").utf8).write(to: codex.appendingPathComponent("sub.jsonl"))
        let claudeRows = "{\"type\":\"user\",\"sessionId\":\"claude\",\"timestamp\":\"2026-10-03T03:00:00Z\",\"message\":{\"content\":\"<command-name>/clear</command-name>\"}}\n{\"type\":\"user\",\"timestamp\":\"2026-10-03T03:01:00Z\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"カレンダーを作って\"}]}}\n"
        try Data(claudeRows.utf8).write(to: claude.appendingPathComponent("claude.jsonl"))
        let rows = Dictionary(uniqueKeysWithValues: Metadata.collect(home: root).snapshot.sessions.map { ($0.id, $0) })
        XCTAssertEqual(Set(rows.keys), ["cli", "claude"])
        XCTAssertEqual(rows["cli"]?.title, "画面を直して")
        XCTAssertEqual(rows["cli"]?.last_activity, "2026-10-03T02:30:00Z")
        XCTAssertEqual(rows["claude"]?.title, "カレンダーを作って")
    }
}
