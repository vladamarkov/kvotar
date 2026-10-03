import XCTest
@testable import KvotarCore

/// REV-32 (STEP_38): reset-boundary one-shot — a single poll at `max(resets_at+30s, now+5s)`
/// when a known reset lands before the next scheduled tick; each boundary attempted once.
final class ResetBoundaryPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testBoundaryBeforeNextTickSchedulesOneShot() {
        var policy = ResetBoundaryPolicy()
        let resets = t0.addingTimeInterval(90)
        let delay = policy.oneShotDelay(primaryResetsAt: resets, weeklyResetsAt: nil,
                                        now: t0, plannedDelay: 120)
        XCTAssertEqual(delay, 120, "resets in 90s < 120s tick → one-shot at resets+30 = 120s")
    }

    func testBoundaryAfterNextTickKeepsThePlan() {
        var policy = ResetBoundaryPolicy()
        let resets = t0.addingTimeInterval(600)
        XCTAssertNil(policy.oneShotDelay(primaryResetsAt: resets, weeklyResetsAt: nil,
                                         now: t0, plannedDelay: 120),
                     "the normal tick lands first — no one-shot")
    }

    func testNoKnownResetNoOneShot() {
        var policy = ResetBoundaryPolicy()
        XCTAssertNil(policy.oneShotDelay(primaryResetsAt: nil, weeklyResetsAt: nil,
                                         now: t0, plannedDelay: 120))
    }

    func testWeeklyUsedWhenSooner() {
        var policy = ResetBoundaryPolicy()
        let primary = t0.addingTimeInterval(400)
        let weekly = t0.addingTimeInterval(60)
        let delay = policy.oneShotDelay(primaryResetsAt: primary, weeklyResetsAt: weekly,
                                        now: t0, plannedDelay: 120)
        XCTAssertEqual(delay, 90, "weekly resets sooner → boundary is the weekly (60+30)")
    }

    func testFloorAgainstThePreviousPoll() {
        var policy = ResetBoundaryPolicy()
        let resets = t0.addingTimeInterval(5)
        let delay = policy.oneShotDelay(primaryResetsAt: resets, weeklyResetsAt: nil,
                                        now: t0, plannedDelay: 120)
        XCTAssertEqual(delay, PollBackoffPolicy.minInterval,
                       "resets+30 = 35s undercuts the 45s floor against the poll that just fired")
    }

    func testSameBoundaryNeverFiresTwice() {
        var policy = ResetBoundaryPolicy()
        let resets = t0.addingTimeInterval(90)
        XCTAssertNotNil(policy.oneShotDelay(primaryResetsAt: resets, weeklyResetsAt: nil,
                                            now: t0, plannedDelay: 120))
        // The one-shot fires at t0+120; the payload still carries the old resets_at (R33-7 shape).
        let afterOneShot = t0.addingTimeInterval(120)
        XCTAssertNil(policy.oneShotDelay(primaryResetsAt: resets, weeklyResetsAt: nil,
                                         now: afterOneShot, plannedDelay: 120),
                     "a stale post-rollover payload must not loop the one-shot every 45s")
    }

    func testEarlyPollBeforeBoundaryReArms() {
        var policy = ResetBoundaryPolicy()
        let resets = t0.addingTimeInterval(90)
        XCTAssertNotNil(policy.oneShotDelay(primaryResetsAt: resets, weeklyResetsAt: nil,
                                            now: t0, plannedDelay: 120))
        // A tripwire/wake poll lands at t0+40 — before the boundary. The one-shot was cancelled
        // with the sleeper, so it must re-arm for the same (still-future) boundary.
        let early = t0.addingTimeInterval(40)
        XCTAssertEqual(policy.oneShotDelay(primaryResetsAt: resets, weeklyResetsAt: nil,
                                           now: early, plannedDelay: 120), 80,
                       "boundary not yet polled past → re-schedule (50s to reset + 30)")
    }

    func testNewBoundaryAfterConsumedOneSchedules() {
        var policy = ResetBoundaryPolicy()
        let resets = t0.addingTimeInterval(90)
        _ = policy.oneShotDelay(primaryResetsAt: resets, weeklyResetsAt: nil,
                                now: t0, plannedDelay: 120)
        let afterOneShot = t0.addingTimeInterval(120)
        _ = policy.oneShotDelay(primaryResetsAt: resets, weeklyResetsAt: nil,
                                now: afterOneShot, plannedDelay: 120)
        // Next poll carries the next 5-hour window's reset, again landing inside the tick.
        let nextResets = resets.addingTimeInterval(18_000)
        let later = nextResets.addingTimeInterval(-60)
        XCTAssertEqual(policy.oneShotDelay(primaryResetsAt: nextResets, weeklyResetsAt: nil,
                                           now: later, plannedDelay: 120), 90,
                       "a genuinely new boundary schedules its own one-shot")
    }
}
