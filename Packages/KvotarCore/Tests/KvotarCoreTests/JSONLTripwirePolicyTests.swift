import XCTest
@testable import KvotarCore

/// REV-31 (STEP_38): JSONL tripwire — first local delta after an idle stretch cuts the poll
/// sleeper short, floored at 45s against the previous poll.
final class JSONLTripwirePolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFirstDeltaTrips() {
        var policy = JSONLTripwirePolicy()
        XCTAssertTrue(policy.deltaArrived(now: t0, lastPollAt: t0.addingTimeInterval(-120)),
                      "the first delta this launch is an idle→active transition")
    }

    func testSecondDeltaShortlyAfterDoesNotReFire() {
        var policy = JSONLTripwirePolicy()
        _ = policy.deltaArrived(now: t0, lastPollAt: t0.addingTimeInterval(-120))
        XCTAssertFalse(policy.deltaArrived(now: t0.addingTimeInterval(10),
                                           lastPollAt: t0.addingTimeInterval(2)),
                       "a burst of flushes must not hammer the endpoint — the session is now "
                       + "active, and the tripwire poll just fired anyway")
    }

    func testDeltaAfterIdleGapTrips() {
        var policy = JSONLTripwirePolicy()
        _ = policy.deltaArrived(now: t0, lastPollAt: nil)
        let resumed = t0.addingTimeInterval(JSONLTripwirePolicy.idleGap)
        XCTAssertTrue(policy.deltaArrived(now: resumed,
                                          lastPollAt: resumed.addingTimeInterval(-300)),
                      "a delta after ≥ 8 min of silence is the idle→active transition")
    }

    func testContinuouslyActiveSessionNeverTrips() {
        var policy = JSONLTripwirePolicy()
        _ = policy.deltaArrived(now: t0, lastPollAt: nil)
        for i in 1...20 {
            let now = t0.addingTimeInterval(TimeInterval(i) * 60)
            XCTAssertFalse(policy.deltaArrived(now: now, lastPollAt: now.addingTimeInterval(-50)),
                           "deltas a minute apart are one continuously active session — polling "
                           + "must stay on normal cadence, never pinned to the floor")
        }
    }

    func testFloorSuppressesATripAfterARecentPoll() {
        var policy = JSONLTripwirePolicy()
        XCTAssertFalse(policy.deltaArrived(now: t0, lastPollAt: t0.addingTimeInterval(-10)),
                       "a poll 10s ago is fresher than the 45s floor — the transition is real "
                       + "but the poll is not needed")
    }

    func testNilLastPollTrips() {
        var policy = JSONLTripwirePolicy()
        XCTAssertTrue(policy.deltaArrived(now: t0, lastPollAt: nil),
                      "no poll on record (first run, nothing restored) — nothing to floor against")
    }

    func testFloorSuppressionDoesNotConsumeTheTransition() {
        var policy = JSONLTripwirePolicy()
        _ = policy.deltaArrived(now: t0, lastPollAt: nil)
        // Idle 10 min, then a delta 10s after a poll: transition detected but floored…
        let resumed = t0.addingTimeInterval(600)
        XCTAssertFalse(policy.deltaArrived(now: resumed, lastPollAt: resumed.addingTimeInterval(-10)))
        // …and the next delta 30s later is within the new activity — no late double-fire.
        XCTAssertFalse(policy.deltaArrived(now: resumed.addingTimeInterval(30),
                                           lastPollAt: resumed.addingTimeInterval(-10)),
                       "the suppressed trip is not deferred — the next scheduled poll is near")
    }
}
