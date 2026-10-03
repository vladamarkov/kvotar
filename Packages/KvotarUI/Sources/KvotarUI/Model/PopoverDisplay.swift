import Foundation
import KvotarCore

/// Popover presentation models. Pure "dumb" bags of already-formatted values — no business logic.
/// Previews (step 3) build these directly from stub data; the StateEngine / AppViewModel wiring
/// (steps 14–15) will map live engine output onto the same shapes. Section structure follows
/// UI Spec v4.5 §2 (Claude) and §2 (Codex).

/// Which card a tab shows. `content` renders the full section stack; `loading` / `idle` /
/// `firstRun` render the minimal cards from Baseline §13.3 — three *distinct* pre-content states:
/// `loading` (detected, first poll in flight), `idle` (detected but unreachable / no session),
/// and `firstRun` (tool never detected — no credentials and no JSONL; setup guidance).
public enum PopoverPhase: Sendable {
    case loading
    case content
    case idle
    case firstRun
}

/// Severity of a contextual hint / recommendation box (UI Spec §2.6 · prototype `.hint-d/-w/-i`).
/// Drives the tinted background + text colour, not the copy.
public enum HintSeverity: Sendable {
    case danger   // hard block / at-risk — red
    case warning  // elevated / burn signals — amber
    case info     // informational (credits accruing, null-window) — blue
}

/// Plan-badge styling (prototype `.badge-exact` green / `.badge-credit` blue). `credit` signals the
/// account is operating on usage credits; `exact` is the normal account-derived source; `stale`
/// greys the badge while cached data is shown (STEP_32 stale-keep — the pill must not read fresh).
public enum PlanBadgeKind: Sendable {
    case exact
    case credit
    case stale
}

/// Generic label / value row with an optional colour cue on the value (e.g. quota-percent colour).
public struct LabeledRow: Sendable, Equatable {
    public let label: String
    public let value: String
    public let dot: StatusDot?
    /// The explanation-layer element this row is (UI Spec Part 3 §5.2 — STEP_111), or `nil` for a
    /// plain row. Set by `DisplayFormatter`, which knows the row's shape; the view only reacts. A
    /// tagged row is a hover-card target; an untagged one is inert.
    public let explanation: ExplanationElement?
    /// The row's live line, filled from state by `DisplayFormatter` (UI Spec Part 3 §5.2 rule 4
    /// as amended — REV-75/D-88, STEP_130). `nil` on a row that has no live line at all;
    /// `.dropped(reason)` when it has one and a value it needed was missing. The view reads only
    /// `.text`, so a drop renders the concept card alone — never a placeholder, never a dash.
    public let explanationLive: ExplanationLive?
    /// The row's **bridge line** (UI Spec Part 3 §5.2 rule 8 — REV-77/D-97, STEP_139): the
    /// first line of every card on an element that shows a quota percentage, *`[left]% left ·
    /// [used]% used`*, filled from the same utilization the row was drawn from. `nil` on a row
    /// that shows no percentage; `.dropped` when the value is missing — like the live line, the
    /// view reads only `.text`.
    public let explanationBridge: ExplanationLive?

    public init(label: String, value: String, dot: StatusDot? = nil,
                explanation: ExplanationElement? = nil,
                explanationLive: ExplanationLive? = nil,
                explanationBridge: ExplanationLive? = nil) {
        self.label = label
        self.value = value
        self.dot = dot
        self.explanation = explanation
        self.explanationLive = explanationLive
        self.explanationBridge = explanationBridge
    }
}

