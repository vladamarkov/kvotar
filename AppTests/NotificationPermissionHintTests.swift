import XCTest
import UserNotifications

// STEP_150 (D-103): the Notify me ▸ denied-permission hint shows for exactly one status.
final class NotificationPermissionHintTests: XCTestCase {

    func testDeniedShowsTheHint() {
        XCTAssertTrue(NotificationPermissionHint.showsHint(for: .denied))
    }

    func testEveryOtherStatusStaysSilent() {
        for status: UNAuthorizationStatus in [.notDetermined, .authorized, .provisional] {
            XCTAssertFalse(NotificationPermissionHint.showsHint(for: status), "\(status)")
        }
    }

    func testCopyNamesTheSystemNotOurSwitches() {
        XCTAssertEqual(NotificationPermissionHint.title, "Off in System Settings — Open…")
        XCTAssertEqual(NotificationPermissionHint.settingsURL.scheme, "x-apple.systempreferences")
        XCTAssertEqual(NotificationPermissionHint.deniedParentTitle, "Notify me — off in System Settings")
        XCTAssertEqual(NotificationPermissionHint.parentTitle, "Notify me")
    }

    // MARK: D-127 (STEP_225) — the permission and the style, read together

    func testDeniedIsOffWhateverTheStyle() {
        for style: UNAlertStyle in [.none, .banner, .alert] {
            XCTAssertEqual(NotificationPermissionHint.reading(status: .denied, alertStyle: style), .off)
        }
    }

    func testAllowedButNoneIsOff() {
        XCTAssertEqual(NotificationPermissionHint.reading(status: .authorized, alertStyle: .none), .off)
    }

    func testAllowedBannersHint() {
        XCTAssertEqual(NotificationPermissionHint.reading(status: .authorized, alertStyle: .banner), .banners)
    }

    func testAlertsAndUnaskedAreFine() {
        XCTAssertEqual(NotificationPermissionHint.reading(status: .authorized, alertStyle: .alert), .fine)
        for style: UNAlertStyle in [.none, .banner, .alert] {
            XCTAssertEqual(NotificationPermissionHint.reading(status: .notDetermined, alertStyle: style), .fine)
        }
    }

    func testBannersCopy() {
        XCTAssertEqual(NotificationPermissionHint.bannersTitle,
                       "Warnings hide after a few seconds — Keep them on screen…")
    }
}
