import XCTest
@testable import SessionCalendar

final class DotTaskPipelineTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func testNativeCollectorBuildsAnonymousWorkerPayloadAndRetainsProvenance() throws {
        let source = try fixture("dot-task-snapshot")
        let imported = try DotTaskSnapshot.decode(source)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let collection = Metadata.collect(home: home, dotTaskSnapshot: imported)
        XCTAssertEqual(collection.failures, 0)
        XCTAssertEqual(collection.snapshot.sessions.count, 1)
        let anonymous = Metadata.prepared(collection.snapshot, includeTitles: false)
        let data = try JSONEncoder.sorted.encode(anonymous)
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expectedData = try fixture("dot-task-native-payload")
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: expectedData) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: actual).isEqual(to: expected))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-only body"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("conversation"))

        if let output = ProcessInfo.processInfo.environment["DOT_TASK_PIPELINE_OUTPUT"] {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    func testMissingOrOldObservationIsNotReplacedByImportTime() throws {
        let noObservation = Data(#"{"tasks":[{"id":"fixture-task-1","attachedAt":"2026-10-03T01:00:00Z","latestTurn":{"status":"completed"}}]}"#.utf8)
        let first = try DotTaskSnapshot.decode(noObservation)
        let reread = try DotTaskSnapshot.decode(noObservation)
        XCTAssertNil(first.snapshotObservedAt)
        XCTAssertEqual(first, reread)

        let records = Metadata.collect(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), dotTaskSnapshot: first)
        let data = try JSONEncoder.sorted.encode(Metadata.prepared(records.snapshot, includeTitles: false))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let row = try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first)
        XCTAssertTrue(row["snapshot_observed_at"] is NSNull)
    }

    func testExplicitTitleConsentAndIDCollision() throws {
        var imported = try DotTaskSnapshot.decode(Data(#"{"tasks":[{"id":"fixture-task-1","attachedAt":"2026-10-03T01:00:00Z","latestTurn":{"status":"running"},"title":"Fixture task","project":"FixtureProject"}]}"#.utf8))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codex = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cli = #"{"type":"session_meta","timestamp":"2026-10-03T01:00:00Z","payload":{"id":"fixture-task-1","cwd":"/tmp/FixtureProject"}}"# + "\n"
        try Data(cli.utf8).write(to: codex.appendingPathComponent("cli.jsonl"))
        let collision = Metadata.collect(home: home, dotTaskSnapshot: imported)
        XCTAssertEqual(collision.failures, 1)
        XCTAssertFalse(collision.snapshot.sessions.contains { $0.source == "dot-task" })

        imported.tasks[0].id = "fixture-task-2"
        let noCollision = Metadata.collect(home: home, dotTaskSnapshot: imported)
        let anonymous = Metadata.prepared(noCollision.snapshot, includeTitles: false).sessions.first { $0.source == "dot-task" }
        XCTAssertEqual(anonymous?.title, "ChatGPT タスク e-task-2")
        let consented = Metadata.prepared(noCollision.snapshot, includeTitles: true).sessions.first { $0.source == "dot-task" }
        XCTAssertEqual(consented?.title, "Fixture task")
    }

    func testMalformedDuplicateAndMissingRequiredMetadataAreRejected() throws {
        XCTAssertThrowsError(try DotTaskSnapshot.decode(Data("{bad".utf8)))
        let duplicate = #"{"tasks":[{"id":"same","attachedAt":"2026-10-03T01:00:00Z","latestTurn":{"status":"completed"}},{"id":"same","attachedAt":"2026-10-03T01:00:00Z","latestTurn":{"status":"running"}}]}"#
        XCTAssertThrowsError(try DotTaskSnapshot.decode(Data(duplicate.utf8)))
        let missingStatus = #"{"tasks":[{"id":"missing-status","attachedAt":"2026-10-03T01:00:00Z","latestTurn":{}}]}"#
        XCTAssertThrowsError(try DotTaskSnapshot.decode(Data(missingStatus.utf8)))
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }
}
