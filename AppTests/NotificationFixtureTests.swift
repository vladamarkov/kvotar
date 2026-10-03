import XCTest
import KvotarCore

/// STEP_233: the debug notification fixture (`KVOTAR_NOTIFICATION_FIXTURE`). A fixture states
/// the state its own numbers produce (PATTERNS.md) — each script is run through the real
/// `NotificationEngine` and must deliver exactly what its name claims, or the live check that
/// uses it would be looking at something the engine never decides.
final class NotificationFixtureTests: XCTestCase {

    private final class Recorder: NotificationPresenter, @unchecked Sendable {
        private let lock = NSLock()
        private var _decisions: [NotificationDecision] = []
        func present(_ decision: NotificationDecision) async {
            lock.withLock { _decisions.append(decision) }
        }
        var decisions: [NotificationDecision] { lock.withLock { _decisions } }
    }

    private func play(_ fixture: NotificationFixture) async -> [NotificationDecision] {
        let recorder = Recorder()
        await fixture.play(presenter: recorder, startDelay: 0, spacing: 0)
        return recorder.decisions
    }

    func testLadderStepsSendsHalfThenQuarterAndNothingAfter() async {
        let sent = await play(.ladderSteps)
        XCTAssertEqual(sent.map(\.eventType), [.limitAheadOfPace, .limitAheadOfPace])
        XCTAssertEqual(sent.map(\.copyVariant), ["half", "quarter"])
        XCTAssertEqual(sent.map(\.tool), [.claude, .claude])
        XCTAssertEqual(sent.map { $0.longLimit?.limit }, [.secondary, .secondary])
    }

    func testAFirstReadingAtNinetyTwoSendsNearlySpentAlone() async {
        let sent = await play(.weeklyOnlyNearlySpent)
        XCTAssertEqual(sent.map(\.eventType), [.limitNearlySpent])
        XCTAssertEqual(sent.first?.longLimit?.limit, .primary)
        XCTAssertEqual(sent.first.map(UserNotificationPresenter.title), "Codex weekly nearly spent")
    }

    /// STEP_238: the poll that turns the weekly-only tab red sends nearly spent with it —
    /// event 2 is still never sent there, and the notice no longer waits for 90 %.
    func testAWeeklyOnlyEightyFiveSendsNearlySpentAndNoBadTimingNotice() async {
        let sent = await play(.weeklyOnlyBadTiming)
        XCTAssertEqual(sent.map(\.eventType), [.limitNearlySpent])
        XCTAssertEqual(sent.first?.longLimit?.limit, .primary)
        XCTAssertEqual(sent.first.map(UserNotificationPresenter.title), "Codex weekly nearly spent")
        let body = sent.first.map { UserNotificationPresenter.body(for: $0, includeProject: false) }
        XCTAssertEqual(body?.hasPrefix("15% of the weekly left, "), true, body ?? "nil")
    }

    func testEveryFixtureIsNamedAndAnUnknownNameIsNone() {
        XCTAssertEqual(NotificationFixture.allCases.count, 3)
        XCTAssertNil(NotificationFixture(rawValue: "no-such-fixture"))
    }
}
