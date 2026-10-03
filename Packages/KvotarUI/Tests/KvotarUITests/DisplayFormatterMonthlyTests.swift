import XCTest
import KvotarCore
@testable import KvotarUI

/// STEP_44 (REV-38/D-34/D-35) — the Codex monthly (period-quota) layout, fixture-driven from
/// prototype v6.9 (`ent_monthly` family, 1:1). E8/E10 menu-bar clauses as locked 2026-07-16
/// (P1-15). The `ent_monthly` base values are synthetic, in the shape of the 2026-07-15 capture: limit "5000",
/// used "2376.91…", reset Aug 1 2026 00:00 UTC.
/// STEP_47 (REV-40/D-36/D-37) — the Claude Enterprise money variant (`cle_*` family below):
/// same layout, `unit = .money`, synthetic base values in the shape of the 2026-07-16 capture.
final class DisplayFormatterMonthlyTests: XCTestCase {

    /// Aug 1 2026 00:00:00 UTC — cycle end; Jul 1 2026 00:00:00 UTC — cycle start.
    private let augustFirst = Date(timeIntervalSince1970: 1_785_542_400)
    private let julyFirst = Date(timeIntervalSince1970: 1_782_864_000)

    private func monthly(used: Double = 2376.905242651701,
                         remainingPercent: Int = 52) -> MonthlyLimit {
        MonthlyLimit(limitAmount: 5000, usedAmount: used,
                     remainingPercent: remainingPercent, resetsAt: augustFirst,
                     source: "group_based_spend_controls")
    }

    private func snapshot(monthly: MonthlyLimit?, reached: Bool? = false,
                          primaryUsed: Double? = nil, primaryResetsAt: Date? = nil,
                          secondary: Double? = nil, secondaryResetsAt: Date? = nil,
                          plan: String = "enterprise") -> QuotaSnapshot {
        QuotaSnapshot(tool: .codex, primaryUsedPct: primaryUsed,
                      primaryResetsAt: primaryResetsAt,
                      secondaryUsedPct: secondary, secondaryResetsAt: secondaryResetsAt,
                      rateLimitReached: nil, extraUsage: nil,
                      spendControlReached: reached,
                      monthlyLimit: monthly, source: .appServerRPC, planType: plan)
    }

    private func codexForecast() -> Forecast {
        Forecast(tool: .codex, tier: .creditBased, runwayMinutes: nil,
                 burnRatePerMin: nil, isEstimate: false, pollCount: 5)
    }

    // MARK: ent_monthly — healthy, synthetic values in the 2026-07-15 shape

    /// now = Jul 16 00:00 UTC → 15 days elapsed (pace ≈ 158/day), 16 days to reset.
    private var nowHealthy: Date { julyFirst.addingTimeInterval(15 * 86_400) }

    func testMonthlyHealthyPopover() throws {
        let cx = DisplayFormatter.codex(state: .nullWindow, snapshot: snapshot(monthly: monthly()),
                                        forecast: codexForecast(), now: nowHealthy)
        // Hero recomputed from used/limit at 1% (E3); dot from the monthly forecast — green.
        XCTAssertEqual(cx.header?.heroText, "52%")
        XCTAssertEqual(cx.dot, .green)
        XCTAssertEqual(cx.header?.verdict?.line1, "On pace — resets Aug 1 (16d)")
        XCTAssertEqual(cx.header?.verdict?.line2,
                       "~158 credits/day · 2,377 of 5,000 · workspace pool")
        XCTAssertEqual(cx.header?.verdict?.colour, .green)
        // The meter is the hero (STEP_178): its caption names it, its amounts and reset are in
        // the verdict above, and the organisation-and-pace note is its one detail line — the
        // three facts the retired Monthly section carried, in one place each.
        XCTAssertEqual(cx.header?.limitCaption, "Monthly usage limit left")
        XCTAssertEqual(cx.header?.heroDetails.map(\.text),
                       ["Workspace limit · shared across ChatGPT and Codex · on pace"])
        XCTAssertEqual(cx.header?.heroDetails.map(\.explanation), [.monthlyPace])
        // With no window reported there is nothing else to list, and the null-window note is
        // superseded by the layout.
        XCTAssertNil(cx.otherLimits)
        XCTAssertNil(cx.nullWindowNote)
        // Credits slimmed: Plan + Spend control only — no Credit-balance row.
        let credits = try XCTUnwrap(cx.creditsSpend)
        XCTAssertEqual(credits.rows.map(\.label), ["Plan", "Spend control"])
        XCTAssertEqual(credits.rows[1].value, "Active · not reached")
        // %/min suppressed — no window denominator. Since STEP_68 the freed slot carries the live
        // credits/hr rate; with no measured rate the optional row is absent.
        XCTAssertNil(cx.header?.accountBurn)
        XCTAssertNil(cx.recommendation)
        XCTAssertNil(cx.recommendationURL)
    }

    func testMonthlyBurnDistinguishesZeroFromASubPrecisionPositive() {
        let zero = DisplayFormatter.codex(state: .nullWindow, snapshot: snapshot(monthly: monthly()),
                                          forecast: codexForecast(), monthlyRatePerHour: 0,
                                          now: nowHealthy)
        XCTAssertEqual(zero.header?.accountBurn?.value, "No measurable burn")

        let positive = DisplayFormatter.codex(state: .nullWindow,
                                              snapshot: snapshot(monthly: monthly()),
                                              forecast: codexForecast(),
                                              monthlyRatePerHour: 0.4, now: nowHealthy)
        XCTAssertEqual(positive.header?.accountBurn?.value, "Very low · <1 credit/hr")
    }

