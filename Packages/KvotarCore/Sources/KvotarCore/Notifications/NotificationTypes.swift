import Foundation

/// The eleven fired-notification kinds (Baseline §13.2, UI Spec §4 + §4.1a). Raw values are the
/// exact `notification_events.event_type` strings from the schema (§17.1) — do not rename without
/// updating the migration's documented value list.
public enum NotificationEventType: String, Sendable, Equatable, CaseIterable {
    case atRisk = "at_risk"
    case badTiming = "bad_timing"
    case overQuota = "over_quota"
    case fastBurnSpike = "fast_burn_spike"
    case offMachineBurn = "off_machine_burn"
    case multiSurface = "multi_surface"
    case windowResetPre = "window_reset_pre"
    case windowResetPost = "window_reset_post"
    case spendControl = "spend_control"
    /// The seventh §4 event (§4.1a, REV-69/D-76 — STEP_146): a provider added, removed or
    /// re-sized a quota window. Path 2, one per recorded fact; a window reset does not clear it.
    case windowChanged = "window_changed"
    /// The ninth §4 event (REV-96 §3.2 — defined STEP_193, **live since STEP_194**): a long
    /// limit — a secondary window or a monthly pool — is nearly spent. Path 1, on entry to rank
    /// 5b, once per limit instance. By ranking it cannot fire while a five-hour red state is
    /// live; when that calms and the long limit is still past the line, the transition into 5b
    /// fires it then.
    case limitNearlySpent = "limit_nearly_spent"
    /// The tenth §4 event (REV-106 — STEP_232): a weekly is ahead of pace at one of the ladder's
    /// two early steps, carried as the copy variant (`half` / `quarter`). Path 2, level-triggered
    /// against the lowest step already announced for the instance — never on a state change, so
    /// a five-hour warning cannot mask it. Delivered since STEP_233 (`WeeklyLadder.isEnabled`).
    case limitAheadOfPace = "limit_ahead_of_pace"

    /// Baseline §16 arbitration priority — lower wins; at most one notification fires per
    /// evaluation cycle (no stacking, UI Spec §4.2 / D-11). Spend-control shares rank 1 with
    /// over-quota per §16 item 1. Window changed sits below over quota and above at risk (§4.1a —
    /// the planning assumptions just broke).
    var arbitrationPriority: Int {
        switch self {
        case .overQuota, .spendControl: return 1
        case .windowChanged: return 2
        case .atRisk: return 3
        // Between At risk and Bad timing (REV-96 §3.2): a limit about to stop you outranks a
        // warning that you *might* be stopped before the window refreshes.
        case .limitNearlySpent: return 4
        case .badTiming: return 5
        // Below Bad timing, above Fast burn (REV-106 §2.7): a planning notice never outranks a
        // warning about the next hour. Losing here costs the step one poll, not the step.
        case .limitAheadOfPace: return 6
        case .fastBurnSpike: return 7
        case .offMachineBurn: return 8
        case .multiSurface: return 9
        case .windowResetPre, .windowResetPost: return 10
        }
    }
}

/// The four user-facing on/off groups over ten of the eleven events (REV-79 / UI Spec D-100, Part 3 §3a
/// screen 4 table; Baseline §16 amendment, STEP_144). A UI contract over the engine: a disabled
/// group is dropped in `NotificationEngine.evaluateCycle` before arbitration and before `fire`,
/// so it consumes no cap, no cooldown, and writes no `notification_events` row. Thresholds,
/// caps, cooldowns and priorities are untouched.
public enum NotificationGroup: String, CaseIterable, Sendable, Hashable {
    case atRisk = "at_risk"
    case fastBurn = "fast_burn"
    case overQuota = "over_quota"
    case windowReset = "window_reset"

    /// The `settings` row (§17.1). Values `"true"` / `"false"`; absent ⇒ `defaultEnabled`.
    public var settingsKey: String { "notification_\(rawValue)_enabled" }

    /// Absent ⇒ on / on / on / **off** (§3a screen 4).
    public var defaultEnabled: Bool { self != .windowReset }

    /// The user-facing group name — the only copy this type carries (UI Spec §1a **Notify me ▸**).
    public var label: String {
        switch self {
        case .atRisk: return "At risk"
        case .fastBurn: return "Fast burn"
        case .overQuota: return "Over quota"
        case .windowReset: return "Window reset"
        }
    }

