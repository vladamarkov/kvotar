import XCTest
import KvotarCore
@testable import KvotarUI

/// STEP_88 (REV-59 §5 / UI Spec D-60) — **the burn card, the runway verdict and the forecast come
/// off the low-allowance Codex shape.** Not a fork, a removal: no pill, no `%/min`, no `tok/min`,
/// no `Local source` row, no `Off-machine` row, no `Measuring…`, no footer.
///
/// The reason is measurement, not taste. On the live `go` account the whole 30-day allowance went
/// 0% → 89% in seven minutes across twelve turns, per-turn deltas `6, 11, 9, 5, 4, 8, 5, 19, 4, 10,
/// 8`. `%/hr` on a meter observed at ~12%/min renders in the hundreds, and `Measuring…` promises a
/// number we would never usefully deliver.
///
/// The dot is the one thing that stays loud. State cannot carry red here — At risk and Bad timing
/// are the only red ranks below 100% and both are gated off — so the display paints it from the
/// used percentage, exactly as the Enterprise monthly layout already paints its dot from the
/// monthly forecast rather than from its calm rank-12 state.
///
/// Fixtures are real corpus values, same provenance as `DisplayFormatterWindowGrainTests`.
final class DisplayFormatterLowAllowanceTests: XCTestCase {

    /// `go` account, 2026-08-11: anchored at first use, resetting 2026-09-10 18:47:32 CEST.
    private static let goResetsAt = Date(timeIntervalSince1970: 1_789_058_852)
    private static let thirtyDayWidth = 43_200 * 60
    private static let entPrimaryResetsAt = Date(timeIntervalSince1970: 1_772_425_633)
    private static let entSecondaryResetsAt = Date(timeIntervalSince1970: 1_773_012_433)

    /// Plus account, 2026-08-12 (REV-63 §2): one 7-day window, resetting 2026-08-18.
    private static let plusResetsAt = Date(timeIntervalSince1970: 1_787_169_006)

    private var goNow: Date { Self.goResetsAt.addingTimeInterval(-27 * 86_400) }
    private var plusNow: Date { Self.plusResetsAt.addingTimeInterval(-6 * 86_400) }
    private var entNow: Date { Self.entPrimaryResetsAt.addingTimeInterval(-90 * 60) }

    private func goSnapshot(used: Double? = 97) -> QuotaSnapshot {
        QuotaSnapshot(tool: .codex, primaryUsedPct: used, primaryResetsAt: Self.goResetsAt,
                      primaryWindowSeconds: Self.thirtyDayWidth,
                      secondaryUsedPct: nil, secondaryResetsAt: nil,
                      rateLimitReached: false, extraUsage: nil,
                      source: .appServerRPC, planType: "go")
    }

    private func enterpriseSnapshot() -> QuotaSnapshot {
        QuotaSnapshot(tool: .codex, primaryUsedPct: 62, primaryResetsAt: Self.entPrimaryResetsAt,
                      primaryWindowSeconds: 300 * 60,
                      secondaryUsedPct: 40, secondaryResetsAt: Self.entSecondaryResetsAt,
                      rateLimitReached: false, extraUsage: nil,
                      source: .appServerRPC, planType: "enterprise")
    }

    /// A live forecast, as if the buffer were full — the point is that the *card* refuses it, not
    /// that the engine happens to hand over nils.
    private func liveForecast() -> Forecast {
        Forecast(tool: .codex, tier: .fullRunway, runwayMinutes: 42, burnRatePerMin: 0.7,
                 isEstimate: false, pollCount: 10)
    }

    private func codex(_ snapshot: QuotaSnapshot, state: AppState,
                       forecast: Forecast?, now: Date) -> CodexDisplayState {
        DisplayFormatter.codex(state: state, snapshot: snapshot, forecast: forecast,
                               pollAsOf: now, now: now)
    }

    // MARK: The card comes off

    /// The burn card is gone (STEP_178); the quantity lives on the header's `Quota burn` line,
    /// and on this shape that line is **inapplicable** — hidden, never dashed.
    func testBurnFactIsNotRenderedOnTheShape() {
        let display = codex(goSnapshot(), state: .elevated, forecast: liveForecast(), now: goNow)
        XCTAssertEqual(display.header?.accountBurn?.isApplicable, false,
                       "a rate we have failed to model must not be stated — the line does not render")
        XCTAssertEqual(display.header?.notSeenLocally?.isApplicable, false)
    }

    func testVerdictIsNotRenderedOnTheShape() {
        let display = codex(goSnapshot(), state: .elevated, forecast: liveForecast(), now: goNow)
        XCTAssertNil(display.header?.verdict,
                     "a forecast obsolete before it draws is worse than silence")
    }

    /// The rows above and below the removed card are STEP_87's and must be untouched by it.
    func testTheRowsAroundItSurvive() {
        let display = codex(goSnapshot(), state: .elevated, forecast: liveForecast(), now: goNow)
        XCTAssertEqual(display.header?.heroText, "3%")
        XCTAssertEqual(display.header?.limitCaption, "Monthly quota left")
        XCTAssertEqual(display.header?.heroDetails.map(\.text), ["resets in 27 days"])
    }

