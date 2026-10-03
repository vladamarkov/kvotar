import Foundation

/// Everything the `StateEngine` needs to classify one tool on one evaluation (Baseline §13).
///
/// Account data comes from the poll (`snapshot`, `health`) and runway from `forecast`. The
/// local-derived metrics are pre-computed by the caller (the future `AttributionEngine` /
/// Step 15 driver) so `StateEngine.classify` stays pure and unit-testable. A `nil` local metric
/// means "cannot confirm" — the dependent state is skipped rather than assumed.
public struct StateInputs: Sendable, Equatable {
    public let tool: Tool
    /// Latest normalized poll, or `nil` if no account data has ever been obtained for this tool.
    public let snapshot: QuotaSnapshot?
    /// Adapter health after the most recent fetch attempt (Baseline §9.3).
    public let health: AdapterHealth
    /// Runway/burn tier for this tool from `ForecastEngine`.
    public let forecast: Forecast
    /// What triggered this evaluation (Baseline §13.1).
    public let trigger: StateTrigger
    /// Evaluation time — reset-distance and staleness are measured against this.
    public let now: Date

    // MARK: Local-derived signals (supplied by the caller; `nil` = cannot confirm)
    /// Δ primary-window utilization between the two most recent polls, valid only while they sit
    /// within `ForecastEngine.fastBurnMaxPollGap` of each other and of now — the Fast-burn-spike
    /// signal (§13 rank 6). Cadence-independent since STEP_189; the 2-minute wall-clock window it
    /// replaced could not fill itself at the 120s base.
    public let fastBurnDelta: Double?
    /// Δ primary-window utilization across the two most recent polls — Off-machine rise signal.
    public let utilDeltaLast2Polls: Double?
    /// Local tokens attributed on this machine in the last 2 minutes — Off-machine idle floor.
    public let localTokensLast2Min: Int?
    /// Distinct active surface buckets this window — Multi-surface signal (Codex only).
    public let activeSurfaceBucketCount: Int
    /// Active subagent count — carried for completeness; not used in state selection.
    public let subagentCount: Int
    /// Most recent local JSONL activity for this tool — §13.4 dominant-agent tiebreaker 4.
    public let lastLocalActivityAt: Date?

    public init(
        tool: Tool,
        snapshot: QuotaSnapshot?,
        health: AdapterHealth,
        forecast: Forecast,
        trigger: StateTrigger,
        now: Date = Date(),
        fastBurnDelta: Double? = nil,
        utilDeltaLast2Polls: Double? = nil,
        localTokensLast2Min: Int? = nil,
        activeSurfaceBucketCount: Int = 0,
        subagentCount: Int = 0,
        lastLocalActivityAt: Date? = nil
    ) {
        self.tool = tool
        self.snapshot = snapshot
        self.health = health
        self.forecast = forecast
        self.trigger = trigger
        self.now = now
        self.fastBurnDelta = fastBurnDelta
        self.utilDeltaLast2Polls = utilDeltaLast2Polls
        self.localTokensLast2Min = localTokensLast2Min
        self.activeSurfaceBucketCount = activeSurfaceBucketCount
        self.subagentCount = subagentCount
        self.lastLocalActivityAt = lastLocalActivityAt
    }
}
