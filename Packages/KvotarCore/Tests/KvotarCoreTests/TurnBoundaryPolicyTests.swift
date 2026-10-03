import XCTest
@testable import KvotarCore

/// REV-53 §4 (STEP_77): turn-boundary alignment — when local activity stops, one floor-respecting
/// poll places an interval boundary at the front edge of the pause that follows, so the STEP_76
/// recompute gets a whole classifiable interval out of it.
final class TurnBoundaryPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let resets = Date(timeIntervalSince1970: 1_700_010_000)
    private let floor = PollBackoffPolicy.minInterval

    /// A policy that has seen one poll on a live window — the normal armed state.
    private func armedPolicy() -> TurnBoundaryPolicy {
        var policy = TurnBoundaryPolicy()
        policy.pollCompleted(primaryResetsAt: resets)
        return policy
    }

    // MARK: - Trailing edge

    func testFlushSchedulesAFireAtTheQuietDelay() {
        let policy = armedPolicy()
        XCTAssertEqual(policy.activityObserved(now: t0, latestEventAt: t0),
                       TurnBoundaryPolicy.quietDelay,
                       "a flush arms the quiet timer — it does not itself fire")
    }

    func testEveryFlushKeepsRearmingTheTimer() {
        let policy = armedPolicy()
        // The driver replaces its pending timer on each of these, so a burst never fires.
        for offset in stride(from: 0.0, through: 100.0, by: 20.0) {
            XCTAssertEqual(policy.activityObserved(now: t0.addingTimeInterval(offset),
                                                   latestEventAt: t0.addingTimeInterval(offset)),
                           TurnBoundaryPolicy.quietDelay,
                           "mid-burst flushes re-arm; only the surviving timer fires")
        }
    }

    func testCatchUpBacklogIsNotATurnBoundary() {
        let policy = armedPolicy()
        let stale = t0.addingTimeInterval(-TurnBoundaryPolicy.maxActivityAge - 1)
        XCTAssertNil(policy.activityObserved(now: t0, latestEventAt: stale),
                     "a rescan replaying an old file is not a turn ending now — aligning a "
                     + "boundary to it buys nothing and would spend a fire")
    }

    func testFireAfterTheQuietStretch() {
        var policy = armedPolicy()
        let fireAt = t0.addingTimeInterval(TurnBoundaryPolicy.quietDelay)
        XCTAssertTrue(policy.fire(now: fireAt, lastPollAt: t0.addingTimeInterval(-120),
                                  floor: floor))
    }

    // MARK: - Floor

    func testFloorSuppressesAFireAfterARecentPoll() {
        var policy = armedPolicy()
        XCTAssertFalse(policy.fire(now: t0, lastPollAt: t0.addingTimeInterval(-10), floor: floor),
                       "a poll 10s ago already placed a boundary — the 45s floor holds")
    }

    func testSuppressedFireIsNotSpent() {
        var policy = armedPolicy()
        XCTAssertFalse(policy.fire(now: t0, lastPollAt: t0.addingTimeInterval(-10), floor: floor))
        XCTAssertTrue(policy.fire(now: t0.addingTimeInterval(60),
                                  lastPollAt: t0.addingTimeInterval(-10), floor: floor),
                      "a floored fire consumes neither the arm nor a slot of the cap")
    }

    func testElevatedLadderFloorSuppressesTheFire() {
        var policy = armedPolicy()
        XCTAssertFalse(policy.fire(now: t0, lastPollAt: t0.addingTimeInterval(-60), floor: 300),
                       "while the transient 429 ladder is elevated the floor rises to the ladder "
                       + "delay — cutting that wait short is the eager re-hit STEP_42 warned about")
    }

    func testNoPollOnRecordHasNothingToFloorAgainst() {
        var policy = armedPolicy()
        XCTAssertTrue(policy.fire(now: t0, lastPollAt: nil, floor: floor))
    }

    // MARK: - Re-arm discipline

    func testOnlyOneFireBetweenTwoPolls() {
        var policy = armedPolicy()
        XCTAssertTrue(policy.fire(now: t0, lastPollAt: nil, floor: floor))
        XCTAssertNil(policy.activityObserved(now: t0.addingTimeInterval(120),
                                             latestEventAt: t0.addingTimeInterval(120)),
                     "spent — no timer is armed until a poll completes")
        XCTAssertFalse(policy.fire(now: t0.addingTimeInterval(200), lastPollAt: nil, floor: floor))
        policy.pollCompleted(primaryResetsAt: resets)
        XCTAssertTrue(policy.fire(now: t0.addingTimeInterval(300), lastPollAt: nil, floor: floor),
                      "the completed poll re-arms exactly one further alignment poll")
    }

    func testNothingFiresBeforeTheFirstPollOfTheLaunch() {
        var policy = TurnBoundaryPolicy()
        XCTAssertNil(policy.activityObserved(now: t0, latestEventAt: t0))
        XCTAssertFalse(policy.fire(now: t0, lastPollAt: nil, floor: floor),
                       "the first poll is deliberately delayed to respect the persisted poll "
                       + "clock (R33-5) — an alignment poll must not defeat it")
    }

    // MARK: - Per-window cap

    func testCapBindsWithinAWindow() {
        var policy = armedPolicy()
        for i in 0..<TurnBoundaryPolicy.maxFiresPerWindow {
            XCTAssertTrue(policy.fire(now: t0, lastPollAt: nil, floor: floor), "fire \(i + 1)")
            policy.pollCompleted(primaryResetsAt: resets)
        }
        XCTAssertEqual(policy.firesSpentThisWindow, TurnBoundaryPolicy.maxFiresPerWindow)
        XCTAssertNil(policy.activityObserved(now: t0, latestEventAt: t0))
        XCTAssertFalse(policy.fire(now: t0, lastPollAt: nil, floor: floor),
                       "the cap is the step's remedy lever — it must actually bind")
    }

    func testNewWindowRefillsTheCap() {
        var policy = armedPolicy()
        for _ in 0..<TurnBoundaryPolicy.maxFiresPerWindow {
            _ = policy.fire(now: t0, lastPollAt: nil, floor: floor)
            policy.pollCompleted(primaryResetsAt: resets)
        }
        policy.pollCompleted(primaryResetsAt: resets.addingTimeInterval(18_000))
        XCTAssertEqual(policy.firesSpentThisWindow, 0)
        XCTAssertTrue(policy.fire(now: t0, lastPollAt: nil, floor: floor))
    }

    func testEndpointJitterIsNotANewWindow() {
        var policy = armedPolicy()
        _ = policy.fire(now: t0, lastPollAt: nil, floor: floor)
        policy.pollCompleted(primaryResetsAt: resets.addingTimeInterval(1))
        XCTAssertEqual(policy.firesSpentThisWindow, 1,
                       "the endpoint wobbles ±1s between polls — that is the same window")
    }

    // MARK: - Window anchor

    func testNullWindowDisarms() {
        var policy = armedPolicy()
        policy.pollCompleted(primaryResetsAt: nil)
        XCTAssertNil(policy.activityObserved(now: t0, latestEventAt: t0))
        XCTAssertFalse(policy.fire(now: t0, lastPollAt: nil, floor: floor),
                       "no window anchor means STEP_76 writes no quota_series row — there is no "
                       + "series for an alignment poll to sharpen (the Enterprise monthly layout)")
    }

    func testWindowReappearingRearms() {
        var policy = armedPolicy()
        policy.pollCompleted(primaryResetsAt: nil)
        policy.pollCompleted(primaryResetsAt: resets)
        XCTAssertTrue(policy.fire(now: t0, lastPollAt: nil, floor: floor))
    }
}
