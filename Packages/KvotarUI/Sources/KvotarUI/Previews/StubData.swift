import Foundation
import KvotarCore

// Static stub fixtures for SwiftUI previews. One fixture per state from UI Spec §REV92 §7's
// verification matrix. No business logic — every value is pre-formatted exactly as a view
// renders it. Rebuilt for the STEP_178 composition: a header naming one limit, `OTHER LIMITS`,
// the daily local section and its value companion, then the applicable credits card.
//
// These are illustrative figures, not evidence. STEP_180 replaces them with fixtures produced by
// the real formatter for the final visual acceptance pass.

// MARK: - Shared stub builders

enum Stub {
    /// A header with the §REV92 parts: hero, caption, verdict, detail lines, the two facts.
    static func header(hero: String, progress: Double, caption: String?,
                       verdict: HeaderVerdict?, plan: String, badge: PlanBadgeKind = .exact,
                       email: String? = "user@example.org",
                       details: [DetailLine] = [],
                       burnLabel: String = "Quota burn",
                       burn: String? = "Low · 0.4% / min",
                       burnTier: String? = "low",
                       notSeenLabel: String = "Not seen locally",
                       notSeen: String? = nil,
                       modelWarnings: [ModelLimitWarning] = [],
                       heroElement: ExplanationElement = .heroPercent,
                       limit: AccountLimitCandidate? = nil,
                       strip: LongLimitStrip? = nil,
                       heroCue: StatusDot? = nil,
                       source: SourceTag? = "Source: Claude account · exact") -> HeaderSection {
        HeaderSection(
            heroText: hero, progress: progress, verdict: verdict, planBadge: plan,
            badgeKind: badge, email: email, heroExplanation: heroElement,
            selection: AccountLimitSelection(hero: limit ?? candidate(.primaryWindow),
                                             heroReason: .primaryDefault, others: []),
            limitCaption: caption,
            accountBurn: burn.map {
                HeaderFact(limitID: .primaryWindow, label: burnLabel, value: $0, dot: .green,
                           intervalLabel: "5-hour", availability: .shown, explanation: .burn,
                           tier: burnTier)
            },
            notSeenLocally: notSeen.map {
                HeaderFact(limitID: .primaryWindow, label: notSeenLabel, value: $0, dot: .grey,
                           intervalLabel: "5-hour", availability: .shown,
                           explanation: .offMachine)
            },
            modelWarnings: modelWarnings,
            heroDetails: details, sourceTag: source, heroCue: heroCue, longLimitStrip: strip)
    }

    static func candidate(_ id: AccountLimitID, name: String = "5-hour quota",
                          used: Double? = 38) -> AccountLimitCandidate {
        AccountLimitCandidate(id: id, scope: .account, unit: .percent, name: name,
                              periodSeconds: 18_000, periodLabel: "5-hour", usedPercent: used,
                              usedAmount: nil, limitAmount: nil, resetsAt: nil,
                              status: .healthy, statusReason: .state(.healthy), cue: .green,
                              availability: .fresh, source: nil)
    }

    /// An `OTHER LIMITS` row, pre-formatted.
    static func limitRow(_ id: AccountLimitID, _ label: String, _ value: String,
                         cue: StatusDot? = .green, reset: String? = nil,
                         detail: String? = nil, meta: String? = nil,
                         element: ExplanationElement = .secondaryWindow,
                         resetElement: ExplanationElement? = .weeklyReset) -> OtherLimitRow {
        OtherLimitRow(id: id, label: label, value: value, cue: cue, detail: detail, reset: reset,
                      meta: meta.map { DetailLine(text: $0, explanation: .monthlyPace) },
                      explanation: element, resetExplanation: resetElement)
    }

    static func otherLimits(_ rows: [OtherLimitRow],
                            models: [OtherLimitsSection.ModelGroup] = [],
                            source: SourceTag? = "Source: Claude account · exact")
        -> OtherLimitsSection {
        OtherLimitsSection(rows: rows, modelGroups: models, sourceTag: source)
    }

    /// A populated `LOCAL ACTIVITY · TODAY`.
    static func local(tool: Tool, tokens: String = "496k", sessions: String = "1 session",
                      rate: String = "—", cache: String = "94%",
                      projects: [LocalActivitySection.ProjectRow]? = nil,
                      surfaces: [LocalActivitySection.SurfaceRow] = [],
                      moreCount: Int = 2,
                      values: [String]? = nil,
                      organization: Bool = false) -> LocalActivitySection {
        // STEP_180: Today's dollars are derived from this fixture's own token count, at one
        // blended rate, so the two can never disagree. They used to be a fixed `$0.59` beside
        // whatever token figure a state happened to set — 3.1M tokens priced at 59 cents on the
        // Team shape, which is exactly the kind of incoherent sample REV-92 §7 rules out of the
        // acceptance evidence. The rolling 7- and 30-day rows are a different population and
        // stay fixed; only their ordering against Today has to hold.
        let rows = values ?? [dollars(fromTokens: tokens), "$285.34", "$2,473.05"]
        let projectRows = projects ?? defaultProjects(tool: tool, total: tokenCount(tokens),
                                                      hidden: moreCount)
        return LocalActivitySection(
            availability: .available, statusCopy: nil,
            summary: LabeledRow(label: tool == .claude ? "Claude Code" : "Codex",
                                value: "\(tokens) tokens · \(sessions)",
                                explanation: .localActivity),
            recentRate: rate, cacheHit: cache, surfaces: surfaces,
            projects: projectRows, moreCount: moreCount,
            valueRows: [LabeledRow(label: "Today", value: rows[0]),
                        LabeledRow(label: "7-day", value: rows[1]),
                        LabeledRow(label: "30-day", value: rows[2])],
            valueNote: organization ? LocalActivitySection.organizationValueNote
                                    : LocalActivitySection.valueNote,
            overflowLabel: moreCount > 0 ? "\(moreCount) more projects" : nil,
            sourceTag: SourceTag(base: tool == .claude ? "Source: Claude Code JSONL"
                                                       : "Source: Codex JSONL · originator field",
                                 age: "35s ago"),
            lastEventAt: nil, readAt: nil)
    }

    /// One blended dollars-per-million rate, back-solved from the fixture family's original
    /// `496k → $0.59`, so the figures move together when a state's token count changes.
    private static let blendedDollarsPerMTok = 1.19

    static func tokenCount(_ tokens: String) -> Int {
        let scale: Double = tokens.hasSuffix("M") ? 1_000_000 : (tokens.hasSuffix("k") ? 1_000 : 1)
        return Int((Double(tokens.dropLast(scale == 1 ? 0 : 1)) ?? 0) * scale)
    }

    static func dollars(fromTokens tokens: String) -> String {
        String(format: "$%.2f", Double(tokenCount(tokens)) / 1_000_000 * blendedDollarsPerMTok)
    }