    // MARK: The verdict that still matters

    /// Being blocked is the one thing left worth saying, so the over-quota verdict must survive the
    /// suppression that removes every runway line above it.
    func testOverQuotaVerdictStillRenders() {
        let display = codex(goSnapshot(used: 100), state: .overQuota, forecast: nil, now: goNow)
        XCTAssertNotNil(display.header?.verdict)
        XCTAssertTrue(display.header?.verdict?.line1.hasPrefix("Stopped") == true,
                      "got: \(display.header?.verdict?.line1 ?? "nil")")
    }

    /// A window that has not started (REV-57) keeps its own informational line — "not started" is
    /// a statement about the window, not a forecast about its burn.
    func testUnanchoredWindowKeepsItsNullVerdict() {
        let unanchored = QuotaSnapshot(
            tool: .codex, primaryUsedPct: 0, primaryResetsAt: nil,
            primaryWindowSeconds: Self.thirtyDayWidth,
            secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: false,
            source: .appServerRPC, planType: "go")
        let display = codex(unanchored, state: .nullWindow, forecast: nil, now: goNow)
        XCTAssertEqual(display.header?.verdict?.line1, "No active window")
    }

    // MARK: The dot is painted from the used percentage

    func testDotFollowsUsedPercent() {
        XCTAssertEqual(codex(goSnapshot(used: 97), state: .elevated,
                             forecast: nil, now: goNow).dot, .red)
        XCTAssertEqual(codex(goSnapshot(used: 70), state: .elevated,
                             forecast: nil, now: goNow).dot, .amber)
        XCTAssertEqual(codex(goSnapshot(used: 40), state: .healthy,
                             forecast: nil, now: goNow).dot, .green)
    }

    func testMenuBarDotFollowsUsedPercent() {
        let bar = DisplayFormatter.toolMenuBar(tool: .codex, state: .elevated,
                                               snapshot: goSnapshot(used: 97),
                                               forecast: nil, now: goNow)
        XCTAssertEqual(bar.dot, .red)
        XCTAssertEqual(bar.percentText, "3%")
        XCTAssertEqual(bar.timeSlot, "↻27d", "STEP_87's reset slot is unaffected")
    }

    /// A hard block is already red and owns its own colour — the repaint must never demote it, and
    /// never repaints over the stale grey either.
    func testHardBlockAndStaleKeepTheirOwnColour() {
        XCTAssertEqual(codex(goSnapshot(used: 100), state: .overQuota,
                             forecast: nil, now: goNow).dot, .red)
        let stale = DisplayFormatter.codex(state: .elevated, snapshot: goSnapshot(used: 40),
                                           forecast: nil,
                                           staleAsOf: goNow.addingTimeInterval(-3_600),
                                           now: goNow)
        XCTAssertEqual(stale.dot, .grey, "staleness owns the colour — a green repaint would hide it")
    }

    // MARK: The regression that matters — every other shape is untouched

    func testEnterpriseFiveHourCardIsUnchanged() {
        let display = codex(enterpriseSnapshot(), state: .elevated,
                            forecast: liveForecast(), now: entNow)
        XCTAssertEqual(display.header?.accountBurn?.isApplicable, true,
                       "the five-hour shape keeps its burn line")
        XCTAssertNotNil(display.header?.verdict)
        XCTAssertEqual(display.dot, DisplayFormatter.dot(for: .elevated),
                       "no repaint off the shape — the state owns the colour")
    }

    func testClaudeIsUnreachable() {
        let claude = QuotaSnapshot(tool: .claude, primaryUsedPct: 97,
                                   primaryResetsAt: Self.entPrimaryResetsAt,
                                   secondaryUsedPct: 14,
                                   secondaryResetsAt: Self.entSecondaryResetsAt,
                                   rateLimitReached: false, extraUsage: .disabled,
                                   planType: "max_20x")
        let display = DisplayFormatter.claude(state: .elevated, snapshot: claude,
                                              forecast: liveForecast(), now: entNow)
        XCTAssertEqual(display.header?.accountBurn?.isApplicable, true)
        XCTAssertNotNil(display.header?.verdict)
        XCTAssertEqual(display.dot, DisplayFormatter.dot(for: .elevated))
    }

    // MARK: STEP_89 — the tier note, the upgrade link, and the money that is not ours

    /// A local history straddling the 2026-07-31 account switch: `$73.16` of Enterprise-era work
    /// still inside the rolling 30-day lookback, `$12.40` inside the rolling 7-day one, against
    /// `$3.06` of real work in this account's own window and nothing today. Real shape, real
    /// numbers — this is the card the dogfood machine actually rendered.
    private func attributionSpanningAnAccountSwitch() -> LocalAttribution {
        LocalAttribution(
            project: "kvotar", model: "gpt-5.5", surfaceBucket: "IDE extension",
            subagentCount: 0, cacheHitRatio: 0.85,
            estValue: EstimatedValueEngine.WindowValue(weekly: 12.40, thirtyDay: 73.16, today: 0),
            surfaceShares: [], tokensPerMinute: nil,
            lastActivityAt: goNow, sessionCount: 1, modelTotals: [], windowValue: 3.06)
    }

