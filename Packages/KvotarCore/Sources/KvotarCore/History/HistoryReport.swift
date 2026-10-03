import Foundation

/// The History window's whole payload (STEP_109) — raw, formatting-free values, exactly as
/// `LocalAttribution` is for the popover. No view logic here; the UI package turns these into rows.
///
/// **Calendar time, never plan windows.** Reset anchors live only in poll data (`poll_snapshots`,
/// `quota_series`) and cannot be reconstructed for the past, so a window-aligned report could show
/// nothing from before the day the app was installed — which is the whole point of reading the
/// backfilled corpus. Wall-clock timestamps are the only time structure the local corpus has.
public struct HistoryReport: Sendable, Equatable {

    /// One 7-day bucket, `[start, end)`. The oldest bucket in a 30-day period is clipped (30 is not
    /// a multiple of 7) and says so, rather than pretending to a full week it does not cover.
    public struct Week: Sendable, Equatable {
        public let start: Date
        public let end: Date
        public let isPartial: Bool
        public let tokens: Int
        public let value: Double

        public init(start: Date, end: Date, isPartial: Bool, tokens: Int, value: Double) {
            self.start = start
            self.end = end
            self.isPartial = isPartial
            self.tokens = tokens
            self.value = value
        }
    }

    /// One **local calendar day** of the period (STEP_116 — the day strip). Days with nothing are
    /// present with zeros: the strip's axis is the calendar, not the data. The oldest day is
    /// clipped at `periodStart` and flagged, exactly as the oldest `Week` is — the period is 30×24
    /// hours from an arbitrary time of day, so it touches 31 local days and the first is a sliver.
    public struct Day: Sendable, Equatable {
        /// Local midnight — except the clipped oldest day, whose slot begins at `periodStart`.
        public let start: Date
        public let isPartial: Bool
        /// Displayed tokens under this tool's own rule (`DisplayedTokens`). Never a cross-tool sum.
        public let tokens: Int
        /// Distinct sessions active that day. A session spanning midnight counts in both days —
        /// the same "active in the period" semantics `sessionCount` has.
        public let sessions: Int
        /// A quota window was blocked on this day (`notification_events.over_quota`).
        public let hitLimit: Bool
        /// Per-event-model token totals for exactly this local-day bucket (STEP_158 — REV-84
        /// §5.1), grouped from the same hourly read the strip's `tokens` are folded from — so
        /// `tokens == DisplayedTokens.total(modelTotals, tool:)` by construction, and the day
        /// rows sum to `ToolReport.totalTokens`. An unknown model stays an honest nil-model
        /// row, never dropped. Largest displayed count first.
        public let modelTotals: [SQLiteStore.ModelTokenTotals]
        /// Per-model Est. token value, index-aligned with `modelTotals` (STEP_159 — REV-84
        /// §5.1: the selected-day model rows carry a value). Priced per row through the same
        /// engine, so the list sums to `value` in the same addition order — exactly.
        public let modelValues: [ModelValue]
        /// Est. token value for the day: `modelTotals` priced through the one
        /// `EstimatedValueEngine` — never a second pricing path. Day values sum to
        /// `ToolReport.value` within floating-point tolerance.
        public let value: Double
        /// The day's work grouped by project (STEP_178 — REV-92 §2 decision 6): what the
        /// popover's `N more projects ›` sends the reader here to read. Grouped with
        /// `ProjectGrouping.canonical` over the **provider-wide** stored path set — the same
        /// basis the popover's daily report uses — so the two lists agree row for row and the
        /// popover's overflow count matches what is drawn here. Largest displayed count first;
        /// `(no project)` is a row like any other. Sums to `tokens` by construction.
        public let projects: [DayProject]

