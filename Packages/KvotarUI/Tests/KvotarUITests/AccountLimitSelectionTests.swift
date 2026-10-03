import XCTest
import KvotarCore
@testable import KvotarUI

/// STEP_176 — the selected account limit (REV-92 / D-114; Baseline §15.2). The acceptance matrix
/// from `TASKS/STEP_176_popover_limit_selection.md`, one case per test: which limit is the hero,
/// why, and that every other limit sits in `others` exactly once with its own identity.
final class AccountLimitSelectionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Builders

    private func snapshot(tool: Tool = .claude, used: Double? = 40, resetsInMin: Double? = 120,
                          windowSeconds: Int? = 18_000, weekly: Double? = 30,
                          weeklyResetDays: Double = 5, reached: Bool = false,
                          spendControl: Bool? = nil, monthly: MonthlyLimit? = nil,
                          models: [AdditionalRateLimit] = []) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, primaryUsedPct: used,
                      primaryResetsAt: resetsInMin.map { now.addingTimeInterval($0 * 60) },
                      primaryWindowSeconds: windowSeconds,
                      secondaryUsedPct: weekly,
                      secondaryResetsAt: weekly == nil ? nil : now.addingTimeInterval(weeklyResetDays * 86_400),
                      rateLimitReached: reached, extraUsage: tool == .claude ? .disabled : nil,
                      spendControlReached: spendControl, additionalRateLimits: models,
                      monthlyLimit: monthly, source: tool == .codex ? .appServerRPC : .oauth,
                      email: "user@example.com", planType: tool == .claude ? "max" : "pro")
    }

    private func spark(primaryUsed: Double? = 0, primaryReset: Date? = nil,
                       weeklyUsed: Double? = 0, weeklyResetDays: Double = 6.9) -> AdditionalRateLimit {
        AdditionalRateLimit(id: "codex_bengalfox", name: "GPT-5.3-Codex-Spark",
                            usedPercent: primaryUsed, resetsAt: primaryReset,
                            primaryWindowSeconds: 18_000,
                            secondary: .init(usedPercent: weeklyUsed,
                                             resetsAt: now.addingTimeInterval(weeklyResetDays * 86_400),
                                             windowSeconds: 604_800))
    }

    private func forecast(runway: Double? = 300, burn: Double? = 0.2) -> Forecast {
        Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: runway, burnRatePerMin: burn,
                 isEstimate: false, pollCount: 10)
    }

    private func select(_ s: QuotaSnapshot?, state: AppState = .healthy, forecast: Forecast? = nil,
                        staleAsOf: Date? = nil) -> AccountLimitSelection {
        DisplayFormatter.selectLimit(tool: s?.tool ?? .claude, state: state, snapshot: s,
                                     forecast: forecast ?? self.forecast(), staleAsOf: staleAsOf,
                                     now: now)
    }

    private func ids(_ sel: AccountLimitSelection) -> [AccountLimitID] { sel.others.map(\.id) }

    // MARK: Shapes

    func testPrimaryOnlyIsTheHeroWithNothingElse() {
        let sel = select(snapshot(weekly: nil))
        XCTAssertEqual(sel.hero?.id, .primaryWindow)
        XCTAssertEqual(sel.heroReason, .primaryDefault)
        XCTAssertTrue(sel.others.isEmpty)
        XCTAssertTrue(sel.forecastApplies)
        XCTAssertEqual(sel.hero?.periodLabel, "5-hour")
        XCTAssertEqual(DisplayFormatter.limitCaption(sel.hero), "5-hour quota left")
    }

    func testHealthyPrimaryWithWeeklyPutsTheWeeklyInOthersOnce() {
        let sel = select(snapshot())
        XCTAssertEqual(sel.hero?.id, .primaryWindow)
        XCTAssertEqual(ids(sel), [.secondaryWindow])
        XCTAssertEqual(sel.others[0].periodLabel, "Weekly")
        XCTAssertEqual(sel.others[0].status, .healthy)
    }

    /// A Codex weekly-only main allowance: the weekly *is* the primary window. No five-hour row
    /// is invented anywhere.
    func testWeeklyOnlyMainAllowanceIsThePrimaryHero() {
        let sel = select(snapshot(tool: .codex, used: 4, resetsInMin: 6 * 1440,
                                  windowSeconds: 604_800, weekly: nil))
        XCTAssertEqual(sel.hero?.id, .primaryWindow)
        XCTAssertEqual(sel.hero?.periodLabel, "Weekly")
        XCTAssertEqual(DisplayFormatter.limitCaption(sel.hero), "Weekly quota left")
        XCTAssertTrue(sel.others.isEmpty)
    }

    func testMonthlyOnlySpendMeterIsTheHeroInItsOwnUnits() {
        let monthly = MonthlyLimit(limitAmount: 12_000, usedAmount: 6_916, remainingPercent: 42,
                                   resetsAt: now.addingTimeInterval(10 * 86_400),
                                   unit: .money(currency: "USD", exponent: 2), source: nil)
        let sel = select(snapshot(used: nil, resetsInMin: nil, windowSeconds: nil, weekly: nil,
                                  monthly: monthly), state: .nullWindow)
        XCTAssertEqual(sel.hero?.id, .monthly)
        XCTAssertEqual(sel.heroReason, .monthlyDefault)
        XCTAssertEqual(sel.hero?.unit, .money(currency: "USD", exponent: 2))
        XCTAssertEqual(sel.hero?.usedAmount, 6_916)
        XCTAssertEqual(DisplayFormatter.limitCaption(sel.hero), "Monthly spend limit left")
        XCTAssertFalse(sel.forecastApplies)
        XCTAssertTrue(sel.others.isEmpty)
    }

    func testMonthlyOnlyCreditsMeterOnCodexNamesUsage() {
        let monthly = MonthlyLimit(limitAmount: 5000, usedAmount: 2377, remainingPercent: 52,
                                   resetsAt: now.addingTimeInterval(10 * 86_400), source: nil)
        let sel = select(snapshot(tool: .codex, used: nil, resetsInMin: nil, windowSeconds: nil,
                                  weekly: nil, monthly: monthly), state: .nullWindow)
        XCTAssertEqual(sel.hero?.id, .monthly)
        XCTAssertEqual(sel.hero?.unit, .credits)
        XCTAssertEqual(DisplayFormatter.limitCaption(sel.hero), "Monthly usage limit left")
    }

    /// No five-hour, weekly + monthly: the monthly layout keeps the hero (D-34 precedence,
    /// deferred to STEP_178 — see the task file) and the weekly is listed once.
    func testWeeklyAndMonthlyWithNoFiveHourKeepsTheMonthlyLayoutAndListsTheWeekly() {
        let monthly = MonthlyLimit(limitAmount: 12_000, usedAmount: 2_000, remainingPercent: 83,
                                   resetsAt: now.addingTimeInterval(10 * 86_400),
                                   unit: .money(currency: "USD", exponent: 2), source: nil)
        let sel = select(snapshot(used: nil, resetsInMin: nil, windowSeconds: nil, weekly: 12,
                                  monthly: monthly), state: .nullWindow)
        XCTAssertEqual(sel.hero?.id, .monthly)
        XCTAssertEqual(ids(sel), [.secondaryWindow])
    }

    func testNoLimitsYieldsNoHero() {
        XCTAssertEqual(select(nil), .empty)
        let sel = select(snapshot(tool: .codex, used: nil, resetsInMin: nil, windowSeconds: nil,
                                  weekly: nil), state: .nullWindow)
        // Codex both-null: the primary slot keeps its identity with no value (the `——` hero).
        XCTAssertEqual(sel.hero?.id, .primaryWindow)
        XCTAssertNil(sel.hero?.usedPercent)
        XCTAssertEqual(sel.hero?.status, .unknown)
        XCTAssertTrue(sel.others.isEmpty)
    }

    // MARK: Promotion

    /// **The promotion is retired** (REV-96 §2.4 — STEP_194): the five-hour keeps the hero while
    /// every limit is below 100 %, whatever tier a long limit is in. The weekly still carries its
    /// own critical status as a row, and the header strip is what speaks for it.
    func testANearlySpentWeeklyDoesNotTakeTheHero() {
        let sel = select(snapshot(used: 0, weekly: 91), state: .limitNearlySpent)
        XCTAssertEqual(sel.hero?.id, .primaryWindow)
        XCTAssertEqual(sel.heroReason, .primaryDefault)
        XCTAssertEqual(ids(sel), [.secondaryWindow])
        XCTAssertEqual(sel.others.first?.status, .critical)
        XCTAssertEqual(sel.others.first?.statusReason, .state(.limitNearlySpent))
        XCTAssertTrue(sel.forecastApplies, "the primary hero keeps its own runway")
        XCTAssertEqual(DisplayFormatter.limitCaption(sel.hero), "5-hour quota left")
    }

    /// **The limit that stops you takes the hero.** A spent weekly beside a five-hour window with
    /// everything left: the weekly is the header at 0 %, and the five-hour is greyed and says why.
    func testASpentWeeklyTakesTheHeroAndGreysTheFiveHour() {
        let sel = select(snapshot(used: 0, weekly: 100), state: .overQuota)
        XCTAssertEqual(sel.hero?.id, .secondaryWindow)
        XCTAssertEqual(sel.heroReason, .blocked(limitIdentified: true))
        XCTAssertEqual(sel.hero?.remainingPercent, 0)
        XCTAssertEqual(ids(sel), [.primaryWindow])
        XCTAssertFalse(sel.forecastApplies, "a weekly hero inherits no five-hour runway")
        XCTAssertEqual(DisplayFormatter.limitCaption(sel.hero), "Weekly quota left")
    }

    /// The §13.4 hold: the state is still a long-limit rank while the weekly has dropped below
    /// the line. The selector creates no second state machine — the hero is the primary either
    /// way now, and the row simply loses its tier suffix.
    func testHeldLongLimitRankKeepsThePrimaryHero() {
        let sel = select(snapshot(used: 10, weekly: 40), state: .limitAheadOfPace)
        XCTAssertEqual(sel.hero?.id, .primaryWindow)
        XCTAssertEqual(sel.others.first?.status, .healthy)
    }

    /// State first: a primary-window warning keeps the primary hero even beside a weekly past
    /// the line — §13 already ranks Elevated above Weekly-elevated, and the primary carries the
    /// validated forecast. The weekly still shows its own warning cue in Other Limits.
    func testPrimaryWarningStateKeepsThePrimaryOverAHotWeekly() {
        let sel = select(snapshot(used: 70, weekly: 96), state: .elevated)
        XCTAssertEqual(sel.hero?.id, .primaryWindow)
        XCTAssertEqual(sel.heroReason, .stateWarning)
        XCTAssertEqual(sel.others[0].id, .secondaryWindow)
        // Critical since STEP_194: 96 % is past the nearly-spent line, and the row says so even
        // though the *header* stays with the primary window's warning.
        XCTAssertEqual(sel.others[0].status, .critical)
        XCTAssertEqual(sel.others[0].cue, .red)
    }

    /// Model-only warning: the account keeps the header while the warning names its model scope.
    func testModelOnlyWarningNamesTheModelAndKeepsTheAccountHero() {
        let s = snapshot(tool: .codex, used: 4, resetsInMin: 6 * 1440, windowSeconds: 604_800,
                         weekly: nil, models: [spark(primaryUsed: 3, primaryReset: now.addingTimeInterval(3600),
                                                     weeklyUsed: 92)])
        let sel = select(s)
        XCTAssertEqual(sel.hero?.id, .primaryWindow)
        XCTAssertEqual(sel.heroReason, .primaryDefault)
        XCTAssertEqual(ids(sel), [.modelWindow(allowance: "codex_bengalfox", slot: .primary),
                                  .modelWindow(allowance: "codex_bengalfox", slot: .secondary)])
        let warning = try! XCTUnwrap(DisplayFormatter.modelLimitWarnings(sel, now: now).first)
        XCTAssertEqual(warning.id, .modelWindow(allowance: "codex_bengalfox", slot: .secondary))
        XCTAssertEqual(warning.headline, "⚠ GPT-5.3-Codex-Spark weekly · 8% left")
        XCTAssertEqual(warning.status, .warning)
    }

    /// Main weekly-only + Spark five-hour + Spark weekly: three windows, three identities,
    /// three periods, three resets, no invented main five-hour.
    func testMainWeeklyOnlyPlusSparkPreservesAllThreeWindows() {
        let s = snapshot(tool: .codex, used: 4, resetsInMin: 6 * 1440, windowSeconds: 604_800,
                         weekly: nil, models: [spark(primaryUsed: 0, primaryReset: nil, weeklyUsed: 0)])
        let sel = select(s)
        XCTAssertEqual(sel.hero?.id, .primaryWindow)
        XCTAssertEqual(ids(sel), [.modelWindow(allowance: "codex_bengalfox", slot: .primary),
                                  .modelWindow(allowance: "codex_bengalfox", slot: .secondary)])
        XCTAssertEqual(sel.others.map(\.periodSeconds), [18_000, 604_800])
        XCTAssertEqual(sel.others[0].availability, .unanchored, "0 %, width, no anchor = not started")
        XCTAssertEqual(sel.others[0].status, .notStarted)
        XCTAssertNotNil(sel.others[1].resetsAt)
        XCTAssertNotEqual(sel.others[1].resetsAt, sel.hero?.resetsAt)
        let all = [sel.hero!] + sel.others
        XCTAssertEqual(Set(all.map(\.id)).count, 3, "every window exactly once")
    }

    /// Either Spark window can warn, but neither takes over the account header.
    func testSparkWeeklyCriticalVersusSparkFiveHourCritical() {
        let weeklyHot = snapshot(tool: .codex, used: 4, resetsInMin: 6 * 1440, windowSeconds: 604_800,
                                 weekly: nil, models: [spark(primaryUsed: 10, primaryReset: now.addingTimeInterval(3600),
                                                             weeklyUsed: 100)])
        let a = select(weeklyHot)
        XCTAssertEqual(a.hero?.id, .primaryWindow)
        XCTAssertEqual(a.others.filter { $0.id.isModelWindow }.map(\.id),
                       [.modelWindow(allowance: "codex_bengalfox", slot: .primary),
                        .modelWindow(allowance: "codex_bengalfox", slot: .secondary)])
        XCTAssertEqual(DisplayFormatter.modelLimitWarnings(a, now: now).first?.id,
                       .modelWindow(allowance: "codex_bengalfox", slot: .secondary))

        let fiveHourHot = snapshot(tool: .codex, used: 4, resetsInMin: 6 * 1440, windowSeconds: 604_800,
                                   weekly: nil, models: [spark(primaryUsed: 90, primaryReset: now.addingTimeInterval(3600),
                                                               weeklyUsed: 12)])
        let b = select(fiveHourHot)
        XCTAssertEqual(b.hero?.id, .primaryWindow)
        XCTAssertEqual(b.others.filter { $0.id.isModelWindow }.map(\.id),
                       [.modelWindow(allowance: "codex_bengalfox", slot: .primary),
                        .modelWindow(allowance: "codex_bengalfox", slot: .secondary)])
        XCTAssertEqual(DisplayFormatter.modelLimitWarnings(b, now: now).first?.id,
                       .modelWindow(allowance: "codex_bengalfox", slot: .primary))
    }

    /// Warning order: higher used % wins, then the stable ID.
    func testModelWarningTieBreaksOnUsedThenStableID() {
        let two = [
            AdditionalRateLimit(id: "b", name: "B", usedPercent: 90, resetsAt: now.addingTimeInterval(3600)),
            AdditionalRateLimit(id: "a", name: "A", usedPercent: 90, resetsAt: now.addingTimeInterval(3600)),
        ]
        let sel = select(snapshot(tool: .codex, models: two))
        XCTAssertEqual(DisplayFormatter.modelLimitWarnings(sel, now: now).first?.id,
                       .modelWindow(allowance: "a", slot: .primary), "equal used ⇒ earlier ID")
        let sel2 = select(snapshot(tool: .codex, models: [
            AdditionalRateLimit(id: "a", name: "A", usedPercent: 86, resetsAt: nil),
            AdditionalRateLimit(id: "b", name: "B", usedPercent: 95, resetsAt: nil),
        ]))
        XCTAssertEqual(DisplayFormatter.modelLimitWarnings(sel2, now: now).first?.id,
                       .modelWindow(allowance: "b", slot: .primary), "higher used wins")
    }

    /// A Claude scoped warning has no invented period and leaves the primary in the header.
    func testClaudeScopedLimitWarnsWithoutAnInventedPeriod() {
        let fable = AdditionalRateLimit(id: nil, name: "Fable", usedPercent: 88,
                                        resetsAt: now.addingTimeInterval(5 * 86_400))
        let sel = select(snapshot(used: 20, weekly: 30, models: [fable]))
        XCTAssertEqual(sel.hero?.id, .primaryWindow)
        let warning = try! XCTUnwrap(DisplayFormatter.modelLimitWarnings(sel, now: now).first)
        XCTAssertEqual(warning.id, .modelWindow(allowance: "Fable", slot: .primary))
        XCTAssertEqual(warning.headline, "⚠ Fable · 12% left")
    }

    /// The monthly meter is never promoted over a populated window (D-34 precedence): a near-cap
    /// meter shows its cue in Other Limits and the window keeps the hero.
    func testNearCapMonthlyIsNotPromotedOverAPopulatedWindow() {
        let monthly = MonthlyLimit(limitAmount: 4000, usedAmount: 3700, remainingPercent: 7,
                                   resetsAt: now.addingTimeInterval(10 * 86_400), source: nil)
        let sel = select(snapshot(tool: .codex, used: 30, weekly: nil, monthly: monthly))
        XCTAssertEqual(sel.hero?.id, .primaryWindow)
        XCTAssertEqual(ids(sel), [.monthly])
        XCTAssertEqual(sel.others[0].status, .critical)
        XCTAssertEqual(sel.others[0].cue, .red)
    }

    // MARK: Blocks, not-started, stale

    func testOverQuotaKeepsThePrimaryAndSaysWhetherTheLimitIsIdentified() {
        let identified = select(snapshot(used: 100, weekly: 91, reached: true), state: .overQuota)
        XCTAssertEqual(identified.hero?.id, .primaryWindow)
        XCTAssertEqual(identified.heroReason, .blocked(limitIdentified: true))
        XCTAssertEqual(identified.hero?.status, .critical)
        // An unscoped flag with the primary below 100 %: the flag anchors on the primary window,
        // which is what `BlockEpisode` names, so the limit *is* identified since STEP_193 — rank
        // 3's own reading, now written down rather than inferred at the display.
        let unscoped = select(snapshot(used: 60, weekly: 91, reached: true), state: .overQuota)
        XCTAssertEqual(unscoped.hero?.id, .primaryWindow)
        XCTAssertEqual(unscoped.heroReason, .blocked(limitIdentified: true))
        // With no reset anywhere there is no episode, and the display falls back to rank 3's
        // unscoped reading exactly as it did before.
        let noAnchor = select(snapshot(used: 60, resetsInMin: nil, weekly: 91, reached: true),
                              state: .overQuota)
        XCTAssertEqual(noAnchor.heroReason, .blocked(limitIdentified: false))
    }

    func testSpendControlIsTheMonthlyBlockWhereAMeterExists() {
        let monthly = MonthlyLimit(limitAmount: 4000, usedAmount: 4000, remainingPercent: 0,
                                   resetsAt: now.addingTimeInterval(10 * 86_400), source: nil)
        let sel = select(snapshot(tool: .codex, used: nil, resetsInMin: nil, windowSeconds: nil,
                                  weekly: nil, spendControl: true, monthly: monthly),
                         state: .spendControl)
        XCTAssertEqual(sel.hero?.id, .monthly)
        XCTAssertEqual(sel.heroReason, .blocked(limitIdentified: true))
        XCTAssertEqual(sel.hero?.status, .critical)
    }

    func testNotStartedPrimaryKeepsItsMeaning() {
        let sel = select(snapshot(used: 0, resetsInMin: nil, weekly: 30))
        XCTAssertEqual(sel.hero?.id, .primaryWindow)
        XCTAssertEqual(sel.hero?.status, .notStarted)
        XCTAssertEqual(sel.hero?.availability, .unanchored)
        XCTAssertEqual(sel.hero?.usedPercent, 0)
    }

    /// Stale: no promotion from frozen data — the primary keeps the hero with its status
    /// withheld — except the known block, which survives with its verdict (R33-1).
    func testStaleWithholdsStatusExceptTheKnownBlock() {
        let asOf = now.addingTimeInterval(-900)
        let calm = select(snapshot(used: 40, weekly: 96), state: .idleFallback, staleAsOf: asOf)
        XCTAssertEqual(calm.hero?.id, .primaryWindow)
        XCTAssertEqual(calm.hero?.status, .unknown)
        XCTAssertEqual(calm.hero?.statusReason, .stale)
        XCTAssertEqual(calm.hero?.availability, .stale(asOf: asOf))
        XCTAssertEqual(calm.others[0].status, .unknown, "no promotion from a stale weekly")

        let blocked = select(snapshot(used: 100, weekly: 40, reached: true), state: .overQuota,
                             staleAsOf: asOf)
        XCTAssertEqual(blocked.hero?.status, .critical)
        XCTAssertEqual(blocked.hero?.statusReason, .blocked)
    }

    /// An expired model window degrades on its own before selection (Core's rule), so it can
    /// neither be promoted nor listed with a dead value.
    func testExpiredModelWindowIsNotACandidate() {
        let dead = spark(primaryUsed: 95, primaryReset: now.addingTimeInterval(-600), weeklyUsed: 5)
        let sel = select(snapshot(tool: .codex, used: 4, resetsInMin: 6 * 1440, windowSeconds: 604_800,
                                  weekly: nil, models: [dead]))
        XCTAssertEqual(sel.hero?.id, .primaryWindow)
        XCTAssertEqual(ids(sel), [.modelWindow(allowance: "codex_bengalfox", slot: .secondary)])
    }

    /// Unknown values stay unknown — `—`, never 100 % left.
    func testUnknownModelValueIsUnknownNotFull() {
        let blank = AdditionalRateLimit(id: "x", name: "X", usedPercent: nil,
                                        resetsAt: now.addingTimeInterval(3600))
        let sel = select(snapshot(tool: .codex, models: [blank]))
        let row = sel.others.first { $0.id.isModelWindow }!
        XCTAssertNil(row.usedPercent)
        XCTAssertNil(row.remainingPercent)
        XCTAssertEqual(row.status, .unknown)
        let section = DisplayFormatter.otherLimitsSection(sel, tool: .codex, now: now)!
        let modelRow = section.modelGroups.flatMap(\.rows).last
        XCTAssertEqual(modelRow?.value, "—")
        XCTAssertNil(modelRow?.cue)
    }
}
