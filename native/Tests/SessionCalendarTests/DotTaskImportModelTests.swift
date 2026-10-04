import XCTest
import Foundation
import CryptoKit
@testable import SessionCalendar

private final class FirstTaskASnapshotGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let returned = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false
    private var didBlock = false

    func arm() {
        lock.lock(); defer { lock.unlock() }
        armed = true
    }

    func behavior(_ imported: DotTaskSnapshot?) -> Int {
        guard imported?.tasks.map(\.id) == ["task-a"] else { return 0 }
        lock.lock(); defer { lock.unlock() }
        guard armed else { return 0 }
        if !didBlock { didBlock = true; return 1 }
        return 2
    }
}

private func modelCollection(_ imported: DotTaskSnapshot?, failForTaskB: Bool = false) -> Collection {
    let rows = (imported?.tasks ?? []).map { task in
        SessionRecord(id: task.id, tool: "ChatGPT", start: task.attachedAt, last_activity: nil,
                      project: task.project, title: task.title, source: "dot-task",
                      task_registered_at: task.attachedAt, latest_turn_status: task.latestTurnStatus,
                      snapshot_observed_at: imported?.snapshotObservedAt)
    }
    let collides = failForTaskB && imported?.tasks.contains(where: { $0.id == "task-b" }) == true
    return Collection(snapshot: Snapshot(sessions: rows), failures: collides ? 1 : 0)
}

private func codexCollection(_ count: Int) -> Collection {
    let rows = (0..<count).map { index in
        SessionRecord(id: "cli-fixture-\(index)", tool: "Codex", start: "2026-10-04T00:00:00Z",
                      last_activity: "2026-10-04T00:01:00Z", project: "Fixture", title: "Fixture")
    }
    return Collection(snapshot: Snapshot(sessions: rows), failures: 0)
}