/// Runway verdict (UI Spec §2.2a, D-20/REV-25; advisory voice v5.1, D-27/REV-34): two stacked
/// lines directly under the progress bar — line 1 the state-coloured verdict sentence, line 2
/// the muted clock-first detail line. Supersedes the v4.6 weekly thin bar (D-19), now→reset
/// runway timeline, and both subtitle slots; weekly now renders only in the Account-quota rows.
/// `line2` is `—` for the null-window / idle / loading placeholders, and `nil` where the row is
/// **removed** (REV-66/D-70: the long-window calm family, whose only number is the reset the
/// D-58 caption already states — `—` claims *unknown*, and "no extra numbers" is not unknown).
/// `moneyPrefix` marks the accruing row's leading `$` — the §1.6 money glyph rendered as a
/// verdict prefix in charging colour, independent of the sentence colour (a glyph, never an
/// amount; D-24/D-31).
public struct HeaderVerdict: Sendable, Equatable {
    public let line1: String      // "Won't make it — slow down or you'll stop in ~1h56m" / "—"
    public let colour: StatusDot  // state colour for line 1 (green / amber / red / neutral / grey)
    public let line2: String?     // "resets 10:41 pm · in 2h14m · runway ~18m" / "—" / nil (removed)
    public let moneyPrefix: Bool  // leading §1.6 money glyph (accruing row only)
    /// The glyph's character — the account's currency symbol, `$` fallback (STEP_219).
    public let moneySymbol: String
    /// Which §2.2a row this is (STEP_110 / D-73). Identity, not wording — the anatomy collapses
    /// when this changes and REV-68's "since you last looked" snapshot keys on it.
    public let family: VerdictFamily
    /// The verdict's work, shown when line 1 is clicked (UI Spec Part 3 §5.3). `nil` on the
    /// condition verdicts and wherever burn is unmeasured — the line is then inert.
    public let anatomy: VerdictAnatomy?
    /// E-08's card, whole (REV-75/D-90, STEP_130). Not a trailing line: the family decides the
    /// card's *concept* ("Runway" vs "Two resets" vs "Blocked"), so `card(.verdictDetail)` is nil
    /// and this string is the entire body — lead, sentence and live segment, already filled.
    /// **`nil` wherever line 2 reads `—` or is removed**: an inert target carries no card, and
    /// STEP_133 must not record a drop for one.
    public let detailLive: ExplanationLive?

    public init(line1: String, colour: StatusDot, line2: String?, moneyPrefix: Bool = false,
                moneySymbol: String = "$",
                family: VerdictFamily = .unknown, anatomy: VerdictAnatomy? = nil,
                detailLive: ExplanationLive? = nil) {
        self.line1 = line1
        self.colour = colour
        self.line2 = line2
        self.moneyPrefix = moneyPrefix
        self.moneySymbol = moneySymbol
        self.family = family
        self.anatomy = anatomy
        self.detailLive = detailLive
    }
}

/// The §2.2a verdict families, one case per row of the table (STEP_110 / REV-67 D-73). Coarser
/// than the rendered string on purpose: "Safe at this pace" and "Safe, barely" are one family
/// (`resetsFirst`) because they share an anatomy; the D-46 held row is its own (`held`) because
/// its next verdict differs; both credits variants of "Won't make it" are `exhaustion`.
public enum VerdictFamily: String, Sendable, Equatable {
    case monthly, spendControl, signInExpired, reconnecting, unknown, nullWindow, idle
    // `weeklyElevated` was retired in STEP_194 with the row it named (REV-96 §2.4/§3.7): the
    // weekly no longer takes the header outside a block, and a blocked weekly is `overQuota`.
    case overQuota, exhaustion, longWindowPace, held, resetsFirst
    case measuring, nothingBurning
    /// The window has not started, so no row is drawn at all (D-123 — STEP_207). It is a family
    /// without a rendered verdict on purpose: the §2.8 delta line asks *what was this render*,
    /// and "nothing, because the tab was frozen" (`unknown`) is a different answer from "a full
    /// window waiting for your first turn" — the second is where the `Last window ended at [N]%`
    /// boundary form lives, and reading it as the first would delete that line.
    case notStarted
}