    private func codexWithLocal(_ snapshot: QuotaSnapshot, now: Date) -> CodexDisplayState {
        DisplayFormatter.codex(state: .elevated, snapshot: snapshot, forecast: nil,
                               localAttribution: attributionSpanningAnAccountSwitch(),
                               pollAsOf: now, now: now)
    }

    /// D-61 — verbatim, always on. The wording is locked: it states an observation ("in practice")
    /// rather than a specification, and names no number, because OpenAI publishes none.
    func testTierNoteRendersVerbatimUnderTheHeader() {
        let display = codex(goSnapshot(), state: .elevated, forecast: nil, now: goNow)
        XCTAssertEqual(display.quotaNote,
                       "OpenAI doesn't publish this plan's Codex limit. In practice, one working session can use most of it.")
    }

    /// The one control the card can offer on a plan that lasts about one working session — the
    /// same one OpenAI puts at this spot in its own menu.
    func testUpgradeLinkAccompaniesTheNote() {
        let display = codex(goSnapshot(), state: .elevated, forecast: nil, now: goNow)
        XCTAssertEqual(display.quotaNoteURL?.absoluteString, "https://chatgpt.com/#pricing")
    }

    /// Shape-gated, so it disappears by itself the moment the account moves to a tier whose
    /// ceiling OpenAI does publish — no state to specify, no fade to test.
    func testTierNoteAndLinkAreAbsentOffTheShape() {
        let ent = codex(enterpriseSnapshot(), state: .elevated, forecast: nil, now: entNow)
        XCTAssertNil(ent.quotaNote)
        XCTAssertNil(ent.quotaNoteURL)
    }

    /// **The row set is the same on every card in the app, and this test is a pin.** Two
    /// proposals to shorten it here were considered and rejected (user ruling 2026-08-12), so the
    /// next reader does not re-derive either of them:
    ///
    /// - Drop `30-day` because the window row "measures the same 30 days" (REV-59 §8, UI Spec
    ///   §2.6). True only at the reset — on 2026-08-12, against a window running Aug 11 → Sep 10,
    ///   `This window` covered one day and `30-day` covered thirty.
    /// - Drop both rolling horizons so a lookback cannot bill this account for a previous one's
    ///   work (P1-27 — the attribution does not exist, and `30-day $73.16` of Enterprise-era spend
    ///   really did render under a `go` account). Rejected because switching accounts is a corner
    ///   case and the user to design for has one account and one plan; the shortened set removed a
    ///   real pace signal from that user and bought them nothing.
    ///
    /// The account exposure is therefore **documented, not mitigated**: bounded by the horizon and
    /// self-clearing as the lookback moves past the switch. Since STEP_178 the first row is
    /// `Today` — the popover's own bounded local day — rather than the window's span.
    func testRowSetMatchesEveryOtherCard() {
        let display = codexWithLocal(goSnapshot(), now: goNow)
        let rows = display.localActivity?.valueRows ?? []
        XCTAssertEqual(rows.map(\.label), ["Today", "7-day", "30-day"],
                       "the low-allowance shape counts money exactly like every other one")
        XCTAssertEqual(rows.map(\.value).dropFirst(), ["$12.40", "$73.16"])
    }

    /// The same three rows on a five-hour window — one row set, no shape fork anywhere.
    func testFiveHourShapeRendersTheSameRowSet() {
        XCTAssertEqual(codexWithLocal(enterpriseSnapshot(), now: entNow)
                        .localActivity?.valueRows.map(\.label),
                       ["Today", "7-day", "30-day"])
    }


    private func plusSnapshot(used: Double? = 3) -> QuotaSnapshot {
        QuotaSnapshot(tool: .codex, primaryUsedPct: used,
                      primaryResetsAt: Self.plusResetsAt,
                      primaryWindowSeconds: 10_080 * 60,
                      secondaryUsedPct: nil, secondaryResetsAt: nil,
                      rateLimitReached: false, extraUsage: nil,
                      source: .appServerRPC, planType: "plus")
    }

    /// **No second gate, and this is the pin** (REV-63 §5). The note is a rate claim gated on the
    /// same boolean the mute uses, so correcting the rule corrected the copy with no change in
    /// this file. A separate gate would have been two places to keep in agreement about one fact.
    func testTierNoteAndLinkAreAbsentOnPlus() {
        let display = codex(plusSnapshot(), state: .healthy, forecast: liveForecast(),
                            now: plusNow)
        XCTAssertNil(display.quotaNote)
        XCTAssertNil(display.quotaNoteURL)
    }

    /// And everything the mute had removed comes back on the same card.
    func testBurnSectionAndVerdictReturnOnPlus() {
        let display = codex(plusSnapshot(), state: .healthy, forecast: liveForecast(),
                            now: plusNow)
        XCTAssertEqual(display.header?.accountBurn?.isApplicable, true, "the burn line is back")
        XCTAssertNotNil(display.header?.verdict, "the runway verdict row is back")
    }
}
