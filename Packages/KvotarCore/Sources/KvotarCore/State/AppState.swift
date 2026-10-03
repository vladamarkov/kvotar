import Foundation

/// The state machine's output for one tool (Baseline §13). Raw values are the exact
/// `state_transitions.to_state` strings from the schema (§17.1) — do not rename without
/// updating the migration's documented value list.
///
/// This is the semantic state. The UI layer maps it to a `StatusDot` colour and copy
/// (UI Spec §1.2); Core never imports the UI package. Pre-first-poll "Loading" (§13.3) is a
/// view-model concern (the absence of any evaluation yet), not a state this engine emits.
public enum AppState: String, Sendable, Equatable, CaseIterable {
    case healthy
    case elevated
    /// Rank 10 (REV-96 §2.3 — STEP_194). **Replaces Weekly-elevated**, whose whole rule was
    /// `weekly ≥ 85 %`: this one is the long-limit assessment's amber tier on whichever long
    /// limit is worst, so a monthly can reach it too and a weekly only does when it is ahead of
    /// the *week*. Amber, display-only, fires nothing.
    case limitAheadOfPace = "limit_ahead_of_pace"
    /// Rank 5b (REV-96 §2.3 — STEP_194): a long limit at or past the nearly-spent line. Red, and
    /// the only long-limit rank that notifies (event 9, once per limit instance).
    case limitNearlySpent = "limit_nearly_spent"
    case atRisk = "at_risk"
    case badTiming = "bad_timing"
    case overQuota = "over_quota"
    case fastBurnSpike = "fast_burn_spike"
    case offMachineBurn = "off_machine_burn"
    case multiSurface = "multi_surface"
    case nullWindow = "null_window"
    case idleFallback = "idle_fallback"
    case spendControl = "spend_control"

    /// Severity ordering for the §15.1 default-tab selection and §13.4 dominant-agent
    /// comparison: lower rank = higher urgency. This is the §13 priority list read as
    /// *urgency* — the §13 list's leading Idle/fallback entry is the no-data guard, not a
    /// high-urgency signal, so here Idle/fallback ranks least urgent (both-idle tie-breaks
    /// to the Claude tab per §15.1).
    public var priorityRank: Int {
        switch self {
        case .spendControl:     return 1
        case .overQuota:        return 2
        case .atRisk:           return 3
        case .badTiming:        return 4
        // Rank 5b sits here (REV-96 §2.3): a five-hour *red* state still speaks first, a
        // five-hour amber does not — a limit about to stop you outranks Elevated.
        case .limitNearlySpent: return 5
        case .fastBurnSpike:    return 6
        case .offMachineBurn:   return 7
        case .multiSurface:     return 8
        case .elevated:         return 9
        case .limitAheadOfPace: return 10
        case .healthy:          return 11
        case .nullWindow:       return 12
        case .idleFallback:     return 13
        }
    }

    /// The warning tier: the states whose display is a warning to the user (UI Spec §4 "previous
    /// state was warning"). One home for the definition — `NotificationEngine` arms the pre-reset
    /// warning off it, and `ForecastLogRecorder` stamps `forecast_log.warning_first_shown_at` off
    /// the same set, so the notifier and the grading substrate can never disagree about what
    /// counts as a warning (STEP_188 — REV-95 §3.2).
    /// **Rank 5b is deliberately not a member** (owner ruling 2026-09-14, STEP_194). Both readers
    /// are about the *primary* window: a spent weekly is no reason to arm a five-hour pre-reset
    /// banner, and `warning_first_shown_at` is scoped to the current primary-window instance —
    /// adding a state to this set two weeks into STEP_191's grading would change the substrate
    /// under a running experiment.
    public static let warningStates: Set<AppState> = [.atRisk, .badTiming, .overQuota, .spendControl]

    /// Raw values this enum no longer emits, and what a stored one means now (REV-96 §5.4 —
    /// STEP_194). `weekly_elevated` was rank 10 until this step; every `state_transitions` row
    /// written before it keeps that string, and nothing rewrites them (no migration). A reader
    /// that decodes a stored state goes through `init(storedRawValue:)` so history stays legible.
    public static let retiredRawValues: [String: AppState] = [
        "weekly_elevated": .limitAheadOfPace,
    ]

    /// Decodes a state as **stored**, accepting the retired vocabulary above. Use this for
    /// anything read back out of `state_transitions`; `init(rawValue:)` stays the strict
    /// round-trip for values this build writes.
    public init?(storedRawValue raw: String) {
        if let state = AppState(rawValue: raw) { self = state; return }
        guard let state = Self.retiredRawValues[raw] else { return nil }
        self = state
    }