        public init(start: Date, isPartial: Bool, tokens: Int, sessions: Int, hitLimit: Bool,
                    modelTotals: [SQLiteStore.ModelTokenTotals] = [], value: Double = 0,
                    modelValues: [ModelValue] = [], projects: [DayProject] = []) {
            self.start = start
            self.isPartial = isPartial
            self.tokens = tokens
            self.sessions = sessions
            self.hitLimit = hitLimit
            self.modelTotals = modelTotals
            self.modelValues = modelValues
            self.value = value
            self.projects = projects
        }
    }

    /// One project's share of one local day (STEP_178). The canonical stored path (`nil` for the
    /// no-project group) and its displayed tokens — no session count, because the hourly read
    /// this is folded from cannot distinguish a session that spans two hours from two sessions.
    public struct DayProject: Sendable, Equatable {
        public let project: String?
        public let tokens: Int

        public init(project: String?, tokens: Int) {
            self.project = project
            self.tokens = tokens
        }
    }

    /// Est. token value for one model row (STEP_159 amendment to the STEP_158 contract): the
    /// matching `modelTotals` entry priced through the one `EstimatedValueEngine`. A parallel,
    /// index-aligned list rather than a widened totals type, so the token contract STEP_158
    /// shipped is untouched and a display layer zips the two without a lookup.
    public struct ModelValue: Sendable, Equatable {
        public let model: String?
        public let value: Double
        /// Priced at the provider fallback because today's table has no row for the model — the
        /// recap's `≈` (REV-104 §2.3, STEP_228). Today's table, because the report reprices on
        /// every open; `unpriced_models` records when pricing ran, not when the tokens were used.
        public let pricedAtFallback: Bool

        public init(model: String?, value: Double, pricedAtFallback: Bool = false) {
            self.model = model
            self.value = value
            self.pricedAtFallback = pricedAtFallback
        }
    }

    public struct Project: Sendable, Equatable {
        public let name: String?          // nil when the corpus never recorded one
        public let sessions: Int
        public let tokens: Int

        public init(name: String?, sessions: Int, tokens: Int) {
            self.name = name
            self.sessions = sessions
            self.tokens = tokens
        }
    }

    public struct Session: Sendable, Equatable {
        public let sessionId: String
        public let project: String?
        public let model: String?
        public let lastSeenAt: Date
        public let tokens: Int
        public let value: Double

        public init(sessionId: String, project: String?, model: String?,
                    lastSeenAt: Date, tokens: Int, value: Double) {
            self.sessionId = sessionId
            self.project = project
            self.model = model
            self.lastSeenAt = lastSeenAt
            self.tokens = tokens
            self.value = value
        }
    }

    /// One recorded quota block (REV-73 / D-80 — STEP_120): the instant it fired, the window that
    /// blocked, and when that window reset. A block is **not one kind of event** — on the dogfood
    /// corpus two Claude blocks fired six and seven minutes before their window reset while two
    /// cost three and a half and nearly three hours — so the row prints the clock and the cost
    /// rather than one identical tick each.
    ///
    /// `resetAt` and `windowSeconds` are derived together and are **both nil or both set**: the
    /// width is what sanity-checks the reset (`lockout ≤ width`), so without one we do not trust
    /// the other. A block whose reset cannot be recovered keeps its row and loses its duration —
    /// never a guessed one (REV-73 §4.3).
    public struct LimitBlock: Sendable, Equatable {
        /// When the block was recorded (`notification_events.fired_at`). Always known.
        public let firedAt: Date
        /// The blocking window's reset instant, from the hourly rollups. `nil` when the rollup hour
        /// is missing, or when the window reset inside the fired hour and the rollup's `_last`
        /// column had already advanced to the *next* window's reset (the rollover guard).
        public let resetAt: Date?
        /// The blocking window's width in seconds, `resetAt − notification_events.window_start`.
        /// `nil` when that key is unusable — one corpus row claims a window starting Aug 30 for a
        /// block on Aug 1 (a five-hour default width applied against a monthly reset).
        public let windowSeconds: Int?

