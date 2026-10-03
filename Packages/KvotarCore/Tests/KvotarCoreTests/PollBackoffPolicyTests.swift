import XCTest
@testable import KvotarCore

final class PollBackoffPolicyTests: XCTestCase {

    /// Fixed reference instant — the policy takes its clock as a parameter, so no faking is
    /// needed; `t(seconds)` just moves the wall clock forward by hand.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: The base is a constant (§9.2 — REV-39 Change A)

    func testSteadyCadenceIsAlwaysTheFixedBase() {
        var policy = PollBackoffPolicy()
        let step = policy.succeeded(jitter: 0, now: t0)
        XCTAssertEqual(step.delay, PollBackoffPolicy.defaultBase)
        XCTAssertFalse(step.recovered)
    }

    /// The headline invariant of this step: no sequence of 429s can leave a *lasting* mark on
    /// the steady cadence. The ladder elevates it transiently, wall-clock recovery removes it,
    /// and nothing survives to be persisted or restored.
    func testNoSequenceOf429sPermanentlyRaisesTheBase() {
        var policy = PollBackoffPolicy()
        for i in 0..<6 { _ = policy.rateLimited(retryAfter: 0, now: t(Double(i) * 5)) }
        // Two half-lives of quiet from the last 429 (at t=25) walks the rung back to the base.
        let quiet = t(25 + 2 * PollBackoffPolicy.ladderHalfLife)
        let step = policy.succeeded(jitter: 0, now: quiet)
        XCTAssertEqual(step.delay, PollBackoffPolicy.defaultBase,
                       "the ladder is transient — it can never become a new steady base")
        XCTAssertFalse(policy.isElevated(now: quiet))
        XCTAssertTrue(step.recovered)
    }

    func testFreshPolicyStartsAtTheBase() {
        // No `init(sessionBase:)` exists any more: a relaunch cannot inherit an elevated base,
        // which is what dissolves the R31-1 restart-thrash bug rather than patching it.
        let policy = PollBackoffPolicy()
        XCTAssertEqual(policy.steadyDelay(now: t0), PollBackoffPolicy.defaultBase)
        XCTAssertFalse(policy.isElevated(now: t0))
        XCTAssertEqual(policy.consecutive429s, 0)
    }

    // MARK: The transient 429 ladder (§9.3 — REV-39 Change B)

    func testFirst429HonorsRetryAfter() {
        var policy = PollBackoffPolicy()
        let step = policy.rateLimited(retryAfter: 30, now: t0)
        XCTAssertEqual(step.waitSeconds, 30, "the advertised value wins on the first 429")
        XCTAssertEqual(step.consecutiveCount, 1)
        XCTAssertFalse(policy.isElevated(now: t(30)),
                       "STEP_166 reshaped the zero-`Retry-After` path only — a non-zero first 429 " +
                       "still leaves the steady cadence untouched")
    }

    /// STEP_166 (spike A, 2026-09-06): a `Retry-After: 0` 429 is the shared allowance saying the
    /// bank is empty and the next call is granted ~120 s later — not "retry now". The 5 s retry
    /// failed in 53 of 55 logged bursts; the 120 s retry recovered 48 of 55. So the first
    /// rate-shaped 429 waits the refill period straight away.
    func testRetryAfterZeroWaitsTheRetryCadence() {
        var policy = PollBackoffPolicy()
        let step = policy.rateLimited(retryAfter: 0, now: t0)
        XCTAssertEqual(step.waitSeconds, PollBackoffPolicy.retryCadence,
                       "a zero `Retry-After` retries at the allowance's refill period, never 5 s")
        XCTAssertEqual(step.consecutiveCount, 1)
    }