    /// Whether this state is warning-tier — see `warningStates`.
    public var isWarningTier: Bool { Self.warningStates.contains(self) }

    /// The two directly-observed hard blocks (§13 ranks 2/3: Spend control, Over quota) — the one
    /// class of verdict that survives staleness (REV-33): utilization is monotone within a window,
    /// so a consummated block is a fact with an expiry (`resets_at`), not a decaying estimate.
    /// Every rate-derived state (and Bad timing, deliberately) still clears at the §9.3 TTL.
    public var isHardBlock: Bool {
        self == .overQuota || self == .spendControl
    }
}

/// What caused a state evaluation (Baseline §13.1). Persisted in `state_transitions.triggered_by`.
public enum StateTrigger: String, Sendable, Equatable {
    /// Trigger 1 — a successful account poll completed (primary trigger).
    case poll
    /// Trigger 2 — a meaningful JSONL delta, debounced 5s.
    case jsonlDelta = "jsonl_delta"
    /// A poll attempt failed or was rate-limited — re-evaluate cached state so the §9.3
    /// cached-state TTL and the crossed-`resets_at` cache invalidation can fire. Never
    /// refreshes the cached-state clock.
    case pollFailure = "poll_failure"
    /// Launch restore of the newest persisted `poll_snapshots` row (REV-33, R33-1/R33-3):
    /// classifies the restored snapshot (a stale hard block keeps its verdict) and seeds the
    /// engine's `lastPrimaryResetsAt` anchor. Never refreshes the cached-state clock, never
    /// seeds the forecast buffer — restored data must not impersonate a live poll (STEP_32).
    case restore
}

/// Produced on every state transition (Baseline §13.2). Returned from `StateEngine.evaluate`
/// as `StateEvaluation.change` and handed to `NotificationEngine.evaluateCycle` to drive
/// Path 1 (transition-based) notifications (STEP_28 — the former `stateChanges` bus made
/// Path 1 race the same cycle's Path 2 signal, defeating the §16 no-stacking arbitration).
///
/// The event is self-contained: it carries the copy/gating context Path 1 needs (runway, reset
/// time, credits toggle) so the consuming actor never has to reach back for a possibly-stale
/// snapshot.
public struct StateChange: Sendable, Equatable {
    public let tool: Tool
    public let previous: AppState
    public let new: AppState
    /// Account utilization% at the transition, if known — logged and stored for debugging.
    public let utilizationPct: Double?
    /// Runway minutes from `ForecastEngine` at the transition — over/at-risk copy.
    public let runwayMinutes: Double?
    /// Primary-window reset time at the transition — reset-countdown copy and `window_start` key.
    public let resetsAt: Date?
    /// Provider-reported width of the primary window in seconds, carried so `NotificationEngine`
    /// can bucket the per-window cap on the window that actually exists (REV-59 §5). `nil` on
    /// Claude, which reports no width — the engine falls back to five hours there, which is what
    /// Claude's windows genuinely are.
    public let primaryWindowSeconds: Int?
    /// True when this transition happened on the §11.3 low-allowance shape
    /// (`QuotaSnapshot.isLowAllowanceShape`). Carried rather than re-derived because
    /// `NotificationEngine` never sees a snapshot — it sees only this and the poll signal.
    public let isLowAllowanceShape: Bool
    /// Claude `extra_usage.is_enabled` — selects the over-quota copy variant (§7.1). Nil for Codex.
    public let extraUsageEnabled: Bool?
    /// Claude `extra_usage.used_credits` at the transition — over-quota case 1/2 dollar copy
    /// (UI Spec §4.1). Nil for Codex / when never populated. STEP_27.
    public let extraUsageUsedCredits: Decimal?
    /// Claude `extra_usage.monthly_limit` (minor units) at the transition. STEP_27.
    public let extraUsageMonthlyLimit: Int?
    /// True when `extraUsageUsedCredits` came from the §7.1 cached-value rule — copy must say
    /// "last observed" (case 2). STEP_27.
    public let extraUsageIsCached: Bool
    /// The §2.4a card state at the transition (REV-102 §2.6 — STEP_221): `capReached` is what
    /// keeps the over-quota banner from saying credits are paying over a spent cap. The same
    /// `MoneyModel.moneyState` the card, the verdict and the recommendation box read. Nil for Codex.
    public let moneyState: MoneyState?
    /// Currency and minor-unit exponent of the credits amounts, so the banner prints the
    /// provider's money (REV-102 §2.5). Nil ⇒ USD / cents, as everywhere else.
    public let extraUsageCurrency: String?
    public let extraUsageCurrencyExponent: Int?
    /// The block this transition belongs to, when it is one (REV-96 §2.1 — STEP_193). It is what
    /// the Over-quota / Spend-control cap is keyed on, replacing the five-hour `window_start`
    /// bucket that re-armed the banner on every rollover. Carried on the *change* and not only on
    /// the poll signal because the launch-restore path calls `evaluateCycle(change:signal: nil)` —
    /// and firing nothing on a relaunch inside an episode is half the point.
    public let blockEpisode: BlockEpisode?
    /// The worst long limit at this transition (REV-96 §2.2 — STEP_194) — event 9's whole input.
    /// Carried on the change rather than looked up later because `NotificationEngine` never sees
    /// a snapshot, and the body has to name the limit, what is left of it and how long its period
    /// still has to run.
    public let longLimit: LongLimitAssessment?

