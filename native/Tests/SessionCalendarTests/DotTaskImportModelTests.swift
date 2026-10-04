import XCTest
@testable import SessionCalendar

@MainActor final class DotTaskImportModelTests: XCTestCase {
    private func oldSnapshot() throws -> Data {
        let snapshot = DotTaskSnapshot(snapshotObservedAt: "2026-10-03T01:00:00Z", tasks: [
            DotTaskMetadata(id: "task-a", attachedAt: "2026-10-03T00:00:00Z",
                            latestTurnStatus: "completed", title: "Fixture A", project: "Fixture")
        ])
        return try JSONEncoder().encode(snapshot)
    }

    private func importedFile(_ id: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let contents = """
        {"snapshot_observed_at":"2026-10-04T01:00:00Z","tasks":[{"id":"\(id)","attachedAt":"2026-10-04T00:00:00Z","latestTurn":{"status":"running"},"title":"Fixture B","project":"Fixture"}]}
        """
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testCollisionKeepsPreviousSnapshotAndSyncPreferenceOnAndOff() async throws {
        for wasEnabled in [false, true] {
            let suite = "dot-import.fixture." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let savedA = try oldSnapshot()
            defaults.set(savedA, forKey: "dotTaskSnapshot")
            defaults.set(wasEnabled, forKey: "syncEnabled")
            let retainedA = expectation(description: "refresh still receives task-a")
            let model = AppModel(defaults: defaults, startBackgroundTasks: false,
                                 collectMetadata: { imported in
                if imported?.tasks.map(\.id) == ["task-a"] { retainedA.fulfill() }
                let rows = (imported?.tasks ?? []).map { task in
                    SessionRecord(id: task.id, tool: "ChatGPT", start: task.attachedAt, last_activity: nil,
                                  project: task.project, title: task.title, source: "dot-task",
                                  task_registered_at: task.attachedAt, latest_turn_status: task.latestTurnStatus,
                                  snapshot_observed_at: imported?.snapshotObservedAt)
                }
                let collides = imported?.tasks.contains(where: { $0.id == "task-b" }) == true
                return Collection(snapshot: Snapshot(sessions: rows), failures: collides ? 1 : 0)
            })
            let url = try importedFile("task-b")
            defer { try? FileManager.default.removeItem(at: url) }

            model.importDotSnapshot(.success([url]))
            await model.waitForDotSnapshotForTesting()
            XCTAssertFalse(model.busy)
            XCTAssertTrue(model.hasDotTaskSnapshot)
            XCTAssertEqual(try XCTUnwrap(defaults.data(forKey: "dotTaskSnapshot")), savedA)
            XCTAssertEqual(model.enabled, wasEnabled)
            XCTAssertEqual(defaults.bool(forKey: "syncEnabled"), wasEnabled)
            XCTAssertNotNil(model.errorMessage)

            model.refresh()
            await fulfillment(of: [retainedA], timeout: 1)
            XCTAssertEqual(model.enabled, wasEnabled)
        }
    }

    func testImportAndClearAreIgnoredWhileAppModelIsBusy() throws {
        let suite = "dot-import.fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let savedA = try oldSnapshot()
        defaults.set(savedA, forKey: "dotTaskSnapshot")
        let model = AppModel(defaults: defaults, startBackgroundTasks: false,
                             collectMetadata: { _ in XCTFail("busy import or clear must not collect"); return Collection(snapshot: Snapshot(sessions: []), failures: 0) })
        let url = try importedFile("task-b")
        defer { try? FileManager.default.removeItem(at: url) }
        model.busy = true

        model.importDotSnapshot(.success([url]))
        model.clearDotSnapshot()

        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.hasDotTaskSnapshot)
        XCTAssertEqual(try XCTUnwrap(defaults.data(forKey: "dotTaskSnapshot")), savedA)
    }
}