/// The verdict's anatomy (UI Spec Part 3 §5.3, D-73): the inputs the verdict was computed from,
/// the comparison it made, and — verdict tier — the flip line: what the line will read next and
/// the single nearest condition that gets it there. Built by the same branch walk as the verdict
/// (`DisplayFormatter.headerVerdict`), never re-derived. `flip` is `nil` where no honest next
/// condition exists (e.g. an unanchored window). `*…*` in `flip` marks the quoted verdict; the
/// view renders it as emphasis.
public struct VerdictAnatomy: Sendable, Equatable {
    public let rows: [LabeledRow]
    public let comparison: String
    public let flip: String?

    public init(rows: [LabeledRow], comparison: String, flip: String?) {
        self.rows = rows
        self.comparison = comparison
        self.flip = flip
    }
}

/// A source / freshness tag (UI Spec v4.7 §2.2a, D-21). `base` is the source label with its
/// confidence — `Source: Claude account · exact` while live, `Source: Claude account · as of
/// 11:32 pm` once past the §9.3 TTL (stale-keep, STEP_32). `age` is the always-on per-source
/// freshness stamp driven by that source's own last-success time — `12s ago` / `4m ago` — nil
/// past the TTL (the "as of" stamp lives in `base` then) or when no timestamp is available.
/// `ageIsAmber` turns the stamp amber past 2 minutes (§2.3). One continuous grammar:
/// `· exact · 12s ago` → amber `· exact · 4m ago` → `· as of 11:32 pm`.
public struct SourceTag: Sendable, Equatable, ExpressibleByStringLiteral {
    public let base: String
    public let age: String?
    public let ageIsAmber: Bool

    public init(base: String, age: String? = nil, ageIsAmber: Bool = false) {
        self.base = base
        self.age = age
        self.ageIsAmber = ageIsAmber
    }

    /// String-literal convenience (previews / plain tags with no freshness stamp).
    public init(stringLiteral value: String) { self.init(base: value) }
}

/// One muted detail line (STEP_178 — REV-92 / UI Spec §REV92): the hero's reset, the monthly
/// meter's organization-and-pace note, the same two facts under an `OTHER LIMITS` row. The
/// formatter composes the text; the view draws it and attaches the card the element names.
public struct DetailLine: Sendable, Equatable {
    public let text: String
    /// The registry element this line is (E-03 / E-16 / E-17), or `nil` for an inert line.
    public let explanation: ExplanationElement?

    public init(text: String, explanation: ExplanationElement? = nil) {
        self.text = text
        self.explanation = explanation
    }
}