    func testMonthlyNotSeenLocallyHidesZeroAndBoundsASmallPositive() {
        let zeroSplit = MonthlyAttribution(localAmount: 10, offMachineAmount: 0,
                                           unattributedAmount: 0, usedAmount: 10)
        let zero = DisplayFormatter.codex(state: .nullWindow, snapshot: snapshot(monthly: monthly()),
                                          forecast: codexForecast(), monthlyAttribution: zeroSplit,
                                          now: nowHealthy)
        XCTAssertNil(zero.header?.notSeenLocally)

        let smallSplit = MonthlyAttribution(localAmount: 9.6, offMachineAmount: 0.4,
                                            unattributedAmount: 0, usedAmount: 10)
        let small = DisplayFormatter.codex(state: .nullWindow, snapshot: snapshot(monthly: monthly()),
                                           forecast: codexForecast(), monthlyAttribution: smallSplit,
                                           now: nowHealthy)
        XCTAssertEqual(small.header?.notSeenLocally?.value, "<1 credit (est.)")
    }

    func testMonthlyHealthyMenuBar() {
        let m = DisplayFormatter.toolMenuBar(tool: .codex, state: .nullWindow,
                                             snapshot: snapshot(monthly: monthly()),
                                             forecast: nil, now: nowHealthy)
        XCTAssertEqual(m.fullString, "CX 52% ↻16d")
        XCTAssertEqual(m.dot, .green)
    }

    func testMonthlyMenuBarKeepsWarningStateColour() {
        // A higher-rank state that fires with null windows (multi-surface, local-signal-driven)
        // keeps its own dot/tier — the calm forecast never demotes the state machine — while
        // the string still carries the monthly percent (`——` would claim "no reading").
        let m = DisplayFormatter.toolMenuBar(tool: .codex, state: .multiSurface,
                                             snapshot: snapshot(monthly: monthly()),
                                             forecast: nil, now: nowHealthy)
        XCTAssertEqual(m.fullString, "CX 52% ↻16d")
        XCTAssertEqual(m.dot, .amber)
    }

    // MARK: ent_monthly_pace — forecast-driven amber (E6 gate)

    /// now = Jul 13 00:00 UTC → 12 days elapsed, 19 to reset; used 3,550 ⇒ pace ≈ 296/day,
    /// runway ≈ 4.9d — exhaustion ~14d before reset.
    private var nowPace: Date { julyFirst.addingTimeInterval(12 * 86_400) }
    private var paceMonthly: MonthlyLimit { monthly(used: 3550, remainingPercent: 29) }

    func testMonthlyPaceAmberForecast() throws {
        let cx = DisplayFormatter.codex(state: .nullWindow,
                                        snapshot: snapshot(monthly: paceMonthly),
                                        forecast: codexForecast(), now: nowPace)
        XCTAssertEqual(cx.header?.heroText, "29%")
        XCTAssertEqual(cx.dot, .amber, "position would be calm — the E6 pace forecast drives amber")
        XCTAssertEqual(cx.header?.verdict?.line1,
                       "At this pace, runs out in ~5d — 14d before reset")
        XCTAssertEqual(cx.header?.verdict?.colour, .amber)
        XCTAssertEqual(cx.header?.verdict?.line2,
                       "~296 credits/day · 3,550 of 5,000 · workspace pool")
        let pace = try XCTUnwrap(cx.header?.heroDetails.first)
        XCTAssertTrue(pace.text.hasSuffix("runs out ~Jul 17"), pace.text)
        XCTAssertFalse(pace.text.contains("296 credits/day"),
                       "the rate is stated once, in the verdict directly above")
    }

    func testMonthlyPaceMenuBarRunwaySlot() {
        // E8: all three conditions hold (confidence ≥ 7d elapsed; exhaustion before reset;
        // runway ≤ 7d) → the day-scale runway slot — first day-unit ◔ in the grammar.
        let m = DisplayFormatter.toolMenuBar(tool: .codex, state: .nullWindow,
                                             snapshot: snapshot(monthly: paceMonthly),
                                             forecast: nil, now: nowPace)
        XCTAssertEqual(m.fullString, "CX 29% ◔~5d")
        XCTAssertEqual(m.dot, .amber)
    }

    // MARK: ent_monthly_nearcap — ≥ 90% red + recommendation (E5)

    /// now = Jul 25 00:00 UTC → 24 days elapsed, 7 to reset; used 4,550 (91%) ⇒ pace ≈ 190/day,
    /// runway ≈ 2.4d.
    private var nowNearCap: Date { julyFirst.addingTimeInterval(24 * 86_400) }
    private var nearCapMonthly: MonthlyLimit { monthly(used: 4550, remainingPercent: 9) }

    func testMonthlyNearCapRecommendationAndRed() throws {
        let cx = DisplayFormatter.codex(state: .nullWindow,
                                        snapshot: snapshot(monthly: nearCapMonthly),
                                        forecast: codexForecast(), now: nowNearCap)
        XCTAssertEqual(cx.header?.heroText, "9%")
        XCTAssertEqual(cx.dot, .red)
        XCTAssertEqual(cx.header?.verdict?.line1,
                       "At this pace, runs out in ~2d — 5d before reset")
        XCTAssertEqual(cx.header?.verdict?.colour, .red)
        XCTAssertEqual(cx.recommendation,
                       "Monthly workspace limit nearly reached — 9% left with 7d until reset. "
                       + "You can request a limit increase from ChatGPT settings → Usage.")
        XCTAssertEqual(cx.recommendationURL?.absoluteString, "https://chatgpt.com/#settings/Usage")
        XCTAssertEqual(cx.header?.limit?.cue, .red, "the hero's cue turns red at ≥ 90%")
    }

    func testMonthlyNearCapMenuBar() {
        let m = DisplayFormatter.toolMenuBar(tool: .codex, state: .nullWindow,
                                             snapshot: snapshot(monthly: nearCapMonthly),
                                             forecast: nil, now: nowNearCap)
        XCTAssertEqual(m.fullString, "CX 9% ◔~2d")
        XCTAssertEqual(m.dot, .red)
    }

