import XCTest
import GRDB
@testable import KvotarCore

final class StateEngineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Builders

    private func forecast(
        tool: Tool = .claude,
        runway: Double? = nil,
        pollCount: Int = 10
    ) -> Forecast {
        Forecast(tool: tool, tier: .fullRunway, runwayMinutes: runway,
                 burnRatePerMin: runway == nil ? nil : 1, isEstimate: false, pollCount: pollCount)
    }

    /// Minutes to a secondary reset that leaves the week exactly half gone, and one that leaves
    /// a single day of it — the two calendar positions every tier test below is read against.
    private let halfWeek: Double = 7 * 24 * 60 / 2
    private let oneDayLeft: Double = 24 * 60

    private func snapshot(
        tool: Tool = .claude,
        used: Double?,
        secondary: Double? = 10,
        resetMinutes: Double? = nil,
        windowSeconds: Int? = nil,
        reached: Bool = false,
        spendControl: Bool? = nil,
        monthlyResetMinutes: Double? = nil,
        secondaryResetMinutes: Double? = nil,
        monthlyUsed: Double = 4000
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: tool,
            primaryUsedPct: used,
            primaryResetsAt: resetMinutes.map { now.addingTimeInterval($0 * 60) },
            primaryWindowSeconds: windowSeconds,
            secondaryUsedPct: secondary,
            secondaryResetsAt: secondaryResetMinutes.map { now.addingTimeInterval($0 * 60) },
            rateLimitReached: reached,
            extraUsage: .disabled,
            spendControlReached: spendControl,
            monthlyLimit: monthlyResetMinutes.map {
                MonthlyLimit(limitAmount: 4000, usedAmount: monthlyUsed,
                             remainingPercent: Int(100 - monthlyUsed / 40),
                             resetsAt: now.addingTimeInterval($0 * 60))
            }
        )
    }

    private func inputs(
        tool: Tool = .claude,
        snapshot: QuotaSnapshot?,
        forecast: Forecast? = nil,
        trigger: StateTrigger = .poll,
        fastBurnDelta: Double? = nil,
        utilDeltaLast2Polls: Double? = nil,
        localTokensLast2Min: Int? = nil,
        lastLocalActivityAt: Date? = nil,
        activeSurfaceBucketCount: Int = 0
    ) -> StateInputs {
        StateInputs(
            tool: tool, snapshot: snapshot, health: .healthy,
            forecast: forecast ?? self.forecast(tool: tool),
            trigger: trigger, now: now,
            fastBurnDelta: fastBurnDelta,
            utilDeltaLast2Polls: utilDeltaLast2Polls,
            localTokensLast2Min: localTokensLast2Min,
            activeSurfaceBucketCount: activeSurfaceBucketCount,
            lastLocalActivityAt: lastLocalActivityAt)
    }

    private func classify(_ i: StateInputs, isStale: Bool = false) -> AppState {
        StateEngine.classify(i, isStale: isStale)
    }

    // MARK: Priority list — one test per state (§13)

    func testIdleWhenNoSnapshot() {
        XCTAssertEqual(classify(inputs(snapshot: nil)), .idleFallback)
    }

    func testIdleWhenStale() {
        XCTAssertEqual(classify(inputs(snapshot: snapshot(used: 40)), isStale: true), .idleFallback)
    }

    func testSpendControl() {
        let s = snapshot(tool: .codex, used: 50, spendControl: true)
        XCTAssertEqual(classify(inputs(tool: .codex, snapshot: s)), .spendControl)
    }

    func testOverQuotaByUtilization() {
        XCTAssertEqual(classify(inputs(snapshot: snapshot(used: 106))), .overQuota)
    }

    func testOverQuotaByRateLimitReached() {
        XCTAssertEqual(classify(inputs(snapshot: snapshot(used: 40, reached: true))), .overQuota)
    }

    // Boundary: the Claude usage endpoint caps `utilization` at exactly 100.0 (real-data finding
    // 2026-07-05), so a fully-spent window reports 100, not >100. Over-quota must fire at the
    // boundary — a strict `>` left it classifying as Healthy (green "Comfortable" at a hard stop).
    func testOverQuotaAtExactly100() {
        XCTAssertEqual(classify(inputs(snapshot: snapshot(used: 100))), .overQuota)
    }

    // Step 21 invariant: a maxed window (exactly 100%, idle) must never render Healthy/green
    // regardless of how far the reset is — over-quota (rank 3) outranks bad-timing/elevated/
    // healthy, so the reset distance cannot pull it back to green. Covers the reproduced live
    // case (2026-07-03: green "100% · Comfortable" with reset 1h07m away).
    func testCeilingNeverHealthyRegardlessOfResetDistance() {
        for reset in [60.0, 89.0, 120.0] {
            let i = inputs(snapshot: snapshot(used: 100, resetMinutes: reset))
            XCTAssertEqual(classify(i), .overQuota,
                           "exactly 100% must never read healthy — reset \(reset)m away")
        }
    }

    func testAtRisk() {
        let i = inputs(snapshot: snapshot(used: 87), forecast: forecast(runway: 11))
        XCTAssertEqual(classify(i), .atRisk)
    }

    func testBadTiming() {
        let i = inputs(snapshot: snapshot(used: 91, resetMinutes: 128))
        XCTAssertEqual(classify(i), .badTiming)
    }

    func testFastBurnSpike() {
        let i = inputs(snapshot: snapshot(used: 54), fastBurnDelta: 22)
        XCTAssertEqual(classify(i), .fastBurnSpike)
    }

    func testOffMachineBurn() {
        // Local activity observed but now stale (older than the 8-min idle gap) → confirmed idle.
        let i = inputs(snapshot: snapshot(used: 72), utilDeltaLast2Polls: 3,
                       lastLocalActivityAt: now.addingTimeInterval(-600))
        XCTAssertEqual(classify(i), .offMachineBurn)
    }

    func testOffMachineBurnSkippedWhenLocalActive() {
        // Recent local activity (within the gap, e.g. mid-turn) → not confirmed idle.
        let i = inputs(snapshot: snapshot(used: 72), utilDeltaLast2Polls: 3,
                       lastLocalActivityAt: now.addingTimeInterval(-30))
        XCTAssertEqual(classify(i), .healthy, "recent local activity → not off-machine")
    }

    func testOffMachineBurnSkippedWhenLocalNeverObserved() {
        // No local activity ever this run (nil) is "cannot confirm idle" — not off-machine (REV-23).
        let i = inputs(snapshot: snapshot(used: 72), utilDeltaLast2Polls: 3,
                       lastLocalActivityAt: nil)
        XCTAssertEqual(classify(i), .healthy, "never-observed local → cannot confirm → not off-machine")
    }

    func testOffMachineBurnFiresJustPastIdleGap() {
        // Exactly at the gap boundary reads as idle (>=), just inside stays active.
        let past = inputs(snapshot: snapshot(used: 72), utilDeltaLast2Polls: 3,
                          lastLocalActivityAt: now.addingTimeInterval(-LocalAttribution.idleGap))
        XCTAssertEqual(classify(past), .offMachineBurn)
        let inside = inputs(snapshot: snapshot(used: 72), utilDeltaLast2Polls: 3,
                            lastLocalActivityAt: now.addingTimeInterval(-LocalAttribution.idleGap + 1))
        XCTAssertEqual(classify(inside), .healthy)
    }

    func testMultiSurfaceCodexOnly() {
        let codex = inputs(tool: .codex, snapshot: snapshot(tool: .codex, used: 30),
                           activeSurfaceBucketCount: 2)
        XCTAssertEqual(classify(codex), .multiSurface)
        let claude = inputs(snapshot: snapshot(used: 30), activeSurfaceBucketCount: 2)
        XCTAssertEqual(classify(claude), .healthy, "multi-surface is Codex-only")
    }

    // Elevated gate (UI Spec §5, STEP_26): runway < minutes-to-reset — projected exhaustion
    // before the window resets, while the At-risk/Bad-timing gates are unmet.

    func testElevated() {
        let i = inputs(snapshot: snapshot(used: 68, resetMinutes: 120), forecast: forecast(runway: 38))
        XCTAssertEqual(classify(i), .elevated)
    }

    func testElevatedNotWhenRunwayOutlastsReset() {
        let i = inputs(snapshot: snapshot(used: 68, resetMinutes: 30), forecast: forecast(runway: 45))
        XCTAssertEqual(classify(i), .healthy, "reset arrives before exhaustion → not elevated")
    }

    func testElevatedRequiresResetTime() {
        let i = inputs(snapshot: snapshot(used: 68), forecast: forecast(runway: 38))
        XCTAssertEqual(classify(i), .healthy, "no reset time → Elevated gate cannot fire")
    }

    // Pace clock (REV-65/D-69, §11.3): rank 9 is dual-horizon — `runway < reset` alone no longer
    // fires it. The live false alarm this pins: 2026-08-13, "Won't make it ~4h46m" at 5% weekly
    // used with 6.9 days to the reset, 19% of the evening's polls amber.

    func testElevatedPaceGatedOnWeeklyWindow() {
        // 6 days to reset of a 7-day window → elapsed ≈ 14% > used 5% → under pace → healthy
        // despite a hot burst runway (289 min ≪ 6 days).
        let i = inputs(tool: .codex,
                       snapshot: snapshot(tool: .codex, used: 5, secondary: nil,
                                          resetMinutes: 6 * 24 * 60, windowSeconds: 604_800),
                       forecast: forecast(tool: .codex, runway: 289))
        XCTAssertEqual(classify(i), .healthy,
                       "a burst against a weekly window at 5% used is not exhaustion")
    }

    func testElevatedFiresOnWeeklyWindowWhenOverPace() {
        // 30% used with 85% of the week still to run (elapsed 15%) → over pace AND runway < reset.
        let i = inputs(tool: .codex,
                       snapshot: snapshot(tool: .codex, used: 30, secondary: nil,
                                          resetMinutes: 0.85 * 7 * 24 * 60, windowSeconds: 604_800),
                       forecast: forecast(tool: .codex, runway: 400))
        XCTAssertEqual(classify(i), .elevated, "over pace and exhausting → the warning is genuine")
    }

    func testElevatedSilentInsideWindowOpenGrace() {
        // 3% used one hour into the week (elapsed 0.6% < the 2% grace) — the pace clock may not
        // fire, however hot the burst: window-open usage is always "ahead of linear schedule".
        let i = inputs(tool: .codex,
                       snapshot: snapshot(tool: .codex, used: 3, secondary: nil,
                                          resetMinutes: 7 * 24 * 60 - 60, windowSeconds: 604_800),
                       forecast: forecast(tool: .codex, runway: 300))
        XCTAssertEqual(classify(i), .healthy, "the grace covers the window's first 2%")
    }

    func testElevatedOnClaudeFallbackWidthStillFires() {
        // The Claude regression pin: no reported width (the REV-60 18,000s fallback), 68% used at
        // 60% elapsed (reset in 120 of 300 min) → over pace → today's behaviour survives the gate.
        let i = inputs(snapshot: snapshot(used: 68, resetMinutes: 120), forecast: forecast(runway: 38))
        XCTAssertEqual(classify(i), .elevated,
                       "Claude rides primaryWindowLength's fallback — the gate must not mute it")
    }

    // The two long-limit ranks (REV-96 §2.3 — STEP_194). Rank 10 replaces Weekly-elevated and
    // rank 5b is new; both read `QuotaSnapshot.longLimit`, so a weekly with no reset — which is
    // what every one of these cases used to be — now produces no assessment and no rank at all.

    /// Half a week gone, 70 % spent: ahead of the calendar, past the floor, below the line.
    func testLimitAheadOfPace() {
        let i = inputs(snapshot: snapshot(used: 22, secondary: 70, secondaryResetMinutes: halfWeek),
                       forecast: forecast(runway: 240))
        XCTAssertEqual(classify(i), .limitAheadOfPace)
    }

    /// Past the red line, whatever the calendar says — here the week is barely half gone.
    func testLimitNearlySpent() {
        let i = inputs(snapshot: snapshot(used: 22, secondary: 91, secondaryResetMinutes: halfWeek),
                       forecast: forecast(runway: 240))
        XCTAssertEqual(classify(i), .limitNearlySpent)
    }

    func testNearlySpentBoundary() {
        let at = inputs(snapshot: snapshot(used: 22, secondary: 90, secondaryResetMinutes: halfWeek),
                        forecast: forecast(runway: 240))
        XCTAssertEqual(classify(at), .limitNearlySpent, "the line is inclusive")
        let below = inputs(snapshot: snapshot(used: 22, secondary: 89.9,
                                              secondaryResetMinutes: halfWeek),
                           forecast: forecast(runway: 240))
        XCTAssertEqual(classify(below), .limitAheadOfPace)
    }

    /// The amber floor: ahead of the calendar but not far enough into the budget to say so.
    /// 40 % of the week gone in both cases, so only the floor is under test.
    func testBelowAmberFloorStaysHealthy() {
        let sixtyPercentLeft = 7 * 24 * 60 * 0.6
        let below = inputs(snapshot: snapshot(used: 22, secondary: 49,
                                              secondaryResetMinutes: sixtyPercentLeft),
                           forecast: forecast(runway: 240))
        XCTAssertEqual(classify(below), .healthy,
                       "under the floor — being ahead of the week says little")
        let at = inputs(snapshot: snapshot(used: 22, secondary: 50,
                                           secondaryResetMinutes: sixtyPercentLeft),
                        forecast: forecast(runway: 240))
        XCTAssertEqual(classify(at), .limitAheadOfPace, "the floor is inclusive")
    }

    /// Exactly level with the calendar is on pace — the test is `used > elapsed`, strictly.
    func testLevelWithTheCalendarIsOnPace() {
        let i = inputs(snapshot: snapshot(used: 22, secondary: 50,
                                          secondaryResetMinutes: halfWeek),
                       forecast: forecast(runway: 240))
        XCTAssertEqual(classify(i), .healthy)
    }

    /// REV-38/40's monthly layout keeps rank 12 and its own E6 amber; only the red rank
    /// pre-empts it, because rank 12 cannot say *nearly spent* and cannot fire event 9.
    func testMonthlyLayoutKeepsNullWindowAtAmberAndYieldsAtRed() {
        let amber = inputs(snapshot: snapshot(used: nil, secondary: nil,
                                              monthlyResetMinutes: 17 * 24 * 60,
                                              monthlyUsed: 3400))
        XCTAssertEqual(classify(amber), .nullWindow, "the monthly layout owns its own amber")
        let red = inputs(snapshot: snapshot(used: nil, secondary: nil,
                                            monthlyResetMinutes: 17 * 24 * 60,
                                            monthlyUsed: 3700))
        XCTAssertEqual(classify(red), .limitNearlySpent, "92 % of the budget is not a calm state")
    }

    /// Under the calendar is on pace however much is spent, short of the red line.
    func testUnderPaceStaysHealthy() {
        let i = inputs(snapshot: snapshot(used: 22, secondary: 60,
                                          secondaryResetMinutes: oneDayLeft),
                       forecast: forecast(runway: 240))
        XCTAssertEqual(classify(i), .healthy, "86% of the week gone against 60% spent")
    }

    /// The grace: a fresh week is always "ahead of schedule" and must not say so.
    func testInsideGraceStaysHealthy() {
        // 1 % of the week elapsed — inside `paceGraceFraction` (2 %).
        let i = inputs(snapshot: snapshot(used: 22, secondary: 60,
                                          secondaryResetMinutes: 7 * 24 * 60 * 0.99),
                       forecast: forecast(runway: 240))
        XCTAssertEqual(classify(i), .healthy)
    }

    /// A weekly with no reset has no calendar to be measured against, so no rank (§11.3).
    func testUnanchoredWeeklyYieldsNoRank() {
        let i = inputs(snapshot: snapshot(used: 22, secondary: 91), forecast: forecast(runway: 240))
        XCTAssertEqual(classify(i), .healthy, "no secondary reset ⇒ no assessment, no tier")
    }

    /// Rank order: a five-hour red state outranks 5b, a five-hour amber does not.
    func testNearlySpentYieldsToAtRiskAndBadTiming() {
        let atRisk = inputs(snapshot: snapshot(used: 87, secondary: 91,
                                               secondaryResetMinutes: halfWeek),
                            forecast: forecast(runway: 11))
        XCTAssertEqual(classify(atRisk), .atRisk, "At risk outranks rank 5b")
        let badTiming = inputs(snapshot: snapshot(used: 90, secondary: 91, resetMinutes: 120,
                                                  secondaryResetMinutes: halfWeek),
                               forecast: forecast(runway: 240))
        XCTAssertEqual(classify(badTiming), .badTiming, "Bad timing outranks rank 5b")
    }

    func testNearlySpentOutranksFastBurnAndElevated() {
        let fastBurn = inputs(snapshot: snapshot(used: 40, secondary: 91,
                                                 secondaryResetMinutes: halfWeek),
                              forecast: forecast(runway: 240), fastBurnDelta: 25)
        XCTAssertEqual(classify(fastBurn), .limitNearlySpent, "rank 5b outranks Fast burn")
        let elevated = inputs(snapshot: snapshot(used: 68, secondary: 91, resetMinutes: 120,
                                                 secondaryResetMinutes: halfWeek),
                              forecast: forecast(runway: 38))
        XCTAssertEqual(classify(elevated), .limitNearlySpent, "rank 5b outranks Elevated")
    }

    /// Rank 10 is below every warning, including Elevated — it must never pre-empt one.
    func testAheadOfPaceYieldsToEveryWarning() {
        let elevated = inputs(snapshot: snapshot(used: 68, secondary: 70, resetMinutes: 120,
                                                 secondaryResetMinutes: halfWeek),
                              forecast: forecast(runway: 38))
        XCTAssertEqual(classify(elevated), .elevated)
        let atRisk = inputs(snapshot: snapshot(used: 87, secondary: 70,
                                               secondaryResetMinutes: halfWeek),
                            forecast: forecast(runway: 11))
        XCTAssertEqual(classify(atRisk), .atRisk)
    }

    /// A spent weekly is rank 3, never a tier — the defect REV-96 §1.1 opens with.
    func testSpentWeeklyIsOverQuotaNotATier() {
        let i = inputs(snapshot: snapshot(used: 22, secondary: 100,
                                          secondaryResetMinutes: halfWeek),
                       forecast: forecast(runway: 240))
        XCTAssertEqual(classify(i), .overQuota)
    }

    func testLongLimitRankWithNoPrimaryWindow() {
        // Weekly present but primary null (partial data) — the rank reads the secondary window
        // and must not require a primary utilization value.
        let i = inputs(snapshot: snapshot(used: nil, secondary: 91,
                                          secondaryResetMinutes: halfWeek))
        XCTAssertEqual(classify(i), .limitNearlySpent)
    }

    /// The monthly is a long limit too (REV-96 §2.2) — the whole point of retiring the
    /// weekly-only rank. Here a five-hour window is populated, so rank 10 is reachable.
    func testMonthlyReachesTheTiers() {
        // 3,400 of 4,000 = 85 % used, ~13 days into a ~30-day cycle.
        let i = inputs(snapshot: snapshot(used: 22, secondary: nil,
                                          monthlyResetMinutes: 17 * 24 * 60, monthlyUsed: 3400),
                       forecast: forecast(runway: 240))
        XCTAssertEqual(classify(i), .limitAheadOfPace)
    }

    /// Worse tier wins across limits (REV-96 §2.3): a nearly-spent monthly beats an
    /// ahead-of-pace weekly, and the rank is the worse one's.
    func testWorseTierWinsAcrossLimits() {
        let i = inputs(snapshot: snapshot(used: 22, secondary: 70,
                                          monthlyResetMinutes: 17 * 24 * 60,
                                          secondaryResetMinutes: halfWeek, monthlyUsed: 3700),
                       forecast: forecast(runway: 240))
        XCTAssertEqual(classify(i), .limitNearlySpent)
    }

    func testHealthy() {
        let i = inputs(snapshot: snapshot(used: 20), forecast: forecast(runway: 240))
        XCTAssertEqual(classify(i), .healthy)
    }

    func testNullWindowCodex() {
        let s = snapshot(tool: .codex, used: nil, secondary: nil)
        let f = Forecast(tool: .codex, tier: .creditBased, runwayMinutes: nil,
                         burnRatePerMin: nil, isEstimate: false, pollCount: 3)
        XCTAssertEqual(classify(inputs(tool: .codex, snapshot: s, forecast: f)), .nullWindow)
    }

    // STEP_32: Claude overnight shape — a present five_hour with `resets_at: null`, weekly live
    // (2026-07-06 capture). Since REV-80 / D-101 the adapter emits it as the not-started shape
    // (0%, no reset, 18 000 s) and gate 11 classifies it Healthy — exactly as Codex's REV-57
    // placeholder — never Null-window and never Idle/fallback.
    func testNotStartedClaudeWithLiveWeekly() {
        let f = Forecast(tool: .claude, tier: .unknown, runwayMinutes: nil,
                         burnRatePerMin: nil, isEstimate: false, pollCount: 3)
        let i = inputs(snapshot: snapshot(used: 0, secondary: 51, windowSeconds: 18_000), forecast: f)
        XCTAssertEqual(classify(i), .healthy)
    }

    func testNotStartedClaudeWithNullWeekly() {
        let f = Forecast(tool: .claude, tier: .unknown, runwayMinutes: nil,
                         burnRatePerMin: nil, isEstimate: false, pollCount: 3)
        let i = inputs(snapshot: snapshot(used: 0, secondary: nil, windowSeconds: 18_000), forecast: f)
        XCTAssertEqual(classify(i), .healthy)
    }

    /// The absent-object shape (Claude Enterprise `five_hour: null`) still lands on item 12 —
    /// REV-80 narrowed the item, it did not remove it.
    func testNullWindowClaudeAbsentObject() {
        let f = Forecast(tool: .claude, tier: .unknown, runwayMinutes: nil,
                         burnRatePerMin: nil, isEstimate: false, pollCount: 3)
        let i = inputs(snapshot: snapshot(used: nil, secondary: nil), forecast: f)
        XCTAssertEqual(classify(i), .nullWindow)
    }

    // REV-40 (STEP_46): Claude Enterprise's default healthy shape — persistent null windows with
    // a populated monthly spend limit — classifies rank-12 Null-window (never broken/idle),
    // exactly the Codex monthly pattern (§13 item 12, tool-agnostic by construction).
    func testNullWindowClaudeWithMonthlySpendLimit() {
        let f = Forecast(tool: .claude, tier: .unknown, runwayMinutes: nil,
                         burnRatePerMin: nil, isEstimate: false, pollCount: 3)
        let s = QuotaSnapshot(
            tool: .claude, primaryUsedPct: nil, primaryResetsAt: nil,
            secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: nil,
            monthlyLimit: MonthlyLimit(
                limitAmount: 12000, usedAmount: 6916, remainingPercent: 42,
                resetsAt: now.addingTimeInterval(16 * 86_400),
                unit: .money(currency: "USD", exponent: 2),
                source: "derived_calendar_month_utc"))
        XCTAssertEqual(classify(inputs(snapshot: s, forecast: f)), .nullWindow)
    }

    // MARK: Priority ordering

    func testSpendControlBeatsOverQuota() {
        let s = snapshot(tool: .codex, used: 130, spendControl: true)
        XCTAssertEqual(classify(inputs(tool: .codex, snapshot: s)), .spendControl)
    }

    func testOverQuotaBeatsAtRisk() {
        let i = inputs(snapshot: snapshot(used: 101), forecast: forecast(runway: 5))
        XCTAssertEqual(classify(i), .overQuota)
    }

    func testAtRiskBeatsBadTiming() {
        // util ≥ 85 (bad-timing eligible) + reset far, but runway < 30 → at-risk wins.
        let i = inputs(snapshot: snapshot(used: 90, resetMinutes: 120), forecast: forecast(runway: 12))
        XCTAssertEqual(classify(i), .atRisk)
    }

    // MARK: Cold start (§11.4) — user decision: hard blocks fire, burn warnings do not

    func testColdStartOverQuotaStillFires() {
        let f = forecast(runway: nil, pollCount: 1)
        XCTAssertEqual(classify(inputs(snapshot: snapshot(used: 105), forecast: f)), .overQuota)
    }

    func testColdStartBadTimingStillFires() {
        let f = forecast(runway: nil, pollCount: 1)
        let i = inputs(snapshot: snapshot(used: 88, resetMinutes: 120), forecast: f)
        XCTAssertEqual(classify(i), .badTiming)
    }

    func testColdStartHighUtilStaysHealthyWithoutRunway() {
        // util ≥ 75 but no runway yet (poll 1) → cannot be at-risk/elevated → healthy.
        let f = forecast(runway: nil, pollCount: 1)
        XCTAssertEqual(classify(inputs(snapshot: snapshot(used: 80), forecast: f)), .healthy)
    }

    // MARK: De-escalation hysteresis (v5.4 §13.4, REV-17) — pure helper

    private func resolve(
        previous: AppState?, candidate: AppState, streak: Int = 0,
        trigger: StateTrigger = .poll, windowReset: Bool = false, localActive: Bool = false
    ) -> (state: AppState, streak: Int) {
        StateEngine.resolveHysteresis(previous: previous, candidate: candidate,
                                      calmStreak: streak, trigger: trigger,
                                      windowReset: windowReset, localActive: localActive)
    }

    func testHysteresisFirstEvaluationAdoptsCandidate() {
        let r = resolve(previous: nil, candidate: .elevated)
        XCTAssertEqual(r.state, .elevated)
        XCTAssertEqual(r.streak, 0)
    }

    func testHysteresisEscalatesImmediately() {
        let r = resolve(previous: .healthy, candidate: .atRisk, streak: 2)
        XCTAssertEqual(r.state, .atRisk)
        XCTAssertEqual(r.streak, 0, "escalation resets the calm streak")
    }

    func testHysteresisSameStateResetsStreak() {
        let r = resolve(previous: .elevated, candidate: .elevated, streak: 2)
        XCTAssertEqual(r.state, .elevated)
        XCTAssertEqual(r.streak, 0, "re-confirmation of the held state clears partial calm streaks")
    }

    func testHysteresisHoldsCalmerCandidateForNPolls() {
        var r = resolve(previous: .elevated, candidate: .healthy, streak: 0)
        XCTAssertEqual(r.state, .elevated, "1st calm poll holds")
        XCTAssertEqual(r.streak, 1)
        r = resolve(previous: .elevated, candidate: .healthy, streak: r.streak)
        XCTAssertEqual(r.state, .elevated, "2nd calm poll holds")
        XCTAssertEqual(r.streak, 2)
        r = resolve(previous: .elevated, candidate: .healthy, streak: r.streak)
        XCTAssertEqual(r.state, .healthy, "3rd calm poll de-escalates (N = 3)")
        XCTAssertEqual(r.streak, 0)
    }

    func testHysteresisWindowResetBypasses() {
        let r = resolve(previous: .badTiming, candidate: .healthy, windowReset: true)
        XCTAssertEqual(r.state, .healthy, "a window reset genuinely de-escalates — no hold")
    }

    func testHysteresisIdleFallbackBypasses() {
        let r = resolve(previous: .atRisk, candidate: .idleFallback, trigger: .pollFailure)
        XCTAssertEqual(r.state, .idleFallback,
                       "staleness/data-loss is not 'calming down' — never hold a warning on dead data")
    }

    func testHysteresisOffMachineDeSticksWhenLocalResumes() {
        // REV-23: leaving off_machine_burn while local is active adopts the calmer state at once —
        // the "Claude Code is idle" banner must not linger while the burn card shows active local.
        let r = resolve(previous: .offMachineBurn, candidate: .healthy, localActive: true)
        XCTAssertEqual(r.state, .healthy, "recent local activity de-sticks off-machine immediately")
        XCTAssertEqual(r.streak, 0)
    }

    func testHysteresisOffMachineDeStickFiresOnJsonlDelta() {
        // The first local write after a lull (a jsonlDelta trigger) clears it, not just a poll.
        let r = resolve(previous: .offMachineBurn, candidate: .healthy,
                        trigger: .jsonlDelta, localActive: true)
        XCTAssertEqual(r.state, .healthy)
    }

    func testHysteresisOffMachineStillHeldWhenLocalNotActive() {
        // Without recent local activity the normal 3-poll de-escalation still applies (no de-stick).
        let r = resolve(previous: .offMachineBurn, candidate: .healthy, localActive: false)
        XCTAssertEqual(r.state, .offMachineBurn, "no local resume → ordinary hysteresis holds")
        XCTAssertEqual(r.streak, 1)
    }

    func testHysteresisNonPollTriggersDoNotCount() {
        var r = resolve(previous: .elevated, candidate: .healthy, streak: 1, trigger: .jsonlDelta)
        XCTAssertEqual(r.state, .elevated)
        XCTAssertEqual(r.streak, 1, "JSONL-delta evaluations hold without advancing the streak")
        r = resolve(previous: .elevated, candidate: .healthy, streak: 1, trigger: .pollFailure)
        XCTAssertEqual(r.state, .elevated)
        XCTAssertEqual(r.streak, 1, "pollFailure evaluations hold without advancing the streak")
    }

    func testHysteresisStreakResetsOnReEscalation() {
        // 2 calm polls, then burn resumes (same state re-classified) — a later calm run
        // must start counting from zero again.
        var r = resolve(previous: .elevated, candidate: .healthy, streak: 1)
        XCTAssertEqual(r.streak, 2)
        r = resolve(previous: .elevated, candidate: .elevated, streak: r.streak)
        XCTAssertEqual(r.streak, 0)
        r = resolve(previous: .elevated, candidate: .healthy, streak: r.streak)
        XCTAssertEqual(r.state, .elevated)
        XCTAssertEqual(r.streak, 1)
    }

    // MARK: De-escalation hysteresis — actor sequences

    func testEngineHoldsDeEscalationForThreeCalmPolls() async {
        let engine = StateEngine()
        // Establish Elevated (runway 38 < reset 120).
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 68, resetMinutes: 120),
                                         forecast: forecast(runway: 38)))
        // Calm classification (runway 45 outlasts reset 30) — polls 1 and 2 hold Elevated.
        let calm = { self.inputs(snapshot: self.snapshot(used: 68, resetMinutes: 30),
                                 forecast: self.forecast(runway: 45)) }
        let p1 = await engine.evaluate(calm())
        XCTAssertEqual(p1.state, .elevated)
        XCTAssertNil(p1.change)
        let p2 = await engine.evaluate(calm())
        XCTAssertEqual(p2.state, .elevated)
        XCTAssertNil(p2.change)
        // Poll 3 de-escalates, emitting the one transition elevated → healthy.
        let p3 = await engine.evaluate(calm())
        XCTAssertEqual(p3.state, .healthy)
        XCTAssertEqual(p3.change?.previous, .elevated)
        XCTAssertEqual(p3.change?.new, .healthy)
    }

    func testEngineJsonlDeltaDoesNotAdvanceDeEscalation() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 68, resetMinutes: 120),
                                         forecast: forecast(runway: 38)))
        // Three calm JSONL-delta evaluations must all hold — only polls count.
        for _ in 0..<3 {
            let e = await engine.evaluate(inputs(snapshot: snapshot(used: 68, resetMinutes: 30),
                                                 forecast: forecast(runway: 45),
                                                 trigger: .jsonlDelta))
            XCTAssertEqual(e.state, .elevated)
        }
    }

    func testEngineWindowResetDeEscalatesImmediately() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 68, resetMinutes: 120),
                                         forecast: forecast(runway: 38)))
        // resets_at advances by 5h → windowReset → the calm candidate lands at once.
        let e = await engine.evaluate(inputs(snapshot: snapshot(used: 2, resetMinutes: 420),
                                             forecast: forecast(runway: 500)))
        XCTAssertEqual(e.state, .healthy)
        XCTAssertEqual(e.change?.previous, .elevated)
    }

    func testEngineEscalationStillImmediate() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 20), forecast: forecast(runway: 240)))
        let e = await engine.evaluate(inputs(snapshot: snapshot(used: 106)))
        XCTAssertEqual(e.state, .overQuota, "escalations are never held")
        XCTAssertEqual(e.change?.new, .overQuota)
    }

    // `testEvaluationCarriesDominantTool` lived here until D-98 (REV-78) deleted
    // `DominantAgentSelector` and `StateEvaluation.dominantTool` with the Adaptive display mode.

    // MARK: Actor behaviour

    func testFirstEvaluationEstablishesStateSilently() async {
        let engine = StateEngine()
        let evaluation = await engine.evaluate(inputs(snapshot: snapshot(used: 20)))
        XCTAssertEqual(evaluation.state, .healthy)
        XCTAssertNil(evaluation.change, "first evaluation must not report a transition")
        let current = await engine.currentState(for: .claude)
        XCTAssertEqual(current, .healthy)
    }

    func testTransitionReturnsStateChange() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 20), forecast: forecast(runway: 240)))
        let evaluation = await engine.evaluate(inputs(snapshot: snapshot(used: 106)))

        XCTAssertEqual(evaluation.change?.previous, .healthy)
        XCTAssertEqual(evaluation.change?.new, .overQuota)
        XCTAssertEqual(evaluation.change?.tool, .claude)
    }

    func testTransitionCarriesExtraUsageAmounts() async {
        // STEP_27: over-quota case 1/2 notification copy needs the dollar amounts on the change.
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 20), forecast: forecast(runway: 240)))

        let credits = QuotaSnapshot(
            tool: .claude, primaryUsedPct: 106, primaryResetsAt: nil,
            secondaryUsedPct: 10, secondaryResetsAt: nil, rateLimitReached: true,
            extraUsage: ExtraUsage(
                isEnabled: false, monthlyLimit: 2000, usedCredits: Decimal(string: "3.20"),
                usedCreditsIsCached: true))
        let evaluation = await engine.evaluate(inputs(snapshot: credits))

        XCTAssertEqual(evaluation.change?.new, .overQuota)
        XCTAssertEqual(evaluation.change?.extraUsageUsedCredits, Decimal(string: "3.20"))
        XCTAssertEqual(evaluation.change?.extraUsageMonthlyLimit, 2000)
        XCTAssertEqual(evaluation.change?.extraUsageIsCached, true)
    }

    /// STEP_221 (REV-102 §2.6): the tester's Sunday — weekly spent on a Team seat, org-paid euro
    /// credits. The change carries the card's own money state and the currency, and the banner
    /// variant follows: paying ⇒ case 1, cap spent ⇒ case 3 (the block is real).
    private func teamWeeklySpent(usedCredits: String) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: .claude, primaryUsedPct: 12, primaryResetsAt: now.addingTimeInterval(3600),
            secondaryUsedPct: 100, secondaryResetsAt: now.addingTimeInterval(38 * 3600),
            rateLimitReached: false,
            extraUsage: ExtraUsage(
                isEnabled: true, monthlyLimit: 7000, usedCredits: Decimal(string: usedCredits),
                currency: "EUR", managedByOrganization: true, currencyExponent: 2))
    }

    func testWeeklyBlockWithCreditsPayingCarriesChargingAndCurrency() async throws {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 20), forecast: forecast(runway: 240)))
        let evaluation = await engine.evaluate(inputs(snapshot: teamWeeklySpent(usedCredits: "12.40")))

        let change = try XCTUnwrap(evaluation.change)
        XCTAssertEqual(change.new, .overQuota)
        XCTAssertEqual(change.moneyState, .charging)
        XCTAssertEqual(change.extraUsageCurrency, "EUR")
        XCTAssertEqual(change.extraUsageCurrencyExponent, 2)
        XCTAssertEqual(NotificationEngine.overQuotaVariant(change), "case_1")
    }

    func testWeeklyBlockWithTheCapSpentIsNotACreditsBanner() async throws {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 20), forecast: forecast(runway: 240)))
        // The at-cap shape (synthetic amounts): €70.25 of a €70.00 cap.
        let evaluation = await engine.evaluate(inputs(snapshot: teamWeeklySpent(usedCredits: "70.25")))

        let change = try XCTUnwrap(evaluation.change)
        XCTAssertEqual(change.new, .overQuota)
        XCTAssertEqual(change.moneyState, .capReached)
        XCTAssertEqual(NotificationEngine.overQuotaVariant(change), "case_3")
    }

    func testCodexChangeCarriesNoMoneyState() async throws {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(tool: .codex, snapshot: snapshot(tool: .codex, used: 20),
                                         forecast: forecast(tool: .codex, runway: 240)))
        let evaluation = await engine.evaluate(
            inputs(tool: .codex, snapshot: snapshot(tool: .codex, used: 106)))
        XCTAssertNil(try XCTUnwrap(evaluation.change).moneyState)
    }

    func testNoChangeWhenStateUnchanged() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 20), forecast: forecast(runway: 240)))
        let evaluation = await engine.evaluate(inputs(snapshot: snapshot(used: 22), forecast: forecast(runway: 240)))
        XCTAssertNil(evaluation.change, "same state must not report a transition")
        XCTAssertEqual(evaluation.state, .healthy)
    }

    func testWindowResetEmittedWhenResetsAtAdvances() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 90, resetMinutes: 30)))
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 5, resetMinutes: 330)))

        var iterator = engine.windowResets.makeAsyncIterator()
        let tool = await iterator.next()
        XCTAssertEqual(tool, .claude)
    }

    func testWindowResetIgnoresSubSecondJitter() async {
        // Claude's `resets_at` wobbles by ~1s between polls; that must not emit a windowReset.
        // Discriminate deterministically by tool: jitter Claude (must stay silent), genuinely
        // advance Codex — the stream preserves order, so the first (and only) yield must be Codex.
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 90, resetMinutes: 30)))
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 90, resetMinutes: 30 + 1.0 / 60)))
        _ = await engine.evaluate(inputs(tool: .codex, snapshot: snapshot(tool: .codex, used: 90, resetMinutes: 30)))
        _ = await engine.evaluate(inputs(tool: .codex, snapshot: snapshot(tool: .codex, used: 5, resetMinutes: 330)))

        var iterator = engine.windowResets.makeAsyncIterator()
        let tool = await iterator.next()
        XCTAssertEqual(tool, .codex, "sub-second Claude jitter must not emit a windowReset")
    }

    func testCachedStateExpiresToIdleAfterTTL() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 20), forecast: forecast(runway: 240)))
        // A JSONL delta 11 minutes later with no fresh poll → cached state past the 10-min TTL.
        let stale = StateInputs(
            tool: .claude, snapshot: snapshot(used: 20), health: .healthy,
            forecast: forecast(runway: 240), trigger: .jsonlDelta,
            now: now.addingTimeInterval(660))
        let state = await engine.evaluate(stale).state
        XCTAssertEqual(state, .idleFallback)
    }

    // MARK: jsonlDelta trigger — §13.1 Trigger 2 (STEP_26)

    func testJsonlDeltaDrivesTransition() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 20), forecast: forecast(runway: 240)))
        // A meaningful JSONL delta between polls re-evaluates against cached account data —
        // here a fast-burn short-window delta flips healthy → fastBurnSpike.
        let evaluation = await engine.evaluate(inputs(snapshot: snapshot(used: 54),
                                                      trigger: .jsonlDelta,
                                                      fastBurnDelta: 22))
        XCTAssertEqual(evaluation.state, .fastBurnSpike)
        XCTAssertEqual(evaluation.change?.previous, .healthy)
        XCTAssertEqual(evaluation.change?.new, .fastBurnSpike)
    }

    func testJsonlDeltaMultiSurfaceReachable() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(tool: .codex, snapshot: snapshot(tool: .codex, used: 30)))
        let state = await engine.evaluate(inputs(tool: .codex,
                                                 snapshot: snapshot(tool: .codex, used: 30),
                                                 trigger: .jsonlDelta,
                                                 activeSurfaceBucketCount: 2)).state
        XCTAssertEqual(state, .multiSurface, "multi-surface reachable from a JSONL delta")
    }

    func testJsonlDeltaAloneNeverEstablishesFreshness() async {
        // No successful poll has ever landed: a jsonlDelta evaluation must not treat cached-less
        // data as fresh (only `.poll` refreshes the staleness clock).
        let engine = StateEngine()
        let state = await engine.evaluate(inputs(snapshot: snapshot(used: 30), trigger: .jsonlDelta)).state
        XCTAssertEqual(state, .idleFallback)
    }

    // MARK: pollFailure trigger — §9.3 TTL and cache invalidation

    func testPollFailureDoesNotRefreshCachedStateClock() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 20), forecast: forecast(runway: 240)))
        // 9 min of failures: cached state still served (TTL not yet reached)…
        let nineMin = StateInputs(
            tool: .claude, snapshot: snapshot(used: 20), health: .unknown,
            forecast: forecast(runway: 240), trigger: .pollFailure,
            now: now.addingTimeInterval(540))
        let midway = await engine.evaluate(nineMin).state
        XCTAssertEqual(midway, .healthy, "cached state shown until the TTL expires")
        // …and the 9-min evaluation must not have reset the clock: 2 more minutes → stale.
        let elevenMin = StateInputs(
            tool: .claude, snapshot: snapshot(used: 20), health: .unknown,
            forecast: forecast(runway: 240), trigger: .pollFailure,
            now: now.addingTimeInterval(660))
        let state = await engine.evaluate(elevenMin).state
        XCTAssertEqual(state, .idleFallback, "a pollFailure evaluation never refreshes the TTL clock")
    }

    func testTTLExpiryViaPollFailureReturnsStateChange() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 20), forecast: forecast(runway: 240)))
        let stale = StateInputs(
            tool: .claude, snapshot: snapshot(used: 20), health: .unknown,
            forecast: forecast(runway: 240), trigger: .pollFailure,
            now: now.addingTimeInterval(660))
        let evaluation = await engine.evaluate(stale)

        XCTAssertEqual(evaluation.change?.previous, .healthy)
        XCTAssertEqual(evaluation.change?.new, .idleFallback)
    }

    func testPollFailureWithCrossedResetInvalidatesImmediately() async {
        let engine = StateEngine()
        // Fresh poll: window resets in 5 minutes.
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 90, resetMinutes: 5),
                                         forecast: forecast(runway: 240)))
        // 7 minutes later (well inside the 10-min TTL) a poll fails; the cached snapshot's
        // resets_at is now 2 min in the past → the window rolled over → invalidate at once.
        let failed = StateInputs(
            tool: .claude, snapshot: snapshot(used: 90, resetMinutes: 5), health: .unknown,
            forecast: forecast(runway: 240), trigger: .pollFailure,
            now: now.addingTimeInterval(420))
        let state = await engine.evaluate(failed).state
        XCTAssertEqual(state, .idleFallback,
                       "a crossed resets_at makes cached numbers wrong regardless of age")
    }

    func testFreshPollWithPastResetsAtClassifiesNullWindow() async {
        let engine = StateEngine()
        // R33-7 rewrite: this test used to assert `.healthy` ("a fresh poll's numbers are
        // current even at a just-passed boundary") — while the display was simultaneously
        // blanking the same snapshot to `——` (REV-16). That incoherence is precisely what the
        // unified Core degradation removes: an expired primary window IS a null window, on
        // every path, fresh polls included. The window this 20% describes no longer exists.
        let fresh = StateInputs(
            tool: .claude, snapshot: snapshot(used: 20, resetMinutes: -2), health: .healthy,
            forecast: forecast(runway: 240), trigger: .poll, now: now)
        let state = await engine.evaluate(fresh).state
        XCTAssertEqual(state, .nullWindow)
    }

    func testPollFailureWithFutureResetStaysOnCachedState() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 20, resetMinutes: 120),
                                         forecast: forecast(runway: 240)))
        let failed = StateInputs(
            tool: .claude, snapshot: snapshot(used: 20, resetMinutes: 120), health: .unknown,
            forecast: forecast(runway: 240), trigger: .pollFailure,
            now: now.addingTimeInterval(120))
        let state = await engine.evaluate(failed).state
        XCTAssertEqual(state, .healthy, "freeze on cached state while it is fresh (§9.3 step 2)")
    }

    // MARK: REV-33 — a hard block survives staleness, and dies with its window (STEP_39)

    /// The REV-33 regression test: the 2026-07-14 incident snapshot — 100%, blocked, resets in
    /// the future, 66 seconds old — must classify Over quota on launch restore, not Idle/fallback.
    func testRestoredHardBlockKeepsItsVerdict() async {
        let engine = StateEngine()
        let restored = StateInputs(
            tool: .claude, snapshot: snapshot(used: 100, resetMinutes: 28, reached: true),
            health: .unknown, forecast: forecast(runway: nil), trigger: .restore, now: now)
        let evaluation = await engine.evaluate(restored)
        XCTAssertEqual(evaluation.state, .overQuota,
                       "a monotone-true block must survive the restore path")
    }

    /// Same rule on the stale (`.pollFailure` past the TTL) path: the block holds while its
    /// window is open, however long polls keep failing.
    func testStaleHardBlockSurvivesTTLOnPollFailure() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 100, resetMinutes: 28, reached: true),
                                         forecast: forecast(runway: nil)))
        let stale = StateInputs(
            tool: .claude, snapshot: snapshot(used: 100, resetMinutes: 28, reached: true),
            health: .unknown, forecast: forecast(runway: nil), trigger: .pollFailure,
            now: now.addingTimeInterval(660))
        let state = await engine.evaluate(stale).state
        XCTAssertEqual(state, .overQuota, "quota cannot be un-spent — the TTL does not apply")
    }

    /// Expiry: the same snapshot with `resets_at` in the past → Idle/fallback via the null-window
    /// degradation. No block outlives its own reset time — restore path included.
    func testRestoredHardBlockExpiresWithItsWindow() async {
        let engine = StateEngine()
        let restored = StateInputs(
            tool: .claude, snapshot: snapshot(used: 100, resetMinutes: -2, reached: true),
            health: .unknown, forecast: forecast(runway: nil), trigger: .restore, now: now)
        let state = await engine.evaluate(restored).state
        XCTAssertEqual(state, .idleFallback)
    }

    /// A stale block with no `resets_at` at all has no expiry stamp and must not hold forever.
    func testStaleHardBlockWithoutResetsAtFallsToIdle() {
        let i = inputs(snapshot: snapshot(used: 100, reached: true))
        XCTAssertEqual(classify(i, isStale: true), .idleFallback,
                       "no expiry stamp → no monotone-safe survival")
    }

    /// Spend control (Codex, §13 rank 2) survives staleness exactly like Over quota — window
    /// open → rank kept; window expired → degradation strips the flag and the rank with it.
    func testStaleSpendControlSurvivesWhileWindowOpen() {
        let open = snapshot(tool: .codex, used: 50, resetMinutes: 60, spendControl: true)
        XCTAssertEqual(classify(inputs(tool: .codex, snapshot: open), isStale: true), .spendControl)
        let expired = snapshot(tool: .codex, used: 50, resetMinutes: -2, spendControl: true)
        XCTAssertEqual(classify(inputs(tool: .codex, snapshot: expired), isStale: true), .idleFallback)
    }

    // MARK: REV-96 (STEP_193) — a block is one episode, keyed to the limit that caused it

    /// The tester's shape: the five-hour window is idle and the provider's flag is up, but what
    /// is actually spent is the weekly, and the weekly is what has to reset. Keying anywhere else
    /// is what sent eleven banners for one block.
    func testEpisodeKeysToTheLimitWithTheLatestReset() {
        let blocked = snapshot(tool: .codex, used: 0, secondary: 100, resetMinutes: 90,
                               reached: true, secondaryResetMinutes: 3 * 24 * 60)
        let episode = blocked.blockEpisode
        XCTAssertEqual(episode?.limit, .secondary)
        XCTAssertEqual(episode?.limitResetsAt, now.addingTimeInterval(3 * 24 * 60 * 60))
    }

    func testEpisodeOnThePrimaryWhenItIsTheOnlySpentLimit() {
        let blocked = snapshot(used: 100, secondary: 40, resetMinutes: 45)
        XCTAssertEqual(blocked.blockEpisode?.limit, .primary)
    }

    func testEpisodeOnTheMonthlyWhenItOutlastsTheRest() {
        let blocked = snapshot(tool: .codex, used: 100, secondary: nil, resetMinutes: 60,
                               monthlyResetMinutes: 20 * 24 * 60)
        XCTAssertEqual(blocked.blockEpisode?.limit, .monthly)
    }

    func testNoEpisodeWhileNothingIsSpent() {
        XCTAssertNil(snapshot(used: 40, secondary: 60, resetMinutes: 120).blockEpisode)
    }

    /// A flagged block with no reset anywhere cannot key an episode — the notification falls back
    /// to the §16 per-window cap, which is what shipped before this step.
    func testNoEpisodeWithoutAnAnchor() {
        let flagged = snapshot(used: nil, secondary: nil, resetMinutes: nil, reached: true)
        XCTAssertNil(flagged.blockEpisode)
    }

    func testEpisodeKeyIsTheLimitAndItsReset() {
        let blocked = snapshot(used: 100, secondary: 40, resetMinutes: 45)
        XCTAssertEqual(blocked.blockEpisode?.key,
                       "primary|\(Int(now.addingTimeInterval(45 * 60).timeIntervalSince1970))")
    }

    /// Rank 3 reads the secondary since STEP_193: a spent weekly stops the account whether or not
    /// the provider raises a flag, where before it rendered amber Weekly-elevated.
    func testSpentWeeklyIsOverQuota() {
        let spent = snapshot(used: 20, secondary: 100, resetMinutes: 120,
                             secondaryResetMinutes: 2 * 24 * 60)
        XCTAssertEqual(classify(inputs(snapshot: spent)), .overQuota)
    }

    /// REV-102 / STEP_218 — the Team tester's Sunday (2026-09-20), replayed in the shape the
    /// adapter now produces: windows plus org-managed credits, **no monthly limit**. Every poll
    /// from the weekly hitting 100 % to its reset is Over quota on the weekly — never Spend
    /// control, which is what the monthly's later reset used to win — and the account is Healthy
    /// after the reset with the cap still spent.
    func testTeamSundayIsOverQuotaOnTheWeeklyNeverSpendControl() {
        func team(weekly: Double, credits: String) -> QuotaSnapshot {
            QuotaSnapshot(
                tool: .claude, primaryUsedPct: 0, primaryResetsAt: nil,
                primaryWindowSeconds: 18_000,
                secondaryUsedPct: weekly,
                secondaryResetsAt: now.addingTimeInterval(36 * 3600),
                rateLimitReached: false,
                extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 5000,
                                       usedCredits: Decimal(string: credits),
                                       currency: "EUR", managedByOrganization: true,
                                       currencyExponent: 2))
        }
        for credits in ["16.8", "57.4", "70.25"] {   // severity normal / warning / critical
            let poll = team(weekly: 100, credits: credits)
            XCTAssertEqual(classify(inputs(snapshot: poll)), .overQuota, "credits \(credits)")
            XCTAssertEqual(poll.blockEpisode?.limit, .secondary, "credits \(credits)")
            XCTAssertFalse(poll.monthlyReached)
        }
        XCTAssertEqual(classify(inputs(snapshot: team(weekly: 0, credits: "70.25"))), .healthy,
                       "a spent cap alone stops nothing (owner ruling 2026-09-21, REV-102 §4)")
    }

    /// Rank 2 reads the monthly since STEP_193 — the Claude Team/Enterprise spend limit has no
    /// flag behind it, so this was the gap where the card said "Spend limit reached" and the
    /// engine said Null-window (REV-96 §1.4).
    func testMonthlyAtTheCeilingIsSpendControlWithoutAFlag() {
        let spent = snapshot(used: nil, secondary: nil, monthlyResetMinutes: 9 * 24 * 60)
        XCTAssertEqual(classify(inputs(snapshot: spent)), .spendControl)
        let notSpent = snapshot(used: nil, secondary: nil, monthlyResetMinutes: 9 * 24 * 60,
                                monthlyUsed: 2000)
        XCTAssertNotEqual(classify(inputs(snapshot: notSpent)), .spendControl)
    }

    /// The stale anchor is the blocking limit's reset. The five-hour window rolls over inside the
    /// block — its reset passes, the degradation nils it — and the weekly still holds the block,
    /// where before the state dropped to Idle and the next poll re-entered as a new transition.
    func testStaleBlockSurvivesOnTheWeeklyAnchorAfterThePrimaryExpires() {
        let stale = snapshot(tool: .codex, used: 0, secondary: 100, resetMinutes: -30,
                             reached: true, secondaryResetMinutes: 2 * 24 * 60)
        XCTAssertEqual(classify(inputs(tool: .codex, snapshot: stale), isStale: true), .overQuota)
    }

    /// And it dies with the limit that held it: past the weekly's own reset there is no episode
    /// and no block, on the stale path exactly as on the fresh one (R33-7, unchanged).
    func testStaleBlockExpiresWithTheWeekly() {
        let expired = snapshot(tool: .codex, used: 0, secondary: 100, resetMinutes: -30,
                               reached: true, secondaryResetMinutes: -2)
        XCTAssertEqual(classify(inputs(tool: .codex, snapshot: expired), isStale: true),
                       .idleFallback)
    }

    // MARK: REV-38 (STEP_43) — spend-control recovery via the monthly reset (R33-1 extension)

    /// A monthly-limit account's windows are null in every healthy capture (§8.3), so a stale
    /// spend-control block has no `primary_resets_at` — its recovery anchor is the monthly
    /// `individual_limit.reset_at`. Future monthly reset → the block survives the TTL.
    func testStaleSpendControlSurvivesOnMonthlyAnchorWithNullWindows() {
        let s = snapshot(tool: .codex, used: nil, secondary: nil, spendControl: true,
                         monthlyResetMinutes: 3 * 24 * 60)
        XCTAssertEqual(classify(inputs(tool: .codex, snapshot: s), isStale: true), .spendControl,
                       "the monthly reset is the block's expiry stamp — rank 2 holds")
    }

    /// …and the block dies with its month: an expired monthly reset degrades the limit and the
    /// flag (D-35 — the R33-7 rule at month scale), so the stale path finds nothing to hold.
    func testStaleSpendControlExpiresWithItsMonth() {
        let s = snapshot(tool: .codex, used: nil, secondary: nil, spendControl: true,
                         monthlyResetMinutes: -3)
        XCTAssertEqual(classify(inputs(tool: .codex, snapshot: s), isStale: true), .idleFallback)
    }

    /// Without any anchor — null windows AND no monthly limit — a stale spend-control flag has
    /// no expiry stamp and must not hold forever (the pre-REV-38 rule, unchanged).
    func testStaleSpendControlWithoutAnyAnchorFallsToIdle() {
        let s = snapshot(tool: .codex, used: nil, secondary: nil, spendControl: true)
        XCTAssertEqual(classify(inputs(tool: .codex, snapshot: s), isStale: true), .idleFallback)
    }

    /// Live (non-stale) rank 2 needs no anchor — an observed block is never suppressed (§13).
    func testLiveSpendControlClassifiesOnMonthlyAccountNullWindows() {
        let s = snapshot(tool: .codex, used: nil, secondary: nil, spendControl: true,
                         monthlyResetMinutes: 3 * 24 * 60)
        XCTAssertEqual(classify(inputs(tool: .codex, snapshot: s)), .spendControl)
    }

    /// Scope boundary (anti-regression): no rate-derived warning — and Bad timing, deliberately —
    /// ever survives the TTL. A stale sub-100 number can only understate; warnings still rot.
    func testStaleWarningsStillClearAtTTL() {
        let cases: [(String, StateInputs)] = [
            ("bad timing", inputs(snapshot: snapshot(used: 91, resetMinutes: 128))),
            ("at risk", inputs(snapshot: snapshot(used: 87, resetMinutes: 20),
                               forecast: forecast(runway: 11))),
            ("elevated", inputs(snapshot: snapshot(used: 60, resetMinutes: 100),
                                forecast: forecast(runway: 40))),
            ("fast burn", inputs(snapshot: snapshot(used: 54, resetMinutes: 100),
                                 fastBurnDelta: 22)),
            ("off-machine", inputs(snapshot: snapshot(used: 72, resetMinutes: 100),
                                   utilDeltaLast2Polls: 3,
                                   lastLocalActivityAt: now.addingTimeInterval(-3600))),
        ]
        for (label, i) in cases {
            XCTAssertEqual(classify(i, isStale: true), .idleFallback,
                           "\(label) must not survive staleness")
        }
    }

    /// The restore trigger never counts as freshness: a restored *healthy* snapshot classifies
    /// Idle/fallback however young it is — only the hard block is monotone-safe (R33-1), and
    /// only a real `.poll` refreshes the TTL clock.
    func testRestoreNeverClassifiesFromRateDerivedFreshness() async {
        let engine = StateEngine()
        let restored = StateInputs(
            tool: .claude, snapshot: snapshot(used: 40, resetMinutes: 120), health: .unknown,
            forecast: forecast(runway: 240), trigger: .restore, now: now)
        let state = await engine.evaluate(restored).state
        XCTAssertEqual(state, .idleFallback,
                       "restored data must not impersonate a live poll")
    }

    // MARK: R33-7 — a reset into a null window is a reset

    /// The R33-7 regression test: anchor `resets_at = T`, state Over quota; a poll at `T + 90s`
    /// returns Claude's post-reset shape — since REV-80 / D-101 the **not-started** one (0%, no
    /// reset, 18 000 s). The reset must be detected off the clock (the payload carries no
    /// `resets_at` to advance) and the state must be Healthy on **that** poll — not three calm
    /// polls later.
    func testResetIntoNotStartedWindowClearsBlockOnFirstPoll() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 100, resetMinutes: 5, reached: true),
                                         forecast: forecast(runway: nil)))
        let postReset = StateInputs(
            tool: .claude, snapshot: snapshot(used: 0, secondary: 18, windowSeconds: 18_000),
            health: .healthy, forecast: forecast(runway: nil), trigger: .poll,
            now: now.addingTimeInterval(390))   // T = +5 min; poll at T + 90s
        let evaluation = await engine.evaluate(postReset)
        XCTAssertEqual(evaluation.state, .healthy,
                       "the §13.4 bypass must fire on the expired anchor, not wait 3 calm polls")

        var iterator = engine.windowResets.makeAsyncIterator()
        let tool = await iterator.next()
        XCTAssertEqual(tool, .claude, "a reset into a not-started window emits windowReset")
    }

    /// Fire once per anchor: a run of post-reset null polls must not re-emit `windowReset` (and
    /// re-clear §13.2 notification state) every cycle. Order-discrimination pattern: after three
    /// Claude null polls, a genuine Codex reset — the stream preserves order, so exactly one
    /// Claude yield may precede the Codex one.
    func testExpiredAnchorFiresOncePerAnchor() async {
        let engine = StateEngine()
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 100, resetMinutes: 5, reached: true),
                                         forecast: forecast(runway: nil)))
        for offset in [390.0, 630.0, 870.0] {
            let nullPoll = StateInputs(
                tool: .claude, snapshot: snapshot(used: nil, secondary: 18), health: .healthy,
                forecast: forecast(runway: nil), trigger: .poll,
                now: now.addingTimeInterval(offset))
            _ = await engine.evaluate(nullPoll)
        }
        _ = await engine.evaluate(inputs(tool: .codex, snapshot: snapshot(tool: .codex, used: 90, resetMinutes: 30)))
        _ = await engine.evaluate(inputs(tool: .codex, snapshot: snapshot(tool: .codex, used: 5, resetMinutes: 330)))

        var iterator = engine.windowResets.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first, .claude, "the expiry fire")
        XCTAssertEqual(second, .codex,
                       "no second Claude yield — the anchor was cleared on the expiry fire")
    }

    /// Expired ⇒ null on every trigger: no hard block can be classified from an expired window,
    /// whatever the path (`classify` applies the shared Core degradation itself).
    func testExpiredWindowIsNullOnEveryTrigger() {
        let expired = snapshot(used: 100, resetMinutes: -2, reached: true)
        for trigger in [StateTrigger.poll, .pollFailure, .jsonlDelta, .restore] {
            let i = inputs(snapshot: expired, trigger: trigger)
            XCTAssertNotEqual(classify(i, isStale: false), .overQuota, "trigger \(trigger.rawValue)")
            XCTAssertNotEqual(classify(i, isStale: true), .overQuota, "trigger \(trigger.rawValue)")
        }
    }

    // MARK: R33-6 — a cold launch into a blocked window is not silent

    /// A first evaluation landing directly in a hard block emits a StateChange (a transition
    /// from nothing) so the over-quota notification can fire on a cold launch.
    func testFirstEvaluationHardBlockEmitsChange() async {
        let engine = StateEngine()
        let evaluation = await engine.evaluate(
            inputs(snapshot: snapshot(used: 100, resetMinutes: 28, reached: true),
                   forecast: forecast(runway: nil)))
        XCTAssertEqual(evaluation.change?.previous, .idleFallback)
        XCTAssertEqual(evaluation.change?.new, .overQuota)
    }

    /// No rate-derived state may fire from a first evaluation — it has no prior sample to be a
    /// change from. (This is the pre-R33-6 rule, kept for everything but the hard block.)
    func testFirstEvaluationWarningStaysSilent() async {
        let engine = StateEngine()
        let evaluation = await engine.evaluate(
            inputs(snapshot: snapshot(used: 87, resetMinutes: 20), forecast: forecast(runway: 11)))
        XCTAssertEqual(evaluation.state, .atRisk)
        XCTAssertNil(evaluation.change, "launching into a warning state never notifies")
    }

    // MARK: D-124 — a first evaluation into Limit nearly spent is not silent (REV-100 §2.4)

    /// A tool with no saved reading whose first live poll lands in rank 5b emits the transition
    /// from nothing, carrying the assessment event 9 is keyed on.
    func testFirstEvaluationNearlySpentEmitsChange() async {
        let engine = StateEngine()
        let evaluation = await engine.evaluate(
            inputs(snapshot: snapshot(used: 22, secondary: 91, secondaryResetMinutes: halfWeek),
                   forecast: forecast(runway: 240)))
        XCTAssertEqual(evaluation.change?.previous, .idleFallback)
        XCTAssertEqual(evaluation.change?.new, .limitNearlySpent)
        XCTAssertEqual(evaluation.change?.longLimit?.tier, .nearlySpent)
    }

    /// Amber has no notification to lose, so its first evaluation stays silent.
    func testFirstEvaluationAheadOfPaceStaysSilent() async {
        let engine = StateEngine()
        let evaluation = await engine.evaluate(
            inputs(snapshot: snapshot(used: 22, secondary: 70, secondaryResetMinutes: halfWeek),
                   forecast: forecast(runway: 240)))
        XCTAssertEqual(evaluation.state, .limitAheadOfPace)
        XCTAssertNil(evaluation.change)
    }

    /// The relaunch path, which needed no exemption: restore classifies the saved reading stale
    /// (Idle, silently), and the first live poll is a real Idle → 5b transition.
    func testRestoreThenLivePollIntoNearlySpentEmitsChange() async {
        let engine = StateEngine()
        let red = snapshot(used: 22, secondary: 91, secondaryResetMinutes: halfWeek)
        let restored = await engine.evaluate(
            inputs(snapshot: red, forecast: forecast(runway: nil), trigger: .restore))
        XCTAssertEqual(restored.state, .idleFallback)
        XCTAssertNil(restored.change)

        let live = await engine.evaluate(inputs(snapshot: red, forecast: forecast(runway: 240)))
        XCTAssertEqual(live.change?.previous, .idleFallback)
        XCTAssertEqual(live.change?.new, .limitNearlySpent)
    }

    // MARK: R33-7 — money glyph demotes with its window

    func testGlyphWindowResetBypassesDemoteHold() {
        // A red `charging` $ measured against a spent window demotes on the reset evaluation,
        // not after `glyphDemotePolls`.
        let held = StateEngine.resolveGlyphHysteresis(
            previous: .charging, candidate: .none, demoteStreak: 0, trigger: .poll)
        XCTAssertEqual(held.glyph, .charging, "without a reset the demote hold applies")
        let bypassed = StateEngine.resolveGlyphHysteresis(
            previous: .charging, candidate: .none, demoteStreak: 0, trigger: .poll,
            windowReset: true)
        XCTAssertEqual(bypassed.glyph, .none, "nothing measured about a spent window outlives it")
    }

    func testPersistsTransitionWhenStoreProvided() async throws {
        let path = NSTemporaryDirectory().appending("state-engine-\(UUID().uuidString).db")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let store = try SQLiteStore(path: path)
        let engine = StateEngine(store: store)

        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 20), forecast: forecast(runway: 240)))
        _ = await engine.evaluate(inputs(snapshot: snapshot(used: 106)))

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM state_transitions WHERE tool = ?", arguments: ["claude"])
                XCTAssertEqual(row?["from_state"], "healthy")
                XCTAssertEqual(row?["to_state"], "over_quota")
                XCTAssertEqual(row?["triggered_by"], "poll")
            }
        }
    }
}
