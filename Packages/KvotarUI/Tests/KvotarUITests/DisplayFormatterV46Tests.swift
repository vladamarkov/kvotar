import XCTest
import KvotarCore
@testable import KvotarUI

/// Display semantics for the v4.6 menu bar (still current) plus the v4.7 header rework (STEP_33):
/// the §2.2a runway verdict matrix, the weekly-elevated signal chain, per-source freshness stamps,
/// and over-quota overflow. The v4.6 weekly thin bar + runway timeline are gone (REV-25).
final class DisplayFormatterV46Tests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        tool: Tool = .claude, used: Double?, secondary: Double? = nil,
        secondaryResetDays: Double? = nil, resetMinutes: Double? = nil,
        windowSeconds: Int? = nil,
        extraUsage: ExtraUsage = .disabled, plan: String? = "Pro"
    ) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool,
                      primaryUsedPct: used,
                      primaryResetsAt: resetMinutes.map { now.addingTimeInterval($0 * 60) },
                      primaryWindowSeconds: windowSeconds,
                      secondaryUsedPct: secondary,
                      secondaryResetsAt: secondaryResetDays.map { now.addingTimeInterval($0 * 86_400) },
                      rateLimitReached: false,
                      extraUsage: extraUsage,
                      planType: plan)
    }

    /// `burn` defaults to a measured 0 when there is no runway — the burn≈0 case. Pass `burn: nil`
    /// explicitly for the *unmeasurable* case (cold start, or a flat reading inside the §11.2a
    /// quantization span); the two are different claims and the verdict distinguishes them.
    private func forecast(tool: Tool = .claude, runway: Double?,
                          burn: Double? = -1) -> Forecast {
        let resolved = burn == -1 ? (runway == nil ? 0 : 1) : burn
        return Forecast(tool: tool, tier: .fullRunway, runwayMinutes: runway,
                        burnRatePerMin: resolved, isEstimate: false, pollCount: 10)
    }

    private func clock(_ minutes: Double) -> String { Fmt.clock(now.addingTimeInterval(minutes * 60)) }
    private func cd(_ minutes: Double) -> String { Fmt.countdown(to: now.addingTimeInterval(minutes * 60), from: now)! }

    // MARK: The ⚠ menu slot (§1.2 / §1.3 — moved to red in STEP_195, REV-96 §2.5)

    /// **Amber changes the dot and nothing else.** The slot used to fire here — it was
    /// Weekly-elevated's, and STEP_194 re-pointed the condition without moving the tier — which
    /// spent the bar's one slot on the quieter of the two signals. The string is now identical to
    /// the green one for the same inputs; only the dot says anything.
    func testLimitAheadOfPaceKeepsTheOrdinaryStringAndOnlyMovesTheDot() {
        let s = snapshot(used: 22, secondary: 91, secondaryResetDays: 3, resetMinutes: 112)
        let amber = DisplayFormatter.toolMenuBar(tool: .claude, state: .limitAheadOfPace,
                                                 snapshot: s, forecast: nil, now: now)
        let green = DisplayFormatter.toolMenuBar(tool: .claude, state: .healthy,
                                                 snapshot: s, forecast: nil, now: now)
        XCTAssertEqual(amber.fullString, "CL 78% ↻1h52m", "both numbers are remaining (D-97)")
        XCTAssertEqual(amber.fullString, green.fullString, "amber must not change the string")
        XCTAssertEqual(amber.dot, .amber)
        XCTAssertEqual(green.dot, .green)
    }

    func testLimitAheadOfPaceKeepsTheOrdinaryStringOnCodex() {
        let s = snapshot(tool: .codex, used: 24, secondary: 88, secondaryResetDays: 3,
                         resetMinutes: 124)
        let amber = DisplayFormatter.toolMenuBar(tool: .codex, state: .limitAheadOfPace,
                                                 snapshot: s, forecast: nil, now: now)
        XCTAssertEqual(amber.fullString, "CX 76% ↻2h04m")
        XCTAssertEqual(
            amber.fullString,
            DisplayFormatter.toolMenuBar(tool: .codex, state: .healthy, snapshot: s,
                                         forecast: nil, now: now).fullString)
    }

    /// **Red takes the bar** (REV-100 §2.1 / D-124 — STEP_210): the long limit's left percent and
    /// its own reset, held, red dot, no reminder. Until this step red kept the five-hour string and
    /// put the weekly in a five-second reminder, which is how the tester's red weekly went unseen
    /// on 2026-09-16 behind `CX 96% ↻41m`.
    func testLimitNearlySpentHoldsTheBarOnBothTools() {
        let claude = DisplayFormatter.toolMenuBar(
            tool: .claude, state: .limitNearlySpent,
            snapshot: snapshot(used: 36, secondary: 92, secondaryResetDays: 3, resetMinutes: 112),
            forecast: nil, now: now)
        XCTAssertEqual(claude.fullString, "CL ⚠wk 8% ↻3d")
        XCTAssertEqual(claude.reminders, [])
        XCTAssertEqual(claude.dot, .red)
        // Held, not ended: the limit stays in the reading, so the episode survives.
        XCTAssertEqual(claude.longLimits.statuses.map(\.tier), [.nearlySpent])

        // The primary is calm in both: every five-hour warning outranks 5b, so a tight primary
        // under this rank is a state the engine cannot reach.
        let codex = DisplayFormatter.toolMenuBar(
            tool: .codex, state: .limitNearlySpent,
            snapshot: snapshot(tool: .codex, used: 24, secondary: 92, secondaryResetDays: 3,
                               resetMinutes: 124),
            forecast: nil, now: now)
        XCTAssertEqual(codex.fullString, "CX ⚠wk 8% ↻3d")
        XCTAssertEqual(codex.reminders, [])
        XCTAssertEqual(codex.dot, .red)
    }

    /// A *monthly* nearly reached says `mo`, not `wk` — which limit it is changes what the reader
    /// does about it — and counts down to the month's own reset.
    func testMonthlyNearlyReachedSaysMo() {
        let monthly = MonthlyLimit(limitAmount: 5000, usedAmount: 4600, remainingPercent: 8,
                                   resetsAt: now.addingTimeInterval(9 * 86_400))
        let s = QuotaSnapshot(tool: .claude, primaryUsedPct: 16,
                              primaryResetsAt: now.addingTimeInterval(112 * 60),
                              primaryWindowSeconds: 18_000, secondaryUsedPct: nil,
                              secondaryResetsAt: nil, rateLimitReached: false,
                              extraUsage: .disabled, monthlyLimit: monthly, planType: "team")
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .limitNearlySpent,
                                             snapshot: s, forecast: nil, now: now)
        XCTAssertEqual(m.fullString, "CL ⚠mo 8% ↻9d")
        XCTAssertEqual(m.reminders, [])
    }

    /// P1-16b: the Claude spend limit is reached and nobody has captured what that stops, so the
    /// five-hour keeps the hero — and the bar still has to say the budget is gone.
    ///
    /// The limit that stopped you takes
    /// the bar and holds it, with no cycle (§2.5). This is what STEP_195 deferred — the bar used
    /// to read the five-hour number and the five-hour reset under a red dot while the popover
    /// hero read `0% Weekly quota left`.
    func testAConfirmedWeeklyBlockTakesTheBarAndHolds() {
        let s = snapshot(used: 19, secondary: 100, secondaryResetDays: 2.2, resetMinutes: 112)
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .overQuota, snapshot: s,
                                             forecast: nil, now: now)
        XCTAssertEqual(m.fullString, "CL ⚠wk 0% ↻3d")
        XCTAssertTrue(m.reminders.isEmpty)
        XCTAssertEqual(m.dot, .red)
    }

    /// A block by the **five-hour** is untouched: today's shape was already right.
    func testAFiveHourBlockKeepsTodaysShape() {
        let s = snapshot(used: 100, secondary: 61, secondaryResetDays: 3, resetMinutes: 48)
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .overQuota, snapshot: s,
                                             forecast: nil, now: now)
        XCTAssertEqual(m.fullString, "CL 0% ↻48m")
        XCTAssertTrue(m.reminders.isEmpty)
    }

    /// A monthly *ahead of pace* never claims the slot — amber is dot-only whichever limit it is,
    /// and `⚠wk` would in any case be naming the wrong one.
    func testMonthlyAheadOfPaceDoesNotClaimTheWeeklySlot() {
        let monthly = MonthlyLimit(limitAmount: 4000, usedAmount: 3400, remainingPercent: 15,
                                   resetsAt: now.addingTimeInterval(17 * 86_400))
        let s = QuotaSnapshot(tool: .claude, primaryUsedPct: 22,
                              primaryResetsAt: now.addingTimeInterval(112 * 60),
                              primaryWindowSeconds: nil, secondaryUsedPct: nil,
                              secondaryResetsAt: nil, rateLimitReached: false,
                              extraUsage: .disabled, monthlyLimit: monthly, planType: "team")
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .limitAheadOfPace,
                                             snapshot: s, forecast: nil, now: now)
        XCTAssertFalse(m.fullString.contains("⚠wk"))
    }

    /// D-98 (REV-78) deleted `gaugeFill` and `tier` with the gauge glyph, so the two tests that
    /// asserted them directly are gone. What they were really pinning — that the state's colour
    /// and the displayed number both survive the trip through `toolMenuBar` — is asserted here on
    /// the two fields that still render.
    func testContentStateCarriesDotAndRemainingPercent() {
        let m = DisplayFormatter.toolMenuBar(
            tool: .claude, state: .atRisk,
            snapshot: snapshot(used: 87, resetMinutes: 40), forecast: forecast(runway: 11),
            now: now)
        XCTAssertEqual(m.percentText, "13%", "the number is remaining (D-97)")
        XCTAssertEqual(m.dot, .red)
    }

    func testIdleAndNullWindowRenderTheEstForms() {
        let idle = DisplayFormatter.toolMenuBar(tool: .claude, state: .idleFallback,
                                                snapshot: nil, forecast: nil, now: now)
        XCTAssertEqual(idle.fullString, "CL –– est")
        let null = DisplayFormatter.toolMenuBar(
            tool: .codex, state: .nullWindow,
            snapshot: snapshot(tool: .codex, used: nil), forecast: nil, now: now)
        XCTAssertEqual(null.fullString, "CX —— est")
    }

    /// The utilization reaches the display untransformed apart from the D-97 subtraction. This
    /// used to be asserted on `gaugeFill`; `percentText` is the value a user actually reads.
    func testUtilizationPassesThroughUntransformed() {
        let m = DisplayFormatter.toolMenuBar(
            tool: .claude, state: .healthy,
            snapshot: snapshot(used: 38, resetMinutes: 112), forecast: nil, now: now)
        XCTAssertEqual(m.percentText, "62%")
    }

    // MARK: §2.2a runway verdict matrix

    func testVerdictHealthyResetsFirst() {
        // runway 155 ≥ reset 112 → resets-first, green; margin |155−112| = 43 ≥ 30 → comfortable.
        // Detail is clock-first (D-28): resets · in [countdown] · runway.
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .healthy,
            snapshot: snapshot(used: 38, resetMinutes: 112), forecast: forecast(runway: 155), now: now)!
        XCTAssertEqual(v.line1, "Safe at this pace — reset comes first")
        XCTAssertEqual(v.colour, .green)
        XCTAssertEqual(v.line2, "resets \(clock(112)) · in \(cd(112)) · runway ~2h35m")
    }

    func testVerdictExhaustsBeforeResetAmber() {
        // runway 18 < reset 134 → exhaustion-before-reset; the verdict carries the runway, the
        // detail leads with the D-29 stops clock (now + runway) and drops the countdown. Elevated → amber.
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .elevated,
            snapshot: snapshot(used: 68, resetMinutes: 134, extraUsage: creditsOn), forecast: forecast(runway: 18), now: now)!
        XCTAssertEqual(v.line1, "Won't make it — slow down or you'll stop in ~18m")
        XCTAssertEqual(v.colour, .amber)
        XCTAssertEqual(v.line2, "stops ~\(clock(18)) · resets \(clock(134)) · runway ~18m")
    }

    func testVerdictExhaustsBeforeResetRedInCriticalState() {
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .atRisk,
            snapshot: snapshot(used: 87, resetMinutes: 202, extraUsage: creditsOn), forecast: forecast(runway: 3), now: now)!
        XCTAssertEqual(v.line1, "Won't make it — slow down or you'll stop in ~3m")
        XCTAssertEqual(v.colour, .red)
    }

    /// REV-29 / STEP_35 / STEP_36 lineage; advisory rewrite v5.1: exhaustion-before-reset with
    /// credits OFF (no backstop) replaces the generic exhaustion verdict with "Won't make it —
    /// you'll be blocked in ~[runway]", keeping the state colour (not forced amber — an At-risk
    /// red stays red). The "usage credits are off" cause lives in its canonical home, the §2.4a
    /// card sub-line (STEP_36); the header states only the consequence. Detail line unchanged
    /// from the generic exhaustion row.
    func testVerdictNoBackstopBlocksBeforeReset() {
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .elevated,
            snapshot: snapshot(used: 68, resetMinutes: 134, extraUsage: .disabled),
            forecast: forecast(runway: 18), now: now)!
        XCTAssertEqual(v.line1, "Won't make it — you'll be blocked in ~18m")
        XCTAssertEqual(v.colour, .amber)
        XCTAssertEqual(v.line2, "stops ~\(clock(18)) · resets \(clock(134)) · runway ~18m")
    }

    func testVerdictNothingBurningWhenRunwayInfinite() {
        // Healthy, no runway, burn *measured* at 0 → "Nothing burning", green; the detail names
        // the measured zero ("no burn") then the reset pair.
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .healthy,
            snapshot: snapshot(used: 38, resetMinutes: 112),
            forecast: forecast(runway: nil, burn: 0), now: now)!
        XCTAssertEqual(v.line1, "Nothing burning")
        XCTAssertEqual(v.colour, .green)
        XCTAssertEqual(v.line2, "no burn · resets \(clock(112)) · in \(cd(112))")
    }

    func testVerdictMeasuringWhenBurnUnknown(){
        // §11.2a (REV-35): burn unmeasurable — cold start, or a flat reading too short for the
        // endpoint's whole-percent quantization to resolve. The app must not assert calm it has
        // not measured; it states the reset and claims nothing about burn.
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .healthy,
            snapshot: snapshot(used: 44, resetMinutes: 127),
            forecast: forecast(runway: nil, burn: nil), now: now)!
        XCTAssertEqual(v.line1, "Measuring…")
        XCTAssertEqual(v.line2, "resets \(clock(127)) · in \(cd(127))")
    }

    /// The "Tight — N% of the weekly left" row is retired (REV-96 §2.4/§3.7 — STEP_194): the
    /// five-hour verdict keeps the header, scoped, and the weekly gets one line under it.
    func testNearlySpentWeeklyScopesTheFiveHourVerdict() {
        let s = snapshot(used: 22, secondary: 91, secondaryResetDays: 3, resetMinutes: 180)
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .limitNearlySpent, snapshot: s,
            forecast: forecast(runway: 260), now: now)!
        XCTAssertEqual(v.line1, "Safe at this pace — 5-hour reset comes first")
        XCTAssertEqual(v.colour, .green)
        XCTAssertEqual(v.line2, "resets \(clock(180)) · in \(cd(180)) · runway ~4h20m")
        let selection = DisplayFormatter.selectLimit(tool: .claude, state: .limitNearlySpent,
                                                     snapshot: s, forecast: forecast(runway: 260),
                                                     now: now)
        let strip = try! XCTUnwrap(DisplayFormatter.longLimitStrip(
            tool: .claude, state: .limitNearlySpent, selection: selection, snapshot: s,
            staleAsOf: nil, now: now))
        XCTAssertEqual(strip.text, "Weekly nearly spent — 9% left for 3 days, resets "
                       + Fmt.monthDay(now.addingTimeInterval(3 * 86_400)))
        XCTAssertEqual(strip.cue, .red)
    }

    func testVerdictOverQuotaClaudeAccruing() {
        // Accruing (§7.1 Case 1): the `$` is the §1.6 glyph as prefix (`moneyPrefix`), never in
        // the string; live detail is the D-30 money mirror (`+$[rate]/hr` omitted — no spend-rate
        // derivation exists, STEP_40 flagged decision 1).
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .overQuota,
            snapshot: snapshot(used: 106, resetMinutes: 48, extraUsage: creditsOn), forecast: forecast(runway: nil), now: now)!
        XCTAssertEqual(v.line1, "Running on credits — every token costs now")
        XCTAssertTrue(v.moneyPrefix)
        XCTAssertEqual(v.colour, .red)
        XCTAssertEqual(v.line2, "$3.20 this window · resets \(clock(48))")
        XCTAssertEqual(v.moneySymbol, "$")
    }

    /// STEP_219 (REV-102 §2.5): the D-30 money detail and the glyph follow the account's currency.
    func testVerdictAccruingInEuros() {
        let euros = ExtraUsage(isEnabled: true, monthlyLimit: 7000,
                               usedCredits: Decimal(string: "29.96"), currency: "EUR",
                               managedByOrganization: true, currencyExponent: 2)
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .overQuota,
            snapshot: snapshot(used: 106, resetMinutes: 48, extraUsage: euros), forecast: forecast(runway: nil), now: now)!
        // STEP_220: org-paid credits are a monthly meter, stated against the cap.
        XCTAssertEqual(v.line2, "€29.96 of €70.00 this month · resets \(clock(48))")
        XCTAssertEqual(v.moneySymbol, "€")
    }

    func testVerdictAccruingStaleDegradesDollarless() {
        // D-30: stale/restored keeps the verdict (R33-1 extended — util ≥ 100 with credits on is
        // monotone) but the detail drops every money token — a stale spend figure invites
        // decisions on old data.
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .overQuota,
            snapshot: snapshot(used: 106, resetMinutes: 48, extraUsage: creditsOn),
            forecast: forecast(runway: nil), stale: true, now: now)!
        XCTAssertEqual(v.line1, "Running on credits — every token costs now")
        XCTAssertTrue(v.moneyPrefix)
        XCTAssertEqual(v.line2, "over quota · resets \(clock(48)) · in \(cd(48))")
        XCTAssertFalse(v.line2?.contains("$") ?? false)
    }

    func testVerdictOverQuotaCodexHardBlock() {
        // v5.2 §2.2a merged blocked template (D-31, STEP_39): one advisory string for every
        // blocked over-quota, measured overage included; detail is `blocked · resets · in [cd]`.
        let v = DisplayFormatter.headerVerdict(
            tool: .codex, state: .overQuota,
            snapshot: snapshot(tool: .codex, used: 104, resetMinutes: 31), forecast: forecast(runway: nil), now: now)!
        XCTAssertEqual(v.line1, "Stopped — quota returns at \(clock(31))")
        XCTAssertEqual(v.line2, "blocked · resets \(clock(31)) · in \(cd(31))")
    }

    func testVerdictQuotaSpentExactly100NoCredits() {
        // §7.1 Case 3, exactly-100 hard cap, no credits — same merged blocked template as a
        // measured overage (D-31 retired the separate "Quota spent — resets [t]" string).
        let v = DisplayFormatter.headerVerdict(
            tool: .codex, state: .overQuota,
            snapshot: snapshot(tool: .codex, used: 100, resetMinutes: 89), forecast: forecast(runway: nil), now: now)!
        XCTAssertEqual(v.line1, "Stopped — quota returns at \(clock(89))")
    }

    /// The provider-null verdicts survive only for a provider that sent **no window object**
    /// (REV-80 / D-101): Claude Enterprise's absent `five_hour`, Codex both-null.
    func testVerdictNullWindowByTool() {
        let claude = DisplayFormatter.headerVerdict(
            tool: .claude, state: .nullWindow, snapshot: snapshot(used: nil), forecast: nil, now: now)!
        XCTAssertEqual(claude.line1, "No active session")
        XCTAssertEqual(claude.line2, "—")
        let codex = DisplayFormatter.headerVerdict(
            tool: .codex, state: .nullWindow, snapshot: snapshot(tool: .codex, used: nil), forecast: nil, now: now)!
        XCTAssertEqual(codex.line1, "No active window")
    }

    /// A not-started window (0%, no reset, width known) has **no verdict row at all** on either
    /// tool — one fact, one shape (REV-80 / D-101), and D-123 removes the row rather than
    /// answering a question about burn on a window that has not begun (STEP_207). The rest of the
    /// header still states the fact: `100%`, the caption, and the `not started` detail line.
    func testVerdictNotStartedHasNoVerdictOnBothTools() {
        let claude = DisplayFormatter.headerVerdict(
            tool: .claude, state: .healthy, snapshot: snapshot(used: 0, windowSeconds: 18_000),
            forecast: forecast(runway: nil, burn: nil), now: now)
        let codex = DisplayFormatter.headerVerdict(
            tool: .codex, state: .healthy, snapshot: snapshot(tool: .codex, used: 0, windowSeconds: 18_000),
            forecast: forecast(tool: .codex, runway: nil, burn: nil), now: now)
        XCTAssertNil(claude, "a window that has not started answers nothing about burn")
        XCTAssertNil(codex, "and it answers the same nothing on both tools")
    }

    /// The **measured** zero is untouched by D-123: an anchored window with a resolved burn of 0
    /// still says "Nothing burning", and an anchored window with an unresolved one still says
    /// "Measuring…" (the test two rows above). The removal is keyed on the shape, not the burn.
    func testVerdictAnchoredZeroBurnStillSpeaks() {
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .healthy,
            snapshot: snapshot(used: 0, resetMinutes: 112, windowSeconds: 18_000),
            forecast: forecast(runway: nil, burn: 0), now: now)
        XCTAssertEqual(v?.line1, "Nothing burning")
    }

    func testVerdictIdleAndSpendControl() {
        let idle = DisplayFormatter.headerVerdict(
            tool: .claude, state: .idleFallback,
            snapshot: snapshot(used: 43, resetMinutes: 60), forecast: nil, now: now)!
        XCTAssertEqual(idle.line1, "—")
        XCTAssertEqual(idle.line2, "—")
        XCTAssertEqual(idle.colour, .grey)
        let spend = DisplayFormatter.headerVerdict(
            tool: .codex, state: .spendControl, snapshot: snapshot(tool: .codex, used: nil), forecast: nil, now: now)!
        XCTAssertEqual(spend.line1, "Spend limit reached")
    }

    // MARK: §2.2a verdict matrix — remaining fixture states (STEP_33 completion)
    //
    // These states collapse onto verdict *rows* already asserted above (exhaustion-before-reset,
    // resets-first, weekly-elevated), but each carries its own §13 colour. Asserting them through
    // `headerVerdict` locks the state→colour contract for every fixture state and proves the colour
    // is the state's own dot, never re-derived from the runway/reset geometry (an off-machine or
    // multi-surface warning stays amber even on a resets-first geometry). Loading is intentionally
    // absent: the "Connecting…" row is owned upstream by `LoadingCardView`, so `headerVerdict` is
    // never invoked in the loading phase (verified STEP_33).

    func testVerdictBadTimingExhaustsBeforeFarResetRed() {
        // Bad timing = high burn, far reset: exhausts long before reset. runway 30 < reset 240.
        // One exhaustion sentence for the whole family (F5) — colour carries severity.
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .badTiming,
            snapshot: snapshot(used: 78, resetMinutes: 240, extraUsage: creditsOn), forecast: forecast(runway: 30), now: now)!
        XCTAssertEqual(v.line1, "Won't make it — slow down or you'll stop in ~30m")
        XCTAssertEqual(v.colour, .red)
        XCTAssertEqual(v.line2, "stops ~\(clock(30)) · resets \(clock(240)) · runway ~30m")
    }

    func testVerdictFastBurnSpikeExhaustsBeforeResetAmber() {
        // Fast-burn spike = short runway. runway 8 < reset 120. §13 colour amber.
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .fastBurnSpike,
            snapshot: snapshot(used: 61, resetMinutes: 120, extraUsage: creditsOn), forecast: forecast(runway: 8), now: now)!
        XCTAssertEqual(v.line1, "Won't make it — slow down or you'll stop in ~8m")
        XCTAssertEqual(v.colour, .amber)
        XCTAssertEqual(v.line2, "stops ~\(clock(8)) · resets \(clock(120)) · runway ~8m")
    }

    func testVerdictOffMachineBurnExhaustsBeforeResetAmber() {
        // Off-machine burn (local idle, account burning) — a §13 amber warning; runway geometry
        // is unchanged, the split is a burn-card concern (tested in DisplayFormatterTests).
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .offMachineBurn,
            snapshot: snapshot(used: 66, resetMinutes: 150, extraUsage: creditsOn), forecast: forecast(runway: 40), now: now)!
        XCTAssertEqual(v.line1, "Won't make it — slow down or you'll stop in ~40m")
        XCTAssertEqual(v.colour, .amber)
        XCTAssertEqual(v.line2, "stops ~\(clock(40)) · resets \(clock(150)) · runway ~40m")
    }

    func testVerdictCodexMultiSurfaceExhaustsBeforeResetAmber() {
        // ≥ 2 local Codex surfaces active — §13 amber; verdict is runway-driven. Reset moved
        // 100 → 130 min for REV-65: at 100 the 5h-fallback elapsed (67%) exceeded used (63%),
        // and the pace gate correctly holds the row back — the pin is about the multi-surface
        // wording, so the fixture gets over-pace geometry (elapsed 57%) instead.
        let v = DisplayFormatter.headerVerdict(
            tool: .codex, state: .multiSurface,
            snapshot: snapshot(tool: .codex, used: 63, resetMinutes: 130), forecast: forecast(tool: .codex, runway: 25), now: now)!
        XCTAssertEqual(v.line1, "Won't make it — slow down or you'll stop in ~25m")
        XCTAssertEqual(v.colour, .amber)
        XCTAssertEqual(v.line2, "stops ~\(clock(25)) · resets \(clock(130)) · runway ~25m")
    }

    func testVerdictCodexEnterpriseHealthyResetsFirst() {
        // Enterprise-plan Codex, comfortable healthy window: resets-first, green. The plan type
        // never reaches the verdict (badge-only) — the verdict is the healthy resets-first row.
        let v = DisplayFormatter.headerVerdict(
            tool: .codex, state: .healthy,
            snapshot: snapshot(tool: .codex, used: 41, resetMinutes: 130, plan: "Enterprise"),
            forecast: forecast(tool: .codex, runway: 300), now: now)!
        XCTAssertEqual(v.line1, "Safe at this pace — reset comes first")
        XCTAssertEqual(v.colour, .green)
        XCTAssertEqual(v.line2, "resets \(clock(130)) · in \(cd(130)) · runway ~5h00m")
    }

    func testVerdictCodexTightForecastAtRiskRed() {
        // "tightf": runway lands just short of the reset — §13 at-risk red; the exhaustion
        // verdict carries the runway (the margin moved to the "Safe, barely" green row, D-31).
        let v = DisplayFormatter.headerVerdict(
            tool: .codex, state: .atRisk,
            snapshot: snapshot(tool: .codex, used: 89, resetMinutes: 118), forecast: forecast(tool: .codex, runway: 100), now: now)!
        XCTAssertEqual(v.line1, "Won't make it — slow down or you'll stop in ~1h40m")
        XCTAssertEqual(v.colour, .red)
        XCTAssertEqual(v.line2, "stops ~\(clock(100)) · resets \(clock(118)) · runway ~1h40m")
    }

    // MARK: Pace gate + long-window pace verdicts (REV-65/D-69)

    func testVerdictWeeklyBurstUnderPaceReadsOnPace() {
        // The 2026-08-13 live false alarm, as a fixture: 5% weekly used, ~14% of the week
        // elapsed, a hot burst (runway ~4.8h ≪ 6 days to reset). The old rule rendered
        // "Won't make it — slow down or you'll stop in ~4h49m". Bare hero and no line 2 since
        // REV-66/D-70: the D-58 caption owns the reset, and behind "On pace" there is no other
        // number for a detail row to state.
        let resetMin = 6.0 * 24 * 60
        let v = DisplayFormatter.headerVerdict(
            tool: .codex, state: .healthy,
            snapshot: snapshot(tool: .codex, used: 5, resetMinutes: resetMin, windowSeconds: 604_800),
            forecast: forecast(tool: .codex, runway: 289), now: now)!
        XCTAssertEqual(v.line1, "On pace")
        XCTAssertEqual(v.colour, .green)
        XCTAssertNil(v.line2, "removed, not dashed — `—` is the unknown placeholder (D-70)")
    }

    func testVerdictWeeklyUnknownBurnReadsOnPaceNotMeasuring() {
        // The pace clock needs no burn buffer, so the long-window hero never says "Measuring…" —
        // that grammar retreats to the burn pill (§11.2a). 80% of the live evening's idle polls
        // rendered "Measuring…" here. The fractional reset (6.4 days) stays from the pre-D-70
        // fixture: it now proves the bare hero renders regardless of where the countdown rounds.
        let resetMin = 6.4 * 24 * 60
        let v = DisplayFormatter.headerVerdict(
            tool: .codex, state: .healthy,
            snapshot: snapshot(tool: .codex, used: 5, resetMinutes: resetMin, windowSeconds: 604_800),
            forecast: forecast(tool: .codex, runway: nil, burn: nil), now: now)!
        XCTAssertEqual(v.line1, "On pace")
        XCTAssertNil(v.line2)
        XCTAssertEqual(v.colour, .green)
    }

    func testVerdictWeeklyOverPaceIdleReadsAbovePaceCalm() {
        // Over budget but not burning: the pace statement decouples from the warning verdict —
        // "slow down" is meaningless while idle, but "On pace" would be a lie. Calm colour.
        // The used% survives D-70's reset-clause drop: it is the pace claim's own evidence,
        // not a reset echo.
        let resetMin = 0.8 * 7 * 24 * 60   // elapsed 20% < used 35%
        let v = DisplayFormatter.headerVerdict(
            tool: .codex, state: .healthy,
            snapshot: snapshot(tool: .codex, used: 35, resetMinutes: resetMin, windowSeconds: 604_800),
            forecast: forecast(tool: .codex, runway: nil, burn: nil), now: now)!
        XCTAssertEqual(v.line1, "Above pace — 35% used")
        XCTAssertEqual(v.colour, .green)
        XCTAssertNil(v.line2)
    }

    func testVerdictWeeklyHeldWarningDropsDetailLine() {
        // The D-46 held row on a *long* window (colour still amber inside the de-escalation
        // hold): line 1 keeps its wording, but line 2 — which on this branch carried only the
        // reset echo — is removed per D-70. The short-window held row keeps its runway detail
        // (pinned separately below).
        let resetMin = 5.0 * 24 * 60
        let v = DisplayFormatter.headerVerdict(
            tool: .codex, state: .elevated,
            snapshot: snapshot(tool: .codex, used: 10, resetMinutes: resetMin, windowSeconds: 604_800),
            forecast: forecast(tool: .codex, runway: nil, burn: nil), now: now)!
        XCTAssertEqual(v.line1, "Was on track to run out — safe if this pace holds")
        XCTAssertEqual(v.colour, .amber)
        XCTAssertNil(v.line2)
    }

    func testVerdictWeeklyOverPaceAndExhaustingStillWarns() {
        // Both clocks agree → the warning is genuine and the existing row renders unchanged:
        // 30% used at 15% elapsed, runway 6h40m against a 5-day reset.
        let resetMin = 0.85 * 7 * 24 * 60
        let v = DisplayFormatter.headerVerdict(
            tool: .codex, state: .elevated,
            snapshot: snapshot(tool: .codex, used: 30, resetMinutes: resetMin, windowSeconds: 604_800),
            forecast: forecast(tool: .codex, runway: 400), now: now)!
        XCTAssertEqual(v.line1, "Won't make it — slow down or you'll stop in ~6h40m")
        XCTAssertEqual(v.colour, .amber)
    }

    func testMenuBarTimeSlotPaceGated() {
        // §1.3 carries the pace condition, so the ◔ slot and the §2.2a verdict cannot disagree:
        // a 40-minute runway on an under-pace weekly window keeps the ↻ reset form.
        let resetMin = 6.0 * 24 * 60
        let slot = DisplayFormatter.menuBarTimeSlot(
            state: .elevated,
            snapshot: snapshot(tool: .codex, used: 5, resetMinutes: resetMin, windowSeconds: 604_800),
            forecast: forecast(tool: .codex, runway: 40), now: now)
        XCTAssertEqual(slot, "↻6d", "under pace → reset countdown, never the runway slot")
    }

    func testVerdictCodexComfortableHighHealthyResetsFirst() {
        // "comfhigh": high utilization but comfortable timing — resets first, green.
        let v = DisplayFormatter.headerVerdict(
            tool: .codex, state: .healthy,
            snapshot: snapshot(tool: .codex, used: 72, resetMinutes: 95), forecast: forecast(tool: .codex, runway: 250), now: now)!
        XCTAssertEqual(v.line1, "Safe at this pace — reset comes first")
        XCTAssertEqual(v.colour, .green)
        XCTAssertEqual(v.line2, "resets \(clock(95)) · in \(cd(95)) · runway ~4h10m")
    }

    /// Codex takes the same strip from the same derivation — one rule, both tools.
    func testCodexWeeklyAheadOfPaceTakesTheSameStrip() {
        let s = snapshot(tool: .codex, used: 24, secondary: 70, secondaryResetDays: 4,
                         resetMinutes: 130)
        let selection = DisplayFormatter.selectLimit(tool: .codex, state: .limitAheadOfPace,
                                                     snapshot: s,
                                                     forecast: forecast(tool: .codex, runway: 260),
                                                     now: now)
        XCTAssertEqual(selection.hero?.id, .primaryWindow)
        let strip = try! XCTUnwrap(DisplayFormatter.longLimitStrip(
            tool: .codex, state: .limitAheadOfPace, selection: selection, snapshot: s,
            staleAsOf: nil, now: now))
        XCTAssertEqual(strip.text, "Weekly won't last the week at this rate — 30% left for 4 "
                       + "days, resets " + Fmt.monthDay(now.addingTimeInterval(4 * 86_400)))
        XCTAssertEqual(strip.cue, .amber)
    }

    /// Regression: the runway verdict never double-prefixes the tilde (the prototype `~~38m` bug).
    func testVerdictHasNoDoubleTilde() {
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .elevated,
            snapshot: snapshot(used: 68, resetMinutes: 134, extraUsage: creditsOn), forecast: forecast(runway: 18), now: now)!
        XCTAssertFalse(v.line1.contains("~~"))
        XCTAssertFalse(v.line2?.contains("~~") ?? false)
    }

    // MARK: Thin-margin split (D-31, STEP_40)

    /// The "Safe, barely" boundary: margin 29m → barely (carrying the margin), 31m → comfortable.
    /// Both green — a copy variant within Healthy, never a state change. Fixtures are computed
    /// from `thinMarginMinutes` itself, so the split provably reads the display constant — and
    /// tuning §3.2's at-risk gate (a different quantity: runway, not margin) cannot move it
    /// (REV-34b(ii) decoupling anti-regression).
    func testVerdictThinMarginBoundary() {
        let reset = 120.0
        let barely = DisplayFormatter.headerVerdict(
            tool: .claude, state: .healthy,
            snapshot: snapshot(used: 38, resetMinutes: reset),
            forecast: forecast(runway: reset + DisplayFormatter.thinMarginMinutes - 1), now: now)!
        XCTAssertEqual(barely.line1, "Safe, barely — reset beats you by ~29m")
        XCTAssertEqual(barely.colour, .green)
        XCTAssertEqual(barely.line2, "resets \(clock(120)) · in \(cd(120)) · runway ~2h29m")
        let comfortable = DisplayFormatter.headerVerdict(
            tool: .claude, state: .healthy,
            snapshot: snapshot(used: 38, resetMinutes: reset),
            forecast: forecast(runway: reset + DisplayFormatter.thinMarginMinutes + 1), now: now)!
        XCTAssertEqual(comfortable.line1, "Safe at this pace — reset comes first")
        XCTAssertEqual(comfortable.colour, .green)
    }

    // MARK: De-escalation hold (D-46, REV-51, STEP_71)

    /// §13.4 escalates at once and de-escalates only after 3 confirming polls, so the resets-first
    /// branch is reachable while a warning colour is still held. The verdict then names the danger
    /// the colour is carrying instead of asserting safety in the colour of danger. Fixture is the
    /// live 2026-07-21 22:05 reading (46%, runway 202m, reset 124m); the detail line is asserted in
    /// full to prove D-46 changes line 1 only.
    func testVerdictHeldWarningTakesDeEscalationRow() {
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .elevated,
            snapshot: snapshot(used: 46, resetMinutes: 124), forecast: forecast(runway: 202), now: now)!
        XCTAssertEqual(v.line1, "Was on track to run out — safe if this pace holds")
        XCTAssertEqual(v.colour, .amber)
        XCTAssertEqual(v.line2, "resets \(clock(124)) · in \(cd(124)) · runway ~3h22m")
    }

    /// D-46 **pre-empts D-31**: "Safe, barely" is a copy variant *within* green, so a held warning
    /// must never reach it. Not a corner case — a de-escalation passes *through* small margins on
    /// its way up (the REV-51 capture crossed at a 4-minute margin), so this is the normal path.
    /// Margin is computed from `thinMarginMinutes` itself, mirroring the green boundary test above.
    func testVerdictHeldWarningPreemptsThinMarginVariant() {
        let reset = 120.0
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .elevated,
            snapshot: snapshot(used: 52, resetMinutes: reset),
            forecast: forecast(runway: reset + DisplayFormatter.thinMarginMinutes - 1), now: now)!
        XCTAssertEqual(v.line1, "Was on track to run out — safe if this pace holds")
        XCTAssertNotEqual(v.line1, "Safe, barely — reset beats you by ~29m")
        XCTAssertEqual(v.colour, .amber)
    }

    /// Colour follows the *held* state, per the table's global rule — a held At-risk stays red
    /// rather than being downgraded to amber (the §2.2 credits-off note's rule, applied to the
    /// calming direction). Red is the colour of the clause the sentence leads with: an At-risk
    /// account genuinely *was* on track to run out. REV-51 §9.3 keeps the wording open as polish;
    /// this pins current behaviour so a later ruling has to change the test deliberately.
    func testVerdictHeldAtRiskKeepsRedOnDeEscalationRow() {
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .atRisk,
            snapshot: snapshot(used: 78, resetMinutes: 120), forecast: forecast(runway: 200), now: now)!
        XCTAssertEqual(v.line1, "Was on track to run out — safe if this pace holds")
        XCTAssertEqual(v.colour, .red)
    }

    /// Both tools through one code path: Part 2 §2.2 defers to Part 1 §2.2a, so Codex needs no
    /// separate row. `multiSurface` is Codex-only (§13 rank 8) and reaches the branch identically.
    func testVerdictCodexHeldMultiSurfaceTakesDeEscalationRow() {
        let v = DisplayFormatter.headerVerdict(
            tool: .codex, state: .multiSurface,
            snapshot: snapshot(tool: .codex, used: 63, resetMinutes: 100),
            forecast: forecast(tool: .codex, runway: 250), now: now)!
        XCTAssertEqual(v.line1, "Was on track to run out — safe if this pace holds")
        XCTAssertEqual(v.colour, .amber)
    }

    // MARK: Cross-midnight clock tokens (D-29, STEP_40)

    /// Any clock token landing on the next local calendar day appends ` tomorrow` — the stops
    /// clock and the reset clock share one formatter. Same-day clocks carry no suffix (every
    /// exact-string assertion above is the same-day proof).
    func testVerdictCrossMidnightAppendsTomorrow() {
        // reset 950 min ≈ 15.8h and runway 930 both land past local midnight (now is 9:00 am
        // local in this fixture). The fixture used to leave the width to the 5h fallback ("not a
        // real 5-hour geometry — the formatter must not care"); since REV-65 the pace clock does
        // care (a reset beyond the window width reads as zero elapsed), so it declares an 18-hour
        // window — sub-day, so the short-window grammar this test pins still applies, and 68%
        // used at 12% elapsed is over pace.
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .elevated,
            snapshot: snapshot(used: 68, resetMinutes: 950, windowSeconds: 64_800, extraUsage: creditsOn),
            forecast: forecast(runway: 930), now: now)!
        XCTAssertEqual(v.line2,
                       "stops ~\(clock(930)) tomorrow · resets \(clock(950)) tomorrow · runway ~15h30m")
    }

    func testClockDayFormatter() {
        XCTAssertEqual(Fmt.clockDay(now.addingTimeInterval(3600), from: now),
                       Fmt.clock(now.addingTimeInterval(3600)), "same-day → no suffix")
        let nextDay = now.addingTimeInterval(20 * 3600)
        XCTAssertEqual(Fmt.clockDay(nextDay, from: now), "\(Fmt.clock(nextDay)) tomorrow")
        let past = now.addingTimeInterval(-20 * 3600)
        XCTAssertEqual(Fmt.clockDay(past, from: now), Fmt.clock(past),
                       "a past clock never gains the suffix")
    }

    // MARK: Blocked-row merge (D-31) and expiry (R33-7)

    /// §7.1 Case 2 (credits used earlier this window, since disabled — "last observed") merges
    /// into the same blocked template as Case 3 and any measured overage: the distinction is a
    /// data shape, not a different user situation. The cached dollars live in the §2.4a card.
    func testVerdictCase2LastObservedReadsBlocked() {
        let lastObserved = ExtraUsage(isEnabled: false, monthlyLimit: 2000, usedCredits: 3.20,
                                      utilization: nil, currency: "usd", disabledReason: nil,
                                      usedCreditsIsCached: true)
        let v = DisplayFormatter.headerVerdict(
            tool: .claude, state: .overQuota,
            snapshot: snapshot(used: 100, resetMinutes: 31, extraUsage: lastObserved),
            forecast: forecast(runway: nil), now: now)!
        XCTAssertEqual(v.line1, "Stopped — quota returns at \(clock(31))")
        XCTAssertFalse(v.moneyPrefix)
        XCTAssertEqual(v.line2, "blocked · resets \(clock(31)) · in \(cd(31))")
    }

    /// No block outlives its own reset time (R33-7): past `resets_at` the stale path degrades the
    /// window and the verdict drops the block. REV-37 (STEP_41) further corrects *what* it drops to
    /// — an expired-on-stale window is *unknown* (`—`), never the confident "No active session"
    /// (that read as empty for ~5 h while quota burned off-machine on 2026-07-15). Same for the
    /// accruing verdict; the money prefix still clears.
    func testBlockedAndAccruingVerdictsExpireWithTheirWindow() {
        for extra in [ExtraUsage.disabled, creditsOn] {
            let c = DisplayFormatter.claude(
                state: .overQuota,
                snapshot: snapshot(used: 100, resetMinutes: -5, extraUsage: extra),
                forecast: nil, staleAsOf: now.addingTimeInterval(-11 * 60), now: now)
            XCTAssertEqual(c.header?.verdict?.line1, "—")
            XCTAssertEqual(c.header?.verdict?.moneyPrefix, false)
            XCTAssertEqual(c.header?.heroText, "——")
        }
    }

    // MARK: Voice tiers (D-27)

    /// The data tier is impersonal: no pronoun in any detail line, quota row, or source tag —
    /// only the verdict sentence (line 1) may say "you" (grep-level assertion per STEP_40).
    func testDataTierCarriesNoPronoun() {
        let cases: [(AppState, QuotaSnapshot, Forecast?)] = [
            (.elevated, snapshot(used: 68, resetMinutes: 134, extraUsage: creditsOn), forecast(runway: 18)),
            (.healthy, snapshot(used: 38, resetMinutes: 112), forecast(runway: 155)),
            (.healthy, snapshot(used: 38, resetMinutes: 120), forecast(runway: 149)),
            (.overQuota, snapshot(used: 106, resetMinutes: 48, extraUsage: creditsOn), forecast(runway: nil)),
            (.overQuota, snapshot(used: 104, resetMinutes: 31), forecast(runway: nil)),
            (.limitNearlySpent, snapshot(used: 22, secondary: 91, secondaryResetDays: 3, resetMinutes: 180), forecast(runway: 260)),
        ]
        for (state, snap, fc) in cases {
            let c = DisplayFormatter.claude(state: state, snapshot: snap, forecast: fc, now: now)
            let otherLimitRows = c.otherLimits.map { $0.rows + $0.modelGroups.flatMap(\.rows) } ?? []
            let dataTier = [c.header?.verdict?.line2, c.header?.sourceTag?.base]
                .compactMap { $0 }
                + c.header!.heroDetails.map(\.text)
                + otherLimitRows.flatMap { [$0.label, $0.value] }
            for text in dataTier {
                XCTAssertFalse(text.lowercased().contains("you"),
                               "data tier must be impersonal, found in: \(text)")
            }
        }
    }

    // MARK: The long-limit signal chain (REV-96 §2.4 — STEP_194)

    /// Three surfaces, one assessment: the tab dot goes red for the weekly, the header keeps the
    /// five-hour number and a green scoped verdict, and the red line sits between them.
    func testNearlySpentWeeklySignalChain() {
        let c = DisplayFormatter.claude(
            state: .limitNearlySpent,
            snapshot: snapshot(used: 22, secondary: 91, secondaryResetDays: 3, resetMinutes: 180),
            forecast: forecast(runway: 260), now: now)
        XCTAssertEqual(c.dot, .red, "the account-level cue follows the limit")
        XCTAssertEqual(c.header?.limitCaption, "5-hour quota left")
        XCTAssertEqual(c.header?.heroText, "78%")
        XCTAssertEqual(c.header?.verdict?.colour, .green,
                       "the sentence is about the five-hour window and stays true to it")
        XCTAssertEqual(c.header?.longLimitStrip?.cue, .red)
    }

    // MARK: Per-source freshness stamps (§2.2a, D-21)

    func testFreshnessStampTiers() {
        let snap = snapshot(used: 38, resetMinutes: 112)
        let fc = forecast(runway: 155)
        // < 2 min → muted "12s ago".
        let fresh = DisplayFormatter.claude(state: .healthy, snapshot: snap, forecast: fc,
                                            pollAsOf: now.addingTimeInterval(-12), now: now)
        XCTAssertEqual(fresh.header?.sourceTag?.base, "Source: Claude account · exact")
        XCTAssertEqual(fresh.header?.sourceTag?.age, "12s ago")
        XCTAssertEqual(fresh.header?.sourceTag?.ageIsAmber, false)
        // ≥ 2 min → amber "4m ago".
        let aging = DisplayFormatter.claude(state: .healthy, snapshot: snap, forecast: fc,
                                            pollAsOf: now.addingTimeInterval(-240), now: now)
        XCTAssertEqual(aging.header?.sourceTag?.age, "4m ago")
        XCTAssertEqual(aging.header?.sourceTag?.ageIsAmber, true)
        // Past TTL (stale-keep) → "as of [t]", no age stamp.
        let stale = DisplayFormatter.claude(state: .idleFallback, snapshot: snap, forecast: nil,
                                            staleAsOf: now.addingTimeInterval(-33 * 60), now: now)
        XCTAssertNil(stale.header?.sourceTag?.age)
        XCTAssertTrue(stale.header?.sourceTag?.base.contains("as of") ?? false)
    }

    func testJSONLTagFreshnessFollowsLastActivity() {
        // The burn/local tags age off the JSONL last-activity time, not the poll.
        let attr = LocalAttribution(project: "/p", model: "m", surfaceBucket: "Claude Code",
                                    subagentCount: 0, cacheHitRatio: 0.7,
                                    estValue: .init(weekly: 0, thirtyDay: 0),
                                    surfaceShares: [], tokensPerMinute: 350,
                                    lastActivityAt: now.addingTimeInterval(-240))
        let c = DisplayFormatter.claude(state: .healthy, snapshot: snapshot(used: 38, resetMinutes: 112),
                                        forecast: forecast(runway: 155), localAttribution: attr, now: now)
        // The local tag ages off the newest observed event of the day, not the poll (STEP_178).
        XCTAssertNotNil(c.localActivity)
    }

    // MARK: Over quota (§0.5 as amended — REV-77 / D-97: the bar drains, nothing overflows)

    func testHeaderOverQuotaReadsZeroLeftOverAnEmptyBar() {
        let h = DisplayFormatter.header(tool: .claude, state: .overQuota,
                                        snapshot: snapshot(used: 106, resetMinutes: 48),
                                        forecast: nil, now: now)
        XCTAssertEqual(h.heroText, "0%", "106 used floors to 0 left — never a negative")
        XCTAssertEqual(h.progress, 0, accuracy: 0.001,
                       "the overflow stripe is retired; the bar is simply empty")
        // The overshoot is not lost: it is the bridge line's used figure, uncapped.
        XCTAssertEqual(h.heroBridge?.text, "*0% left · 106% used*")
        XCTAssertEqual(h.verdict?.line1,
                       "Stopped — quota returns at \(clock(48))")
    }

    private let creditsOn = ExtraUsage(isEnabled: true, monthlyLimit: 2000, usedCredits: 3.20,
                                       utilization: nil, currency: "usd", disabledReason: nil,
                                       usedCreditsIsCached: false)
}
