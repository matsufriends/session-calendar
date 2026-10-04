import XCTest
@testable import SessionCalendar
final class CodexCloudTests: XCTestCase {
    func testOnlyTaskThreadsBecomeSessions() throws {
        let task = try XCTUnwrap(CodexCloud.record(["id": "a", "createdAt": 1791130405.0, "updatedAt": 1791130812.0, "threadSource": "aeon_child", "name": "更新する カレンダー", "cwd": "/tmp/Codex/task-1"]))
        XCTAssertEqual(task.tool, "Codex"); XCTAssertEqual(task.title, "更新する カレンダー"); XCTAssertEqual(task.project, "task-1")
        XCTAssertEqual(task.start, "2026-10-04T16:13:25Z"); XCTAssertEqual(task.last_activity, "2026-10-04T16:20:12Z")
        XCTAssertEqual(CodexCloud.record(["id": "b", "createdAt": 1.0, "threadSource": "aeon", "preview": "最初の依頼\n詳細"])?.title, "最初の依頼")
        XCTAssertNil(CodexCloud.record(["id": "c", "createdAt": 1.0, "threadSource": "dreaming", "name": "memory"]))
    }
}