    /// The two drawn project rows, derived from the day's own total (STEP_180). They used to be
    /// fixed at `402k` and `94k` whatever the summary said above them — on the Team shape that
    /// left 3.1M tokens with two visible projects summing to under half a million and an
    /// overflow that, by the top-two-by-tokens rule, could not have held the rest.
    ///
    /// The split is 45% / 25%, leaving 30% for the hidden rows. That keeps every hidden project
    /// smaller than the second drawn one for any `hidden >= 2`, which is what makes the ranking
    /// and the overflow count consistent rather than merely plausible.
    static func defaultProjects(tool: Tool, total: Int,
                                hidden: Int) -> [LocalActivitySection.ProjectRow] {
        let (share1, share2) = hidden > 0 ? (0.45, 0.25) : (0.62, 0.38)
        // The model names follow the tool: the Codex tab used to draw `fable-5.1` and `haiku-4.5`
        // in its own project rows, because the fixture family shared one hardcoded pair.
        let models = tool == .claude ? ("fable-5.1", "haiku-4.5") : ("gpt-5.5", "gpt-5.3-codex")
        return [
            LocalActivitySection.ProjectRow(
                name: "kvotar", fullName: "/Users/v/code/kvotar",
                tokens: Fmt.tokens(Int(Double(total) * share1)), isMostRecent: true,
                models: [LocalActivitySection.ModelRow(
                    name: models.0, tokens: Fmt.tokens(Int(Double(total) * share1)))]),
            LocalActivitySection.ProjectRow(
                name: "observer", fullName: "/Users/v/code/observer",
                tokens: Fmt.tokens(Int(Double(total) * share2)), isMostRecent: false,
                models: [LocalActivitySection.ModelRow(
                    name: models.1, tokens: Fmt.tokens(Int(Double(total) * share2)))]),
        ]
    }

    /// The three non-populated local states.
    static func local(_ availability: LocalActivitySection.Availability,
                      copy: String) -> LocalActivitySection {
        LocalActivitySection(
            availability: availability, statusCopy: copy, summary: nil,
            recentRate: "—", cacheHit: "—", projects: [], moreCount: 0,
            valueRows: [LabeledRow(label: "Today", value: "—"),
                        LabeledRow(label: "7-day", value: "—"),
                        LabeledRow(label: "30-day", value: "—")],
            valueNote: LocalActivitySection.valueNote, overflowLabel: nil, sourceTag: nil,
            lastEventAt: nil, readAt: nil)
    }

    /// The read failed over a day already collected — numbers retained, dated, never zeroed.
    static func localRetained(tool: Tool) -> LocalActivitySection {
        let base = local(tool: tool, tokens: "1.2M", sessions: tool == .claude ? "3 sessions"
                                                                               : "3 threads")
        return LocalActivitySection(
            availability: .staleRetained(asOf: Date(timeIntervalSince1970: 1_757_500_000)),
            statusCopy: "As of 4:26 pm · couldn’t refresh",
            summary: base.summary,
            recentRate: "—", cacheHit: base.cacheHit, projects: base.projects,
            moreCount: base.moreCount, valueRows: base.valueRows, valueNote: base.valueNote,
            overflowLabel: base.overflowLabel, sourceTag: base.sourceTag,
            lastEventAt: nil, readAt: nil)
    }

    static let claudeWeeklyRows = [
        limitRow(.secondaryWindow, "Weekly quota", "86% left", reset: "resets Jun 12"),
    ]
    static let codexSource = SourceTag(base: "Source: app-server RPC · exact", age: "50s ago")
}

// MARK: - Claude fixtures (UI Spec §REV92)

extension ClaudeDisplayState {

    private static let creditsChargingCard = CreditsCardSection(
        moneyState: .charging,
        status: LabeledRow(label: "Usage credits", value: "On · charging", dot: .red,
                           explanation: .usageCredits),
        rows: [LabeledRow(label: "This month", value: "$3.20 of $20.00", dot: .red)],
        sourceTag: "Credits: Claude account · exact")
    private static let creditsLastObservedCard = CreditsCardSection(
        moneyState: .lastObserved,
        status: LabeledRow(label: "Usage credits", value: "Off · was on earlier this window",
                           dot: .neutral, explanation: .usageCredits),
        rows: [LabeledRow(label: "This month", value: "$3.20 (last observed)")],
        sourceTag: "Credits: Claude account · exact")
    private static let creditsOffCard = CreditsCardSection(
        moneyState: .blocked,
        status: LabeledRow(label: "Usage credits", value: "Off", dot: .neutral,
                           explanation: .usageCredits),
        subLine: "Hard-block at 100% — usage credits are off",
        subLineSeverity: .info,
        sourceTag: "Credits: Claude account · exact")