        public init(firedAt: Date, resetAt: Date?, windowSeconds: Int?) {
            self.firedAt = firedAt
            self.resetAt = resetAt
            self.windowSeconds = windowSeconds
        }

        /// How long the block lasted. `nil` whenever the reset is unknown.
        public var lockoutSeconds: Int? {
            resetAt.map { Int($0.timeIntervalSince(firedAt)) }
        }
    }

    /// One recorded change to the account or to its windows (REV-73 §4.2 / D-81 — STEP_121): a
    /// plan change, or one of the four observable window facts. **One list, not two**, because the
    /// *What changed* rows interleave them by date and the day strip marks a day on either.
    ///
    /// Values are raw as stored (`go` → `plus`; widths in seconds) — this is a `discontinuity_events`
    /// row, typed at read by its owning component, and every word the reader sees is the display
    /// package's. Plan rows arrive already collapsed by `PlanChangeStability.settled`.
    public struct AccountChange: Sendable, Equatable {
        public enum Kind: String, Sendable, CaseIterable {
            case planChanged = "plan_changed"
            case windowAdded = "window_added"
            case windowRemoved = "window_removed"
            case windowWidthChanged = "window_width_changed"
            case earlyReset = "early_reset"
        }

        public let at: Date
        public let kind: Kind
        /// `"five_hour"` / `"weekly"` / … as stored; nil on the account-scoped kinds and wherever
        /// the detector could not name a width (D-58's load-bearing "say nothing").
        public let windowType: String?
        public let oldValue: String?
        public let newValue: String?

        public init(at: Date, kind: Kind, windowType: String? = nil,
                    oldValue: String? = nil, newValue: String? = nil) {
            self.at = at
            self.kind = kind
            self.windowType = windowType
            self.oldValue = oldValue
            self.newValue = newValue
        }
    }

    /// One recorded entry into a critical state (STEP_158 — REV-84 §3.2/§5.1): the instant
    /// `StateEngine` observed the account cross into At risk, Bad timing, Over quota, or Spend
    /// control, read back from the `state_transitions` log.
    ///
    /// **An instant, never an interval.** A row proves Kvotar recorded entry into the state at
    /// that moment; it says nothing about what happened between polls, and the absence of a row
    /// is absence of retained evidence — never proof the account had headroom. `state_transitions`
    /// retains 90 days and exists only from the day the app was watching, unlike the token
    /// corpus, which is permanent and backfilled 90 days behind — the report's 30-day period sits
    /// inside both horizons, but they are different facts and the copy must not equate them.
    /// `triggered_by` deliberately does not cross this boundary (§9.1/§10 internals ban), and no
    /// duration is inferred.
    public struct CriticalObservation: Sendable, Equatable {
        /// The four §13 destinations the History window reports. Raw values match the stored
        /// `to_state` strings; any other stored state is not a critical observation and is
        /// skipped at read.
        public enum State: String, Sendable, CaseIterable {
            case atRisk = "at_risk"
            case badTiming = "bad_timing"
            case overQuota = "over_quota"
            case spendControl = "spend_control"
        }

        public let at: Date
        public let state: State
        /// Stored account utilization at the transition, when the log kept one.
        public let utilizationPct: Double?

        public init(at: Date, state: State, utilizationPct: Double?) {
            self.at = at
            self.state = state
            self.utilizationPct = utilizationPct
        }
    }

