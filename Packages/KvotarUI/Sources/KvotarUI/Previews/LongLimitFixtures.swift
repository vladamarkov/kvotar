import Foundation
import KvotarCore

/// The REV-96 §3.11 fixture set, built **through the real formatter** rather than stubbed.
///
/// One definition, five consumers: `LongLimitSurfaceAgreementTests` asserts the cross-surface
/// invariant on every frame, `PopoverCompositionSnapshots` and `MenuBarSnapshots` render each one
/// light and dark, the menu-bar width test measures the strings they produce, and the
/// `KVOTAR_MENU_BAR_FIXTURE` override (STEP_199) puts one on the live status item. A stubbed
/// display state could pass all of them while the formatter said something else — these cannot.
///
/// **It lives in `Previews/` rather than in the test target** (moved STEP_199, beside
/// `StubData`): amber and red are unreachable on the owner's account, so the only way to watch
/// them on a real menu bar is to render a fixture there, and a second copy of the set inside the
/// app is exactly the drift STEP_197 paid for.
///
/// Each frame states the rank its inputs classify as. The ranking itself is `StateEngineTests`'
/// job (STEP_194); what is pinned here is that the assessment `Core` derives and the tier the
/// fixture's rank claims agree, so a fixture cannot quietly describe a state its own numbers
/// would never produce.
struct LongLimitFixture {
    let name: String
    let tool: Tool
    let state: AppState
    let snapshot: QuotaSnapshot
    var forecast: Forecast?
    /// Set on the one frame that renders cached data — the stale gap inside a continuing block.
    var staleAsOf: Date?
    /// The tier the fixture's inputs must produce, or `nil` where the frame is deliberately about
    /// a limit with no assessment.
    var expectedTier: LongLimitAssessment.Tier?

    static let now = Date(timeIntervalSince1970: 1_789_000_000)

    var menuBar: ToolMenuBarDisplay {
        if staleAsOf != nil {
            return DisplayFormatter.staleMenuBar(tool: tool, state: state, snapshot: snapshot,
                                                 now: Self.now)
        }
        // The glyph before hysteresis — the view model's two-poll hold is not a fixture's subject.
        return DisplayFormatter.toolMenuBar(
            tool: tool, state: state, snapshot: snapshot, forecast: forecast,
            glyph: MoneyModel.moneyGlyphInstant(snapshot: snapshot, forecast: forecast,
                                                now: Self.now),
            now: Self.now)
    }

    var claude: ClaudeDisplayState {
        DisplayFormatter.claude(state: state, snapshot: snapshot, forecast: forecast,
                                staleAsOf: staleAsOf,
                                pollAsOf: staleAsOf ?? Self.now.addingTimeInterval(-35),
                                now: Self.now)
    }

    var codex: CodexDisplayState {
        DisplayFormatter.codex(state: state, snapshot: snapshot, forecast: forecast,
                               staleAsOf: staleAsOf,
                               pollAsOf: staleAsOf ?? Self.now.addingTimeInterval(-35),
                               now: Self.now)
    }

    /// The tab dot and the header the popover would draw for this frame, per tool.
    var displayDot: StatusDot { tool == .claude ? claude.dot : codex.dot }
    var header: HeaderSection? { tool == .claude ? claude.header : codex.header }
    var otherLimits: OtherLimitsSection? { tool == .claude ? claude.otherLimits : codex.otherLimits }
}

extension LongLimitFixture {

    private static func days(_ n: Double) -> TimeInterval { n * 86_400 }

    /// A comfortable margin on purpose: the five-hour verdict in these frames must read
    /// `Safe at this pace — [grain] reset comes first`, and a runway within `thinMarginMinutes`
    /// of the reset would take D-31's "Safe, barely" variant instead and tell the reader the
    /// five-hour window is the interesting one.
    private static func calmForecast(_ tool: Tool) -> Forecast {
        Forecast(tool: tool, tier: .fullRunway, runwayMinutes: 420, burnRatePerMin: 0.2,
                 isEstimate: false, pollCount: 10)
    }