    // MARK: ent_monthly_reached — spend_control.reached with a real recovery time
    // ⚠ Shape ASSUMED, pending P1-14: the block taxonomy is spend-control-shaped for this
    // regime, but a live reached-state capture has never been taken (first predictable window:
    // this account's Aug 1 reset). Re-verify against the capture when P1-14 lands.

    private var reachedSnapshot: QuotaSnapshot {
        snapshot(monthly: monthly(used: 5000, remainingPercent: 0), reached: true)
    }

    func testMonthlyReachedPopover() throws {
        let cx = DisplayFormatter.codex(state: .spendControl, snapshot: reachedSnapshot,
                                        forecast: codexForecast(), now: nowNearCap)
        XCTAssertEqual(cx.header?.heroText, "0%")
        XCTAssertEqual(cx.dot, .red)
        XCTAssertEqual(cx.header?.verdict?.line1, "Monthly limit reached — resets Aug 1")
        XCTAssertEqual(cx.header?.verdict?.line2, "blocked · resets Aug 1 · ↻ 7d")
        XCTAssertTrue(cx.header?.heroDetails.first?.text.hasSuffix("spend control reached") == true)
        // Slimmed credits: the Spend-control row names its recovery (R33-1 extension).
        XCTAssertEqual(cx.creditsSpend?.rows[1].value, "Limit reached · resets Aug 1")
        XCTAssertEqual(cx.recommendation,
                       "Monthly workspace limit reached. New requests are blocked until the "
                       + "limit resets Aug 1 — 7d away.")
        XCTAssertNil(cx.recommendationURL, "the near-cap link is for the not-yet-blocked state")
    }

    func testMonthlyReachedMenuBarAlwaysResetSlot() {
        // A reached pool never earns ◔ — its runway is spent, not urgent.
        let m = DisplayFormatter.toolMenuBar(tool: .codex, state: .spendControl,
                                             snapshot: reachedSnapshot,
                                             forecast: nil, now: nowNearCap)
        XCTAssertEqual(m.fullString, "CX 0% ↻7d")
        XCTAssertEqual(m.dot, .red)
    }

    // MARK: ent_monthly_windows — stress: monthly 91% red + populated 5h window 34% green
    // (⚠ retained per E9a, PENDING D1 — delete with the precedence rule if P1-14 reads B)

    private var windowsSnapshot: QuotaSnapshot {
        snapshot(monthly: nearCapMonthly, primaryUsed: 34,
                 primaryResetsAt: nowNearCap.addingTimeInterval(130 * 60),
                 secondary: 21, secondaryResetsAt: nowNearCap.addingTimeInterval(3 * 86_400))
    }

    func testMonthlyWindowsPrecedence() throws {
        let cx = DisplayFormatter.codex(state: .healthy, snapshot: windowsSnapshot,
                                        forecast: Forecast(tool: .codex, tier: .fullRunway,
                                                           runwayMinutes: nil,
                                                           burnRatePerMin: 0.4,
                                                           isEstimate: false, pollCount: 5),
                                        now: nowNearCap)
        // (b) dot from the window state — explicitly NOT worst-of-all-dimensions.
        XCTAssertEqual(cx.dot, .green)
        // (c) hero + verdict belong to the window (standard minute-based family resumes).
        XCTAssertEqual(cx.header?.heroText, "66%")
        XCTAssertNotEqual(cx.header?.verdict?.line1.contains("pace"), true,
                          "windowed verdict, not the period-quota family")
        // (d) the meter keeps its own red cue, now as an `OTHER LIMITS` row (STEP_178).
        let monthlyRow = try XCTUnwrap(cx.otherLimits?.rows.first { $0.id == .monthly })
        XCTAssertEqual(monthlyRow.cue, .red)
        XCTAssertTrue(monthlyRow.meta?.text.contains("spend control reached") == true
                      || monthlyRow.meta?.text.contains("credits/day") == true)
        // (e) both limits coexist — the meter is listed beside the window that took the hero.
        XCTAssertTrue(cx.otherLimits!.rows.contains { $0.id == .monthly })
        // %/min restored — the window denominator exists again.
        XCTAssertEqual(cx.header?.accountBurn?.value, "Low · 0.4% / min")
    }

    func testMonthlyWindowsMenuBarReadsTheWindow() {
        // (a) the string builder keys off primary != nil, not individualLimit != nil.
        let m = DisplayFormatter.toolMenuBar(tool: .codex, state: .healthy,
                                             snapshot: windowsSnapshot,
                                             forecast: nil, now: nowNearCap)
        XCTAssertEqual(m.fullString, "CX 66% ↻2h10m")
        XCTAssertEqual(m.dot, .green)
    }

    // MARK: ent_monthly_stale — E10 + D-35 (lower bound, pace suspended, freeze reason)

    private var staleAsOf: Date { nowHealthy.addingTimeInterval(-4 * 3600) }

    func testMonthlyStaleKeepsLowerBoundAndSuspendsPace() throws {
        let cx = DisplayFormatter.codex(state: .idleFallback, snapshot: snapshot(monthly: monthly()),
                                        forecast: nil, staleAsOf: staleAsOf,
                                        freezeReason: .rateLimited(retryAfter: 120),
                                        now: nowHealthy)
        // Muted hero kept — a true lower bound for the whole month (D-35).
        XCTAssertEqual(cx.header?.heroText, "52%")
        XCTAssertEqual(cx.dot, .grey)
        // Freeze reason in the verdict (D-33): rate-limited reads "Reconnecting…".
        XCTAssertEqual(cx.header?.verdict?.line1, "Reconnecting…")
        // The as-of stamp is dated when the snapshot crosses a local calendar day — build the
        // expected value with the same day test so the assertion is timezone-robust.
        let stamp = Calendar.current.isDate(staleAsOf, inSameDayAs: nowHealthy)
            ? Fmt.clock(staleAsOf) : "\(Fmt.monthDay(staleAsOf)), \(Fmt.clock(staleAsOf))"
        XCTAssertEqual(cx.header?.verdict?.line2,
                       "as of \(stamp) · 2,377 of 5,000 · lower bound")
        // Pace suspended — a pace projected from stale data would be a confident claim.
        XCTAssertTrue(cx.header?.heroDetails.first?.text.hasSuffix("pace suspended") == true)
        XCTAssertTrue(cx.header?.sourceTag?.base.contains("· as of") ?? false)
    }

