import XCTest
@testable import SessionCalendar
final class MetadataTests: XCTestCase {
    func testPreparedSnapshotOmitsTitleAndAbsolutePathAndHasNullTimes() throws {
        let input = SessionRecord(id: "fixture-session", tool: "Codex", start: "2026-10-03T01:00:00Z", last_activity: nil, project: "/Users/person/PrivateProject", title: "confidential title")
        let result = Metadata.prepared(Snapshot(sessions: [input]), includeTitles: false)
        let data = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["project"] as? String, "PrivateProject")
        XCTAssertEqual(rows[0]["title"] as? String, "Codex セッション fixture-")
        XCTAssertTrue(rows[0]["end"] is NSNull)
        XCTAssertTrue(rows[0]["last_activity"] is NSNull)
        XCTAssertEqual(Set(rows[0].keys), Set(["id","tool","start","last_activity","end","project","title"]))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("/Users/"))
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
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = repository.appendingPathComponent("tests/fixtures/session-dates.json")
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
    func testEndpointRejectsPlainHTTPEmbeddedCredentialQueryAndRedirectTarget() async {
        await MainActor.run {
            XCTAssertNotNil(AppModel.syncURL("https://calendar.example/api/sync"))
            for value in ["http://calendar.example/api/sync", "https://user:secret@calendar.example/api/sync", "https://calendar.example/wrong", "https://calendar.example/api/sync?token=secret"] { XCTAssertNil(AppModel.syncURL(value)) }
        }
    }
}
