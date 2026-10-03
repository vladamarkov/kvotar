import XCTest
@testable import KvotarCLI

/// `capture` has no way on (STEP_242). Consent needs the app's expiring confirmation, so the CLI
/// can only turn capture off or report it, and `--enable` refuses with directions to the menu item.
final class CaptureCommandTests: XCTestCase {

    func testEnableIsRefused() {
        XCTAssertThrowsError(try Capture.parse(["--enable"]))
    }

    /// The refusal must say where capture is turned on, not just "no".
    func testEnableRefusalPointsToTheAppsMenuItem() {
        XCTAssertThrowsError(try Capture.parse(["--enable"])) { error in
            let message = Capture.message(for: error)
            XCTAssertTrue(message.contains("Enable Extended Diagnostics for 24 Hours…"), message)
            XCTAssertTrue(message.contains("menu-bar item"), message)
        }
    }

    /// Paired with another flag, `--enable` still refuses rather than tripping the generic guard.
    func testEnableWithAnotherFlagIsStillRefusedWithDirections() {
        XCTAssertThrowsError(try Capture.parse(["--enable", "--status"])) { error in
            XCTAssertEqual(Capture.message(for: error), Capture.enableRefusal)
        }
    }

    /// A non-zero exit, so a script that relied on `--enable` notices.
    func testEnableExitsNonZero() {
        XCTAssertThrowsError(try Capture.parse(["--enable"])) { error in
            XCTAssertNotEqual(Capture.exitCode(for: error), .success)
        }
    }

    func testDisableParses() throws {
        let command = try Capture.parse(["--disable"])
        XCTAssertTrue(command.disable)
    }

    func testStatusParses() throws {
        let command = try Capture.parse(["--status"])
        XCTAssertTrue(command.status)
    }

    func testNoFlagIsRefused() {
        XCTAssertThrowsError(try Capture.parse([]))
    }

    func testEnableIsNotInTheHelp() {
        XCTAssertFalse(Capture.helpMessage().contains("--enable"))
    }
}