    static let healthy = ClaudeDisplayState(
        dot: .green, phase: .content,
        header: Stub.header(hero: "62%", progress: 0.62, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Safe at this pace — reset comes first",
                                                   colour: .green,
                                                   line2: "resets 9:47 pm · in 1h52m · runway ~2h35m"),
                            plan: "Pro"),
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows),
        localActivity: Stub.local(tool: .claude))

    static let elevated = ClaudeDisplayState(
        dot: .amber, phase: .content,
        header: Stub.header(
            hero: "32%", progress: 0.32, caption: "5-hour quota left",
            verdict: HeaderVerdict(
                line1: "Won't make it — slow down or you'll stop in ~38m",
                colour: .amber,
                line2: "stops ~7:53 pm · resets 8:20 pm · runway ~38m",
                family: .exhaustion,
                anatomy: VerdictAnatomy(rows: [
                    LabeledRow(label: "Remaining", value: "32% of window"),
                    LabeledRow(label: "Burn (last 9m)", value: "0.84% / min"),
                    LabeledRow(label: "Runway at this burn", value: "~38m → stops ~7:53 pm"),
                    LabeledRow(label: "Reset", value: "8:20 pm — 1h 5m away"),
                    LabeledRow(label: "Pace", value: "68% used at 60% of the window — over pace"),
                ], comparison: "At this speed you run out in about 38m — before the reset, which is 1h 5m away.",
                   flip: "Turns to *Was on track to run out — safe if this pace holds* if you slow down below ~0.49% / min.")),
            // STEP_180: was `1.8% / min`, which contradicted the anatomy beneath it — 32% left
            // at 1.8 is 18 minutes, not the ~38m the runway, the stop time and the flip threshold
            // all agree on. The rate the rest of this fixture implies is 0.84.
            plan: "Pro", burn: "Mid · 0.84% / min", burnTier: "mid",
            notSeen: "≈15% (est.)"),
        otherLimits: Stub.otherLimits([
            Stub.limitRow(.secondaryWindow, "Weekly quota", "69% left", reset: "resets Jun 12"),
        ]),
        localActivity: Stub.local(tool: .claude, tokens: "880k", sessions: "2 sessions",
                                  rate: "~1.6k tokens/min", cache: "68%"))

    static let atRisk = ClaudeDisplayState(
        dot: .red, phase: .content,
        header: Stub.header(hero: "13%", progress: 0.13, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Won't make it — slow down or you'll stop in ~11m",
                                                   colour: .red,
                                                   line2: "stops ~9:00 pm · resets 9:47 pm · runway ~11m"),
                            // STEP_180: was `3.2% / min`, which spends 13% in four minutes, not
                            // the ~11m stated beside it. 1.2 is the rate that reaches 9:00 pm.
                            plan: "Pro", burn: "High · 1.2% / min",
                            burnTier: "high"),
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows),
        localActivity: Stub.local(tool: .claude))

    static let badTiming = ClaudeDisplayState(
        dot: .amber, phase: .content,
        header: Stub.header(hero: "22%", progress: 0.22, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Bad timing — the reset is a long way off",
                                                   colour: .amber,
                                                   line2: "resets 11:20 pm · in 3h 40m · runway ~26m"),
                            // STEP_180: was `1.1% / min` — 22% at that rate is 20 minutes, and it
                            // is 3.3× a five-hour window's even pace, which is the `high` tier,
                            // not `mid`. 0.85 gives the stated ~26m and stays mid.
                            plan: "Pro", burn: "Mid · 0.85% / min",
                            burnTier: "mid"),
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows),
        localActivity: Stub.local(tool: .claude))

    static let creditsActiveAtLimit = ClaudeDisplayState(
        dot: .red, phase: .content,
        header: Stub.header(hero: "0%", progress: 0, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Running on credits — every token costs now",
                                                   colour: .red,
                                                   line2: "$3.20 this window · resets 12:39 am",
                                                   moneyPrefix: true),
                            plan: "Pro", badge: .credit,
                            burn: "No measurable burn", burnTier: "none"),
        creditsCard: creditsChargingCard,
        recommendation: "At the limit — further Claude usage now bills to usage credits "
            + "($3.20 of $20.00 used this month), so requests won't be blocked. Costs accrue until "
            + "the window resets. Window resets in 2h 47m.",
        recommendationSeverity: .warning,
        otherLimits: Stub.otherLimits([
            Stub.limitRow(.secondaryWindow, "Weekly quota", "80% left", reset: "resets Jul 10"),
        ]),
        localActivity: Stub.local(tool: .claude))

    /// Over quota, copy case 1 — usage credits enabled and still accruing (§2.6 / §4.1 case 1).
    static let overQuotaCreditsActive = ClaudeDisplayState(
        dot: .red, phase: .content,
        header: Stub.header(hero: "0%", progress: 0, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Running on credits — every token costs now",
                                                   colour: .red,
                                                   line2: "$3.20 this window · resets 9:47 pm",
                                                   moneyPrefix: true),
                            plan: "Pro", badge: .credit,
                            burn: "No measurable burn", burnTier: "none"),
        creditsCard: creditsChargingCard,
        recommendation: "Usage credits are covering requests until the window resets in 48m.",
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows),
        localActivity: Stub.local(tool: .claude))

    /// Over quota, copy case 2 — credits used earlier, extra usage since disabled.
    static let overQuotaCreditsOff = ClaudeDisplayState(
        dot: .red, phase: .content,
        header: Stub.header(hero: "0%", progress: 0, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Out of quota — blocked until the reset",
                                                   colour: .red,
                                                   line2: "resets 9:47 pm · in 48m"),
                            plan: "Pro",
                            burn: "No measurable burn", burnTier: "none"),
        creditsCard: creditsLastObservedCard,
        recommendation: "Blocked until the window resets in 48m.",
        recommendationSeverity: .danger,
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows),
        localActivity: Stub.local(tool: .claude))

    /// Over quota, copy case 3 — hard block, no credits at all.
    static let overQuotaHardBlock = ClaudeDisplayState(
        dot: .red, phase: .content,
        header: Stub.header(hero: "0%", progress: 0, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Out of quota — blocked until the reset",
                                                   colour: .red,
                                                   line2: "resets 9:47 pm · in 48m"),
                            plan: "Pro",
                            burn: "No measurable burn", burnTier: "none"),
        creditsCard: creditsOffCard,
        recommendation: "Blocked until the window resets in 48m.",
        recommendationSeverity: .danger,
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows),
        localActivity: Stub.local(tool: .claude))

    static let fastBurnSpike = ClaudeDisplayState(
        dot: .amber, phase: .content,
        header: Stub.header(hero: "48%", progress: 0.48, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Burning fast — 4 subagents running",
                                                   colour: .amber,
                                                   line2: "resets 9:47 pm · runway ~22m"),
                            plan: "Max", burn: "High · 2.4% / min",
                            burnTier: "high"),
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows),
        localActivity: Stub.local(tool: .claude, tokens: "2.4M", sessions: "3 sessions",
                                  rate: "~6.1k tokens/min"))

    static let offMachineBurn = ClaudeDisplayState(
        dot: .amber, phase: .content,
        header: Stub.header(hero: "54%", progress: 0.54, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Quota moving without local work",
                                                   colour: .amber,
                                                   line2: "resets 9:47 pm · in 2h 10m"),
                            plan: "Max", burn: "Mid · 0.9% / min",
                            burnTier: "mid", notSeen: "≈31% (est.)"),
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows),
        localActivity: Stub.local(tool: .claude, tokens: "120k"))

    /// The five-hour window keeps the hero while the weekly runs ahead of the week — the shape
    /// REV-96 §2.4 replaced the old weekly promotion with (STEP_194).
    static let limitAheadOfPace = ClaudeDisplayState(
        dot: .amber, phase: .content,
        header: Stub.header(hero: "71%", progress: 0.71, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Safe at this pace — 5-hour reset comes first",
                                                   colour: .green,
                                                   line2: "resets 4:50 pm · in 3h46m · runway ~4h",
                                                   family: .resetsFirst),
                            plan: "Max",
                            details: [],
                            burnLabel: "Quota burn", burn: "Low · 0.4% / min", burnTier: "low",
                            notSeen: nil,
                            limit: Stub.candidate(.primaryWindow, used: 29),
                            strip: LongLimitStrip(
                                limitID: .secondaryWindow,
                                text: "Weekly won't last the week at this rate — 43% left for "
                                    + "4 days, resets Sep 18",
                                cue: .amber, explanation: .secondaryWindow),
                            // The amber is the *weekly's*; the five-hour number under it is calm
                            // and its verdict says so (REV-96 §5.7 — STEP_195).
                            heroCue: .green),
        otherLimits: Stub.otherLimits([
            Stub.limitRow(.primaryWindow, "5-hour quota", "100% left", reset: "resets 9:47 pm",
                          element: .primaryWindow, resetElement: .reset),
        ]),
        localActivity: Stub.local(tool: .claude))

    // MARK: The STEP_180 acceptance shapes
    // Four account shapes the REV-92 §7 matrix names that no earlier fixture drew. Added for the
    // final visual pass, and kept: they are the states where the palette has the most to do.

    /// A Team seat under real pressure — the organisation value note, an amber freshness stamp,
    /// a tinted recommendation box, and every status hue on screen at once.
    static let teamUrgent = ClaudeDisplayState(
        dot: .red, phase: .content,
        header: Stub.header(
            hero: "6%", progress: 0.06, caption: "5-hour quota left",
            verdict: HeaderVerdict(line1: "Won't make it — slow down or you'll stop in ~5m",
                                   colour: .red,
                                   line2: "stops ~3:41 pm · resets 4:58 pm · runway ~5m",
                                   family: .exhaustion),
            plan: "Team",
            details: [DetailLine(text: "resets 4:58 pm · in 1h 22m", explanation: .reset)],
            burn: "High · 1.2% / min", burnTier: "high",
            notSeen: "≈9% (est.)",
            source: SourceTag(base: "Source: Claude account · exact", age: "6m ago",
                              ageIsAmber: true)),
        recommendation: "About five minutes left in this window, and it resets in an hour and "
            + "twenty. A good moment to finish the thought rather than start one.",
        recommendationSeverity: .danger,
        otherLimits: Stub.otherLimits([
            Stub.limitRow(.secondaryWindow, "Weekly quota", "44% left", cue: .green,
                          reset: "resets Jun 12"),
        ], source: SourceTag(base: "Source: Claude account · exact", age: "6m ago",
                             ageIsAmber: true)),
        localActivity: Stub.local(tool: .claude, tokens: "3.1M", sessions: "5 sessions",
                                  rate: "~2.9k tokens/min", cache: "71%", organization: true))

    /// No five-hour limit at all: the weekly leads and the monthly meter is an ordinary row
    /// beneath it (REV-92 §2 decision 2). A missing limit never becomes an empty five-hour row.
    static let weeklyHeroWithMonthly = ClaudeDisplayState(
        dot: .amber, phase: .content,
        header: Stub.header(hero: "23%", progress: 0.23, caption: "Weekly quota left",
                            // No five-hour window exists here, so the weekly *is* the account's
                            // shortest limit and keeps the header (REV-96 §2.4 leaves that case
                            // alone); the verdict is the long-window pace family.
                            verdict: HeaderVerdict(line1: "Above pace — 77% used",
                                                   colour: .amber, line2: nil,
                                                   family: .longWindowPace),
                            plan: "Team",
                            details: [DetailLine(text: "resets in 2 days",
                                                 explanation: .weeklyReset)],
                            burnLabel: "Quota burn · Weekly", burn: "Low · 0.6% / hr",
                            burnTier: "low",
                            notSeenLabel: "Not seen locally · weekly", notSeen: "≈4% (est.)",
                            heroElement: .secondaryWindow,
                            limit: Stub.candidate(.secondaryWindow, name: "Weekly quota",
                                                  used: 77)),
        otherLimits: Stub.otherLimits([
            Stub.limitRow(.monthly, "Monthly spend limit", "$310.00 left", cue: .green,
                          reset: "resets Jul 1", detail: "$90.00 of $400.00 used",
                          meta: "Set by your organisation · on pace",
                          element: .monthlyUsed, resetElement: .monthlyReset),
        ]),
        localActivity: Stub.local(tool: .claude, tokens: "1.4M", sessions: "3 sessions",
                                  organization: true))

    /// The case REV-92 §2 decision 1 exists for, restated by REV-96 §2.4: a spent weekly must
    /// not vanish behind a five-hour window with everything left — it is what stopped you, so it
    /// takes the header, and the five-hour row beneath it is greyed and says why (STEP_194).
    static let criticalWeeklyHealthyPrimary = ClaudeDisplayState(
        dot: .red, phase: .content,
        header: Stub.header(hero: "0%", progress: 0, caption: "Weekly quota left",
                            verdict: HeaderVerdict(line1: "Stopped — weekly spent, resets Jun 12",
                                                   colour: .red,
                                                   line2: "blocked · in 3d",
                                                   family: .overQuota),
                            plan: "Max",
                            details: [DetailLine(text: "resets Jun 12 · in 3 days",
                                                 explanation: .weeklyReset)],
                            burnLabel: "Quota burn · 5-hour", burn: "No measurable burn",
                            burnTier: "none",
                            notSeenLabel: "Not seen locally · 5-hour", notSeen: nil,
                            heroElement: .secondaryWindow,
                            limit: Stub.candidate(.secondaryWindow, name: "Weekly quota",
                                                  used: 100)),
        otherLimits: Stub.otherLimits([
            Stub.limitRow(.primaryWindow, "5-hour quota",
                          "100% left · blocked by the weekly", cue: nil,
                          reset: "not started", element: .primaryWindow, resetElement: .reset),
        ]),
        localActivity: Stub.local(tool: .claude, tokens: "620k", sessions: "2 sessions"))

    /// The local read failed over a day already collected. The numbers stay, dated.
    static let localRetained = ClaudeDisplayState(
        dot: .green, phase: .content,
        header: Stub.header(hero: "62%", progress: 0.62, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Safe at this pace — reset comes first",
                                                   colour: .green,
                                                   line2: "resets 9:47 pm · in 1h52m · runway ~2h35m"),
                            plan: "Pro"),
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows),
        localActivity: Stub.localRetained(tool: .claude))

    /// The first render of a session, before the bounded daily read has come back.
    static let localLoading = ClaudeDisplayState(
        dot: .green, phase: .content,
        header: Stub.header(hero: "62%", progress: 0.62, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Safe at this pace — reset comes first",
                                                   colour: .green,
                                                   line2: "resets 9:47 pm · in 1h52m · runway ~2h35m"),
                            plan: "Pro"),
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows),
        localActivity: Stub.local(.loading, copy: LocalActivitySection.loadingCopy))

    /// The read failed with nothing earlier to retain — distinct from a fresh zero.
    static let localUnavailable = ClaudeDisplayState(
        dot: .green, phase: .content,
        header: Stub.header(hero: "62%", progress: 0.62, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Safe at this pace — reset comes first",
                                                   colour: .green,
                                                   line2: "resets 9:47 pm · in 1h52m · runway ~2h35m"),
                            plan: "Pro"),
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows),
        localActivity: Stub.local(.unavailable, copy: LocalActivitySection.unavailableCopy))

    static let loading = ClaudeDisplayState(dot: .grey, phase: .loading)
    static let idle = ClaudeDisplayState(dot: .grey, phase: .idle)

    static let nullWindow = ClaudeDisplayState(
        dot: .grey, phase: .content,
        header: Stub.header(hero: "——", progress: 1, caption: nil,
                            verdict: HeaderVerdict(line1: "No active session", colour: .grey,
                                                   line2: nil),
                            plan: "Pro", burn: nil, burnTier: nil, notSeen: nil,
                            source: "Source: Claude account · exact"),
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows),
        localActivity: Stub.local(.empty, copy: LocalActivitySection.emptyCopy))

    static let stale = ClaudeDisplayState(
        dot: .grey, phase: .content,
        header: Stub.header(hero: "41%", progress: 0.41, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "No fresh reading — showing last known",
                                                   colour: .grey,
                                                   line2: "as of 2:36 am · lower bound"),
                            plan: "Pro", badge: .stale, burn: nil, burnTier: nil, notSeen: nil,
                            source: SourceTag(base: "Source: Claude account · as of 2:36 am")),
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows,
                                      source: SourceTag(base: "Source: Claude account · as of 2:36 am")),
        localActivity: Stub.local(tool: .claude))

    /// A window that closed while the app was awake — the local section still says *today*.
    static let stressRetrospective = ClaudeDisplayState(
        dot: .green, phase: .content,
        header: Stub.header(hero: "100%", progress: 1, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Not started — your first message starts the clock",
                                                   colour: .green, line2: nil),
                            plan: "Max", details: [DetailLine(text: "not started",
                                                              explanation: .reset)],
                            burn: nil, burnTier: nil, notSeen: nil),
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows),
        localActivity: Stub.local(tool: .claude, tokens: "1.8M", sessions: "4 sessions"))

    static let idleRetrospective = ClaudeDisplayState(
        dot: .green, phase: .content,
        header: Stub.header(hero: "100%", progress: 1, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Not started — your first message starts the clock",
                                                   colour: .green, line2: nil),
                            plan: "Pro", details: [DetailLine(text: "not started",
                                                              explanation: .reset)],
                            burn: nil, burnTier: nil, notSeen: nil),
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows),
        localActivity: Stub.local(tool: .claude, tokens: "310k"))

    static let reconnecting = ClaudeDisplayState(
        dot: .grey, phase: .content,
        header: Stub.header(hero: "41%", progress: 0.41, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Reconnecting…", colour: .grey,
                                                   line2: "as of 2:36 am · lower bound"),
                            plan: "Pro", badge: .stale, burn: nil, burnTier: nil, notSeen: nil,
                            source: SourceTag(base: "Source: Claude account · as of 2:36 am")),
        sourceFreeze: .reconnecting,
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows,
                                      source: SourceTag(base: "Source: Claude account · as of 2:36 am")),
        localActivity: Stub.local(tool: .claude))

    static let signinExpired = ClaudeDisplayState(
        dot: .grey, phase: .content,
        header: Stub.header(hero: "41%", progress: 0.41, caption: "5-hour quota left",
                            verdict: HeaderVerdict(line1: "Claude sign-in expired — open Claude Code to reconnect.",
                                                   colour: .grey,
                                                   line2: "as of 2:36 am · lower bound"),
                            plan: "Pro", badge: .stale, burn: nil, burnTier: nil, notSeen: nil,
                            source: SourceTag(base: "Source: Claude account · as of 2:36 am")),
        sourceFreeze: .signInExpired,
        otherLimits: Stub.otherLimits(Stub.claudeWeeklyRows,
                                      source: SourceTag(base: "Source: Claude account · as of 2:36 am")),
        localActivity: Stub.local(tool: .claude))

    // MARK: Enterprise monthly layout (REV-40/D-36 — the meter as an ordinary hero, STEP_178)

    private static func entHeader(hero: String, progress: Double, verdict: HeaderVerdict,
                                  badge: PlanBadgeKind = .exact, meta: String,
                                  source: SourceTag = "Source: Claude account · exact",
                                  burn: String? = "Low · ~$4.10/hr")
        -> HeaderSection {
        HeaderSection(
            heroText: hero, progress: progress, verdict: verdict, planBadge: "Enterprise",
            badgeKind: badge, email: "user@example.org", heroExplanation: .monthlyUsed,
            selection: AccountLimitSelection(
                hero: AccountLimitCandidate(id: .monthly, scope: .account,
                                            unit: .money(currency: "USD", exponent: 2),
                                            name: "Monthly spend limit", periodSeconds: nil,
                                            periodLabel: "Monthly", usedPercent: 58,
                                            usedAmount: 6_916, limitAmount: 12_000,
                                            resetsAt: nil, status: .healthy,
                                            statusReason: .state(.healthy), cue: .green,
                                            availability: .fresh, source: nil),
                heroReason: .monthlyDefault, others: []),
            limitCaption: "Monthly spend limit left",
            accountBurn: burn.map {
                HeaderFact(limitID: .monthly, label: "Quota burn", value: $0, dot: .green,
                           intervalLabel: "Monthly", availability: .shown,
                           explanation: .spendRate, tier: "low")
            },
            notSeenLocally: HeaderFact(limitID: .monthly, label: "Not seen locally",
                                       value: "≈$104.20 (est.)", dot: .grey,
                                       intervalLabel: "Monthly", availability: .shown,
                                       explanation: .monthlyOffMachine),
            heroDetails: [DetailLine(text: meta, explanation: .monthlyPace)],
            sourceTag: source)
    }

    static let entMonthly = ClaudeDisplayState(
        dot: .green, phase: .content,
        header: entHeader(hero: "42%", progress: 0.42,
                          verdict: HeaderVerdict(line1: "On pace — resets Oct 1 (21d)",
                                                 colour: .green,
                                                 line2: "~$3.96/day · $69.16 of $120.00",
                                                 family: .monthly),
                          meta: "Set by your organization · ~$3.96/day · on pace"),
        localActivity: Stub.local(tool: .claude, organization: true))

    static let entMonthlyIdleDay = ClaudeDisplayState(
        dot: .green, phase: .content,
        header: entHeader(hero: "42%", progress: 0.42,
                          verdict: HeaderVerdict(line1: "On pace — resets Oct 1 (21d)",
                                                 colour: .green,
                                                 line2: "~$3.96/day · $69.16 of $120.00",
                                                 family: .monthly),
                          meta: "Set by your organization · ~$3.96/day · on pace",
                          burn: nil),
        localActivity: Stub.local(.empty, copy: LocalActivitySection.emptyCopy))

    static let entMonthlyNearCap = ClaudeDisplayState(
        dot: .amber, phase: .content,
        header: entHeader(hero: "8%", progress: 0.08,
                          verdict: HeaderVerdict(line1: "Nearly at the monthly limit — resets Oct 1",
                                                 colour: .amber,
                                                 line2: "~$5.22/day · $110.40 of $120.00",
                                                 family: .monthly),
                          meta: "Set by your organization · ~$5.22/day · runs out ~Sep 24"),
        recommendation: "Ask your admin to raise the monthly limit, or slow down until Oct 1.",
        recommendationURL: URL(string: "https://claude.ai/new#settings/usage"),
        localActivity: Stub.local(tool: .claude, organization: true))

    static let entMonthlyReached = ClaudeDisplayState(
        dot: .red, phase: .content,
        header: entHeader(hero: "0%", progress: 0,
                          verdict: HeaderVerdict(line1: "Spend limit reached — resets Oct 1",
                                                 colour: .red,
                                                 line2: "blocked · resets Oct 1 · ↻ 21d",
                                                 family: .monthly),
                          meta: "Set by your organization · spend limit reached"),
        recommendation: "Blocked until the monthly limit resets on Oct 1.",
        recommendationSeverity: .danger,
        localActivity: Stub.local(tool: .claude, organization: true))

    static let entMonthlyStale = ClaudeDisplayState(
        dot: .grey, phase: .content,
        header: entHeader(hero: "42%", progress: 0.42,
                          verdict: HeaderVerdict(line1: "No fresh reading — showing last known",
                                                 colour: .grey,
                                                 line2: "as of 2:36 am · $69.16 of $120.00 · lower bound",
                                                 family: .monthly),
                          badge: .stale,
                          meta: "Set by your organization · pace suspended",
                          source: SourceTag(base: "Source: Claude account · as of 2:36 am"),
                          burn: nil),
        localActivity: Stub.local(tool: .claude, organization: true))

    static let entMonthlySigninExpired = ClaudeDisplayState(
        dot: .grey, phase: .content,
        header: entHeader(hero: "42%", progress: 0.42,
                          verdict: HeaderVerdict(line1: "Claude sign-in expired — open Claude Code to reconnect.",
                                                 colour: .grey,
                                                 line2: "as of 2:36 am · $69.16 of $120.00 · lower bound",
                                                 family: .monthly),
                          badge: .stale,
                          meta: "Set by your organization · pace suspended",
                          source: SourceTag(base: "Source: Claude account · as of 2:36 am"),
                          burn: nil),
        sourceFreeze: .signInExpired,
        localActivity: Stub.local(tool: .claude, organization: true))
}