    public init(
        tool: Tool,
        previous: AppState,
        new: AppState,
        utilizationPct: Double?,
        runwayMinutes: Double? = nil,
        resetsAt: Date? = nil,
        primaryWindowSeconds: Int? = nil,
        isLowAllowanceShape: Bool = false,
        extraUsageEnabled: Bool? = nil,
        extraUsageUsedCredits: Decimal? = nil,
        extraUsageMonthlyLimit: Int? = nil,
        extraUsageIsCached: Bool = false,
        moneyState: MoneyState? = nil,
        extraUsageCurrency: String? = nil,
        extraUsageCurrencyExponent: Int? = nil,
        blockEpisode: BlockEpisode? = nil,
        longLimit: LongLimitAssessment? = nil
    ) {
        self.tool = tool
        self.previous = previous
        self.new = new
        self.utilizationPct = utilizationPct
        self.runwayMinutes = runwayMinutes
        self.resetsAt = resetsAt
        self.primaryWindowSeconds = primaryWindowSeconds
        self.isLowAllowanceShape = isLowAllowanceShape
        self.extraUsageEnabled = extraUsageEnabled
        self.extraUsageUsedCredits = extraUsageUsedCredits
        self.extraUsageMonthlyLimit = extraUsageMonthlyLimit
        self.extraUsageIsCached = extraUsageIsCached
        self.moneyState = moneyState
        self.extraUsageCurrency = extraUsageCurrency
        self.extraUsageCurrencyExponent = extraUsageCurrencyExponent
        self.blockEpisode = blockEpisode
        self.longLimit = longLimit
    }
}

/// Result of one `StateEngine.evaluate` call: the classified state plus the transition it
/// caused, if any — `nil` when the state did not change, and on a tool's first evaluation
/// (established silently, so launching *into* a warning state never notifies, UI Spec §4.2)
/// **except** a first evaluation landing directly in a hard block, which is emitted as a
/// transition from `.idleFallback` (R33-6 — a cold launch into a blocked window is not silent;
/// the persisted per-window notification cap dedupes across relaunches).
/// Carrying the change on the return value lets the caller hand it to the same
/// `NotificationEngine.evaluateCycle` as the poll signal, so Path 1 and Path 2 are arbitrated
/// atomically (STEP_28).
public struct StateEvaluation: Sendable {
    public let state: AppState
    public let change: StateChange?
    /// §1.6 menu-bar money glyph after this evaluation, hysteresis-settled. Carried in-band
    /// (not a separate engine query) so the caller applies state and glyph from the same cycle —
    /// a second `await` would reopen the read-then-race the STEP_28 return-value design closed.
    /// Always `.none` for Codex. REV-29.
    ///
    /// *(A `dominantTool` field sat beside this one until D-98 / REV-78 retired the Adaptive
    /// display mode; nothing consumed it once the mode was gone.)*
    public let moneyGlyph: MoneyGlyph
    /// The block this evaluation is inside, if any (STEP_193) — derived from the *degraded*
    /// snapshot the engine actually classified, so the coordinator never re-derives it from a
    /// snapshot that has not been through `degradingExpiredWindows`.
    public let blockEpisode: BlockEpisode?

    public init(state: AppState, change: StateChange?, moneyGlyph: MoneyGlyph = .none,
                blockEpisode: BlockEpisode? = nil) {
        self.state = state
        self.change = change
        self.moneyGlyph = moneyGlyph
        self.blockEpisode = blockEpisode
    }
}