/// Header section (UI Spec v4.7 §2.2/§2.2a). Hero % + progress bar + two-line runway verdict
/// + plan badge + account email. The v4.6 weekly bar, runway timeline, and subtitle slots
/// are gone (REV-25) — the verdict carries the runway story; weekly renders in the quota rows.
public struct HeaderSection: Sendable {
    public let heroText: String        // "87%", "106%", "——" (null-window), "––" (idle)
    /// True utilization fraction — may exceed 1.0. The view renders the §0.5 overflow segment
    /// beyond the 100% mark (v4.6 supersedes the old cap-at-1.0 rule; 106% ≠ 100% visually).
    public let progress: Double
    /// §2.2a two-line runway verdict (line 1 coloured, line 2 muted). **`nil` on the §11.3
    /// low-allowance Codex shape** (D-60, STEP_88), where there is no rate to build a verdict from
    /// and the row is removed rather than filled with a placeholder — the hero directly above
    /// already reads `Monthly · resets in 30 days` and the quota rows directly below repeat the
    /// reset with its date. Every verdict the user can act on (the over-quota line, the
    /// null/unanchored lines, the credential-expired line) survives that suppression.
    public let verdict: HeaderVerdict?
    /// **What §2.2a row this render is, whether or not one is drawn.** Normally
    /// `verdict?.family`; on the not-started shape, where D-123 removes the row, it is
    /// `.notStarted`. Read by the §2.8 delta line, which must tell a removed row from a silent
    /// one — the low-allowance shape (D-60) leaves it nil, as it always did.
    public let verdictFamily: VerdictFamily?
    public let planBadge: String       // "Pro" — plan name alone, no confidence token (D-49)
    public let badgeKind: PlanBadgeKind // exact (green) / credit (blue) pill styling (§2.2)
    public let email: String?          // account email (both tools); nil when the API omits it
    /// Which registry element the hero `%` is (UI Spec Part 3 §5.2 — STEP_128). E-04 on a windowed
    /// layout; **E-15 on the monthly layout**, where the hero is a money/credit meter and not a
    /// window percent at all (REV-75/D-89). The formatter chooses — the view only attaches.
    public let heroExplanation: ExplanationElement
    /// The hero's live line (E-04 — REV-75/D-88, STEP_130). Dropped on the monthly layout (the
    /// hero is E-15 there and reads money, not a window percent), on the `——` placeholder, and
    /// while stale.
    public let heroLive: ExplanationLive?
    /// The D-58 caption's live line — **E-01's, computed once and shared with the primary quota
    /// row** (Baseline §19 forbids the second derivation). `nil` wherever the caption is.
    public let windowScopeLive: ExplanationLive?
    /// The hero's bridge line (§5.2 rule 8 — REV-77/D-97, STEP_139): *`[left]% left · [used]%
    /// used`* from the figure the hero was drawn from — the window on a windowed layout, the
    /// monthly meter on the monthly one — stale or fresh. `.dropped` on the `——` placeholder.
    public let heroBridge: ExplanationLive?
    /// **The selected limit (STEP_176 — REV-92 / Baseline §15.2).** `limit` is the limit the
    /// number, bar, caption, verdict and cards above describe — the primary window by default,
    /// the weekly when Weekly-elevated, a model window or the monthly meter when promoted over a
    /// calm primary. Model windows never take this role; their constraints render as scoped
    /// warnings below the account summary. `nil` only when there is no snapshot. The full result (`others`, the reason)
    /// rides on `selection`; the hero is duplicated here for the views' convenience.
    public let limit: AccountLimitCandidate?
    public let selection: AccountLimitSelection
    /// The §REV92 caption naming the selected limit: `5-hour quota left`, `Weekly quota left`,
    /// `Monthly spend limit left`, `GPT-5.3-Codex-Spark · Weekly quota left`. `nil` with no hero.
    public let limitCaption: String?
    /// `Quota burn` → `[tier] · [rate]` — the primary series' rate, or the monthly
    /// meter's; labelled with its interval when the hero is a different limit. `nil` = hidden.
    public let accountBurn: HeaderFact?
    /// `Not seen locally · ≈[amount] (est.)` — the existing Elsewhere estimate, same scoping.
    public let notSeenLocally: HeaderFact?
    /// Fresh model-scoped warnings, rendered below the account summary without changing its
    /// verdict, colour, recommendation, or forecast.
    public let modelWarnings: [ModelLimitWarning]
    /// The hero's own detail lines, in render order, between the verdict and the two facts
    /// (STEP_178): `resets Oct 1`, and on a monthly hero `$69.16 of $120.00 used` plus the
    /// organization/pace note. Empty when the hero has nothing further to say.
    public let heroDetails: [DetailLine]
    /// The quota freshness tag, which the header now owns — the Account-quota section that used
    /// to carry it is gone (STEP_178). `nil` on the phases with no reading behind them.
    public let sourceTag: SourceTag?
    /// The hero number's own ink, and the meter's (REV-96 §5.7 — STEP_195). `nil` means *the
    /// account's status dot*, which is what every state but one uses. The exception is a
    /// long-limit rank while the five-hour window still has the hero: the number and the bar are
    /// about that window, the verdict under them already says so in green, and painting them red
    /// would make the header disagree with itself. `DisplayFormatter.longLimitScopesPrimary` is
    /// the one test behind both this and the verdict's colour.
    public let heroCue: StatusDot?
    /// The §2.2 long-limit strip — one line under the verdict when a weekly or monthly limit is
    /// ahead of its calendar, nearly spent, or reached with unverified effect (REV-96 §2.4 —
    /// STEP_194). `nil` in green, while stale, and whenever the limit already has the hero.
    /// **Drawn by STEP_195**; this step only computes it.
    public let longLimitStrip: LongLimitStrip?