// MARK: - Codex fixtures (UI Spec §REV92)

extension CodexDisplayState {

    private static func header(hero: String, progress: Double, caption: String?,
                               verdict: HeaderVerdict?, plan: String,
                               badge: PlanBadgeKind = .exact,
                               details: [DetailLine] = [],
                               burnLabel: String = "Quota burn",
                               burn: String? = "Low · 0.5% / min",
                               burnTier: String? = "low",
                               notSeenLabel: String = "Not seen locally",
                               notSeen: String? = nil,
                               modelWarnings: [ModelLimitWarning] = [],
                               heroElement: ExplanationElement = .heroPercent,
                               limit: AccountLimitCandidate? = nil,
                               source: SourceTag = Stub.codexSource) -> HeaderSection {
        Stub.header(hero: hero, progress: progress, caption: caption, verdict: verdict,
                    plan: plan, badge: badge, email: "user@example.org", details: details,
                    burnLabel: burnLabel, burn: burn, burnTier: burnTier,
                    notSeenLabel: notSeenLabel, notSeen: notSeen,
                    modelWarnings: modelWarnings, heroElement: heroElement,
                    limit: limit, source: source)
    }

    private static let weeklyRow = Stub.limitRow(.secondaryWindow, "Weekly quota", "98% left",
                                                 reset: "resets Sep 17")
    private static let sparkGroup = OtherLimitsSection.ModelGroup(
        name: "GPT-5.3-Codex-Spark",
        rows: [
            Stub.limitRow(.modelWindow(allowance: "spark", slot: .primary), "5-hour quota",
                          "100% left", reset: "resets 9:40 pm", element: .scopedLimit,
                          resetElement: nil),
            Stub.limitRow(.modelWindow(allowance: "spark", slot: .secondary), "Weekly quota",
                          "100% left", reset: "resets Sep 17", element: .scopedLimit,
                          resetElement: nil),
        ])