    /// STEP_166: the ladder is two rungs — base and the refill period. A zero `Retry-After` enters
    /// the 120 s rung on the *first* refusal and never climbs past it: each 300 s wait was one shot
    /// into a contested slot and surrendered four refills to whoever else was calling (the 28-minute
    /// episode of 2026-09-06 crossed the 10-minute TTL that way).
    func testZeroRetryAfterEntersTheCadenceRungAndNeverClimbsPastIt() {
        var policy = PollBackoffPolicy()
        XCTAssertEqual(policy.rateLimited(retryAfter: 0, now: t0).baseIntervalAtTime, 120,
                       "the first rate-shaped 429 already reports the refill rung")
        for i in 1...10 {
            let step = policy.rateLimited(retryAfter: 0, now: t(Double(i) * 120))
            XCTAssertEqual(step.waitSeconds, PollBackoffPolicy.retryCadence,
                           "refusal #\(i + 1): never above 120 s on a zero `Retry-After`")
            XCTAssertEqual(step.baseIntervalAtTime, 120)
        }
    }

    /// A lone zero-`Retry-After` 429 holds the cadence at the refill period for one half-life —
    /// the allowance refills at 120 s, so returning to 60 s straight away would just collect the
    /// next refusal within three polls (the 20-minute cycle in the 09-06 log).
    func testAnIsolated429HoldsTheRefillCadenceForOneHalfLife() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 0, now: t0)
        XCTAssertEqual(policy.succeeded(jitter: 0, now: t(120)).delay,
                       PollBackoffPolicy.retryCadence)
        XCTAssertTrue(policy.isElevated(now: t(121)), "the rung is held for the half-life")
        XCTAssertEqual(policy.succeeded(jitter: 0, now: t(PollBackoffPolicy.ladderHalfLife)).delay,
                       PollBackoffPolicy.defaultBase,
                       "the hold is transient — the wall clock returns the base")
        XCTAssertFalse(policy.isElevated(now: t(PollBackoffPolicy.ladderHalfLife)))
    }

    /// The §9.2 wake floor reads `isElevated`: after a lone rate-shaped 429 a wake must not cut
    /// the refill wait short, and once the hold has decayed the floor is the plain 45 s again.
    func testWakeFloorRisesAfterALoneRateShaped429() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 0, now: t0)
        XCTAssertTrue(policy.isElevated(now: t(5)))
        XCTAssertEqual(policy.steadyDelay(now: t(5)), PollBackoffPolicy.retryCadence)
        XCTAssertFalse(policy.isElevated(now: t(PollBackoffPolicy.ladderHalfLife)))
    }

    /// REV-39 §5.3 burst damping, kept: a second consecutive refusal still waits the rung. Since
    /// STEP_166 the first one does too, so a burst can no longer be manufactured by our own
    /// 5-second retry at all (the 2026-08-09 00:26:32 / :38 / :43 shape).
    func testSecond429WaitsTheRungNotTheFiveSecondFloor() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 0, now: t0)
        let second = policy.rateLimited(retryAfter: 0, now: t(120))
        XCTAssertEqual(second.waitSeconds, 120,
                       "burst damping: the second 429 waits the rung, not 5 seconds")
        XCTAssertEqual(second.consecutiveCount, 2)
    }

    func testLargerRetryAfterStillWinsOverTheRung() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 0, now: t0)
        let second = policy.rateLimited(retryAfter: 280, now: t(5))
        XCTAssertEqual(second.waitSeconds, 280,
                       "the rung is a floor, never a ceiling on what the server asked for")
    }

    func testSuccessResetsTheConsecutiveCount() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 0, now: t0)
        XCTAssertTrue(policy.succeeded(jitter: 0, now: t(5)).recovered)
        XCTAssertEqual(policy.consecutive429s, 0)
        XCTAssertFalse(policy.succeeded(jitter: 0, now: t(65)).recovered,
                       "`recovered` fires once, on the first success after the 429s")
    }

    func testSuccessDelayClampedToFloorAndCeiling() {
        var policy = PollBackoffPolicy()
        XCTAssertEqual(policy.succeeded(jitter: 4, now: t0).delay, PollBackoffPolicy.defaultBase + 4)
        XCTAssertEqual(policy.succeeded(jitter: -100, now: t(60)).delay,
                       PollBackoffPolicy.minInterval)
        XCTAssertEqual(policy.succeeded(jitter: 500, now: t(120)).delay,
                       PollBackoffPolicy.maxInterval)
    }

    // MARK: Wall-clock recovery (§9.3 — REV-39 Change B)

    func testRungDecaysOneStepPerHalfLife() {
        var policy = PollBackoffPolicy()
        for _ in 0..<3 { _ = policy.rateLimited(retryAfter: 0, now: t0) }  // top rung (120s), anchored at t0
        let half = PollBackoffPolicy.ladderHalfLife
        XCTAssertEqual(policy.succeeded(jitter: 0, now: t(half - 1)).delay, 120,
                       "one second short of the half-life is still the elevated rung")
        XCTAssertTrue(policy.isElevated(now: t(half - 1)))
        XCTAssertEqual(policy.succeeded(jitter: 0, now: t(half)).delay,
                       PollBackoffPolicy.defaultBase)
        XCTAssertFalse(policy.isElevated(now: t(half)))
    }

    func testALongQuietGapDropsSeveralRungsAtOnce() {
        var policy = PollBackoffPolicy()
        for _ in 0..<3 { _ = policy.rateLimited(retryAfter: 0, now: t0) }  // top rung → 120s
        // An overnight sleep: recovery is wall-clock, so waking up must not require ~25 hours of
        // clean polls to walk back down (the incumbent's failure mode).
        XCTAssertEqual(policy.succeeded(jitter: 0, now: t(8 * 3600)).delay,
                       PollBackoffPolicy.defaultBase)
    }

    func testA429RestampsTheDecayAnchor() {
        var policy = PollBackoffPolicy()
        let half = PollBackoffPolicy.ladderHalfLife
        _ = policy.rateLimited(retryAfter: 0, now: t0)              // rung 1, anchored at t0
        _ = policy.rateLimited(retryAfter: 0, now: t(half - 60))    // still rung 1, re-anchored here
        XCTAssertEqual(policy.succeeded(jitter: 0, now: t(half)).delay, 120,
                       "the clock runs from the latest 429, not the first")
    }

    /// Escalate fast, demote *moderate*: a single success must not collapse an elevated rung, or
    /// the cadence could oscillate poll → 429 → backoff → poll → 429. Time is the only demoter,
    /// and there is deliberately no second, success-count-based path.
    func testASuccessAloneDoesNotDemoteTheRung() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 0, now: t0)
        _ = policy.rateLimited(retryAfter: 0, now: t0)   // rung 1 → 120s
        for i in 1...5 {
            XCTAssertEqual(policy.succeeded(jitter: 0, now: t(Double(i) * 60)).delay, 120)
            XCTAssertTrue(policy.isElevated(now: t(Double(i) * 60)),
                          "success #\(i) must not clear the rung")
        }
    }

    // MARK: `Retry-After` cap — first probe vs repeat (§9.3 R31-2 + REV-39 Change E)

    func testFirstProbeCappedAtTenMinutes() {
        var policy = PollBackoffPolicy()
        XCTAssertEqual(policy.rateLimited(retryAfter: 3600, now: t0).waitSeconds,
                       PollBackoffPolicy.retryAfterCap,
                       "P1-12's 3600 was bogus — the capped probe recovered 55 minutes early")
    }

    func testRepeat429HonorsTheAdvertisedCooldownInFull() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 2009, now: t0)                 // capped to 600
        let repeated = policy.rateLimited(retryAfter: 2009, now: t(600))
        XCTAssertEqual(repeated.waitSeconds, 2009,
                       "said twice ⇒ genuine (the Enterprise tester's ~33.5 min cooldown)")
    }

    func testRepeat429StillBoundedByTheAbsoluteCeiling() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 7200, now: t0)
        XCTAssertEqual(policy.rateLimited(retryAfter: 7200, now: t(600)).waitSeconds,
                       PollBackoffPolicy.retryAfterAbsoluteCap,
                       "a bogus repeat costs at most an hour, never a day")
    }

    func testRepeatWithZeroRetryAfterUsesTheRung() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 0, now: t0)
        XCTAssertEqual(policy.rateLimited(retryAfter: 0, now: t(120)).waitSeconds, 120,
                       "the absolute cap governs a countdown, never manufactures one")
    }

    // MARK: Taxonomy — only a rate-shaped 429 touches the ladder (§9.1)

    func testFailureKeepsConsecutiveCountAndUsesTheCurrentRung() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 0, now: t0)
        _ = policy.rateLimited(retryAfter: 0, now: t0)   // rung 1
        XCTAssertEqual(policy.failed(jitter: 0, now: t(5)), 120,
                       "a network/decode/5xx failure polls at the rung it finds")
        XCTAssertEqual(policy.consecutive429s, 2,
                       "only a success resets the ladder count — a failure between two 429s must not")
    }

    func testFailureNeverAdvancesTheLadder() {
        var policy = PollBackoffPolicy()
        for i in 0..<10 { _ = policy.failed(jitter: 0, now: t(Double(i) * 60)) }
        XCTAssertEqual(policy.steadyDelay(now: t(600)), PollBackoffPolicy.defaultBase)
        XCTAssertEqual(policy.consecutive429s, 0)
    }

    func testFailuresStillDecayTheRungOnTheWallClock() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 0, now: t0)
        _ = policy.rateLimited(retryAfter: 0, now: t0)   // rung 1
        XCTAssertEqual(policy.failed(jitter: 0, now: t(PollBackoffPolicy.ladderHalfLife)),
                       PollBackoffPolicy.defaultBase,
                       "recovery is a property of elapsed time, not of poll outcomes")
        XCTAssertFalse(policy.isElevated(now: t(PollBackoffPolicy.ladderHalfLife)))
    }

    // MARK: The base sits inside the allowance's refill (§9.2 — STEP_169, REV-89)

    /// Spike C on the tester's Mac (2026-09-07): 60 s → 35 of 90 refused, 90 s → 10 of 54,
    /// 120 s → 1 of 44, 180 s → 0 of 30. The base must not ask faster than the account answers.
    func testTheBaseIsNotFasterThanTheRefillCadence() {
        XCTAssertGreaterThanOrEqual(PollBackoffPolicy.defaultBase, PollBackoffPolicy.retryCadence)
        XCTAssertEqual(PollBackoffPolicy.defaultBase, 120)
    }

    /// With the base equal to `retryCadence` the two rungs carry the same delay, so "elevated"
    /// can no longer be read off the delay: it is the rung. A lone zero refusal must still raise
    /// the wake / tripwire / alignment floor even though the steady delay did not move.
    func testIsElevatedIsKeyedOnTheRungNotTheDelay() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 0, now: t0)
        XCTAssertEqual(policy.steadyDelay(now: t(5)), PollBackoffPolicy.defaultBase,
                       "the delay is unchanged — the rung and the base are both 120 s")
        XCTAssertTrue(policy.isElevated(now: t(5)),
                      "…and yet the endpoint just refused us, so the floor must rise")
        XCTAssertFalse(policy.isElevated(now: t(PollBackoffPolicy.ladderHalfLife)),
                       "the flag decays on the wall clock like the rung it reports")
    }

    /// The popover's amber freshness stamp is one missed poll — two base ticks — and derived from
    /// the base, so a cadence change cannot leave the stamp flickering before every poll (D-112).
    func testFreshnessAmberAgeIsTwoBaseTicks() {
        XCTAssertEqual(PollBackoffPolicy.freshnessAmberAge, 2 * PollBackoffPolicy.defaultBase)
        XCTAssertGreaterThan(PollBackoffPolicy.freshnessAmberAge, PollBackoffPolicy.defaultBase + 5,
                             "a scheduled poll plus its jitter never reaches the amber age")
    }

    // MARK: Wake floor (§9.2 — REV-39 Change C)

    func testSteadyDelayReportsTheLadderWithoutMutating() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 0, now: t0)
        _ = policy.rateLimited(retryAfter: 0, now: t0)   // rung 1
        XCTAssertEqual(policy.steadyDelay(now: t(5)), 120)
        XCTAssertTrue(policy.isElevated(now: t(5)),
                      "a wake must not cut short a ladder wait and re-hit the endpoint")
        XCTAssertEqual(policy.steadyDelay(now: t(5)), 120,
                       "the read is non-mutating — asking twice gives the same answer")
        XCTAssertEqual(policy.steadyDelay(now: t(PollBackoffPolicy.ladderHalfLife)),
                       PollBackoffPolicy.defaultBase)
        XCTAssertFalse(policy.isElevated(now: t(PollBackoffPolicy.ladderHalfLife)))
    }

    // MARK: First-poll launch delay (§9.2 R33-5 — STEP_39; unchanged by REV-39)

    func testFirstPollDelayWaitsOutTheRemainingBase() {
        // The incident arithmetic: age 66s, base 120s → wait 54s and none of the 429s occur.
        XCTAssertEqual(PollBackoffPolicy.firstPollDelay(age: 66, base: 120), 54)
    }

    func testFirstPollDelayImmediateWhenAgeExceedsBase() {
        XCTAssertEqual(PollBackoffPolicy.firstPollDelay(age: 120, base: 120), 0)
        XCTAssertEqual(PollBackoffPolicy.firstPollDelay(age: 4000, base: 120), 0,
                       "the normal case — the app was closed for a while")
    }

    func testFirstPollDelayImmediateOnFirstRun() {
        XCTAssertEqual(PollBackoffPolicy.firstPollDelay(age: nil, base: 120), 0,
                       "no persisted snapshot → poll immediately")
    }

    func testFirstPollDelayClampsClockSkewToBase() {
        // A future polled_at (clock changed) waits the full base rather than trusting it.
        XCTAssertEqual(PollBackoffPolicy.firstPollDelay(age: -300, base: 120), 120)
    }

    // MARK: Credential-shaped exclusion (§9.1/§9.2 rule 6 — REV-41, STEP_48)

    /// The STEP_45 interaction contract: a credential-shaped rejection never advances the ladder.
    /// The coordinator routes it away from the policy entirely, so the policy simply is not called
    /// for that event. Modelled here as two rate-shaped 429s with a credential-shaped rejection
    /// between them (no `rateLimited` call): the consecutive count reaches 2, not 3, and the rung
    /// is 1 step lower than a real third 429 would have left it.
    func testCredentialShapedRejectionDoesNotAdvanceLadder() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 0, now: t0)     // rate-shaped #1
        // — credential-shaped rejection here: the coordinator does NOT touch the policy —
        let step = policy.rateLimited(retryAfter: 0, now: t(5))  // rate-shaped #2 (the next real 429)
        XCTAssertEqual(step.consecutiveCount, 2,
                       "the skipped credential event must not appear in the ladder count")
        XCTAssertEqual(step.baseIntervalAtTime, 120,
                       "two real 429s reach rung 1; the credential event added nothing")
    }

    // MARK: The advertised cooldown is a hold every trigger respects (§9.3 — STEP_168, REV-88)

    /// A non-zero `Retry-After` sets the hold to the scheduled probe time — the capped 600 s on a
    /// first hit — and `isHeld` / `holdRemaining` track it to the boundary.
    func testNonZeroRetryAfterSetsTheHoldToTheScheduledProbe() {
        var policy = PollBackoffPolicy()
        let step = policy.rateLimited(retryAfter: 3600, now: t0)
        XCTAssertEqual(step.waitSeconds, 600, "the R31-2 cap stands (user ruling 2026-09-08)")
        XCTAssertEqual(policy.holdUntil, t(600))
        XCTAssertTrue(policy.isHeld(now: t(599)))
        XCTAssertEqual(policy.holdRemaining(now: t(100)), 500)
        XCTAssertFalse(policy.isHeld(now: t(600)), "the boundary itself is not held")
        XCTAssertEqual(policy.holdRemaining(now: t(601)), 0)
    }

    /// The tester's zero-`Retry-After` refusals are the refill clock, never a ban: no hold, and
    /// one arriving after a countdown clears the countdown's hold rather than extending it.
    func testZeroRetryAfterSetsNoHoldAndClearsAnExistingOne() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 0, now: t0)
        XCTAssertNil(policy.holdUntil)
        XCTAssertFalse(policy.isHeld(now: t0))
        _ = policy.rateLimited(retryAfter: 3600, now: t(120))
        XCTAssertNotNil(policy.holdUntil)
        _ = policy.rateLimited(retryAfter: 0, now: t(720))
        XCTAssertNil(policy.holdUntil, "a zero refusal after a countdown drops the hold")
    }

    /// Said twice ⇒ honoured in full (Change E), and the hold follows the full value.
    func testRepeatCountdownHoldsTheFullAdvertisedValue() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 3600, now: t0)
        _ = policy.rateLimited(retryAfter: 3000, now: t(600))
        XCTAssertEqual(policy.holdUntil, t(3600))
        XCTAssertTrue(policy.isHeld(now: t(3599)))
    }

    func testSuccessClearsTheHold() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 3600, now: t0)
        _ = policy.succeeded(jitter: 0, now: t(30))
        XCTAssertNil(policy.holdUntil)
        XCTAssertFalse(policy.isHeld(now: t(31)))
    }

    /// A network failure between the countdown and its probe is not evidence about the server's
    /// deadline: the hold stays.
    func testNonRateFailureLeavesTheHold() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 3600, now: t0)
        _ = policy.failed(jitter: 0, now: t(30))
        XCTAssertEqual(policy.holdUntil, t(600))
    }

    /// The credential rotated: the one sanctioned early probe drops the hold and nothing else.
    func testClearHoldDropsOnlyTheHold() {
        var policy = PollBackoffPolicy()
        _ = policy.rateLimited(retryAfter: 3600, now: t0)
        _ = policy.rateLimited(retryAfter: 3000, now: t(600))   // rung 1 from the repeat
        policy.clearHold()
        XCTAssertNil(policy.holdUntil)
        XCTAssertEqual(policy.consecutive429s, 2, "the ladder count is untouched")
        XCTAssertTrue(policy.isElevated(now: t(601)), "the rung is untouched")
    }

    /// Launch restore: a past value is a no-op, a future one re-arms the hold, and a value beyond
    /// the absolute cap is clamped — a hand-edited or skewed row costs at most an hour.
    func testSeedHoldPastFutureAndClamped() {
        var past = PollBackoffPolicy()
        past.seedHold(until: t(-1), now: t0)
        XCTAssertNil(past.holdUntil)

        var future = PollBackoffPolicy()
        future.seedHold(until: t(900), now: t0)
        XCTAssertEqual(future.holdUntil, t(900))
        XCTAssertTrue(future.isHeld(now: t(899)))
        XCTAssertEqual(future.consecutive429s, 0, "the ladder starts clean on a relaunch (REV-39)")
        XCTAssertFalse(future.isElevated(now: t0))

        var skewed = PollBackoffPolicy()
        skewed.seedHold(until: t(86_400), now: t0)
        XCTAssertEqual(skewed.holdUntil, t(PollBackoffPolicy.retryAfterAbsoluteCap))
    }
}