    public init(heroText: String, progress: Double, verdict: HeaderVerdict?,
                verdictFamily: VerdictFamily? = nil,
                planBadge: String, badgeKind: PlanBadgeKind = .exact, email: String? = nil,
                heroExplanation: ExplanationElement = .heroPercent,
                heroLive: ExplanationLive? = nil,
                windowScopeLive: ExplanationLive? = nil,
                heroBridge: ExplanationLive? = nil,
                selection: AccountLimitSelection = .empty,
                limitCaption: String? = nil,
                accountBurn: HeaderFact? = nil,
                notSeenLocally: HeaderFact? = nil,
                modelWarnings: [ModelLimitWarning] = [],
                heroDetails: [DetailLine] = [],
                sourceTag: SourceTag? = nil,
                heroCue: StatusDot? = nil,
                longLimitStrip: LongLimitStrip? = nil) {
        self.heroText = heroText
        self.progress = progress
        self.verdict = verdict
        // Defaults to the drawn row's own family, so every existing caller is unchanged; the
        // formatter passes `.notStarted` explicitly on the one shape that draws no row.
        self.verdictFamily = verdictFamily ?? verdict?.family
        self.planBadge = planBadge
        self.badgeKind = badgeKind
        self.email = email
        self.heroExplanation = heroExplanation
        self.heroLive = heroLive
        self.windowScopeLive = windowScopeLive
        self.heroBridge = heroBridge
        self.selection = selection
        self.limit = selection.hero
        self.limitCaption = limitCaption
        self.accountBurn = accountBurn
        self.notSeenLocally = notSeenLocally
        self.modelWarnings = modelWarnings
        self.heroDetails = heroDetails
        self.sourceTag = sourceTag
        self.heroCue = heroCue
        self.longLimitStrip = longLimitStrip
    }
}

/// Usage-credits card (UI Spec §2.4a, REV-29) — Claude only, always shown when the account exposes
/// an `extra_usage` object (suppressed entirely when absent — Enterprise / no pay-as-you-go). The
/// D-08 header alert row is retired; dollars live only here (the §2.2a verdict carries the
/// dollarless urgency). `moneyState` is the data-driven state model (§2.4a.1) — the cross-surface
/// invariant (§19) asserts it agrees with the §1.6 menu-bar glyph for identical forecast input.
public struct CreditsCardSection: Sendable {
    /// `Usage credits`, or `Usage credits · set by your organization` on a seat whose
    /// organization pays (REV-102 §2.3 — STEP_220).
    public let title: String
    public let moneyState: MoneyState
    /// "Usage credits" row (always): status text + a colour cue (charging red, imminent amber, else
    /// neutral). Its `dot` drives the value colour via `RowView`.
    public let status: LabeledRow
    /// This month / Auto-reload / Prepaid balance — each present only when its §2.4a.2 condition holds.
    public let rows: [LabeledRow]
    /// One conditional sub-line: the NO-BACKSTOP backstop sentence or the `Off: [reason]` line.
    public let subLine: String?
    public let subLineSeverity: HintSeverity?
    /// "Manage in Claude web ↗" link target (§2.4a.2) — Claude usage settings, opened in the browser.
    /// The card's sole interactive affordance (the app is read-only; the toggle lives server-side).
    /// nil suppresses the link.
    public let manageURL: URL?
    /// Mixed-provenance stamp (§2.4a.4): dual "Credits: … · Balance/reload: …" when the prepaid call
    /// succeeded, collapsing to the single Claude-account stamp when it did not.
    public let sourceTag: SourceTag