    static let healthy = CodexDisplayState(
        dot: .green, phase: .content,
        header: header(hero: "74%", progress: 0.74, caption: "5-hour quota left",
                       verdict: HeaderVerdict(line1: "Safe at this pace — reset comes first",
                                              colour: .green,
                                              line2: "resets 9:40 pm · in 2h 05m · runway ~3h"),
                       plan: "Pro"),
        windowGrain: "5-hour",
        otherLimits: Stub.otherLimits([weeklyRow], models: [sparkGroup],
                                      source: Stub.codexSource),
        localActivity: Stub.local(tool: .codex, tokens: "1.0M", sessions: "1 thread",
                                  rate: "~594.6k tokens/min", cache: "97%"))

    static let elevated = CodexDisplayState(
        dot: .amber, phase: .content,
        header: header(hero: "34%", progress: 0.34, caption: "5-hour quota left",
                       verdict: HeaderVerdict(line1: "Won't make it — slow down or you'll stop in ~24m",
                                              colour: .amber,
                                              line2: "stops ~8:04 pm · resets 9:40 pm · runway ~24m"),
                       plan: "Pro", burn: "Mid · 1.4% / min",
                       burnTier: "mid"),
        windowGrain: "5-hour",
        otherLimits: Stub.otherLimits([weeklyRow], source: Stub.codexSource),
        localActivity: Stub.local(tool: .codex, tokens: "820k", sessions: "2 threads"))

