import XCTest
import KvotarCore

// STEP_143 (REV-79 / D-100): the first-run window's launch gate. Compiled into this bundle the
// same way as the presenter — no store, no window, no app launch.
final class OnboardingGateTests: XCTestCase {

    func testAbsentKeyOpensTheWindow() {
        XCTAssertEqual(OnboardingGate.decide(onboardingCompleted: false), .openWindow)
    }

    func testPresentKeyRequestsAuthorizationInstead() {
        XCTAssertEqual(OnboardingGate.decide(onboardingCompleted: true), .requestAuthorization)
    }

    // STEP_145: Skip / Open Kvotar persist the key only when a tool is detected.
    func testCompletionPersistsWithADetectedTool() {
        XCTAssertTrue(OnboardingGate.shouldPersistCompletion(detectedTools: [.claude]))
    }

    func testCompletionDoesNotPersistOnAnEmptyMachine() {
        XCTAssertFalse(OnboardingGate.shouldPersistCompletion(detectedTools: []))
    }
}
