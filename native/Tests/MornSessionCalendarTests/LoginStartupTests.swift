import XCTest
import ServiceManagement
@testable import MornSessionCalendar

@MainActor final class LoginStartupTests: XCTestCase {
    func testLoginRegistrationUsesOSStateAndNeverUnregisters() {
        var status: SMAppService.Status = .notRegistered
        var registrations = 0, settings = 0
        let model = AppModel(startBackgroundTasks: false,
            loginStatusProvider: { status }, loginRegister: { registrations += 1; status = .enabled },
            openLoginSettings: { settings += 1 })
        XCTAssertEqual(model.loginLabel, "ログイン時に起動：オフ")
        model.registerLogin(); model.registerLogin()
        XCTAssertEqual(model.loginStatus, .enabled); XCTAssertEqual(registrations, 1)
        XCTAssertEqual(model.loginLabel, "ログイン時に起動：オン")
        status = .requiresApproval; model.refreshLoginStatus(); model.registerLogin()
        XCTAssertEqual(model.loginLabel, "ログイン時に起動：承認待ち")
        XCTAssertEqual(registrations, 1); XCTAssertEqual(settings, 1)
    }
    func testRegistrationRefreshesApprovalAndFailureWithoutInventingEnabledState() {
        var status: SMAppService.Status = .notRegistered, settings = 0
        let model = AppModel(startBackgroundTasks: false, loginStatusProvider: { status },
            loginRegister: { status = .requiresApproval }, openLoginSettings: { settings += 1 })
        model.registerLogin()
        XCTAssertEqual(model.loginStatus, .requiresApproval); XCTAssertEqual(settings, 1)
        let failing = AppModel(startBackgroundTasks: false, loginStatusProvider: { .notRegistered },
            loginRegister: { throw NSError(domain: "fixture", code: 1) }, openLoginSettings: { XCTFail() })
        failing.registerLogin()
        XCTAssertEqual(failing.loginStatus, .notRegistered); XCTAssertNotNil(failing.errorMessage)
    }
}