private final class SyncTransportLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var nonces = Set<String>()
    private var acceptedCounts = [Int]()
    private var successfulChecks = 0

    var lastAcceptedCount: Int? {
        lock.lock(); defer { lock.unlock() }
        return acceptedCounts.last
    }

    var checkCount: Int {
        lock.lock(); defer { lock.unlock() }
        return successfulChecks
    }

    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        if url.path.hasSuffix("/sessions") { return (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!) }
        if request.value(forHTTPHeaderField: "X-Sync-Signature") == String(repeating: "0", count: 128) {
            return (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        let nonce = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Sync-Nonce"))
        lock.lock()
        let inserted = nonces.insert(nonce).inserted
        lock.unlock()
        if !inserted { return (Data(), HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: nil)!) }
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        if url.path.hasSuffix("/check") {
            guard payload["check"] as? Bool == true else { return (Data(), HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!) }
            lock.lock(); successfulChecks += 1; lock.unlock()
            return (Data("{\"ok\":true,\"check\":true}".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let count = try XCTUnwrap(payload["sessions"] as? [[String: Any]]).count
        lock.lock(); acceptedCounts.append(count); lock.unlock()
        return (Data("{\"ok\":true,\"count\":\(count)}".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor final class DotTaskImportModelTests: XCTestCase {
    private func oldSnapshot() throws -> Data {
        let snapshot = DotTaskSnapshot(snapshotObservedAt: "2026-10-03T01:00:00Z", tasks: [
            DotTaskMetadata(id: "task-a", attachedAt: "2026-10-03T00:00:00Z",
                            latestTurnStatus: "completed", title: "Fixture A", project: "Fixture")
        ])
        return try JSONEncoder().encode(snapshot)
    }

    private func importedFile(_ ids: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let tasks = ids.map { "{\"id\":\"\($0)\",\"attachedAt\":\"2026-10-04T00:00:00Z\",\"latestTurn\":{\"status\":\"running\"},\"title\":\"Fixture B\",\"project\":\"Fixture\"}" }.joined(separator: ",")
        let contents = """
        {"snapshot_observed_at":"2026-10-04T01:00:00Z","tasks":[\(tasks)]}
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
            let model = AppModel(defaults: defaults, startBackgroundTasks: false,
                                 collectMetadata: { imported in
                return modelCollection(imported, failForTaskB: true)
            })
            let url = try importedFile(["task-b"])
            defer { try? FileManager.default.removeItem(at: url) }

            model.importDotSnapshot(.success([url]))
            await model.waitForDotSnapshotForTesting()
            XCTAssertFalse(model.busy)
            XCTAssertTrue(model.hasDotTaskSnapshot)
            XCTAssertEqual(try XCTUnwrap(defaults.data(forKey: "dotTaskSnapshot")), savedA)
            XCTAssertEqual(model.enabled, wasEnabled)
            XCTAssertEqual(defaults.bool(forKey: "syncEnabled"), wasEnabled)
            XCTAssertNotNil(model.errorMessage)

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
        let url = try importedFile(["task-b"])
        defer { try? FileManager.default.removeItem(at: url) }
        model.busy = true

        model.importDotSnapshot(.success([url]))
        model.clearDotSnapshot()

        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.hasDotTaskSnapshot)
        XCTAssertEqual(try XCTUnwrap(defaults.data(forKey: "dotTaskSnapshot")), savedA)
    }

    func testOlderRefreshCannotOverwriteNewerImport() async throws {
        let suite = "dot-import.fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try oldSnapshot(), forKey: "dotTaskSnapshot")
        defaults.set(false, forKey: "syncEnabled")
        let gate = FirstTaskASnapshotGate()
        let startedA = expectation(description: "refresh captured task-a")
        let model = AppModel(defaults: defaults, startBackgroundTasks: false,
                             collectMetadata: { imported in
            if gate.behavior(imported) == 1 {
                startedA.fulfill()
                gate.started.signal()
                _ = gate.release.wait(timeout: .now() + 5)
                gate.returned.signal()
            }
            return modelCollection(imported)
        })
        let url = try importedFile(["task-c", "task-d"])
        defer { try? FileManager.default.removeItem(at: url) }

        gate.arm()
        model.refresh()
        await fulfillment(of: [startedA], timeout: 2)
        model.importDotSnapshot(.success([url]))
        await model.waitForDotSnapshotForTesting()
        XCTAssertEqual(model.dotTaskCount, 2)

        gate.release.signal()
        XCTAssertEqual(gate.returned.wait(timeout: .now() + 2), .success)
        await model.waitForRefreshForTesting()

        XCTAssertEqual(model.dotTaskCount, 2, "older refresh must not restore task-a after the import")
        let stored = try XCTUnwrap(defaults.data(forKey: "dotTaskSnapshot"))
        XCTAssertEqual(try JSONDecoder().decode(DotTaskSnapshot.self, from: stored).tasks.map(\.id), ["task-c", "task-d"])
    }

    func testOlderRefreshCannotRestoreSnapshotAfterClear() async throws {
        let suite = "dot-import.fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try oldSnapshot(), forKey: "dotTaskSnapshot")
        let gate = FirstTaskASnapshotGate()
        let startedA = expectation(description: "refresh captured task-a")
        let model = AppModel(defaults: defaults, startBackgroundTasks: false,
                             collectMetadata: { imported in
            if gate.behavior(imported) == 1 {
                startedA.fulfill()
                gate.started.signal()
                _ = gate.release.wait(timeout: .now() + 5)
                gate.returned.signal()
            }
            return modelCollection(imported)
        })

        gate.arm()
        model.refresh()
        await fulfillment(of: [startedA], timeout: 2)
        model.clearDotSnapshot()
        await model.waitForDotSnapshotForTesting()
        XCTAssertFalse(model.hasDotTaskSnapshot)
        XCTAssertNil(defaults.data(forKey: "dotTaskSnapshot"))

        gate.release.signal()
        XCTAssertEqual(gate.returned.wait(timeout: .now() + 2), .success)
        await model.waitForRefreshForTesting()

        XCTAssertEqual(model.dotTaskCount, 0, "older refresh must not restore the cleared task")
        XCTAssertNil(defaults.data(forKey: "dotTaskSnapshot"))
    }

    func testSyncCollectSupersedesOlderRefresh() async throws {
        let suite = "dot-import.fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try oldSnapshot(), forKey: "dotTaskSnapshot")
        defaults.set(false, forKey: "syncEnabled")
        let gate = FirstTaskASnapshotGate()
        let startedA = expectation(description: "old refresh captured task-a")
        let ledger = SyncTransportLedger()
        let model = AppModel(defaults: defaults, startBackgroundTasks: false,
                             collectMetadata: { imported in
            if gate.behavior(imported) == 1 {
                startedA.fulfill()
                gate.started.signal()
                _ = gate.release.wait(timeout: .now() + 5)
                gate.returned.signal()
                return codexCollection(1)
            }
            return codexCollection(gate.behavior(imported) == 2 ? 2 : 1)
        }, keyAuthorizer: { P256.Signing.PrivateKey() },
           transport: { request in try ledger.respond(request) })
        model.endpoint = "https://fixture.invalid/api/sync"

        model.enable()
        await model.waitForSyncForTesting()
        XCTAssertTrue(model.enabled)
        XCTAssertEqual(ledger.checkCount, 1, "sync enable must complete the signed non-mutating handshake")

        gate.arm()
        model.refresh()
        await fulfillment(of: [startedA], timeout: 2)

        model.syncNow()
        await model.waitForSyncForTesting()
        XCTAssertEqual(ledger.lastAcceptedCount, 2)
        XCTAssertEqual(model.codexCount, 2, "sync's newer collection should be visible before the old refresh returns")

        gate.release.signal()
        XCTAssertEqual(gate.returned.wait(timeout: .now() + 2), .success)
        await model.waitForRefreshForTesting()
        XCTAssertEqual(model.codexCount, 2, "an older refresh must not overwrite the completed sync collection")
    }

    func testRefreshSupersedesInitialRead() async throws {
        let suite = "dot-import.fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try oldSnapshot(), forKey: "dotTaskSnapshot")
        let gate = FirstTaskASnapshotGate()
        gate.arm()
        let startedA = expectation(description: "initial read captured task-a")
        let model = AppModel(defaults: defaults, startBackgroundTasks: true,
                             collectMetadata: { imported in
            if gate.behavior(imported) == 1 {
                startedA.fulfill()
                gate.started.signal()
                _ = gate.release.wait(timeout: .now() + 5)
                gate.returned.signal()
                return codexCollection(1)
            }
            return codexCollection(2)
        })
        defer { model.shutdown() }

        await fulfillment(of: [startedA], timeout: 2)
        model.refresh()
        await model.waitForRefreshForTesting()
        XCTAssertEqual(model.codexCount, 2)

        gate.release.signal()
        XCTAssertEqual(gate.returned.wait(timeout: .now() + 2), .success)
        await model.waitForInitialReadForTesting()
        XCTAssertEqual(model.codexCount, 2, "the initial read must not overwrite a newer refresh")
    }
}
