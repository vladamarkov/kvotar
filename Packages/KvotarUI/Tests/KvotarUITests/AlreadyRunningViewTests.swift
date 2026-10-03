import XCTest
@testable import KvotarUI

/// The second-instance copy (Baseline §9.2 Display). Until 2026-08-24 one sentence named both
/// products, so a tester on a Mac that never ran AgentPilot was told their problem might involve an
/// app they had never installed. The rule that replaced it is the thing worth pinning: **each
/// variant names the app the user has to quit, and the common one names nothing else.**
final class AlreadyRunningViewTests: XCTestCase {

    /// The case every clean install can reach — and the only one it can reach, since the legacy
    /// lock does not exist until AgentPilot's folder does. It must not mention the old product.
    func testSecondKvotarNamesOnlyKvotar() {
        let message = AlreadyRunningView.Conflict.kvotarInstance.message
        XCTAssertEqual(message, "Kvotar is already running. Only one instance polls at a time.")
        XCTAssertFalse(message.contains("AgentPilot"),
                       "a Mac that never ran AgentPilot must never be shown its name")
    }

    /// The cross-version case names AgentPilot deliberately — the user cannot act on "one of two
    /// apps is running", which is what the old shared sentence amounted to here.
    func testLegacyConflictNamesAgentPilotAndSaysToQuitIt() {
        let message = AlreadyRunningView.Conflict.legacyAgentPilot.message
        XCTAssertEqual(message, "AgentPilot is already running. Quit it before starting Kvotar. "
                       + "Only one app polls at a time.")
        XCTAssertTrue(message.contains("Quit it"),
                      "it must say which app to quit, not that one of two is running")
    }

    /// The old-name audit pins the legacy sentence with `^…$` against `/usr/bin/strings` output of
    /// the built app, and `strings` ends a run at the first non-ASCII byte. An em dash — the house
    /// punctuation everywhere else — would split the sentence in two, so the anchored rule could
    /// never match and `build_friend.sh` / `sign_and_notarize.sh` would fail, long after
    /// `swift test` went green. Caught exactly that way on 2026-08-24.
    func testLegacySentenceStaysReadableToTheReleaseAudit() {
        let message = AlreadyRunningView.Conflict.legacyAgentPilot.message
        XCTAssertFalse(message.contains("\n"), "the audit's anchored pattern matches a single line")
        XCTAssertTrue(message.allSatisfy(\.isASCII),
                      "a non-ASCII byte truncates the string `strings` reports, and the audit "
                      + "pattern is anchored on the whole sentence")
    }
}
