import Foundation
import KvotarCore

// The selected account limit (STEP_176 — REV-92 / D-114; Baseline §15.2). One typed, pure result
// that names the limit the header describes and carries every fact used to explain it, so the
// hero percentage, meter, caption, reset, verdict, explanation cards and the Other Limits rows all
// read one identity and cannot disagree. Built by `DisplayFormatter.selectLimit`; the raw
// `QuotaSnapshot` and the primary-series `Forecast` keep their original meaning — nothing here
// overwrites `primary*` to fake a secondary-primary swap.

/// Which limit. Stable, sortable: the order of the cases is the Other Limits row order.
public enum AccountLimitID: Hashable, Sendable {
    /// The snapshot's primary window — five-hour on Claude, whatever width Codex reports.
    case primaryWindow
    /// The snapshot's secondary window — the weekly.
    case secondaryWindow
    /// The monthly meter (`MonthlyLimit`) — a spend/credits meter, or a percentage window.
    case monthly
    /// One window of a model allowance (`AdditionalRateLimit`), keyed by the allowance's handle
    /// (its `id`, else its `name`) and the slot within it.
    case modelWindow(allowance: String, slot: ModelWindowSlot)

    public enum ModelWindowSlot: Int, Hashable, Sendable, Comparable {
        case primary = 0, secondary = 1
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Stable display order: primary, weekly, monthly, then model windows by allowance then slot.
    var sortKey: (Int, String, Int) {
        switch self {
        case .primaryWindow: return (0, "", 0)
        case .secondaryWindow: return (1, "", 0)
        case .monthly: return (2, "", 0)
        case .modelWindow(let allowance, let slot): return (3, allowance, slot.rawValue)
        }
    }

    public var isModelWindow: Bool {
        if case .modelWindow = self { return true }
        return false
    }
}

/// Whose limit it is. A model-scoped warning never implies every model is blocked.
public enum LimitScope: Hashable, Sendable {
    case account
    case model(name: String)
}

/// What the limit is measured in — the reported unit, never inferred from the period.
public enum LimitUnit: Hashable, Sendable {
    case percent
    case credits
    case money(currency: String, exponent: Int)
}

/// Urgency in the existing vocabulary — no new threshold anywhere (Baseline §15.2). Ordered so
/// the more urgent status compares greater.
public enum LimitStatus: Int, Comparable, Sendable {
    case unknown = 0
    case notStarted = 1
    case healthy = 2
    case warning = 3
    case critical = 4
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Where a status came from — the evidence the explanation layer names.
public enum LimitStatusReason: Hashable, Sendable {
    /// The §13 state (with its §13.4 hold) — the primary window's, or Weekly-elevated's.
    case state(AppState)
    /// A hard block the provider confirmed (Over quota / Spend control).
    case blocked
    /// The existing weekly line (`StateEngine.weeklyElevatedUtil`) applied to a window the state
    /// machine does not rank — a model window.
    case threshold(usedPercent: Double, line: Double)
    /// A percentage window at or past 100 % — exhausted, with no forecast to say more.
    case exhausted
    /// The monthly forecast dot (REV-38 E6 gate / ≥ 90 % / reached).
    case monthlyForecast
    /// Not started: 0 % and no anchor (`primaryWindowIsUnanchored`, or a model window's twin).
    case unanchored
    /// Stale reading — status withheld, the value kept (D-33/D-35).
    case stale
    /// No value reported.
    case noValue
}

/// How current the figure is. Distinct from status: a stale reading is still a reading.
public enum LimitAvailability: Hashable, Sendable {
    case fresh
    case stale(asOf: Date)
    case unanchored
}

/// One limit, with every fact the header needs to describe it.
public struct AccountLimitCandidate: Hashable, Sendable {
    public let id: AccountLimitID
    public let scope: LimitScope
    public let unit: LimitUnit
    /// Display name: `5-hour`, `Weekly`, `Monthly spend limit`, `GPT-5.3-Codex-Spark`.
    public let name: String
    /// Width in seconds where reported. `nil` = unknown, and then no period is claimed.
    public let periodSeconds: Int?
    /// The D-58 grain word for the width (`5-hour` / `Weekly` / `Monthly` / `14-day`), `nil` when
    /// the width is unknown or unnamed.
    public let periodLabel: String?
    /// Utilization (raw, uncapped — `106` over quota); `nil` when unknown.
    public let usedPercent: Double?
    /// Monthly meters only: the native amounts (minor units or credits).
    public let usedAmount: Double?
    public let limitAmount: Double?
    public let resetsAt: Date?
    public let status: LimitStatus
    public let statusReason: LimitStatusReason
    /// The row dot (`Fmt.thresholdDot` on percentage windows, the monthly forecast dot on the
    /// meter) — the cue an Other Limits row shows. **Not** the promotion status.
    public let cue: StatusDot
    public let availability: LimitAvailability
    public let source: QuotaSource?

