import XCTest
@testable import MornSessionCalendar

@MainActor
final class UpdaterTests: XCTestCase {
    func testVersionAndProcessFailures() async throws {
        XCTAssertTrue(Updater.isNewer(latestTag: "v0.10.0", current: "0.9.9"))
        XCTAssertFalse(Updater.isNewer(latestTag: "v0.3", current: "0.3.0"))
        XCTAssertFalse(Updater.isNewer(latestTag: "v0.2.9", current: "0.3.0"))
        for invalid in ["", "v", "1..2", "1.-2.3", "+1.0", "1.0-beta", "99999999999999999999999", "１.0"] {
            XCTAssertNil(Updater.parseVersion(invalid), invalid)
        }
        try await Updater.run("/usr/bin/true", [])
        do {
            try await Updater.run("/usr/bin/false", [])
            XCTFail("更新コマンドの失敗を成功扱いしてはいけません")
        } catch { }
        do {
            try await Updater.run("/missing-morn-session-calendar-command", [])
            XCTFail("起動できないコマンドを成功扱いしてはいけません")
        } catch { }
    }
}