    static let atRisk = CodexDisplayState(
        dot: .red, phase: .content,
        header: header(hero: "11%", progress: 0.11, caption: "5-hour quota left",
                       verdict: HeaderVerdict(line1: "Won't make it — slow down or you'll stop in ~8m",
                                              colour: .red,
                                              line2: "stops ~7:48 pm · resets 9:40 pm · runway ~8m"),
                       plan: "Pro", burn: "High · 2.9% / min",
                       burnTier: "high"),
        windowGrain: "5-hour",
        otherLimits: Stub.otherLimits([weeklyRow], source: Stub.codexSource),
        localActivity: Stub.local(tool: .codex))

    static let badTiming = CodexDisplayState(
        dot: .amber, phase: .content,
        header: header(hero: "19%", progress: 0.19, caption: "5-hour quota left",
                       verdict: HeaderVerdict(line1: "Bad timing — the reset is a long way off",
                                              colour: .amber,
                                              line2: "resets 11:40 pm · in 4h 05m · runway ~30m"),
                       plan: "Pro", burn: "Mid · 0.8% / min",
                       burnTier: "mid"),
        windowGrain: "5-hour",
        otherLimits: Stub.otherLimits([weeklyRow], source: Stub.codexSource),
        localActivity: Stub.local(tool: .codex))

    /// Spark's weekly critical while the account's own weekly is healthy — a scoped warning.
    /// (Named for what it shows since STEP_194; the retired `weeklyElevated` state it used to be
    /// keyed to was never what this fixture was about.)
    static let scopedModelWarning = CodexDisplayState(
        dot: .amber, phase: .content,
        header: header(hero: "98%", progress: 0.98, caption: "5-hour quota left",
                       verdict: HeaderVerdict(line1: "Safe at this pace",
                                              colour: .green, line2: "resets 9:40 pm"),
                       plan: "Pro",
                       details: [], burn: nil, burnTier: nil, notSeen: nil,
                       modelWarnings: [ModelLimitWarning(
                           id: .modelWindow(allowance: "spark", slot: .secondary),
                           headline: "⚠ GPT-5.3-Codex-Spark weekly · 3% left",
                           detail: "Only this model’s allowance · resets Sep 17",
                           status: .warning, cue: .amber, availability: .fresh)]),
        windowGrain: "5-hour",
        otherLimits: Stub.otherLimits(
            [weeklyRow],
            models: [OtherLimitsSection.ModelGroup(
                name: "GPT-5.3-Codex-Spark",
                rows: [Stub.limitRow(.modelWindow(allowance: "spark", slot: .primary),
                                     "5-hour", "100% left", reset: "resets 9:40 pm",
                                     element: .scopedLimit, resetElement: nil),
                       Stub.limitRow(.modelWindow(allowance: "spark", slot: .secondary),
                                     "Weekly", "3% left", reset: "resets Sep 17",
                                     element: .scopedLimit, resetElement: nil)])],
            source: Stub.codexSource),
        localActivity: Stub.local(tool: .codex))

    static let overQuota = CodexDisplayState(
        dot: .red, phase: .content,
        header: header(hero: "0%", progress: 0, caption: "5-hour quota left",
                       verdict: HeaderVerdict(line1: "Out of quota — blocked until the reset",
                                              colour: .red, line2: "resets 9:40 pm · in 52m"),
                       plan: "Plus", burn: "No measurable burn",
                       burnTier: "none"),
        recommendation: "Blocked until the window resets in 52m.",
        recommendationSeverity: .danger,
        windowGrain: "5-hour",
        otherLimits: Stub.otherLimits([weeklyRow], source: Stub.codexSource),
        localActivity: Stub.local(tool: .codex))

    static let enterpriseBlocked = CodexDisplayState(
        dot: .red, phase: .content,
        header: header(hero: "0%", progress: 0, caption: "Monthly usage limit left",
                       verdict: HeaderVerdict(line1: "Monthly limit reached — resets Oct 1",
                                              colour: .red,
                                              line2: "blocked · resets Oct 1 · ↻ 21d",
                                              family: .monthly),
                       plan: "Business",
                       details: [DetailLine(
                           text: "Workspace limit · shared across ChatGPT and Codex · spend control reached",
                           explanation: .monthlyPace)],
                       burn: nil, burnTier: nil, notSeen: nil,
                       heroElement: .monthlyUsed),
        creditsSpend: CreditsSpendSection(rows: [
            LabeledRow(label: "Plan", value: "Business"),
            LabeledRow(label: "Spend control", value: "Reached", dot: .red),
        ]),
        recommendation: "Blocked until the monthly limit resets on Oct 1.",
        recommendationSeverity: .danger,
        localActivity: Stub.local(tool: .codex, organization: true))

    static let nullWindow = CodexDisplayState(
        dot: .grey, phase: .content,
        header: header(hero: "——", progress: 1, caption: nil,
                       verdict: HeaderVerdict(line1: "No active session", colour: .grey,
                                              line2: nil),
                       plan: "Pro", burn: nil, burnTier: nil, notSeen: nil),
        nullWindowNote: "Account quota windows are null (healthy idle). Showing local token data.",
        localActivity: Stub.local(.empty, copy: LocalActivitySection.emptyCopy))

    static let spendControl = CodexDisplayState(
        dot: .red, phase: .content,
        header: header(hero: "0%", progress: 0, caption: "Monthly usage limit left",
                       verdict: HeaderVerdict(line1: "Monthly limit reached — resets Oct 1",
                                              colour: .red,
                                              line2: "blocked · resets Oct 1 · ↻ 21d",
                                              family: .monthly),
                       plan: "Enterprise",
                       details: [DetailLine(
                           text: "Workspace limit · shared across ChatGPT and Codex · spend control reached",
                           explanation: .monthlyPace)],
                       burn: nil, burnTier: nil, notSeen: nil,
                       heroElement: .monthlyUsed),
        creditsSpend: CreditsSpendSection(rows: [
            LabeledRow(label: "Plan", value: "Enterprise"),
            LabeledRow(label: "Spend control", value: "Reached", dot: .red),
        ]),
        localActivity: Stub.local(tool: .codex, organization: true))