    /// One tool's whole report. Every member is empty-able: a tool with no local corpus yields a
    /// section whose rows individually drop out, never a blank page or a fabricated zero.
    public struct ToolReport: Sendable, Equatable {
        public let tool: Tool
        public let sessions: Int
        public let totalTokens: Int
        public let modelTotals: [SQLiteStore.ModelTokenTotals]
        /// Per-model Est. token value over the whole period, index-aligned with `modelTotals`
        /// (STEP_159 — REV-84 §5.3: the Models dimension shows tokens and value). Sums to
        /// `value` within floating-point tolerance.
        public let modelValues: [ModelValue]
        public let cacheHitRatio: Double?
        public let value: Double
        public let projects: [Project]      // largest first, already truncated
        public let topSessions: [Session]   // largest first, already truncated
        public let weeks: [Week]            // most recent first
        /// One entry per local calendar day, **oldest first** — the strip reads left to right,
        /// unlike `weeks`, which is newest first. Empty when the day read failed or the corpus is.
        public let days: [Day]
        /// Oldest local event for this tool — how far back the evidence actually reaches, which is
        /// not the same as the period start on a machine the app has not been watching for long.
        public let evidenceFrom: Date?
        // Events (STEP_109 addendum). Unlike the token corpus these cannot be backfilled — they are
        // recorded from the day the app starts polling — so `watchingSince` lets the section say so.
        /// Plan changes and window facts, **oldest first**, inside the period (STEP_121). Plan
        /// rows are already collapsed: a name pair that traded places three times or more is two
        /// provider sources disagreeing, not an account changing (`PlanChangeStability`).
        public let accountChanges: [AccountChange]
        /// Every window blocked in the period, **oldest first** (STEP_120). The count and the last
        /// date the facts tile shows are read off this list, so a tally and a row can never
        /// disagree. **Weekly-only exhaustion is not in here and cannot be** — `StateEngine`
        /// rank 3 declares over-quota from the primary window and the provider's hard-block flag
        /// and never reads the secondary, so a spent weekly allowance that leaves the five-hour
        /// window under 100 writes no row at all (REV-73 §5 / P1-18, answered 2026-08-18).
        public let limitBlocks: [LimitBlock]
        /// Displayed tokens per **local** clock hour, 24 entries, hour 0 first (STEP_120). Bucketed
        /// by the hour's start, the STEP_114/STEP_116 convention — exact in a whole-hour zone, up
        /// to an hour of skew in a half-hour one, never a lost or duplicated token.
        public let workByHour: [Int]
        public let watchingSince: Date?             // nil until polling evidence exists
        /// "Work per 1 % of window" (REV-69 / STEP_114) — the quota-change evidence series over
        /// `[max(periodStart, watchingSince), periodEnd)`, with its `discontinuity_events` markers.
        public let workPerPercent: WorkPerPercentSeries
        /// Recorded transitions **into** the four critical states inside the period, oldest
        /// first (STEP_158). Multiple entries on one day are multiple facts — the presentation
        /// layer may summarize, but the times stay accessible. Hard blocks are *not* here:
        /// `limitBlocks` (REV-73, `notification_events`) stays their one source.
        public let criticalObservations: [CriticalObservation]
        /// Provider-observed quota windows inside the period, oldest first (REV-93 §4, STEP_181) —
        /// the evidence Explore quota charts. Provider truth, not local observation: each entry is
        /// one window the endpoint itself reported, with its own width where one was recorded and
        /// an explicit statement of how much of it Kvotar watched. **A quiet stretch is missing
        /// from this list, never a 0% entry**, and the poll-side horizon means the list starts at
        /// `watchingSince`, not at `periodStart`.
        public let quotaWindows: [QuotaWindowOutcome]
        /// Every **weekly** limit instance inside the period, oldest reset first (STEP_227 —
        /// REV-104 §4): the overall weekly (the secondary window, or a main window that is itself
        /// seven days wide) and each model allowance's weekly, folded by the same rules as
        /// `quotaWindows`. Overall and model limits are separate entries and are never summed.
        /// Starts where their readings start — 2026-09-13 for the secondary, 2026-09-16 for model
        /// allowances — and is empty for a tool with no weekly limit.
        public let weeklyLimits: [WeeklyLimitOutcome]

