import XCTest
@testable import KvotarCore

/// First-run-vs-idle classification (STEP_30, Baseline §13.3). The rule is tool-agnostic — it
/// applies identically to Claude and Codex — so these cover the full truth table once; the
/// per-tool rendering distinction is exercised in `AppViewModelTests` (applyUndetected vs
/// applyUnavailable).
final class DetectionStatusTests: XCTestCase {

    func testSetupRequiredNoActivityIsFirstRun() {
        // No credential AND no local JSONL ever seen → the tool was never detected.
        XCTAssertEqual(
            DetectionStatus.classify(error: AccountAdapterError.setupRequired, hasLocalActivity: false),
            .firstRun)
    }

    func testSetupRequiredWithLocalActivityIsIdle() {
        // Credential missing but JSONL activity was observed this launch → detected, just idle.
        XCTAssertEqual(
            DetectionStatus.classify(error: AccountAdapterError.setupRequired, hasLocalActivity: true),
            .idle)
    }

    /// STEP_117 / REV-71 §2.5 — the correlated-failure case that produced the false first-run.
    ///
    /// On 2026-08-17 the process had no free file descriptors, so the credential read could not be
    /// *attempted* **and** the JSONL watchers could not open their roots. Both of `classify`'s
    /// inputs were therefore wrong for the same reason, and the user saw the first-run welcome on
    /// a machine where both tools were signed in. The rule is unchanged; what fixes this is that
    /// an unattemptable read now arrives as `credentialUnreadable`, which is not `setupRequired`
    /// and so cannot reach `.firstRun` no matter what `hasLocalActivity` says.
    func testCredentialUnreadableIsNeverFirstRunEvenWithNoLocalActivity() {
        for hasLocalActivity in [false, true] {
            XCTAssertEqual(
                DetectionStatus.classify(
                    error: AccountAdapterError.credentialUnreadable("security tool would not launch"),
                    hasLocalActivity: hasLocalActivity),
                .idle,
                "a failure to look must never be reported as a failure to find")
        }
    }

    func testNonSetupErrorIsIdle() {
        // A reachable-but-failing account (decoding / HTTP / re-auth) is not "undetected".
        for error: AccountAdapterError in [.httpStatus(500), .reauthRequired, .decoding("x"),
                                           .rateLimited(retryAfter: 60, details: nil)] {
            XCTAssertEqual(
                DetectionStatus.classify(error: error, hasLocalActivity: false), .idle,
                "\(error) with no local activity is idle, not first-run")
        }
    }
}