    static let multiSurface = CodexDisplayState(
        dot: .amber, phase: .content,
        header: header(hero: "46%", progress: 0.46, caption: "5-hour quota left",
                       verdict: HeaderVerdict(line1: "Two Codex surfaces are sharing this quota",
                                              colour: .amber,
                                              line2: "resets 9:40 pm · in 2h 05m"),
                       plan: "Pro", burn: "Mid · 1.2% / min",
                       burnTier: "mid"),
        windowGrain: "5-hour",
        otherLimits: Stub.otherLimits([weeklyRow], source: Stub.codexSource),
        localActivity: Stub.local(tool: .codex, tokens: "1.9M", sessions: "3 threads"))

    static let fastBurnSpike = CodexDisplayState(
        dot: .amber, phase: .content,
        header: header(hero: "52%", progress: 0.52, caption: "5-hour quota left",
                       verdict: HeaderVerdict(line1: "Burning fast — 2 subagents running",
                                              colour: .amber,
                                              line2: "resets 9:40 pm · runway ~28m"),
                       plan: "Pro", burn: "High · 2.1% / min",
                       burnTier: "high"),
        windowGrain: "5-hour",
        otherLimits: Stub.otherLimits([weeklyRow], source: Stub.codexSource),
        localActivity: Stub.local(tool: .codex, tokens: "3.1M", sessions: "2 threads"))

    static let offMachineBurn = CodexDisplayState(
        dot: .amber, phase: .content,
        header: header(hero: "58%", progress: 0.58, caption: "5-hour quota left",
                       verdict: HeaderVerdict(line1: "Quota moving without local work",
                                              colour: .amber,
                                              line2: "resets 9:40 pm · in 2h 05m"),
                       plan: "Pro", burn: "Mid · 0.7% / min",
                       burnTier: "mid", notSeen: "≈28% (est.)"),
        windowGrain: "5-hour",
        otherLimits: Stub.otherLimits([weeklyRow], source: Stub.codexSource),
        localActivity: Stub.local(tool: .codex, tokens: "90k"))

    static let loading = CodexDisplayState(dot: .grey, phase: .loading)
    static let idle = CodexDisplayState(dot: .grey, phase: .idle)

    static let cxMonthly = CodexDisplayState(
        dot: .green, phase: .content,
        header: header(hero: "52%", progress: 0.52, caption: "Monthly usage limit left",
                       verdict: HeaderVerdict(line1: "On pace — resets Oct 1 (21d)",
                                              colour: .green,
                                              line2: "~158 credits/day · 2,377 of 5,000 credits · workspace pool",
                                              family: .monthly),
                       plan: "Enterprise",
                       details: [DetailLine(
                           text: "Workspace limit · shared across ChatGPT and Codex · ~158 credits/day · on pace",
                           explanation: .monthlyPace)],
                       burn: "Low · ~14 credits/hr", burnTier: "low",
                       notSeen: "≈310 credits (est.)",
                       heroElement: .monthlyUsed),
        creditsSpend: CreditsSpendSection(rows: [
            LabeledRow(label: "Plan", value: "Enterprise"),
            LabeledRow(label: "Spend control", value: "Active"),
        ]),
        localActivity: Stub.local(tool: .codex, organization: true))

    static let cxMonthlyIdleDay = CodexDisplayState(
        dot: .green, phase: .content,
        header: header(hero: "52%", progress: 0.52, caption: "Monthly usage limit left",
                       verdict: HeaderVerdict(line1: "On pace — resets Oct 1 (21d)",
                                              colour: .green,
                                              line2: "~158 credits/day · 2,377 of 5,000 credits · workspace pool",
                                              family: .monthly),
                       plan: "Enterprise",
                       details: [DetailLine(
                           text: "Workspace limit · shared across ChatGPT and Codex · ~158 credits/day · on pace",
                           explanation: .monthlyPace)],
                       burn: nil, burnTier: nil, notSeen: nil, heroElement: .monthlyUsed),
        creditsSpend: CreditsSpendSection(rows: [
            LabeledRow(label: "Plan", value: "Enterprise"),
            LabeledRow(label: "Spend control", value: "Active"),
        ]),
        localActivity: Stub.local(.empty, copy: LocalActivitySection.emptyCopy))

    /// The §11.3 low-allowance shape (D-60): no rate can be stated, and the tier note says why.
    static let cxLowAllowance = CodexDisplayState(
        dot: .amber, phase: .content,
        header: header(hero: "3%", progress: 0.03, caption: "Monthly quota left",
                       verdict: nil, plan: "Go",
                       details: [DetailLine(text: "resets in 29 days", explanation: .reset)],
                       burn: nil, burnTier: nil, notSeen: nil),
        quotaNote: CodexDisplayState.unpublishedLimitNote,
        quotaNoteURL: URL(string: "https://chatgpt.com/#pricing"),
        windowGrain: "Monthly",
        localActivity: Stub.local(tool: .codex, tokens: "210k", sessions: "1 thread",
                                  moreCount: 0))

    static let cxLowAllowanceBlocked = CodexDisplayState(
        dot: .red, phase: .content,
        header: header(hero: "0%", progress: 0, caption: "Monthly quota left",
                       verdict: HeaderVerdict(line1: "Out of quota — blocked until the reset",
                                              colour: .red, line2: "resets in 29 days"),
                       plan: "Go", burn: nil, burnTier: nil, notSeen: nil),
        quotaNote: CodexDisplayState.unpublishedLimitNote,
        quotaNoteURL: URL(string: "https://chatgpt.com/#pricing"),
        recommendation: "New Codex requests are blocked until the window resets in 29 days.",
        recommendationSeverity: .danger,
        windowGrain: "Monthly",
        localActivity: Stub.local(tool: .codex, tokens: "210k", sessions: "1 thread",
                                  moreCount: 0))
}

// MARK: - Menu-bar fixtures (UI Spec §1.0, Baseline §14.1)

// Per-tool §1.1 slots. Menu-bar countdowns stay compact "1h52m" (§1.1) — only popover copy is
// spaced (§2.3).
extension ToolMenuBarDisplay {
    /// One elevated long limit for a preview slot (REV-98 §2.3 — STEP_202). A preview never runs
    /// the schedule, so the reset only has to be a plausible instance key; the reminder text is
    /// the stub's whole point and is written out rather than derived.
    private static func stubStatus(_ limit: BlockEpisode.Limit,
                                   _ tier: LongLimitAssessment.Tier,
                                   _ resetInDays: Double, _ text: String) -> LongLimitStatus {
        LongLimitStatus(limit: limit, tier: tier,
                        resetsAt: Date(timeIntervalSince1970: 1_757_500_000)
                            .addingTimeInterval(resetInDays * 86_400),
                        reminderText: text)
    }