    static func weeklySnapshot(tool: Tool, primaryUsed: Double?, weeklyUsed: Double,
                               /// How far into its own week the weekly is — the pace
                               /// clock's other hand, set by where the reset lands.
                               weekElapsed: Double,
                               primaryResetMinutes: Double = 226,
                               plan: String) -> QuotaSnapshot {
        let width = days(7)
        return QuotaSnapshot(
            tool: tool, primaryUsedPct: primaryUsed,
            primaryResetsAt: primaryUsed == nil
                ? nil : now.addingTimeInterval(primaryResetMinutes * 60),
            primaryWindowSeconds: 18_000,
            secondaryUsedPct: weeklyUsed,
            secondaryResetsAt: now.addingTimeInterval(width * (1 - weekElapsed)),
            // Codex states its secondary width on both transports; Claude states none and the
            // assessment falls back to seven days (REV-96 §2.2).
            secondaryWindowSeconds: tool == .codex ? Int(width) : nil,
            rateLimitReached: false,
            extraUsage: tool == .claude ? .disabled : nil,
            source: tool == .claude ? .oauth : .appServerRPC,
            email: tool == .claude ? "owner@example.com" : nil, planType: plan)
    }

    private static func monthlySnapshot(usedAmount: Double, monthElapsed: Double,
                                        primaryUsed: Double? = 16,
                                        weeklyUsed: Double = 34,
                                        weeklyResetDays: Double = 4) -> QuotaSnapshot {
        let cycle = days(30)
        let monthly = MonthlyLimit(
            limitAmount: 5_000, usedAmount: usedAmount,
            remainingPercent: Int((100 - usedAmount / 5_000 * 100).rounded()),
            resetsAt: now.addingTimeInterval(cycle * (1 - monthElapsed)),
            unit: .money(currency: "EUR", exponent: 2), source: "derived_calendar_month_utc")
        return QuotaSnapshot(
            tool: .claude, primaryUsedPct: primaryUsed,
            primaryResetsAt: primaryUsed == nil ? nil : now.addingTimeInterval(164 * 60),
            primaryWindowSeconds: 18_000, secondaryUsedPct: weeklyUsed,
            secondaryResetsAt: now.addingTimeInterval(days(weeklyResetDays)),
            rateLimitReached: false, extraUsage: .disabled, monthlyLimit: monthly,
            source: .oauth, email: "teammate@example.com", planType: "team")
    }

    // MARK: The set (REV-96 §3.11)

    /// Weekly 70 % at 40 % of the week with a calm five-hour — rank 10. Amber dot, **unchanged**
    /// menu string, amber strip, hero still the five-hour.
    static let claudeAheadOfPace = LongLimitFixture(
        name: "claude-limit-ahead-of-pace", tool: .claude, state: .limitAheadOfPace,
        snapshot: weeklySnapshot(tool: .claude, primaryUsed: 29, weeklyUsed: 70,
                                 weekElapsed: 0.4, plan: "max"),
        forecast: calmForecast(.claude), expectedTier: .aheadOfPace)

    /// Weekly 91 % — rank 5b. Red dot, red strip, hero still the five-hour and its verdict still
    /// green and scoped, because the five-hour window really is fine. The bar **holds**
    /// `CL ⚠wk 9% ↻4d` and reminds about nothing (REV-100 §2.1 — STEP_210).
    static let claudeNearlySpent = LongLimitFixture(
        name: "claude-limit-nearly-spent", tool: .claude, state: .limitNearlySpent,
        snapshot: weeklySnapshot(tool: .claude, primaryUsed: 36, weeklyUsed: 91,
                                 weekElapsed: 0.5, plan: "max"),
        forecast: calmForecast(.claude), expectedTier: .nearlySpent)

    /// The weekly is spent and the five-hour is idle — the limit that stopped you takes the hero
    /// at 0 %, and the five-hour greys to `blocked by the weekly`.
    static let claudeWeeklySpent = LongLimitFixture(
        name: "claude-weekly-spent-idle-primary", tool: .claude, state: .overQuota,
        snapshot: weeklySnapshot(tool: .claude, primaryUsed: 19, weeklyUsed: 100,
                                 weekElapsed: 0.69, plan: "max"),
        forecast: nil, expectedTier: .spent)

    /// Continuing block, frame 1: the five-hour rolled over *inside* the block. A fresh window
    /// with nothing able to use it — the episode is the weekly's and does not restart here.
    static let claudeBlockRollover = LongLimitFixture(
        name: "claude-block-five-hour-rollover", tool: .claude, state: .overQuota,
        snapshot: weeklySnapshot(tool: .claude, primaryUsed: 0, weeklyUsed: 100,
                                 weekElapsed: 0.75, primaryResetMinutes: 300, plan: "max"),
        forecast: nil, expectedTier: .spent)