    public var events: [NotificationEventType] {
        switch self {
        case .atRisk: return [.atRisk, .badTiming, .limitNearlySpent, .limitAheadOfPace]
        case .fastBurn: return [.fastBurnSpike, .offMachineBurn, .multiSurface]
        case .overQuota: return [.overQuota, .spendControl]
        case .windowReset: return [.windowResetPre, .windowResetPost]
        }
    }

    /// Decodes a stored value: `nil` ⇒ the group's default, `"false"` ⇒ off, anything else ⇒ on.
    public static func isEnabled(_ raw: String?, for group: NotificationGroup) -> Bool {
        guard let raw else { return group.defaultEnabled }
        return raw != "false"
    }
}

extension NotificationEventType {
    /// The group that switches this event on or off — `nil` for the one event no switch
    /// silences: **window changed is always on** (STEP_146, user ruling 2026-08-25). It is rare,
    /// always actionable, and the planning assumptions it reports broke whether or not the user
    /// wanted to hear about it.
    public var group: NotificationGroup? {
        switch self {
        // Owner ruling 2026-09-14: event 9 joins the At risk switch rather than Over quota — it
        // is the warning that lets you *avoid* the block, and a user who silences block banners
        // should not lose it with them. Event 10 sits beside it for the same reason (REV-106 §2.7).
        case .atRisk, .badTiming, .limitNearlySpent, .limitAheadOfPace: return .atRisk
        case .fastBurnSpike, .offMachineBurn, .multiSurface: return .fastBurn
        case .overQuota, .spendControl: return .overQuota
        case .windowResetPre, .windowResetPost: return .windowReset
        case .windowChanged: return nil
        }
    }
}

/// A fully-decided notification handed to the `NotificationPresenter` for delivery. The engine
/// owns *whether* and *which* notification fires (cooldown/re-arm/max-per-window/window logic);
/// the presenter owns copy (UI Spec §4 wins on copy — Core stays copy-free). All display fields
/// are carried structured so the presenter formats the exact title/body per event + `copyVariant`.
public struct NotificationDecision: Sendable, Equatable {
    public let tool: Tool
    public let eventType: NotificationEventType
    /// Unix-second start of the 5-hour window this decision belongs to — the
    /// `notification_events.window_start` key and the stable-ID component.
    public let windowStart: Int
    /// Copy case selector, e.g. `"case_1"`/`"case_3"` for over-quota, `"rearm"` for at-risk
    /// re-arm; `nil` for single-variant notifications. Persisted to `copy_variant`.
    public let copyVariant: String?
    public let utilizationPct: Double?
    public let runwayMinutes: Double?
    public let resetsAt: Date?
    /// Provider-reported width of the window this decision belongs to, in seconds — the window-reset
    /// copy's grain (D-58, REV-59). `Your 5-hour window has reset.` is false on any other width, and
    /// the width is the only honest source for the name (never `plan_type`, never position). `nil`
    /// on Claude, which reports no width, so its copy keeps the literal it has always had.
    public let primaryWindowSeconds: Int?
    /// The recorded window fact a `windowChanged` decision carries — the copy's whole input.
    public let windowFact: WindowFact?
    /// Δ utilization over the 2-minute window — spike/multi-surface copy.
    public let deltaPct: Double?
    /// Active model string when known — spike/multi-surface copy.
    public let model: String?
    /// Active project path when known — §4.2 "project name in body by default". STEP_27.
    public let project: String?
    /// Active surface labels, largest share first — Multi-surface "[A] + [B]" copy. STEP_27.
    public let surfaces: [String]
    /// Claude `extra_usage` amounts for the over-quota case 1/2 dollar bodies (§4.1). STEP_27.
    public let extraUsageUsedCredits: Decimal?
    public let extraUsageMonthlyLimit: Int?
    /// Currency and minor-unit exponent of the two amounts above (REV-102 §2.5 — STEP_221).
    /// Nil ⇒ USD / cents.
    public let extraUsageCurrency: String?
    public let extraUsageCurrencyExponent: Int?
    /// The block this decision belongs to, when it is a block event (STEP_193; carried as the
    /// episode itself rather than as its key string since STEP_194, so the body can name **which**
    /// limit stopped you without parsing one). `fire` persists `key` to `settings` so the episode
    /// is deduped across a rollover, a gap and a relaunch. `nil` on every other event, and on a
    /// block with no anchor to key on.
    public let blockEpisode: BlockEpisode?
    /// The long limit this decision is about (STEP_194) — event 9's whole copy input, and on a
    /// block event the identity that lets the body name *which* limit stopped you. `nil` on every
    /// event that is about the primary window alone.
    public let longLimit: LongLimitAssessment?
    public let firedAt: Date