    public init(title: String = "Usage credits",
                moneyState: MoneyState, status: LabeledRow, rows: [LabeledRow] = [],
                subLine: String? = nil, subLineSeverity: HintSeverity? = nil,
                manageURL: URL? = nil, sourceTag: SourceTag) {
        self.title = title
        self.moneyState = moneyState
        self.status = status
        self.rows = rows
        self.subLine = subLine
        self.subLineSeverity = subLineSeverity
        self.manageURL = manageURL
        self.sourceTag = sourceTag
    }
}



/// Codex credits / spend section (UI Spec §2.4 Codex) — Enterprise only. In the monthly layout
/// (REV-38/D-34) it slims to Plan + Spend control — the quota story lives in `MonthlySection`,
/// and wallet credit balance ≠ the monthly user limit.
public struct CreditsSpendSection: Sendable {
    public let rows: [LabeledRow]  // plan, credit balance, spend control, est value today / 30-day

    public init(rows: [LabeledRow]) {
        self.rows = rows
    }
}



/// Full Claude popover state (UI Spec §REV92 — the STEP_178 composition). One header naming the
/// selected limit, `OTHER LIMITS`, `LOCAL ACTIVITY · TODAY` and its value companion, then the
/// applicable credits card. The Account-quota, Burn-rate, Monthly and two-part local sections
/// were retired at the cutover: their facts live on the header and in the two sections above.
public struct ClaudeDisplayState: Sendable {
    public let dot: StatusDot
    public let phase: PopoverPhase
    public let header: HeaderSection?
    /// Usage-credits card (§2.4a, REV-29): always present when the account exposes an `extra_usage`
    /// object; `nil` only when absent (Enterprise / no pay-as-you-go — the card is suppressed).
    /// Renders below the estimated-value section (§REV92 "applicable credits controls").
    public let creditsCard: CreditsCardSection?
    public let recommendation: String?  // shown only when a warning is active
    public let recommendationSeverity: HintSeverity  // hint-box colour when recommendation is shown
    public let recommendationURL: URL?    // near-cap "Manage in Claude web ↗" deep link (E5)
    /// The freeze reason the source-tag hover card may name (UI Spec Part 3 §5.2 rule 4 —
    /// STEP_111): the same D-33/D-38 fork the verdict uses, `nil` when nothing is frozen.
    public let sourceFreeze: SourceFreeze?
    /// `OTHER LIMITS` (STEP_176 — REV-92): every non-hero limit once; `nil` = section suppressed.
    public let otherLimits: OtherLimitsSection?
    /// `LOCAL ACTIVITY · TODAY` + `ESTIMATED VALUE` (STEP_177 — REV-92): the bounded daily
    /// report as render data; `nil` only on the no-content phases.
    public let localActivity: LocalActivitySection?

    public init(dot: StatusDot, phase: PopoverPhase, header: HeaderSection? = nil,
                creditsCard: CreditsCardSection? = nil, recommendation: String? = nil,
                recommendationSeverity: HintSeverity = .warning,
                recommendationURL: URL? = nil,
                sourceFreeze: SourceFreeze? = nil,
                otherLimits: OtherLimitsSection? = nil,
                localActivity: LocalActivitySection? = nil) {
        self.dot = dot
        self.phase = phase
        self.header = header
        self.creditsCard = creditsCard
        self.recommendation = recommendation
        self.recommendationSeverity = recommendationSeverity
        self.recommendationURL = recommendationURL
        self.sourceFreeze = sourceFreeze
        self.otherLimits = otherLimits
        self.localActivity = localActivity
    }
}