    /// Continuing block, frame 2: a gap, then a render off the cached snapshot. The block is kept
    /// on the **weekly's** reset (R33-1 as REV-96 §3.1 re-anchors it) and the tier suffixes are
    /// withheld — a tier read off a frozen snapshot would be the confident claim D-35 refuses.
    static let claudeBlockStale = LongLimitFixture(
        name: "claude-block-stale-gap", tool: .claude, state: .overQuota,
        snapshot: weeklySnapshot(tool: .claude, primaryUsed: 0, weeklyUsed: 100,
                                 weekElapsed: 0.8, primaryResetMinutes: 200, plan: "max"),
        forecast: nil, staleAsOf: now.addingTimeInterval(-40 * 60), expectedTier: .spent)

    /// Continuing block, frame 3: both windows spent. The copy changes and the count does not —
    /// the weekly's reset is the later one, so it is still when work resumes.
    static let claudeBlockBoth = LongLimitFixture(
        name: "claude-block-both-windows-spent", tool: .claude, state: .overQuota,
        snapshot: weeklySnapshot(tool: .claude, primaryUsed: 100, weeklyUsed: 100,
                                 weekElapsed: 0.82, primaryResetMinutes: 95, plan: "max"),
        forecast: nil, expectedTier: .spent)

    /// The Codex mirror of the amber frame — its secondary states a width, so the pace clock uses
    /// the reported one rather than the seven-day fallback.
    static let codexAheadOfPace = LongLimitFixture(
        name: "codex-limit-ahead-of-pace", tool: .codex, state: .limitAheadOfPace,
        snapshot: weeklySnapshot(tool: .codex, primaryUsed: 24, weeklyUsed: 70,
                                 weekElapsed: 0.4, plan: "plus"),
        forecast: calmForecast(.codex), expectedTier: .aheadOfPace)

    /// The five-hour window is **calm in every rank-5b frame**, and not by coincidence: every
    /// five-hour warning outranks 5b, so a tight primary would have classified as Bad timing or
    /// At risk instead. A fixture with a 95 %-used primary under rank 5b describes a state the
    /// engine cannot produce — and it is what made the green-hero rule look wrong when it was
    /// first drawn.
    static let codexNearlySpent = LongLimitFixture(
        name: "codex-limit-nearly-spent", tool: .codex, state: .limitNearlySpent,
        snapshot: weeklySnapshot(tool: .codex, primaryUsed: 24, weeklyUsed: 92,
                                 weekElapsed: 0.55, plan: "plus"),
        forecast: calmForecast(.codex), expectedTier: .nearlySpent)

    /// A monthly spend limit running ahead of its month, on a Team seat that also has both
    /// windows — the amber strip is about the budget and the hero is still the five-hour.
    static let claudeMonthlyAheadOfPace = LongLimitFixture(
        name: "claude-monthly-ahead-of-pace", tool: .claude, state: .limitAheadOfPace,
        snapshot: monthlySnapshot(usedAmount: 3_150, monthElapsed: 0.4),
        forecast: calmForecast(.claude), expectedTier: .aheadOfPace)

    static let claudeMonthlyNearlyReached = LongLimitFixture(
        name: "claude-monthly-nearly-reached", tool: .claude, state: .limitNearlySpent,
        snapshot: monthlySnapshot(usedAmount: 4_610, monthElapsed: 0.66),
        forecast: calmForecast(.claude), expectedTier: .nearlySpent)

    // MARK: The Team seat (REV-102 §2.3a — STEP_220)

    /// A Team seat shaped like the tester's account, amounts synthetic: a five-hour that has not started, a weekly, and the `spend` meter
    /// mapped to org-paid usage credits — a €70.00 cap, no monthly limit (STEP_218).
    /// `creditsUsed: nil` is the switched-off shape — off, `out_of_credits`, no amounts (STEP_222).
    private static func teamSnapshot(weeklyUsed: Double, weeklyResetHours: Double,
                                     creditsUsed: Decimal?) -> QuotaSnapshot {
        let credits = creditsUsed.map {
            ExtraUsage(isEnabled: true, monthlyLimit: 7_000, usedCredits: $0, currency: "EUR",
                       managedByOrganization: true, currencyExponent: 2)
        } ?? ExtraUsage(isEnabled: false, monthlyLimit: nil, usedCredits: nil, currency: "EUR",
                        disabledReason: "out_of_credits", managedByOrganization: true,
                        currencyExponent: 2)
        return QuotaSnapshot(
            tool: .claude, primaryUsedPct: 0, primaryResetsAt: nil,
            primaryWindowSeconds: 18_000, secondaryUsedPct: weeklyUsed,
            secondaryResetsAt: now.addingTimeInterval(weeklyResetHours * 3_600),
            rateLimitReached: false,
            extraUsage: credits,
            source: .oauth, email: "teammate@example.com", planType: "team")
    }