    /// Stable `UNNotificationRequest` identifier: a re-fire of the same event in the same window
    /// replaces the delivered banner in place instead of stacking (UI Spec §4.2 "no stacking").
    public var stableRequestID: String {
        "\(tool.rawValue)-\(eventType.rawValue)-\(windowStart)"
    }

    public init(
        tool: Tool,
        eventType: NotificationEventType,
        windowStart: Int,
        copyVariant: String?,
        utilizationPct: Double? = nil,
        runwayMinutes: Double? = nil,
        resetsAt: Date? = nil,
        primaryWindowSeconds: Int? = nil,
        windowFact: WindowFact? = nil,
        deltaPct: Double? = nil,
        model: String? = nil,
        project: String? = nil,
        surfaces: [String] = [],
        extraUsageUsedCredits: Decimal? = nil,
        extraUsageMonthlyLimit: Int? = nil,
        extraUsageCurrency: String? = nil,
        extraUsageCurrencyExponent: Int? = nil,
        blockEpisode: BlockEpisode? = nil,
        longLimit: LongLimitAssessment? = nil,
        firedAt: Date = Date()
    ) {
        self.tool = tool
        self.eventType = eventType
        self.windowStart = windowStart
        self.copyVariant = copyVariant
        self.utilizationPct = utilizationPct
        self.runwayMinutes = runwayMinutes
        self.resetsAt = resetsAt
        self.primaryWindowSeconds = primaryWindowSeconds
        self.windowFact = windowFact
        self.deltaPct = deltaPct
        self.model = model
        self.project = project
        self.surfaces = surfaces
        self.extraUsageUsedCredits = extraUsageUsedCredits
        self.extraUsageMonthlyLimit = extraUsageMonthlyLimit
        self.extraUsageCurrency = extraUsageCurrency
        self.extraUsageCurrencyExponent = extraUsageCurrencyExponent
        self.blockEpisode = blockEpisode
        self.longLimit = longLimit
        self.firedAt = firedAt
    }
}

/// Delivery seam (ARCHITECTURE.md DI rule — engines depend on protocols, not concrete types).
/// The App layer provides a `UNUserNotificationCenter`-backed implementation; tests inject a mock.
public protocol NotificationPresenter: Sendable {
    /// Deliver one decided notification. Must never throw or block the engine.
    func present(_ decision: NotificationDecision) async
    /// The tool's primary window just reset (D-128 — STEP_226). The presenter withdraws the
    /// delivered notices about the window that ended. Must never throw or block the engine.
    func windowDidReset(_ tool: Tool) async
}

public extension NotificationPresenter {
    /// Default: nothing delivered to withdraw (test doubles, headless presenters).
    func windowDidReset(_ tool: Tool) async {}
}

