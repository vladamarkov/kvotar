import Foundation

/// Which forecast tier the available data supports (Baseline §11.1). The tier is chosen by
/// `ForecastEngine` from what is present this poll — it is not a user setting.
public enum ForecastTier: String, Sendable, Equatable {
    /// Account quota window + burn-rate delta → real runway / reset / at-risk (§11.2, §11.3).
    case fullRunway
    /// Local burn/value but no quota denominator → pace/value only, no runway.
    case creditBased
    /// Insufficient data → grey fallback.
    case unknown
}

/// One forecast result for a single tool, produced by `ForecastEngine.forecast(for:)`.
///
/// `runwayMinutes` is `nil` whenever runway cannot or should not be shown: cold start with
/// 0–1 polls (§11.4), a near-zero burn rate (§11.2 — show reset countdown instead), or a
/// Codex null-window (§11.3 — suspend runway, display `—`). `isEstimate` mirrors the §11.4
/// `~est.` label shown during the 2–9 poll partial-average phase.
public struct Forecast: Sendable, Equatable {
    public let tool: Tool
    public let tier: ForecastTier
    /// Estimated minutes until the primary window is exhausted at the current pace, or `nil`
    /// when runway must not be shown (see type doc). Never negative.
    public let runwayMinutes: Double?
    /// The burn rate the runway divides by, or `nil` when unmeasured. On Claude's five-hour window
    /// this is the §11.5 blend — or the faster of the blend and the 18-minute rate at
    /// ≥ `StateEngine.atRiskUtilFloor` used (REV-105 / STEP_230); everywhere else, and wherever
    /// the blend has no value, it is the average utilization delta per minute over the rolling
    /// buffer.
    public let burnRatePerMin: Double?
    /// True during the 2–9 poll partial-average phase — surfaced as the `~est.` burn-rate label.
    public let isEstimate: Bool
    /// Number of polls recorded for this tool so far (drives cold-start behaviour, §11.4).
    public let pollCount: Int
    /// The first→last sample span the burn average covers, in minutes (STEP_110 / REV-67 D-73 —
    /// the verdict anatomy's "Burn (last 9m)" label). `nil` whenever `burnRatePerMin` is nil,
    /// and on every path that suppresses the burn output (null window, low-allowance, cold start).
    /// It is the span of the rate actually chosen (D-130): the rolling buffer's when the
    /// 18-minute rate was taken, the trailing hour's otherwise.
    public let burnSpanMinutes: Double?
    /// The 18-minute rate — the rolling buffer's average, whichever rate `burnRatePerMin` carries
    /// (REV-105 §2.4). `forecast_log.burn_rate_pct_per_min` keeps this meaning so both rates sit on
    /// every row; `ForecastLogRecorder` is its only reader. Equal to `burnRatePerMin` wherever
    /// the blend was not chosen.
    public let shortBurnRatePerMin: Double?

    public init(
        tool: Tool,
        tier: ForecastTier,
        runwayMinutes: Double?,
        burnRatePerMin: Double?,
        isEstimate: Bool,
        pollCount: Int,
        burnSpanMinutes: Double? = nil
    ) {
        self.tool = tool
        self.tier = tier
        self.runwayMinutes = runwayMinutes
        self.burnRatePerMin = burnRatePerMin
        self.isEstimate = isEstimate
        self.pollCount = pollCount
        self.burnSpanMinutes = burnSpanMinutes
        self.shortBurnRatePerMin = burnRatePerMin
    }

    /// The engine's own initialiser, for a forecast whose chosen rate may differ from the
    /// 18-minute one (REV-105 / STEP_230).
    init(
        tool: Tool,
        tier: ForecastTier,
        runwayMinutes: Double?,
        burnRatePerMin: Double?,
        isEstimate: Bool,
        pollCount: Int,
        burnSpanMinutes: Double?,
        shortBurnRatePerMin: Double?
    ) {
        self.tool = tool
        self.tier = tier
        self.runwayMinutes = runwayMinutes
        self.burnRatePerMin = burnRatePerMin
        self.isEstimate = isEstimate
        self.pollCount = pollCount
        self.burnSpanMinutes = burnSpanMinutes
        self.shortBurnRatePerMin = shortBurnRatePerMin
    }
}