    /// Frame A: the weekly is spent and the organization's credits are paying — the hero is the
    /// weekly at 0 %, the verdict is the charging one, the bar carries a red `€`. *(€29.96 is
    /// illustrative: the log kept the meter's severity that afternoon, not its amount.)*
    static let claudeTeamWeeklySpentCharging = LongLimitFixture(
        name: "claude-team-weekly-spent-charging", tool: .claude, state: .overQuota,
        snapshot: teamSnapshot(weeklyUsed: 100, weeklyResetHours: 38, creditsUsed: 29.96),
        forecast: nil, expectedTier: .spent)

    /// Frame B — the bundle's moment: the weekly is spent **and** the cap is reached. An ordinary
    /// weekly block, held in the bar, with one muted line saying the credits are gone too.
    /// Replaces `claude-monthly-reached-unconfirmed` (P1-16b, retired).
    static let claudeTeamWeeklySpentCapReached = LongLimitFixture(
        name: "claude-team-weekly-spent-cap-reached", tool: .claude, state: .overQuota,
        snapshot: teamSnapshot(weeklyUsed: 100, weeklyResetHours: 18.12, creditsUsed: 70.25),
        forecast: nil, expectedTier: .spent)

    /// Frame C: the windows are fresh and the cap is still reached. Calm — green dot, no glyph,
    /// no strip; the card alone says the credits are spent.
    static let claudeTeamCapReachedWindowsFine = LongLimitFixture(
        name: "claude-team-cap-reached-windows-fine", tool: .claude, state: .healthy,
        snapshot: teamSnapshot(weeklyUsed: 0, weeklyResetHours: 167, creditsUsed: 70.25),
        forecast: nil, expectedTier: .onPace)

    /// Frame B a day later (REV-102 §6 item 1 — STEP_222): the provider has switched the meter
    /// off and stopped sending amounts. Same block, same organization card, nothing in euros.
    static let claudeTeamWeeklySpentCreditsSwitchedOff = LongLimitFixture(
        name: "claude-team-weekly-spent-credits-switched-off", tool: .claude, state: .overQuota,
        snapshot: teamSnapshot(weeklyUsed: 100, weeklyResetHours: 7.4, creditsUsed: nil),
        forecast: nil, expectedTier: .spent)

    /// The REV-102 frames. **Not in `all`**: that set's invariants are about a long limit
    /// warning under a live five-hour, and here the five-hour has not started.
    static let teamCredits: [LongLimitFixture] = [
        claudeTeamWeeklySpentCharging, claudeTeamWeeklySpentCapReached,
        claudeTeamCapReachedWindowsFine, claudeTeamWeeklySpentCreditsSwitchedOff,
    ]

    /// **Two warnings on one account** (REV-97 §2.3 — STEP_198): the monthly is nearly reached
    /// and the weekly is ahead of its week. Since REV-100 §2.1 (STEP_210) the red monthly
    /// **holds** the bar — `CL ⚠mo 8% ↻…`, red dot — and nothing cycles: the amber weekly stays in
    /// the reading, so its episode is held, but it has no line while the red limit owns the bar.
    static let claudeBothLimitsWarning = LongLimitFixture(
        name: "claude-both-limits-warning", tool: .claude, state: .limitNearlySpent,
        snapshot: monthlySnapshot(usedAmount: 4_610, monthElapsed: 0.66,
                                  weeklyUsed: 70, weeklyResetDays: 4.2),
        forecast: calmForecast(.claude), expectedTier: .nearlySpent)