    func testMonthlyStaleOtherReasonVerdict() {
        let cx = DisplayFormatter.codex(state: .idleFallback, snapshot: snapshot(monthly: monthly()),
                                        forecast: nil, staleAsOf: staleAsOf, now: nowHealthy)
        XCTAssertEqual(cx.header?.verdict?.line1, "No fresh reading — showing last known")
        XCTAssertEqual(cx.header?.verdict?.colour, .grey)
    }

    func testMonthlyStaleMenuBarE10() {
        // E10 (locked P1-15): grey dot + percent kept + ↻Nd kept; ◔ never renders stale.
        let m = DisplayFormatter.staleMenuBar(tool: .codex, snapshot: snapshot(monthly: monthly()),
                                              now: nowHealthy)
        XCTAssertEqual(m.fullString, "CX 52% ↻16d")
        XCTAssertEqual(m.dot, .grey)
    }

    func testMonthlyStaleMenuBarNeverShowsRunwaySlot() {
        // The pace fixture would earn ◔~5d fresh — stale it degrades to the reset slot.
        let m = DisplayFormatter.staleMenuBar(tool: .codex,
                                              snapshot: snapshot(monthly: paceMonthly),
                                              now: nowPace)
        XCTAssertEqual(m.fullString, "CX 29% ↻19d")
        XCTAssertEqual(m.dot, .grey)
    }

    func testMonthlyStaleReachedKeepsRed() {
        // R33-1 extension: a stale hard block keeps its red dot and percent (E10 exception).
        let m = DisplayFormatter.staleMenuBar(tool: .codex, state: .spendControl,
                                              snapshot: reachedSnapshot, now: nowNearCap)
        XCTAssertEqual(m.fullString, "CX 0% ↻7d")
        XCTAssertEqual(m.dot, .red)
    }

    func testMonthlyRolledOverUnseenDegradesToUnknownForm() throws {
        // D-35 / R33-7 analogue: past the snapshot's monthly reset_at the percent no longer
        // bounds anything — Core degrades `monthlyLimit` to nil and the standard unknown forms
        // take over on both surfaces.
        let afterRollover = augustFirst.addingTimeInterval(3600)
        let m = DisplayFormatter.staleMenuBar(tool: .codex, snapshot: snapshot(monthly: monthly()),
                                              now: afterRollover)
        XCTAssertEqual(m.fullString, "CX —— est")
        XCTAssertEqual(m.dot, .grey)

        let cx = DisplayFormatter.codex(state: .idleFallback, snapshot: snapshot(monthly: monthly()),
                                        forecast: nil, staleAsOf: staleAsOf, now: afterRollover)
        XCTAssertEqual(cx.header?.heroText, "——")
        XCTAssertEqual(cx.header?.verdict?.line1, "—",
                       "unknown form — never a confident 'No active window' from a rolled-over month")
        XCTAssertNotEqual(cx.header?.limit?.id, .monthly, "the meter does not outlive its month")
    }

    // MARK: §19 cross-surface agreement (menu-bar dot == tab dot == verdict colour)

    func testCrossSurfaceAgreementFreshStaleAndReached() {
        // Fresh near-cap: red everywhere.
        let nearCap = snapshot(monthly: nearCapMonthly)
        let freshMenu = DisplayFormatter.toolMenuBar(tool: .codex, state: .nullWindow,
                                                     snapshot: nearCap, forecast: nil,
                                                     now: nowNearCap)
        let freshTab = DisplayFormatter.codex(state: .nullWindow, snapshot: nearCap,
                                              forecast: codexForecast(), now: nowNearCap)
        XCTAssertEqual(freshMenu.dot, freshTab.dot)
        XCTAssertEqual(freshTab.dot, freshTab.header?.verdict?.colour)

        // Stale: grey everywhere (E10 joins the stale-keep family).
        let staleMenu = DisplayFormatter.staleMenuBar(tool: .codex,
                                                      snapshot: snapshot(monthly: monthly()),
                                                      now: nowHealthy)
        let staleTab = DisplayFormatter.codex(state: .idleFallback,
                                              snapshot: snapshot(monthly: monthly()),
                                              forecast: nil, staleAsOf: staleAsOf,
                                              now: nowHealthy)
        XCTAssertEqual(staleMenu.dot, staleTab.dot)
        XCTAssertEqual(staleTab.dot, .grey)

        // Reached: red everywhere, live and stale alike (R33-1).
        let reachedMenu = DisplayFormatter.toolMenuBar(tool: .codex, state: .spendControl,
                                                       snapshot: reachedSnapshot, forecast: nil,
                                                       now: nowNearCap)
        let reachedTab = DisplayFormatter.codex(state: .spendControl, snapshot: reachedSnapshot,
                                                forecast: codexForecast(), now: nowNearCap)
        let reachedStaleMenu = DisplayFormatter.staleMenuBar(tool: .codex, state: .spendControl,
                                                             snapshot: reachedSnapshot,
                                                             now: nowNearCap)
        XCTAssertEqual(reachedMenu.dot, .red)
        XCTAssertEqual(reachedTab.dot, .red)
        XCTAssertEqual(reachedTab.header?.verdict?.colour, .red)
        XCTAssertEqual(reachedStaleMenu.dot, .red)
    }