    /// `100 − used`, floored at 0 (REV-77 / D-97); `nil` when unknown.
    public var remainingPercent: Double? { usedPercent.map { max(0, 100 - $0) } }

    public init(id: AccountLimitID, scope: LimitScope, unit: LimitUnit, name: String,
                periodSeconds: Int?, periodLabel: String?, usedPercent: Double?,
                usedAmount: Double? = nil, limitAmount: Double? = nil, resetsAt: Date?,
                status: LimitStatus, statusReason: LimitStatusReason, cue: StatusDot,
                availability: LimitAvailability, source: QuotaSource?) {
        self.id = id
        self.scope = scope
        self.unit = unit
        self.name = name
        self.periodSeconds = periodSeconds
        self.periodLabel = periodLabel
        self.usedPercent = usedPercent
        self.usedAmount = usedAmount
        self.limitAmount = limitAmount
        self.resetsAt = resetsAt
        self.status = status
        self.statusReason = statusReason
        self.cue = cue
        self.availability = availability
        self.source = source
    }
}

/// Why this limit is the hero — the §15.2 selection step that chose it.
public enum HeroReason: Hashable, Sendable {
    /// A provider-confirmed block. `limitIdentified` is false when the block flag is unscoped
    /// (Over quota from `rateLimitReached` with the primary below 100 %) — the identity is then
    /// the existing rank-3 reading, never an invented one.
    case blocked(limitIdentified: Bool)
    /// A primary-window warning state (§13 ranks 4–9) keeps the primary.
    case stateWarning
    /// A more urgent non-primary limit was promoted over a calm primary.
    case promoted
    /// No warning: the populated primary.
    case primaryDefault
    /// No warning and no primary: the weekly.
    case secondaryDefault
    /// No warning and no window: the configured monthly meter.
    case monthlyDefault
    /// No limits at all.
    case none
}

/// The selection result. `others` holds every remaining limit exactly once, in stable order.
public struct AccountLimitSelection: Hashable, Sendable {
    public let hero: AccountLimitCandidate?
    public let heroReason: HeroReason
    public let others: [AccountLimitCandidate]

    /// True only when the hero is the primary window — the one series `ForecastEngine` measures
    /// (Baseline §15.2). A secondary or model hero inherits no burn and no runway.
    public var forecastApplies: Bool { hero?.id == .primaryWindow }

    public static let empty = AccountLimitSelection(hero: nil, heroReason: .none, others: [])

    public init(hero: AccountLimitCandidate?, heroReason: HeroReason,
                others: [AccountLimitCandidate]) {
        self.hero = hero
        self.heroReason = heroReason
        self.others = others
    }
}

/// A fresh model-scoped constraint that deserves attention without taking over the account
/// header. The formatter composes the two visible lines; the view only applies the carried
/// severity and explanation. Model windows remain in `OtherLimitsSection` even when warned here.
public struct ModelLimitWarning: Equatable, Sendable {
    public let id: AccountLimitID
    public let headline: String
    public let detail: String
    public let status: LimitStatus
    public let cue: StatusDot
    public let availability: LimitAvailability
    public let resetAccessibilityText: String?
    public let explanation: ExplanationElement
    public let explanationBridge: ExplanationLive?

    public init(id: AccountLimitID, headline: String, detail: String,
                status: LimitStatus, cue: StatusDot, availability: LimitAvailability,
                resetAccessibilityText: String? = nil,
                explanation: ExplanationElement = .scopedLimit,
                explanationBridge: ExplanationLive? = nil) {
        self.id = id
        self.headline = headline
        self.detail = detail
        self.status = status
        self.cue = cue
        self.availability = availability
        self.resetAccessibilityText = resetAccessibilityText
        self.explanation = explanation
        self.explanationBridge = explanationBridge
    }
}

/// One aligned header fact — `Quota burn` → `Low · 0.3% / min` or
/// `Not seen locally · ≈12% (est.)` — with the interval and unit it belongs to stated, so a
/// five-hour figure can never be read as a weekly one (Baseline §15.2 "scope of header facts").
public struct HeaderFact: Hashable, Sendable {
    public enum Availability: Hashable, Sendable {
        /// A value to show.
        case shown
        /// Applicable but not known — renders `—`.
        case unknown
        /// Not applicable to this shape (low-allowance, retrospective grain, a hero with no
        /// estimate of its own) — the line is hidden.
        case inapplicable(String)
    }