/// Per-poll input to `NotificationEngine.handlePoll` — everything Path 2 (signal/re-arm) needs
/// (Baseline §13.2). Built by the poll driver from the same snapshot/forecast it already computes.
/// `nil` local metrics mean "cannot confirm" — the dependent notification is skipped, not assumed.
public struct NotificationSignal: Sendable {
    public let tool: Tool
    /// State classified for this poll — gates at-risk re-arm and the pre-reset warning history.
    public let state: AppState
    public let utilizationPct: Double?
    public let runwayMinutes: Double?
    public let resetsAt: Date?
    /// Provider-reported width of the primary window, in seconds — the window-reset copy's grain
    /// (D-58, REV-59) and, since STEP_88, the width the per-window notification cap buckets on.
    public let primaryWindowSeconds: Int?
    /// True when this poll landed on the §11.3 low-allowance shape
    /// (`QuotaSnapshot.isLowAllowanceShape`) — the gate that leaves Over quota as the only kind
    /// that can fire (§16 REV-59 amendment, UI Spec §4.1 / D-60).
    public let isLowAllowanceShape: Bool
    /// The window facts this poll recorded (`DiscontinuityDetector` moments, folded by
    /// `WindowFact.fold`) — each one is a `windowChanged` candidate (§4.1a, STEP_146). Empty on
    /// every ordinary poll.
    public let windowFacts: [WindowFact]
    /// The block this poll observed, if any (REV-96 §2.1 — STEP_193). Its absence on a *poll*
    /// signal is what ends an episode: a fresh account reading with no limit at the ceiling.
    public let blockEpisode: BlockEpisode?
    /// The worst long limit this poll saw (REV-96 §2.2 — STEP_194). Its absence for a limit is
    /// what lets the engine retire that limit's spent `nearly_spent.*` key once the period rolls.
    public let longLimit: LongLimitAssessment?
    /// The account's weekly as the ladder reads it (REV-106 §2.3 — STEP_232):
    /// `QuotaSnapshot.weeklyForNotifications`, the secondary window or a seven-day primary.
    /// Only a poll signal carries it, which is what keeps the ladder off every restored, stale
    /// and JSONL-delta evaluation.
    public let weekly: LongLimitAssessment?
    /// Δ primary utilization over the **Multi-surface** 2-minute window. Fast burn left this
    /// input at STEP_189 (see `fastBurnDelta`); multi-surface keeps it, and with it the same
    /// cadence weakness — recorded as a follow-up, not fixed here.
    public let utilDeltaShortWindow: Double?
    /// Δ primary utilization between the two most recent polls while they sit within
    /// `ForecastEngine.fastBurnMaxPollGap` of each other and of now — the Fast-burn signal
    /// (§13 rank 6, STEP_189). Same number rank 6 classifies on, and the figure the body prints.
    public let fastBurnDelta: Double?
    /// Δ primary utilization across the two most recent polls — Off-machine rise signal.
    public let utilDeltaLast2Polls: Double?
    /// Local tokens on this machine in the last 2 minutes — retained for display/telemetry; the
    /// Off-machine idle gate now uses `lastLocalActivityAt` (recency gap) instead (REV-23).
    public let localTokensLast2Min: Int?
    /// Most recent local JSONL activity — the Off-machine idle gate (REV-23): idle when this is nil
    /// or older than `LocalAttribution.idleGap`.
    public let lastLocalActivityAt: Date?
    /// Distinct active surface buckets — Multi-surface signal (Codex only).
    public let activeSurfaceBucketCount: Int
    /// Active model string when known — spike copy.
    public let model: String?
    /// Active project path when known — §4.2 "project name in body by default". STEP_27.
    public let project: String?
    /// Active surface bucket labels, largest share first — Multi-surface "[A] + [B]" copy. STEP_27.
    public let surfaces: [String]
    public let now: Date

    public init(
        tool: Tool,
        state: AppState,
        utilizationPct: Double?,
        runwayMinutes: Double?,
        resetsAt: Date?,
        primaryWindowSeconds: Int? = nil,
        isLowAllowanceShape: Bool = false,
        windowFacts: [WindowFact] = [],
        blockEpisode: BlockEpisode? = nil,
        longLimit: LongLimitAssessment? = nil,
        weekly: LongLimitAssessment? = nil,
        utilDeltaShortWindow: Double? = nil,
        fastBurnDelta: Double? = nil,
        utilDeltaLast2Polls: Double? = nil,
        localTokensLast2Min: Int? = nil,
        lastLocalActivityAt: Date? = nil,
        activeSurfaceBucketCount: Int = 0,
        model: String? = nil,
        project: String? = nil,
        surfaces: [String] = [],
        now: Date = Date()
    ) {
        self.tool = tool
        self.state = state
        self.utilizationPct = utilizationPct
        self.runwayMinutes = runwayMinutes
        self.resetsAt = resetsAt
        self.primaryWindowSeconds = primaryWindowSeconds
        self.isLowAllowanceShape = isLowAllowanceShape
        self.windowFacts = windowFacts
        self.blockEpisode = blockEpisode
        self.longLimit = longLimit
        self.weekly = weekly
        self.utilDeltaShortWindow = utilDeltaShortWindow
        self.fastBurnDelta = fastBurnDelta
        self.utilDeltaLast2Polls = utilDeltaLast2Polls
        self.localTokensLast2Min = localTokensLast2Min
        self.lastLocalActivityAt = lastLocalActivityAt
        self.activeSurfaceBucketCount = activeSurfaceBucketCount
        self.model = model
        self.project = project
        self.surfaces = surfaces
        self.now = now
    }
}