/// Full Codex popover state (UI Spec §REV92 — the STEP_178 composition). The twin of
/// `ClaudeDisplayState` plus the two Codex-only notes and the Enterprise credits/spend card.
public struct CodexDisplayState: Sendable {
    /// The §2.3 tier note (D-61 — REV-59 §7, STEP_89), rendered under the header on the
    /// §11.3 low-allowance shape and nowhere else. Verbatim and static; never computed.
    ///
    /// OpenAI publishes no ceiling for `free` or `go` — its own per-tier reference reads
    /// "Undisclosed" for both — so the `97%` above this line is a share of a quantity nobody will
    /// state. A first-time user reaches 97% within minutes of starting and has no way to tell that
    /// from a fault in this app, and this is the tier a new tester most likely arrives on. The line
    /// therefore states an **observation, not a specification**: hence "in practice", and no
    /// number. It is also deliberately honest that the imprecision is the provider's, not ours.
    public static let unpublishedLimitNote =
        "OpenAI doesn't publish this plan's Codex limit. In practice, one working session can use most of it."

    /// The label on the note's companion link (D-61). Mirrors the control OpenAI places at exactly
    /// this spot in its own account menu; grammar and styling follow the §2.4a "Manage in Claude
    /// web ↗" precedent (STEP_35).
    public static let upgradeLinkLabel = "Upgrade plan ↗"

    public let dot: StatusDot
    public let phase: PopoverPhase
    public let header: HeaderSection?
    /// The D-61 tier note and its upgrade link, both `nil` off the low-allowance shape (STEP_89).
    /// They describe the account's own allowance, so since STEP_178 they render under the header
    /// rather than under a limits list that a single-limit account does not draw at all.
    public let quotaNote: String?
    public let quotaNoteURL: URL?
    public let creditsSpend: CreditsSpendSection?
    public let recommendation: String?
    public let recommendationSeverity: HintSeverity  // hint-box colour when recommendation is shown
    public let recommendationURL: URL?    // near-cap "Request limit increase" deep link (E5)
    public let nullWindowNote: String?    // shown when both RPC and wham return null windows
    /// The freeze reason the source-tag hover card may name (§5.2 rule 4 — STEP_111); the Codex
    /// tab knows only D-33 "Reconnecting…".
    public let sourceFreeze: SourceFreeze?
    /// The D-58 grain word of the primary window (`5-hour` / `Weekly` / `Monthly`), `nil` when the
    /// provider reported no width — fills the E-01 card's `[Width]` (STEP_111).
    public let windowGrain: String?
    /// `OTHER LIMITS` (STEP_176 — REV-92): every non-hero limit once, model windows grouped by
    /// model with their own periods and resets; `nil` = suppressed. It replaced the collapsed
    /// `+ N model limits` disclosure at the STEP_178 cutover.
    public let otherLimits: OtherLimitsSection?
    /// `LOCAL ACTIVITY · TODAY` + `ESTIMATED VALUE` (STEP_177 — REV-92); the exact twin of
    /// `ClaudeDisplayState.localActivity`.
    public let localActivity: LocalActivitySection?

    public init(dot: StatusDot, phase: PopoverPhase, header: HeaderSection? = nil,
                quotaNote: String? = nil, quotaNoteURL: URL? = nil,
                creditsSpend: CreditsSpendSection? = nil,
                recommendation: String? = nil, recommendationSeverity: HintSeverity = .warning,
                recommendationURL: URL? = nil,
                nullWindowNote: String? = nil,
                sourceFreeze: SourceFreeze? = nil,
                windowGrain: String? = nil,
                otherLimits: OtherLimitsSection? = nil,
                localActivity: LocalActivitySection? = nil) {
        self.dot = dot
        self.phase = phase
        self.header = header
        self.quotaNote = quotaNote
        self.quotaNoteURL = quotaNoteURL
        self.creditsSpend = creditsSpend
        self.recommendation = recommendation
        self.recommendationSeverity = recommendationSeverity
        self.recommendationURL = recommendationURL
        self.nullWindowNote = nullWindowNote
        self.sourceFreeze = sourceFreeze
        self.windowGrain = windowGrain
        self.otherLimits = otherLimits
        self.localActivity = localActivity
    }
}