    /// **The five-hour speaks first** (REV-97 §2.4). A weekly at 91 % under an At-risk five-hour:
    /// every five-hour warning outranks ranks 5b and 10, so the bar keeps its own urgent `◔`
    /// string and reminds about nothing. A red runway is never covered by a weekly reminder.
    ///
    /// **Deliberately not in `all`.** The REV-96 §3.11 invariants that set runs are about
    /// long-limit *ranks* — under one of those the hero is the five-hour and its ink is green
    /// (§5.7). Here the five-hour really is in trouble, so a red hero is correct and asserting
    /// green would be asserting the wrong thing.
    static let claudeFiveHourOutranksTheWeekly = LongLimitFixture(
        name: "claude-five-hour-outranks-the-weekly", tool: .claude, state: .atRisk,
        snapshot: weeklySnapshot(tool: .claude, primaryUsed: 96, weeklyUsed: 91,
                                 weekElapsed: 0.5, plan: "max"),
        forecast: Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: 11,
                           burnRatePerMin: 0.4, isEstimate: false, pollCount: 10),
        expectedTier: .nearlySpent)

    /// **The July reading, verbatim** (REV-98 §3.8 — STEP_200): a weekly 62 % used at 61.3 % of
    /// its week, projecting to **101 %**. Amber under REV-96's bare `used > elapsed`, calm under
    /// the projection test — the whole of what this step removes, and one of the five hours on
    /// 21–22 July 2026 that were every sub-1-point amber the 50-floor ever produced.
    ///
    /// **Deliberately not in `all`.** That set's invariants are about long-limit *ranks* — a
    /// strip, a lifted row, a reminder with a strip behind it — and this frame is calm and has
    /// none of them. It is here to be watched on the live bar and to state, permanently, which
    /// reading stopped being a warning.
    static let claudeProjection101Calm = LongLimitFixture(
        name: "claude-projection-101-calm", tool: .claude, state: .healthy,
        snapshot: weeklySnapshot(tool: .claude, primaryUsed: 29, weeklyUsed: 62,
                                 weekElapsed: 0.613, plan: "max"),
        forecast: calmForecast(.claude), expectedTier: .onPace)

    /// **The owner's live reading, verbatim** (2026-09-14, REV-98 §3.8 — STEP_200): 52 % used at
    /// 45.2 % of the week, projecting to **115 %**. The episode that prompted the revision, and
    /// a true warning rather than the marginal one it was assumed to be — the figure that called
    /// it marginal was arithmetic on the rounded `day 4 of 7` label, which rounds up. It stays
    /// amber under every candidate the sweep supports, and it is a permanent regression test
    /// against tuning the trigger past it.
    ///
    /// **Not in `all` either**, for the narrower reason: the eleven-frame set is the REV-96
    /// §3.11 snapshot evidence, and a twelfth amber frame that differs from
    /// `claude-limit-ahead-of-pace` only in its margin would regenerate every PNG to say nothing
    /// new. The invariants it *would* satisfy are already asserted on that frame.
    static let claudeProjection115Amber = LongLimitFixture(
        name: "claude-projection-115-amber", tool: .claude, state: .limitAheadOfPace,
        snapshot: weeklySnapshot(tool: .claude, primaryUsed: 29, weeklyUsed: 52,
                                 weekElapsed: 0.452, plan: "max"),
        forecast: calmForecast(.claude), expectedTier: .aheadOfPace)

    /// **Recovery at unchanged utilization** (REV-98 §3.8 — STEP_202): the same 52 % used as
    /// `claude-projection-115-amber`, three days later in the same week. At 55 % elapsed it
    /// projects to 95 % and is on pace — the warning clears without the number moving, which is
    /// what makes "recovery is the tier clearing, not the percentage falling" a rule the schedule
    /// can be tested against rather than a sentence in a document.
    ///
    /// **Deliberately not in `all`**, for `claude-projection-101-calm`'s reason: the set's
    /// invariants are about long-limit ranks and this frame is calm, with no strip and no lifted
    /// row to assert.
    static let claudeRecoveryOnPace = LongLimitFixture(
        name: "claude-recovery-on-pace", tool: .claude, state: .healthy,
        snapshot: weeklySnapshot(tool: .claude, primaryUsed: 29, weeklyUsed: 52,
                                 weekElapsed: 0.55, plan: "max"),
        forecast: calmForecast(.claude), expectedTier: .onPace)

    /// The frames outside `all` — each one a case the set's rank invariants cannot describe, and
    /// each one still asserted against Core's own tier (`LongLimitSurfaceAgreementTests`).
    static let outsideTheRankSet: [LongLimitFixture] = [
        claudeFiveHourOutranksTheWeekly, claudeProjection101Calm, claudeProjection115Amber,
        claudeRecoveryOnPace,
    ]

    /// The fixture the `KVOTAR_MENU_BAR_FIXTURE` override names, or nil — every frame, in the
    /// set or outside it.
    static func named(_ name: String) -> LongLimitFixture? {
        (all + outsideTheRankSet + teamCredits).first { $0.name == name }
    }

    static let all: [LongLimitFixture] = [
        claudeAheadOfPace, claudeNearlySpent, claudeWeeklySpent,
        claudeBlockRollover, claudeBlockStale, claudeBlockBoth,
        codexAheadOfPace, codexNearlySpent,
        claudeMonthlyAheadOfPace, claudeMonthlyNearlyReached,
        claudeBothLimitsWarning,
    ]
}