        public init(tool: Tool, sessions: Int, totalTokens: Int,
                    modelTotals: [SQLiteStore.ModelTokenTotals], cacheHitRatio: Double?,
                    value: Double, projects: [Project], topSessions: [Session],
                    weeks: [Week], evidenceFrom: Date?,
                    accountChanges: [AccountChange] = [], limitBlocks: [LimitBlock] = [],
                    watchingSince: Date? = nil,
                    workPerPercent: WorkPerPercentSeries = .empty,
                    days: [Day] = [], workByHour: [Int] = [],
                    criticalObservations: [CriticalObservation] = [],
                    modelValues: [ModelValue] = [],
                    quotaWindows: [QuotaWindowOutcome] = [],
                    weeklyLimits: [WeeklyLimitOutcome] = []) {
            self.tool = tool
            self.sessions = sessions
            self.totalTokens = totalTokens
            self.modelTotals = modelTotals
            self.modelValues = modelValues
            self.cacheHitRatio = cacheHitRatio
            self.value = value
            self.projects = projects
            self.topSessions = topSessions
            self.weeks = weeks
            self.evidenceFrom = evidenceFrom
            self.accountChanges = accountChanges
            self.limitBlocks = limitBlocks
            self.watchingSince = watchingSince
            self.workPerPercent = workPerPercent
            self.days = days
            self.workByHour = workByHour
            self.criticalObservations = criticalObservations
            self.quotaWindows = quotaWindows
            self.weeklyLimits = weeklyLimits
        }

        /// Windows blocked in the period. Derived, so the facts tile and the rows cannot diverge.
        public var limitHitCount: Int { limitBlocks.count }
        public var lastLimitHitAt: Date? { limitBlocks.last?.firedAt }

        /// Nothing observed in the period — the caller renders an honest empty section.
        public var isEmpty: Bool { totalTokens == 0 && sessions == 0 }

        /// The busiest **complete** week, for the comparison line. Partial buckets are excluded:
        /// comparing a full week against a clipped one would manufacture a trend.
        public var busiestCompleteWeek: Week? {
            weeks.filter { !$0.isPartial }.max { $0.tokens < $1.tokens }
        }

        /// The most recent bucket, which is the one a comparison is drawn against.
        public var currentWeek: Week? { weeks.first }
    }

    public let periodStart: Date
    public let periodEnd: Date
    public let tools: [ToolReport]
    public let pricingVersion: String?
    public let pricingUpdated: String?

    public init(periodStart: Date, periodEnd: Date, tools: [ToolReport],
                pricingVersion: String?, pricingUpdated: String?) {
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.tools = tools
        self.pricingVersion = pricingVersion
        self.pricingUpdated = pricingUpdated
    }

    /// Every tool section is empty — the brand-new-user case.
    public var isEmpty: Bool { tools.allSatisfy(\.isEmpty) }

    /// The period the window reports on. 30 days matches the §2.5b `30-day` row exactly, so the two
    /// surfaces can be cross-checked against each other.
    public static let periodDays = 30
    public static let weekSeconds: TimeInterval = 7 * 86_400
    /// How many project and session rows the window shows before truncating.
    public static let topRowLimit = 5
}

/// One weekly limit instance and which limit it belongs to (STEP_227 — REV-104 §2.4). The outcome
/// carries everything the recap states — reset, high water, hit limit, ending, and how long before
/// the reset it was last read.
public struct WeeklyLimitOutcome: Sendable, Equatable, Identifiable {
    public enum Limit: Sendable, Equatable {
        /// The account's all-models weekly.
        case overall
        /// A model allowance's weekly — `key` is `model_limit_series.limit_key`.
        case model(key: String, name: String?)
    }

    public let limit: Limit
    public let outcome: QuotaWindowOutcome

    /// The overall weekly and a model weekly routinely share a reset, so the outcome's own id
    /// is not unique across limits.
    public var id: String {
        switch limit {
        case .overall: return "overall-\(outcome.id)"
        case .model(let key, _): return "model-\(key)-\(outcome.id)"
        }
    }

    public init(limit: Limit, outcome: QuotaWindowOutcome) {
        self.limit = limit
        self.outcome = outcome
    }
}
