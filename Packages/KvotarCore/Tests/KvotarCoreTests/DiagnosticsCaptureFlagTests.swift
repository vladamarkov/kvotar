import XCTest
@testable import KvotarCore

/// §10.7a — the capture flag and the build channel (REV-52, STEP_72).
final class DiagnosticsCaptureFlagTests: XCTestCase {

    override func tearDown() {
        DiagnosticsCapture.setEnabled(false)
        super.tearDown()
    }

    func testStoredValueInterpretation() {
        XCTAssertTrue(DiagnosticsCapture.isEnabled("1"))
        XCTAssertFalse(DiagnosticsCapture.isEnabled("0"))
        XCTAssertFalse(DiagnosticsCapture.isEnabled(nil), "absent ⇒ off")
        XCTAssertFalse(DiagnosticsCapture.isEnabled("true"), "only \"1\" is on, as for DebugMode")
    }

    func testLiveFlagRoundTrips() {
        XCTAssertFalse(DiagnosticsCapture.isEnabled)
        DiagnosticsCapture.setEnabled(true)
        XCTAssertTrue(DiagnosticsCapture.isEnabled)
        DiagnosticsCapture.setEnabled(false)
        XCTAssertFalse(DiagnosticsCapture.isEnabled)
    }

    func testCaptureAndDebugAreSeparateKeys() {
        XCTAssertNotEqual(DiagnosticsCapture.settingsKey, DebugMode.settingsKey)
        XCTAssertNotEqual(DiagnosticsCapture.darwinNotificationName,
                          DebugMode.darwinNotificationName)
    }

    /// STEP_205: three Darwin names, all distinct. The other two are level-triggered re-reads of a
    /// settings row; the hand-off is an action with no row behind it, so a collision would not
    /// merely duplicate work — it would open a window on a debug-flag change.
    func testAllThreeDarwinNamesAreDistinct() {
        let names = [DebugMode.darwinNotificationName,
                     DiagnosticsCapture.darwinNotificationName,
                     QuotaHandoff.darwinNotificationName]
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testChannelDefaultsToReleaseWhenUnset() {
        XCTAssertEqual(BuildChannel.current(bundle: Bundle(for: Self.self)), .release,
                       "a bundle with no channel key is a release build — never a beta one")
        XCTAssertFalse(BuildChannel.release.seedsDiagnosticsOn)
        XCTAssertFalse(BuildChannel.beta.seedsDiagnosticsOn,
                       "raw capture is off by default in every build")
        XCTAssertTrue(BuildChannel.beta.seedsDebugOn)
    }

    func testAuthorizationRequiresFutureExpiryAndClampsToTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(DiagnosticsCapture.isAuthorized(
            storedValue: "1", expiresAtValue: nil, now: now))
        XCTAssertFalse(DiagnosticsCapture.isAuthorized(
            storedValue: "1", expiresAtValue: "1799999999", now: now))
        XCTAssertTrue(DiagnosticsCapture.isAuthorized(
            storedValue: "1", expiresAtValue: "1800000060", now: now))

        DiagnosticsCapture.setEnabled(
            true, expiresAt: now.addingTimeInterval(7 * 86_400), now: now)
        XCTAssertEqual(DiagnosticsCapture.expiresAt, now.addingTimeInterval(86_400))
    }

    func testVersionStringCarriesChannelOnlyForBeta() {
        XCTAssertEqual(
            ForecastLogRecorder.appVersionString(shortVersion: "0.1.2", build: "3"),
            "0.1.2 (3)")
        XCTAssertEqual(
            ForecastLogRecorder.appVersionString(shortVersion: "0.1.2", build: "3",
                                                 channel: .beta),
            "0.1.2 (3) beta")
    }

    func testEndpointIdentityMapping() {
        func id(_ s: String) -> String {
            DiagnosticsEndpoint.claudeEndpoint(for: URL(string: s)!)
        }
        XCTAssertEqual(id("https://api.anthropic.com/api/oauth/usage"), "claude_usage")
        XCTAssertEqual(id("https://api.anthropic.com/api/oauth/profile"), "claude_profile")
        XCTAssertEqual(
            id("https://api.anthropic.com/api/oauth/organizations/abc-123/prepaid/credits"),
            "claude_prepaid")
        XCTAssertEqual(id("https://api.anthropic.com/api/oauth/something_new"), "claude_other",
                       "an unmapped endpoint is still captured, under a known-unknown name")
    }
}