    static let claudeHealthy = ToolMenuBarDisplay(
        prefix: "CL", dot: .green, percentText: "62%", timeSlot: "↻1h52m")
    static let claudeAtRisk = ToolMenuBarDisplay(
        prefix: "CL", dot: .red, percentText: "13%", timeSlot: "◔~11m")
    /// A long limit ahead of its own calendar (rank 10): the ordinary string, an amber dot, and
    /// a reminder the bar shows for five seconds at the §2.2 cadence (REV-97 §2.1 — STEP_198).
    /// The steady phase is what the preview draws; `reminderIndex` is the schedule's, not the
    /// stub's.
    static let claudeLimitAheadOfPace = ToolMenuBarDisplay(
        prefix: "CL", dot: .amber, percentText: "78%", timeSlot: "↻1h52m",
        longLimits: .live([stubStatus(.secondary, .aheadOfPace, 5, "CL ⚠wk 43%")]))
    /// Rank 5b, with both long limits warning — two reminders, worst first (§2.3).
    static let claudeLimitNearlySpent = ToolMenuBarDisplay(
        prefix: "CL", dot: .red, percentText: "64%", timeSlot: "↻3h46m",
        longLimits: .live([stubStatus(.monthly, .nearlySpent, 10, "CL ⚠mo 8%"),
                           stubStatus(.secondary, .aheadOfPace, 5, "CL ⚠wk 43%")]))
    /// The weekly is what stopped you — held, never cycled (§2.5).
    static let claudeWeeklyBlocked = ToolMenuBarDisplay(
        prefix: "CL", dot: .red, percentText: "⚠wk 0%", timeSlot: "↻3d")
    static let claudeIdle = ToolMenuBarDisplay(
        prefix: "CL", dot: .grey, percentText: "––", timeSlot: "est")
    static let claudeLoading = ToolMenuBarDisplay(
        prefix: "CL", dot: .grey, percentText: "…", timeSlot: nil)
    /// Stale-keep with a kept percent (§9.3 / STEP_32): grey dot, no time slot — a cached
    /// countdown would lie. The slotless single-tool form.
    static let claudeStaleKept = ToolMenuBarDisplay(
        prefix: "CL", dot: .grey, percentText: "57%", timeSlot: nil)
    static let codexLoading = ToolMenuBarDisplay(
        prefix: "CX", dot: .grey, percentText: "…", timeSlot: nil)
    static let codexHealthy = ToolMenuBarDisplay(
        prefix: "CX", dot: .green, percentText: "58%", timeSlot: "↻2h04m")
    static let codexElevated = ToolMenuBarDisplay(
        prefix: "CX", dot: .amber, percentText: "29%", timeSlot: "◔~31m")
    /// Codex spend-control (§1.2, added 2026-07-04): standard grammar, red dot.
    static let codexSpendControl = ToolMenuBarDisplay(
        prefix: "CX", dot: .red, percentText: "16%", timeSlot: "↻2h10m")
    /// Codex null-window: the `—— est` text form.
    static let codexNullWindow = ToolMenuBarDisplay(
        prefix: "CX", dot: .neutral, percentText: "——", timeSlot: "est")
}

// Full renders per display mode — built through the real §1.0 matrix so fixtures cannot
// drift from `DisplayFormatter.menuBarRender`.
extension MenuBarRender {
    static let stacked = DisplayFormatter.menuBarRender(
        mode: .bothStacked, claude: .claudeHealthy, codex: .codexSpendControl)
    static let stackedLongLimit = DisplayFormatter.menuBarRender(
        mode: .bothStacked, claude: .claudeLimitAheadOfPace, codex: .codexElevated)
    /// The same render mid-reminder — what the bar looks like for five seconds in sixty.
    static let stackedLongLimitReminding = DisplayFormatter.menuBarRender(
        mode: .bothStacked, claude: .claudeLimitNearlySpent, codex: .codexElevated)
        .showingReminder(0, on: 0)
    /// A weekly block: the blocking limit's name and its own reset, held.
    static let stackedWeeklyBlocked = DisplayFormatter.menuBarRender(
        mode: .bothStacked, claude: .claudeWeeklyBlocked, codex: .codexHealthy)
    static let stackedAtRisk = DisplayFormatter.menuBarRender(
        mode: .bothStacked, claude: .claudeAtRisk, codex: .codexHealthy)
    /// Estimated / null-window pair — `–– est` and `—— est` (§1.0).
    static let stackedEstNull = DisplayFormatter.menuBarRender(
        mode: .bothStacked, claude: .claudeIdle, codex: .codexNullWindow)
    /// D-32: one tool detected collapses stacked to the single-tool shape — one reduced-size
    /// row (D-107; the one-day D-106 stack is history).
    static let singleToolCollapse = DisplayFormatter.menuBarRender(
        mode: .bothStacked, claude: .claudeHealthy, codex: nil)
    /// No-slot form: a stale-kept percent renders the same reduced row, just shorter (D-107).
    static let singleToolNoSlot = DisplayFormatter.menuBarRender(
        mode: .claudeOnly, claude: .claudeStaleKept, codex: nil)
    static let claudeOnly = DisplayFormatter.menuBarRender(
        mode: .claudeOnly, claude: .claudeHealthy, codex: .codexElevated)
    /// A single-tool mode whose chosen tool is the undetected one: a tool *is* detected, so this
    /// is legitimately empty and is **not** `nothingDetected` (D-78).
    static let codexOnlyUndetected = DisplayFormatter.menuBarRender(
        mode: .codexOnly, claude: .claudeHealthy, codex: nil)
    static let loading = DisplayFormatter.menuBarRender(
        mode: .bothStacked, claude: .claudeLoading, codex: .codexLoading)
    /// D-78 — neither tool detected. Built through the real matrix like its siblings, so the
    /// preview cannot drift from what `menuBarRender` actually returns on a first launch.
    static let nothingDetected = DisplayFormatter.menuBarRender(
        mode: .bothStacked, claude: nil, codex: nil)
}

// MARK: - AppViewModel preview convenience

extension AppViewModel {
    /// A stub model for previews and Xcode canvas — Claude at risk, Codex healthy.
    static func previewModel(claude: ClaudeDisplayState = .atRisk,
                             codex: CodexDisplayState = .healthy,
                             activeTab: Tool = .claude) -> AppViewModel {
        AppViewModel(claudeState: claude, codexState: codex, activeTab: activeTab)
    }

    /// A single-tool machine (D-68 — STEP_105): only `tool` is detected, so the popover renders
    /// tabless with that tool's content filling it. The dev machine has both tools, so this
    /// preview is the honest stand-in for the layout a one-tool user sees.
    static func previewSingleToolModel(detected tool: Tool) -> AppViewModel {
        let vm: AppViewModel
        switch tool {
        case .claude:
            vm = previewModel(claude: .healthy, activeTab: .claude)
            vm.applyUndetected(tool: .codex)
        case .codex:
            vm = previewModel(codex: .healthy, activeTab: .codex)
            vm.applyUndetected(tool: .claude)
        }
        return vm
    }

    /// A model whose newest poll is 7 minutes old → the account source tag shows an amber
    /// "· 7m ago" freshness stamp (UI Spec v4.7 §2.2a; STEP_33 preview).
    static func previewStaleModel() -> AppViewModel {
        let vm = previewModel(claude: .healthy, activeTab: .claude)
        let staleNow = Date().addingTimeInterval(-7 * 60)
        vm.apply(tool: .claude,
                 snapshot: QuotaSnapshot(tool: .claude, primaryUsedPct: 38,
                                         primaryResetsAt: staleNow.addingTimeInterval(6_720),
                                         secondaryUsedPct: 14,
                                         secondaryResetsAt: staleNow.addingTimeInterval(3 * 86_400),
                                         rateLimitReached: false, extraUsage: .disabled,
                                         source: .oauth, email: "user@example.com", planType: "max"),
                 forecast: Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: nil,
                                    burnRatePerMin: 0.2, isEstimate: false, pollCount: 5),
                 state: .healthy, now: staleNow)
        vm.refreshFreshness()
        return vm
    }
}