    /// Which limit the value is a share of.
    public let limitID: AccountLimitID
    /// The row label, naming the interval when it is not the hero's (`5-hour burn`).
    public let label: String
    /// The value token, or `—` when unknown.
    public let value: String
    public let dot: StatusDot
    /// The interval word the value is measured over (`5-hour`, `Weekly`, `Monthly`), when known.
    public let intervalLabel: String?
    public let availability: Availability
    /// The registry element that explains this quantity (STEP_178): E-05 / E-21 for the burn,
    /// E-07 / E-19 for the estimate. The card followed the quantity when the burn card was
    /// deleted — the fact line is now its only anchor.
    public let explanation: ExplanationElement
    /// A period-specific override for the card. The registry owns the wording; carrying the
    /// resolved body here keeps the view from deriving a period from labels.
    public let explanationBody: String?
    /// The bare urgency word of a burn fact (`none` / `low` / `mid` / `high`), which the §2.8
    /// delta line compares between opens. It rode on the retired burn card's `pill`; the fact
    /// carries it now so that trigger is unchanged. `nil` on the estimate and while unknown.
    public let tier: String?

    /// Whether the line renders at all. An inapplicable fact draws nothing — a dash there would
    /// read as a failed fetch where the truth is that this shape has no such quantity.
    public var isApplicable: Bool {
        if case .inapplicable = availability { return false }
        return true
    }

    public init(limitID: AccountLimitID, label: String, value: String, dot: StatusDot,
                intervalLabel: String?, availability: Availability,
                explanation: ExplanationElement, explanationBody: String? = nil,
                tier: String? = nil) {
        self.limitID = limitID
        self.label = label
        self.value = value
        self.dot = dot
        self.intervalLabel = intervalLabel
        self.availability = availability
        self.explanation = explanation
        self.explanationBody = explanationBody
        self.tier = tier
    }
}

/// One `OTHER LIMITS` row (UI Spec §REV92): the limit's name, its remaining amount, its own cue,
/// its reset when known, and the explanation element the view attaches.
public struct OtherLimitRow: Sendable, Equatable {
    public let id: AccountLimitID
    public let label: String
    public let value: String
    public let cue: StatusDot?
    /// Monthly meters: `$69.16 of $120.00` / `2,377 of 5,000`.
    public let detail: String?
    /// `resets Sep 14` / `resets 6:00 pm` / `not started` / `reset unknown`.
    public let reset: String?
    /// The same reset at full local date/time precision for hover and assistive technology.
    public let resetAccessibilityText: String?
    /// The monthly meter's `Set by your organization · on pace` note (E-16) — the one fact the
    /// retired Monthly section carried that neither the value nor the reset states. `nil`
    /// everywhere else.
    public let meta: DetailLine?
    public let explanation: ExplanationElement
    /// The row's live line (E-01·live on the primary window, E-02·primaryTighter /
    /// ·weeklyTighter on the weekly) — the same derivation the retired quota rows carried, so
    /// moving the row does not silently drop the one line that answers *which window is tighter*.
    public let explanationLive: ExplanationLive?
    public let explanationBridge: ExplanationLive?
    /// The element the **reset line** carries (STEP_178): E-03 under the primary window, E-14
    /// under the weekly, E-17 under the monthly meter. Those three rows had their own cards on
    /// the retired Account-quota and Monthly sections; the reset line keeps them so nothing is
    /// silently retired. `nil` where the reset has no card of its own (model windows).
    public let resetExplanation: ExplanationElement?
    /// True while another limit's block makes this one unusable (REV-96 §2.4 — STEP_194): the
    /// value already ends `· blocked by the weekly`, and the row is drawn back (STEP_195). It
    /// carries no `cue` in that state — a green dot beside quota you cannot spend is a lie about
    /// headroom, which is the whole reason the blocking limit takes the hero.
    public let isBlocked: Bool
    /// True on the one row the §2.2 strip is about (REV-96 §2.4 — STEP_195). The strip names a
    /// limit and this row *is* that limit, so the row is lifted onto a faint chip: the reader who
    /// reads the line under the verdict and then looks down the list should not have to work out
    /// which of three rows it meant. Never set in a block — there the blocking limit has the hero,
    /// and nothing in this section is the thing being talked about.
    public let isHighlighted: Bool

