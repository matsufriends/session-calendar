import XCTest
@testable import MornSessionCalendar
final class SessionTitleTests: XCTestCase {
    func testOfficialTitles() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "session-titles", withExtension: "json", subdirectory: "Fixtures"))
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let cases = try XCTUnwrap(data["cases"] as? [[String: Any]])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var index: [[String: Any]] = []
        for item in cases {
            let id = try XCTUnwrap(item["id"] as? String), tool = try XCTUnwrap(item["tool"] as? String)
            let base = root.appendingPathComponent(tool == "Codex" ? ".codex/sessions" : ".claude/projects/fixture")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let records = try XCTUnwrap(item["records"] as? [[String: Any]])
            let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n" }.joined() + (item["raw_records"] as? [String] ?? []).map { $0 + "\n" }.joined()
            try Data(lines.utf8).write(to: base.appendingPathComponent(id + ".jsonl"))
            if let row = item["index"] as? [String: Any] { index.append(row) }
        }
        let lines = try index.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n" }.joined()
        try Data(lines.utf8).write(to: root.appendingPathComponent(".codex/session_index.jsonl"))
        let collection = Metadata.collect(home: root)
        XCTAssertEqual(collection.failures, 0)
        let rows = Dictionary(uniqueKeysWithValues: collection.snapshot.sessions.map { ($0.id, $0) })
        for item in cases {
            let id = try XCTUnwrap(item["id"] as? String)
            XCTAssertEqual(rows[id]?.title, Metadata.normalizedTitle(try XCTUnwrap(item["expected"] as? String)))
        }
        for row in collection.snapshot.sessions {
            XCTAssertLessThanOrEqual(row.title.utf16.count, 300)
            XCTAssertFalse(row.title.unicodeScalars.contains { $0.value <= 0x1f })
        }
    }
}