    // MARK: - STEP_47 (REV-40/D-36) — Claude Enterprise monthly spend, `cle_*` family
    // Synthetic base values in the shape of the 2026-07-16 capture (`usage_enterprise_spend.json`):
    // spend used 6916¢ = $69.16 of limit 12000¢ = $120.00, server percent 58, USD exponent 2,
    // reset derived Aug 1 2026 00:00 UTC (`derived_calendar_month_utc`).

    private func claudeMonthly(used: Double = 6916,
                               remainingPercent: Int = 42) -> MonthlyLimit {
        MonthlyLimit(limitAmount: 12000, usedAmount: used,
                     remainingPercent: remainingPercent, resetsAt: augustFirst,
                     unit: .money(currency: "USD", exponent: 2),
                     source: "derived_calendar_month_utc")
    }

    /// Claude never carries a reached flag (P1-16 unobserved) — `spendControlReached` stays nil;
    /// over-limit rides `usedPercentExact ≥ 100` only.
    private func claudeSnapshot(monthly: MonthlyLimit?,
                                primaryUsed: Double? = nil, primaryResetsAt: Date? = nil,
                                secondary: Double? = nil,
                                secondaryResetsAt: Date? = nil) -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: primaryUsed,
                      primaryResetsAt: primaryResetsAt,
                      secondaryUsedPct: secondary, secondaryResetsAt: secondaryResetsAt,
                      rateLimitReached: nil, extraUsage: nil,
                      monthlyLimit: monthly, source: .oauth, planType: "enterprise")
    }

    private func claudeForecast(burnRatePerMin: Double? = nil) -> Forecast {
        Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: nil,
                 burnRatePerMin: burnRatePerMin, isEstimate: false, pollCount: 5)
    }

    // MARK: cle_monthly — healthy, capture values verbatim

    /// now = Jul 18 00:00 UTC → 17 days elapsed (pace ≈ $4.07/day, runway ≈ 12.5d), 14 days
    /// to reset — lead < 2d, so the E6 gate stays closed and the verdict reads on-pace.
    private var nowClaudeHealthy: Date { julyFirst.addingTimeInterval(17 * 86_400) }

    func testClaudeMonthlyHealthyPopover() throws {
        let cl = DisplayFormatter.claude(state: .nullWindow,
                                         snapshot: claudeSnapshot(monthly: claudeMonthly()),
                                         forecast: claudeForecast(), now: nowClaudeHealthy)
        // Hero recomputed from used/limit at 1% (E3): 57.63 → 58 — the server's own integer.
        XCTAssertEqual(cl.header?.heroText, "42%")
        XCTAssertEqual(cl.dot, .green)
        XCTAssertEqual(cl.header?.planBadge, "Enterprise")
        XCTAssertEqual(cl.header?.verdict?.line1, "On pace — resets Aug 1 (14d)")
        // Money tokens, never a pool token (P2-11).
        XCTAssertEqual(cl.header?.verdict?.line2, "~$4.07/day · $69.16 of $120.00")
        XCTAssertEqual(cl.header?.verdict?.colour, .green)
        // The meter is the hero (STEP_178): caption, amounts-and-reset in the verdict above, and
        // one organisation-and-pace detail line.
        XCTAssertEqual(cl.header?.limitCaption, "Monthly spend limit left")
        XCTAssertEqual(cl.header?.heroDetails.map(\.text),
                       ["Set by your organization · on pace"])
        XCTAssertTrue(cl.header?.sourceTag?.base.hasPrefix("Source: Claude account") ?? false)
        // No window reported — nothing else to list.
        XCTAssertNil(cl.otherLimits)
        // §2.4a credits card suppressed entirely (D-37 — extraUsage normalized away in STEP_46).
        XCTAssertNil(cl.creditsCard)
        // %/min stays suppressed — no window denominator. The freed slot now carries the live
        // spend rate (REV-47/D-42); with no measured rate the optional row is absent.
        XCTAssertNil(cl.header?.accountBurn)
        XCTAssertNil(cl.recommendation)
        XCTAssertNil(cl.recommendationURL)
    }

    func testClaudeMonthlyHealthyMenuBar() {
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .nullWindow,
                                             snapshot: claudeSnapshot(monthly: claudeMonthly()),
                                             forecast: nil, now: nowClaudeHealthy)
        XCTAssertEqual(m.fullString, "CL 42% ↻14d")
        XCTAssertEqual(m.dot, .green)
    }

    func testClaudeMonthlyNoForbiddenCopy() {
        // DoD sweep: no pool-scope claim, no "remaining", no polling mechanics — on every
        // rendered string of the healthy monthly popover (P2-11, §1.4/§10 copy bans).
        let cl = DisplayFormatter.claude(state: .nullWindow,
                                         snapshot: claudeSnapshot(monthly: claudeMonthly()),
                                         forecast: claudeForecast(), now: nowClaudeHealthy)
        var texts = [cl.header?.verdict?.line1, cl.header?.verdict?.line2,
                     cl.header?.limitCaption, cl.recommendation,
                     cl.header?.sourceTag?.base].compactMap { $0 }
        texts += cl.header!.heroDetails.map(\.text)
        for text in texts {
            for banned in ["workspace pool", "shared across", "remaining",
                           "throttled", "rate limited", "backing off"] {
                XCTAssertFalse(text.lowercased().contains(banned),
                               "banned token \"\(banned)\" in: \(text)")
            }
        }
    }

    // MARK: cle_pace — forecast-driven amber (E6 gate, money tokens)

    /// now = Jul 13 00:00 UTC → 12 days elapsed, 19 to reset; used $90.00 ⇒ pace $7.50/day,
    /// runway 4d — exhaustion 15d before reset, ◔ eligible (runway ≤ 7d).
    private var nowClaudePace: Date { julyFirst.addingTimeInterval(12 * 86_400) }
    private var claudePaceMonthly: MonthlyLimit { claudeMonthly(used: 9000, remainingPercent: 25) }

    func testClaudeMonthlyPaceAmberForecast() throws {
        let cl = DisplayFormatter.claude(state: .nullWindow,
                                         snapshot: claudeSnapshot(monthly: claudePaceMonthly),
                                         forecast: claudeForecast(), now: nowClaudePace)
        XCTAssertEqual(cl.header?.heroText, "25%")
        XCTAssertEqual(cl.dot, .amber, "position would be calm — the E6 pace forecast drives amber")
        XCTAssertEqual(cl.header?.verdict?.line1,
                       "At this pace, runs out in ~4d — 15d before reset")
        XCTAssertEqual(cl.header?.verdict?.colour, .amber)
        XCTAssertEqual(cl.header?.verdict?.line2, "~$7.50/day · $90.00 of $120.00")
        let pace = try XCTUnwrap(cl.header?.heroDetails.first)
        XCTAssertEqual(pace.text, "Set by your organization · runs out ~Jul 17")
    }

    func testClaudeMonthlyPaceMenuBarRunwaySlot() {
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .nullWindow,
                                             snapshot: claudeSnapshot(monthly: claudePaceMonthly),
                                             forecast: nil, now: nowClaudePace)
        XCTAssertEqual(m.fullString, "CL 25% ◔~4d")
        XCTAssertEqual(m.dot, .amber)
    }

    // MARK: cle_nearcap — ≥ 90% red + admin-facing recommendation (E5, §2.6 v5.6)

    /// now = Jul 25 00:00 UTC → 24 days elapsed, 7 to reset; used $110.00 (92%) ⇒ pace
    /// $4.58/day, runway ≈ 2.2d.
    private var claudeNearCapMonthly: MonthlyLimit { claudeMonthly(used: 11000, remainingPercent: 8) }

    func testClaudeMonthlyNearCapRecommendationAndRed() throws {
        let cl = DisplayFormatter.claude(state: .nullWindow,
                                         snapshot: claudeSnapshot(monthly: claudeNearCapMonthly),
                                         forecast: claudeForecast(), now: nowNearCap)
        XCTAssertEqual(cl.header?.heroText, "8%")
        XCTAssertEqual(cl.dot, .red)
        XCTAssertEqual(cl.header?.verdict?.colour, .red)
        // Admin-facing — the seat cannot self-serve (`can_toggle`/`can_purchase_credits` false);
        // never the Codex "request a limit increase" framing.
        XCTAssertEqual(cl.recommendation,
                       "Monthly spend limit nearly reached — ask your workspace admin. "
                       + "Resets Aug 1.")
        XCTAssertEqual(cl.recommendationURL?.absoluteString,
                       "https://claude.ai/new#settings/usage")
        XCTAssertEqual(cl.header?.limit?.cue, .red, "the hero's cue turns red at ≥ 90%")
    }

    func testClaudeMonthlyNearCapMenuBar() {
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .nullWindow,
                                             snapshot: claudeSnapshot(monthly: claudeNearCapMonthly),
                                             forecast: nil, now: nowNearCap)
        XCTAssertEqual(m.fullString, "CL 8% ◔~2d")
        XCTAssertEqual(m.dot, .red)
    }

    // MARK: cle_reached — spend limit consummated
    // ⚠ Shape ASSUMED, pending P1-16: no Claude reached/blocked flag has ever been captured
    // (`severity: "normal"` is the only observed value), so this renders from
    // `usedPercentExact ≥ 100` alone and the state stays rank-12 Null-window (no rank-2
    // wiring). First predictable observation window: the tester's Aug 1 reset — re-verify
    // this fixture against that capture.

    private var claudeReachedSnapshot: QuotaSnapshot {
        claudeSnapshot(monthly: claudeMonthly(used: 12000, remainingPercent: 0))
    }

    func testClaudeMonthlyReachedPopover() throws {
        let cl = DisplayFormatter.claude(state: .nullWindow, snapshot: claudeReachedSnapshot,
                                         forecast: claudeForecast(), now: nowNearCap)
        XCTAssertEqual(cl.header?.heroText, "0%")
        XCTAssertEqual(cl.dot, .red)
        // claude.ai's own wording (REV-40) — Codex keeps "Monthly limit reached".
        XCTAssertEqual(cl.header?.verdict?.line1, "Spend limit reached — resets Aug 1")
        XCTAssertEqual(cl.header?.verdict?.line2, "blocked · resets Aug 1 · ↻ 7d")
        XCTAssertTrue(cl.header?.heroDetails.first?.text.hasSuffix("spend limit reached") == true)
        // A used-out meter must not read "nearly reached" — the near-cap row yields to reached.
        XCTAssertNil(cl.recommendation)
        XCTAssertNil(cl.recommendationURL)
    }

    func testClaudeMonthlyReachedMenuBarAlwaysResetSlot() {
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .nullWindow,
                                             snapshot: claudeReachedSnapshot,
                                             forecast: nil, now: nowNearCap)
        XCTAssertEqual(m.fullString, "CL 0% ↻7d")
        XCTAssertEqual(m.dot, .red)
    }

    // MARK: cle_windows — stress: monthly 92% red + populated 5h window 34% green
    // ⚠ Shape ASSUMED (the E9a analogue): windows + spend coexisting is UNOBSERVED on Claude —
    // the tester's account returns persistently null windows. Five-point precedence checklist
    // as Codex; delete with the precedence rule if a capture falsifies the coexistence.

    private var claudeWindowsSnapshot: QuotaSnapshot {
        claudeSnapshot(monthly: claudeNearCapMonthly, primaryUsed: 34,
                       primaryResetsAt: nowNearCap.addingTimeInterval(130 * 60),
                       secondary: 21,
                       secondaryResetsAt: nowNearCap.addingTimeInterval(3 * 86_400))
    }

    func testClaudeMonthlyWindowsPrecedence() throws {
        let cl = DisplayFormatter.claude(state: .healthy, snapshot: claudeWindowsSnapshot,
                                         forecast: claudeForecast(burnRatePerMin: 0.4),
                                         now: nowNearCap)
        // (b) dot from the window state — explicitly NOT worst-of-all-dimensions.
        XCTAssertEqual(cl.dot, .green)
        // (c) hero + verdict belong to the window (standard minute-based family resumes).
        XCTAssertEqual(cl.header?.heroText, "66%")
        XCTAssertNotEqual(cl.header?.verdict?.line1.contains("pace — resets"), true,
                          "windowed verdict, not the period-quota family")
        // (d) the meter keeps its own red cue, now as an `OTHER LIMITS` row (STEP_178).
        XCTAssertEqual(cl.otherLimits?.rows.first { $0.id == .monthly }?.cue, .red)
        // (e) both limits coexist — the meter is listed beside the window that took the hero.
        XCTAssertTrue(cl.otherLimits!.rows.contains { $0.id == .monthly })
        // %/min restored — the window denominator exists again.
        XCTAssertNotNil(cl.header?.accountBurn?.value)
    }

    func testClaudeMonthlyWindowsMenuBarReadsTheWindow() {
        // (a) the string builder keys off primary != nil, not the spend meter.
        let m = DisplayFormatter.toolMenuBar(tool: .claude, state: .healthy,
                                             snapshot: claudeWindowsSnapshot,
                                             forecast: nil, now: nowNearCap)
        XCTAssertEqual(m.fullString, "CL 66% ↻2h10m")
        XCTAssertEqual(m.dot, .green)
    }

    // MARK: cle_stale — E10 + D-35 verbatim port (lower bound, pace suspended, freeze reason)

    private var claudeStaleAsOf: Date { nowClaudeHealthy.addingTimeInterval(-4 * 3600) }

    func testClaudeMonthlyStaleKeepsLowerBoundAndSuspendsPace() throws {
        let cl = DisplayFormatter.claude(state: .idleFallback,
                                         snapshot: claudeSnapshot(monthly: claudeMonthly()),
                                         forecast: nil, staleAsOf: claudeStaleAsOf,
                                         freezeReason: .rateLimited(retryAfter: 120),
                                         now: nowClaudeHealthy)
        // Muted hero kept — a true lower bound for the whole month (D-35).
        XCTAssertEqual(cl.header?.heroText, "42%")
        XCTAssertEqual(cl.dot, .grey)
        // Freeze reason in the verdict (D-33): rate-limited reads "Reconnecting…".
        XCTAssertEqual(cl.header?.verdict?.line1, "Reconnecting…")
        let stamp = Calendar.current.isDate(claudeStaleAsOf, inSameDayAs: nowClaudeHealthy)
            ? Fmt.clock(claudeStaleAsOf)
            : "\(Fmt.monthDay(claudeStaleAsOf)), \(Fmt.clock(claudeStaleAsOf))"
        XCTAssertEqual(cl.header?.verdict?.line2,
                       "as of \(stamp) · $69.16 of $120.00 · lower bound")
        // Pace suspended — a pace projected from stale data would be a confident claim.
        XCTAssertTrue(cl.header?.heroDetails.first?.text.hasSuffix("pace suspended") == true)
        XCTAssertTrue(cl.header?.sourceTag?.base.contains("· as of") ?? false)
    }

    func testClaudeMonthlyStaleOtherReasonVerdict() {
        let cl = DisplayFormatter.claude(state: .idleFallback,
                                         snapshot: claudeSnapshot(monthly: claudeMonthly()),
                                         forecast: nil, staleAsOf: claudeStaleAsOf,
                                         now: nowClaudeHealthy)
        XCTAssertEqual(cl.header?.verdict?.line1, "No fresh reading — showing last known")
        XCTAssertEqual(cl.header?.verdict?.colour, .grey)
    }

    /// D-38 (STEP_49), monthly layout: a `.credentialExpired` freeze carries the sign-in line while
    /// the D-35 lower-bound grammar is untouched — hero kept, `as of … · lower bound` line2, pace
    /// suspended. The third variant beside "Reconnecting…" (D-33) and the generic stale form.
    func testClaudeMonthlyStaleCredentialExpiredVerdict() {
        let cl = DisplayFormatter.claude(state: .idleFallback,
                                         snapshot: claudeSnapshot(monthly: claudeMonthly()),
                                         forecast: nil, staleAsOf: claudeStaleAsOf,
                                         freezeReason: .credentialExpired,
                                         now: nowClaudeHealthy)
        XCTAssertEqual(cl.header?.verdict?.line1,
                       "Claude sign-in expired — open Claude Code to reconnect.")
        XCTAssertEqual(cl.header?.heroText, "42%", "lower bound kept (D-35)")
        XCTAssertEqual(cl.dot, .grey)
        let stamp = Calendar.current.isDate(claudeStaleAsOf, inSameDayAs: nowClaudeHealthy)
            ? Fmt.clock(claudeStaleAsOf)
            : "\(Fmt.monthDay(claudeStaleAsOf)), \(Fmt.clock(claudeStaleAsOf))"
        XCTAssertEqual(cl.header?.verdict?.line2,
                       "as of \(stamp) · $69.16 of $120.00 · lower bound")
        XCTAssertTrue(cl.header?.heroDetails.first?.text.hasSuffix("pace suspended") == true)
    }

    func testClaudeMonthlyStaleMenuBarE10() {
        // E10 (locked P1-15, per-layout): grey dot + percent kept + ↻Nd kept; ◔ never stale.
        let m = DisplayFormatter.staleMenuBar(tool: .claude,
                                              snapshot: claudeSnapshot(monthly: claudeMonthly()),
                                              now: nowClaudeHealthy)
        XCTAssertEqual(m.fullString, "CL 42% ↻14d")
        XCTAssertEqual(m.dot, .grey)
    }

    // MARK: cle_rolled_over — the derived reset passed unseen (month rollover, D-35)

    func testClaudeMonthlyRolledOverUnseenDegradesToUnknownForm() throws {
        // Past the *derived* monthly reset (§8.0.4 — client-computed calendar month, the one
        // place the Codex pattern does not transfer) the percent no longer bounds anything —
        // Core degrades `monthlyLimit` to nil and the standard unknown forms take over.
        let afterRollover = augustFirst.addingTimeInterval(3600)
        let m = DisplayFormatter.staleMenuBar(tool: .claude,
                                              snapshot: claudeSnapshot(monthly: claudeMonthly()),
                                              now: afterRollover)
        XCTAssertEqual(m.fullString, "CL —— est")
        XCTAssertEqual(m.dot, .grey)

        let cl = DisplayFormatter.claude(state: .idleFallback,
                                         snapshot: claudeSnapshot(monthly: claudeMonthly()),
                                         forecast: nil, staleAsOf: claudeStaleAsOf,
                                         now: afterRollover)
        XCTAssertEqual(cl.header?.heroText, "——")
        XCTAssertEqual(cl.header?.verdict?.line1, "—",
                       "unknown form — never a confident 'No active session' from a rolled-over month")
        XCTAssertNotEqual(cl.header?.limit?.id, .monthly, "the meter does not outlive its month")
    }

    // MARK: §19 cross-surface agreement — Claude (menu-bar dot == tab dot == verdict colour)

    func testClaudeCrossSurfaceAgreementStaleAndReached() {
        // Stale: grey everywhere (E10 joins the stale-keep family).
        let staleMenu = DisplayFormatter.staleMenuBar(tool: .claude,
                                                      snapshot: claudeSnapshot(monthly: claudeMonthly()),
                                                      now: nowClaudeHealthy)
        let staleTab = DisplayFormatter.claude(state: .idleFallback,
                                               snapshot: claudeSnapshot(monthly: claudeMonthly()),
                                               forecast: nil, staleAsOf: claudeStaleAsOf,
                                               now: nowClaudeHealthy)
        XCTAssertEqual(staleMenu.dot, staleTab.dot)
        XCTAssertEqual(staleTab.dot, .grey)

        // Reached: red everywhere (from `usedPercentExact ≥ 100` alone — P1-16 caveat above).
        let reachedMenu = DisplayFormatter.toolMenuBar(tool: .claude, state: .nullWindow,
                                                       snapshot: claudeReachedSnapshot,
                                                       forecast: nil, now: nowNearCap)
        let reachedTab = DisplayFormatter.claude(state: .nullWindow,
                                                 snapshot: claudeReachedSnapshot,
                                                 forecast: claudeForecast(), now: nowNearCap)
        XCTAssertEqual(reachedMenu.dot, .red)
        XCTAssertEqual(reachedTab.dot, .red)
        XCTAssertEqual(reachedTab.header?.verdict?.colour, .red)
    }

    // MARK: Fmt.money (REV-40 minor units, exponent-scaled; REV-102 §2.5 — symbol first)

    func testFmtMoney() {
        XCTAssertEqual(Fmt.money(minor: 6916, exponent: 2, currency: "USD"), "$69.16")
        XCTAssertEqual(Fmt.money(minor: 12000, exponent: 2, currency: "USD"), "$120.00")
        XCTAssertEqual(Fmt.money(minor: 406.80, exponent: 2, currency: "USD"), "$4.07")
        // STEP_219 (REV-102 §2.5) inverts the old "never guess symbols" suffix rule: the four
        // currencies with a symbol of their own lead with it, in the provider's currency.
        XCTAssertEqual(Fmt.money(minor: 6916, exponent: 2, currency: "EUR"), "€69.16")
        XCTAssertEqual(Fmt.money(minor: 6916, exponent: 2, currency: "GBP"), "£69.16")
        XCTAssertEqual(Fmt.money(minor: 5000, exponent: 0, currency: "JPY"), "¥5,000")
        // Everything else keeps the ISO code — a `$` never stands for the wrong dollar.
        XCTAssertEqual(Fmt.money(minor: 6916, exponent: 2, currency: "CHF"), "69.16 CHF")
        XCTAssertEqual(Fmt.money(minor: 6916, exponent: 2, currency: "CAD"), "69.16 CAD")
        // No currency sent ⇒ USD; case is the provider's business, not ours.
        XCTAssertEqual(Fmt.money(minor: 6916, exponent: 2, currency: nil), "$69.16")
        XCTAssertEqual(Fmt.money(minor: 6916, exponent: 2, currency: "eur"), "€69.16")
        XCTAssertEqual(Fmt.money(minor: 6916, exponent: 2, currency: "chf"), "69.16 CHF")
        // The major-unit twin (`used_credits`) is the same rule over the same digits.
        XCTAssertEqual(Fmt.money(major: Decimal(string: "70.25")!, exponent: 2, currency: "EUR"),
                       "€70.25")
        XCTAssertEqual(Fmt.money(major: Decimal(string: "1234.5")!, exponent: 2, currency: nil),
                       "$1,234.50")
        XCTAssertEqual(Fmt.moneyGlyphSymbol("EUR"), "€")
        XCTAssertEqual(Fmt.moneyGlyphSymbol("CHF"), "$", "no symbol of its own ⇒ the `$` glyph")
        XCTAssertEqual(Fmt.moneyGlyphSymbol(nil), "$")
        // Fraction digits follow the exponent; grouping as credits.
        XCTAssertEqual(Fmt.money(minor: 5, exponent: 0, currency: "USD"), "$5")
        XCTAssertEqual(Fmt.money(minor: 123_456_789, exponent: 2, currency: "USD"),
                       "$1,234,567.89")
    }
}