    public init(id: AccountLimitID, label: String, value: String, cue: StatusDot?,
                detail: String? = nil, reset: String?, resetAccessibilityText: String? = nil,
                meta: DetailLine? = nil,
                explanation: ExplanationElement,
                explanationLive: ExplanationLive? = nil,
                explanationBridge: ExplanationLive? = nil,
                resetExplanation: ExplanationElement? = nil,
                isBlocked: Bool = false,
                isHighlighted: Bool = false) {
        self.id = id
        self.label = label
        self.value = value
        self.cue = cue
        self.detail = detail
        self.reset = reset
        self.resetAccessibilityText = resetAccessibilityText
        self.meta = meta
        self.explanation = explanation
        self.explanationLive = explanationLive
        self.explanationBridge = explanationBridge
        self.resetExplanation = resetExplanation
        self.isBlocked = isBlocked
        self.isHighlighted = isHighlighted
    }
}

/// The header's **long-limit strip** (UI Spec §2.2 / REV-96 §2.4, §3.7 — STEP_194): one line
/// under the verdict saying that a weekly or monthly limit is ahead of its calendar, nearly
/// spent, or (the one unverified case) reached with unknown effect.
///
/// It exists because the two clocks answer different questions and only one of them can have the
/// hero. The five-hour window is what the user is spending *now*; the weekly is the budget behind
/// it. Before this, a weekly could only speak by taking the whole header — so it either shouted
/// or said nothing. The strip is the middle voice: the hero keeps answering *am I safe right
/// now*, and one line under it answers *and is the week going to hold*.
///
/// **Never two.** The worst tier wins and, on a tie, the nearer reset — a reader who is told
/// about two limits at once has to work out which one stops them first, which is the job the app
/// is supposed to have done.
public struct LongLimitStrip: Sendable, Equatable {
    /// Which limit the line is about — the hover card and STEP_195's row highlight key on it.
    public let limitID: AccountLimitID
    public let text: String
    /// `.amber` on the ahead-of-pace tier, `.red` on nearly-spent and on the unverified reached
    /// case. Never green: a strip in green would be a line that says nothing.
    public let cue: StatusDot
    /// The registry element whose card explains the limit — E-02 on the weekly, E-15/E-16 on the
    /// monthly meter, so the strip and the row it summarises open the same explanation.
    public let explanation: ExplanationElement
    /// The card's live rows for this limit, already filled.
    public let explanationLive: ExplanationLive?

    public init(limitID: AccountLimitID, text: String, cue: StatusDot,
                explanation: ExplanationElement, explanationLive: ExplanationLive? = nil) {
        self.limitID = limitID
        self.text = text
        self.cue = cue
        self.explanation = explanation
        self.explanationLive = explanationLive
    }
}

/// `OTHER LIMITS` (UI Spec §REV92): the account's own limits as plain rows, then one group per
/// model allowance with **every reported window of that model as its own row** — a weekly-only
/// main allowance can coexist with a model's five-hour and weekly windows, and neither implies
/// the other. The old bottom `+ N model limits` disclosure is gone: these are visible by default.
public struct OtherLimitsSection: Sendable, Equatable {
    /// One model allowance and its windows, in the selection's own stable order.
    public struct ModelGroup: Sendable, Equatable {
        /// The provider's model name (`GPT-5.3-Codex-Spark`, `Fable`).
        public let name: String
        /// A heading is useful only when two or more period rows share this model name.
        public let showsHeading: Bool
        public let rows: [OtherLimitRow]

        public init(name: String, showsHeading: Bool = true, rows: [OtherLimitRow]) {
            self.name = name
            self.showsHeading = showsHeading
            self.rows = rows
        }
    }

    /// Account-scoped limits (primary window, weekly, monthly meter).
    public let rows: [OtherLimitRow]
    /// Model-scoped allowances, grouped by model name.
    public let modelGroups: [ModelGroup]
    /// The quota freshness tag, repeated under the section the way every source-bearing block
    /// carries one.
    public let sourceTag: SourceTag?

    public init(rows: [OtherLimitRow], modelGroups: [ModelGroup] = [],
                sourceTag: SourceTag? = nil) {
        self.rows = rows
        self.modelGroups = modelGroups
        self.sourceTag = sourceTag
    }

    /// True when there is nothing at all to draw — the section is suppressed, never rendered empty.
    public var isEmpty: Bool { rows.isEmpty && modelGroups.isEmpty }
}
