import XCTest
@testable import KvotarCore

/// STEP_88 / REV-59 §5 (UI Spec D-60) — the low-allowance Codex shape: a primary window at least
/// seven days wide with no secondary window, no monthly limit and no credits. On that shape a
/// single turn can move the meter by a fifth of the whole allowance (`go`, 2026-08-11: twelve
/// turns, 0% → 89%, per-turn deltas 4–19 points), so no rate we could state would survive contact
/// with the data. Burn, runway and the forecast are therefore absent — never zero (§11.2a) — and
/// the state falls back to the used percentage alone.
///
/// **Amended STEP_101 (2026-08-13, UI Spec D-64).** The rule was *only* a shape test — primary
/// window ≥ 7 days — and it caught **Plus**, whose window is exactly 7 days wide, muting every
/// Codex alert but Over quota on the day the account upgraded. It is now a plan name (`free`,
/// `go`) **or** a ≥ 30-day single-window shape as the backstop for a plan nobody has captured.
/// The `plan_type` branch is a deliberate, recorded carve-out from D-34/D-58, which still hold
/// everywhere else. Measured 2026-08-13: `go` ~7.1% of its window per turn, `free` ~2.8%, `plus`
/// **0.08%** — roughly 200x apart with nothing between.
final class LowAllowanceShapeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let thirtyDays = 30 * 86_400
    private static let fiveHours = 5 * 3_600

    // MARK: Builders

    /// The measured `go`/`free` shape: one 43,200-minute window, no secondary, no credits, no
    /// monthly limit. `planType` is deliberately settable so the tests can prove the predicate
    /// ignores it.
    private func lowAllowance(
        used: Double?,
        resetMinutes: Double? = 30 * 24 * 60,
        windowSeconds: Int? = thirtyDays,
        secondary: Double? = nil,
        monthly: MonthlyLimit? = nil,
        creditsBalance: Double? = nil,
        reached: Bool = false,
        planType: String = "go"
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: .codex,
            primaryUsedPct: used,
            primaryResetsAt: resetMinutes.map { now.addingTimeInterval($0 * 60) },
            primaryWindowSeconds: windowSeconds,
            secondaryUsedPct: secondary,
            secondaryResetsAt: nil,
            rateLimitReached: reached,
            creditsBalance: creditsBalance,
            monthlyLimit: monthly,
            planType: planType)
    }

    private func classify(_ snapshot: QuotaSnapshot, forecast: Forecast? = nil) -> AppState {
        StateEngine.classify(
            StateInputs(tool: .codex, snapshot: snapshot, health: .healthy,
                        forecast: forecast ?? Forecast(tool: .codex, tier: .unknown,
                                                       runwayMinutes: nil, burnRatePerMin: nil,
                                                       isEstimate: false, pollCount: 10),
                        trigger: .poll, now: now),
            isStale: false)
    }

    // MARK: State — used-% thresholds alone (§13 REV-59 amendment)

    /// **The pre-fix failure.** Bad timing is the one rank whose inputs are *not* rate-derived —
    /// "used ≥ 85% and the reset is ≥ 90 minutes away" is permanently true on a 30-day window — so
    /// it is the only rank-4-to-7 state that survives the loss of the forecast on its own. Left
    /// ungated it would pin a red critical state and its "you risk hitting the limit" hint on
    /// the card for weeks at a stretch. REV-59's stated reason for turning it off (forecast-derived)
    /// does not apply to it; the ruling that it is off does, and this is that ruling.
    func testBadTimingCannotFireOnTheLowAllowanceShape() {
        XCTAssertEqual(classify(lowAllowance(used: 90)), .elevated,
                       "a 30-day window is always ≥ 90 min from its reset — bad timing would never stop firing")
    }

    func testElevatedFromUsedPercentAlone() {
        XCTAssertEqual(classify(lowAllowance(used: 97)), .elevated)
        XCTAssertEqual(classify(lowAllowance(used: 60)), .elevated, "60% is the amber boundary, inclusive")
    }

    func testHealthyBelowTheAmberThreshold() {
        XCTAssertEqual(classify(lowAllowance(used: 59)), .healthy)
        XCTAssertEqual(classify(lowAllowance(used: 0)), .healthy)
    }

    /// The hard block is the one verdict that still matters here, and it is observed rather than
    /// forecast — ranks 2 and 3 stay above the shape branch.
    func testHardBlockStillClassifies() {
        XCTAssertEqual(classify(lowAllowance(used: 100)), .overQuota)
        XCTAssertEqual(classify(lowAllowance(used: 42, reached: true)), .overQuota)
    }

    /// A window that has not started (REV-57) has no utilization to threshold on, so the branch is
    /// guarded on a present `usedPct` and rank 12 keeps the case.
    func testUnanchoredWindowStillReadsNullWindow() {
        let unanchored = lowAllowance(used: nil, resetMinutes: nil)
        XCTAssertEqual(classify(unanchored), .nullWindow)
    }

    /// Rate-derived ranks stay unreachable even when the caller hands us the raw deltas: the shape
    /// branch sits above them, so no local signal can pull a fast-burn or off-machine verdict out
    /// of a meter that moves 4–19 points per turn.
    func testRateDerivedRanksAreUnreachable() {
        let inputs = StateInputs(
            tool: .codex, snapshot: lowAllowance(used: 70), health: .healthy,
            forecast: Forecast(tool: .codex, tier: .unknown, runwayMinutes: nil,
                               burnRatePerMin: nil, isEstimate: false, pollCount: 10),
            trigger: .poll, now: now,
            fastBurnDelta: 45, utilDeltaLast2Polls: 19,
            activeSurfaceBucketCount: 3,
            lastLocalActivityAt: now.addingTimeInterval(-3_600))
        XCTAssertEqual(StateEngine.classify(inputs, isStale: false), .elevated,
                       "a 45-point two-minute jump is an ordinary turn here, not a spike")
    }

    // MARK: Forecast — the outputs are absent, not zero (§11.2a, §11.3 REV-59 amendment)

    /// **The pre-fix failure.** A full ten-sample buffer rising 1% a minute produces a perfectly
    /// well-formed burn rate and runway today. On this shape both are fiction: the samples are
    /// real, the arithmetic over them is not, because the next single turn can move the meter
    /// further than the whole ten-poll average predicts.
    func testForecastProducesNoBurnAndNoRunwayOnTheShape() async {
        let engine = ForecastEngine()
        var f: Forecast?
        for i in 0..<10 {
            f = await engine.record(snapshot: lowAllowance(used: Double(i)),
                                    at: now.addingTimeInterval(Double(i) * 60))
        }
        XCTAssertEqual(f?.pollCount, 10, "the buffer keeps filling — we suppress the output, not the observation")
        XCTAssertNil(f?.burnRatePerMin, "a rate we have failed to model must not be stated")
        XCTAssertNil(f?.runwayMinutes, "a forecast obsolete before it draws is worse than silence")
    }

    /// The same buffer on a five-hour window still computes both — this is the regression that
    /// matters, since the engine is shared by both tools and every Codex tier.
    ///
    /// `planType` is Enterprise here, which is what every five-hour + weekly shape in the corpus
    /// actually is. Before STEP_101 this read `go` and passed on the window width alone; the name
    /// branch is decisive now, so leaving it would have tested the wrong thing.
    func testFiveHourWindowStillForecasts() async {
        let engine = ForecastEngine()
        var f: Forecast?
        for i in 0..<10 {
            f = await engine.record(
                snapshot: lowAllowance(used: Double(i), resetMinutes: 200,
                                       windowSeconds: Self.fiveHours, secondary: 10,
                                       planType: "enterprise"),
                at: now.addingTimeInterval(Double(i) * 60))
        }
        XCTAssertEqual(f?.burnRatePerMin ?? 0, 1, accuracy: 0.01)
        XCTAssertNotNil(f?.runwayMinutes)
    }

    // MARK: The regression that matters — every other shape is untouched

    /// The five-hour consumer/Enterprise shape keeps every rank it has today.
    func testFiveHourWindowKeepsItsExistingClassification() {
        let fiveHour = lowAllowance(used: 91, resetMinutes: 128, windowSeconds: Self.fiveHours,
                                    secondary: 10, planType: "plus")
        XCTAssertEqual(classify(fiveHour), .badTiming,
                       "narrow windows are exactly where bad timing earns its place")
    }

    /// Claude reports no window width at all, which is what makes it structurally immune.
    func testClaudeIsUnreachableByTheShapeRule() {
        let claude = QuotaSnapshot(
            tool: .claude, primaryUsedPct: 91,
            primaryResetsAt: now.addingTimeInterval(128 * 60),
            secondaryUsedPct: 10, secondaryResetsAt: nil, rateLimitReached: false)
        let state = StateEngine.classify(
            StateInputs(tool: .claude, snapshot: claude, health: .healthy,
                        forecast: Forecast(tool: .claude, tier: .unknown, runwayMinutes: nil,
                                           burnRatePerMin: nil, isEstimate: false, pollCount: 10),
                        trigger: .poll, now: now),
            isStale: false)
        XCTAssertEqual(state, .badTiming)
    }

    // MARK: The rule itself — name first, shape as the backstop (STEP_101, D-64)

    /// **The defect this step exists for.** Plus reports one 7-day window, no secondary, no
    /// monthly limit and no credits — the old `≥ 7 days` width test matched it exactly, and from
    /// the 2026-08-12 upgrade the account lost its burn card, its verdict and six of seven alerts
    /// while the popover told a user at 3% used that "one working session can use most of it".
    func testPlusIsNotLowAllowance() {
        let plus = lowAllowance(used: 3, resetMinutes: 7 * 24 * 60,
                                windowSeconds: 7 * 86_400, planType: "plus")
        XCTAssertFalse(plus.isLowAllowanceShape,
                       "0.08% of the window per turn measured across 88 turns — this is a rate a display can carry")
    }

    /// The name is decisive, and this is the case a width test could never express: the same
    /// 7-day width that must stay unmuted on Plus must stay muted if the plan is `go`.
    func testNamedPlansMatchOnAnyWidth() {
        for plan in ["go", "free", "GO", "Free"] {
            let snap = lowAllowance(used: 40, resetMinutes: 7 * 24 * 60,
                                    windowSeconds: 7 * 86_400, planType: plan)
            XCTAssertTrue(snap.isLowAllowanceShape, "\(plan) on a 7-day window must still mute")
        }
    }

    /// A named plan is muted even where the shape guards would not be — the guards belong to the
    /// backstop, which is the branch that guesses about a plan nobody has seen.
    func testNamedPlanBeatsTheShapeGuards() {
        let odd = lowAllowance(used: 40, secondary: 12, creditsBalance: 5, planType: "go")
        XCTAssertTrue(odd.isLowAllowanceShape)
    }

    /// The backstop: an unfamiliar plan string shaped like the two we measured is still muted.
    /// This is what keeps the rule from failing silently on a tier OpenAI has not shipped yet.
    func testUnknownPlanOnAThirtyDayShapeIsMuted() {
        XCTAssertTrue(lowAllowance(used: 40, planType: "starter_2027").isLowAllowanceShape)
        XCTAssertTrue(lowAllowance(used: 40, planType: "").isLowAllowanceShape)
    }

    /// …and it does not overreach: an unfamiliar plan on a **7-day** window keeps its rate display.
    /// 30 days is the measured consumer width (43,200 minutes on both `free` and `go`); Plus is
    /// 10,080 and everything between is unobserved, so the benefit of the doubt goes to showing.
    func testUnknownPlanOnASevenDayShapeIsNotMuted() {
        let weekly = lowAllowance(used: 40, resetMinutes: 7 * 24 * 60,
                                  windowSeconds: 7 * 86_400, planType: "starter_2027")
        XCTAssertFalse(weekly.isLowAllowanceShape)
    }

    /// The backstop's guards, each on its own: anything else in the account means this is a
    /// working quota rather than a consumer allowance.
    func testBackstopGuardsEachExcludeTheShape() {
        let unknown = "starter_2027"
        XCTAssertFalse(lowAllowance(used: 40, secondary: 12, planType: unknown).isLowAllowanceShape)
        XCTAssertFalse(lowAllowance(used: 40, creditsBalance: 0, planType: unknown).isLowAllowanceShape)
        XCTAssertFalse(lowAllowance(
            used: 40,
            monthly: MonthlyLimit(limitAmount: 4_000, usedAmount: 10, remainingPercent: 99,
                                  resetsAt: now.addingTimeInterval(86_400), unit: .credits),
            planType: unknown).isLowAllowanceShape)
        XCTAssertFalse(QuotaSnapshot(
            tool: .codex, primaryUsedPct: 40,
            primaryResetsAt: now.addingTimeInterval(30 * 86_400),
            primaryWindowSeconds: Self.thirtyDays,
            secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: false,
            extraUsage: ExtraUsage(isEnabled: true),
            planType: unknown).isLowAllowanceShape, "pay-as-you-go means the ceiling is not the story")
    }

    /// No width, no name ⇒ no claim. This is the state a launch-restored snapshot was permanently
    /// in before `v18` persisted the width (P1-28), and it is why P1-28 rode this step.
    func testNoEvidenceMeansNoMute() {
        XCTAssertFalse(lowAllowance(used: 40, windowSeconds: nil, planType: "starter_2027")
            .isLowAllowanceShape)
    }

    /// **Claude is out by an explicit tool guard, not by accident** (decision 2026-08-13). It used
    /// to be immune only because it reports no window width; with a name branch in the rule, a
    /// Claude plan string reading `free` would otherwise strip its burn card, verdict and alerts
    /// on a five-hour window that refills roughly five times a day.
    func testClaudeNeverMatchesEvenOnANamedPlan() {
        let claude = QuotaSnapshot(
            tool: .claude, primaryUsedPct: 40,
            primaryResetsAt: now.addingTimeInterval(30 * 86_400),
            primaryWindowSeconds: Self.thirtyDays,
            secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: false,
            planType: "free")
        XCTAssertFalse(claude.isLowAllowanceShape)
    }
}
