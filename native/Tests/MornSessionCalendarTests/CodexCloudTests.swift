import XCTest
@testable import MornSessionCalendar
final class CodexCloudTests: XCTestCase {
    func testOnlyTaskThreadsBecomeSessions() throws {
        let task = try XCTUnwrap(CodexCloud.record(["id": "a", "createdAt": 1791130405.0, "updatedAt": 1791130812.0, "threadSource": "aeon_child", "name": "更新する カレンダー", "cwd": "/tmp/Codex/task-1"]))
        XCTAssertEqual(task.tool, "Codex"); XCTAssertEqual(task.title, "更新する カレンダー"); XCTAssertEqual(task.project, "task-1")
        XCTAssertEqual(task.start, "2026-10-04T16:13:25Z"); XCTAssertEqual(task.last_activity, "2026-10-04T16:20:12Z")
        XCTAssertEqual(CodexCloud.record(["id": "b", "createdAt": 1.0, "threadSource": "aeon", "preview": "最初の依頼\n詳細"])?.title, "最初の依頼")
        XCTAssertNil(CodexCloud.record(["id": "c", "createdAt": 1.0, "threadSource": "dreaming", "name": "memory"]))
    }
}
final class CalendarPushTests: XCTestCase {
    func testTargetRequiresHTTPSAndToken() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(CalendarPush.target(home: home))
        let dir = home.appendingPathComponent(".config/morn-session-calendar")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("push.json")
        try Data(#"{"url":"http://example.test/api/sessions/push","token":"t"}"#.utf8).write(to: file)
        XCTAssertNil(CalendarPush.target(home: home))
        try Data(#"{"url":"https://example.test/api/sessions/push","token":"t"}"#.utf8).write(to: file)
        XCTAssertEqual(CalendarPush.target(home: home)?.url.host, "example.test")
    }
}
