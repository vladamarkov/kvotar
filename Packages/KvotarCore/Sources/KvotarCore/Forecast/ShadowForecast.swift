import Foundation

/// The §11.5 shadow outputs for one evaluation — an adaptive short/long burn rate, the probability
/// that utilization rises measurably in the next half hour, and the 10th/90th percentile of that
/// rise (REV-95 §3.3 — STEP_190).
///
/// **Displayed nowhere. Gates nothing. Notifies nothing.** It is written to `forecast_log` beside
/// the shipped runway so STEP_191 can grade the two against each other on identical inputs and
/// identical behavioural conditions, under the unchanged UI (REV-95 §4). The shipped `Forecast`
/// deliberately does **not** carry these values: `StateEngine`, `DisplayFormatter` and
/// `NotificationEngine` all take `Forecast`, so the type system is what guarantees the shadow
/// cannot reach a surface.
///
/// A `nil` shadow is a gradable prediction ("the app could say nothing here"); a re-served one is
/// corrupt data (REV-54 §7). Nothing is ever carried forward from a previous evaluation.
public struct ShadowForecast: Sendable, Equatable {

    /// Which generation of the §11.5 computation produced this row. A grader must be able to
    /// separate generations — the `app_version` rule applied to the shadow (REV-95 §3.2).
    public let version: String
    /// `alpha·short_rate + (1−alpha)·long_rate`, in percentage points per minute.
    public let blendRate: Double
    /// P(primary used % rises ≥ 1 point in the next 30 minutes), 0–1.
    public let riseProbability: Double
    /// Empirical 10th percentile of the 30-minute rise, in points.
    public let riseP10: Double
    /// Empirical 90th percentile of the 30-minute rise, in points.
    public let riseP90: Double

    public init(version: String, blendRate: Double, riseProbability: Double,
                riseP10: Double, riseP90: Double) {
        self.version = version
        self.blendRate = blendRate
        self.riseProbability = riseProbability
        self.riseP10 = riseP10
        self.riseP90 = riseP90
    }
}

/// How the account itself was moving at an origin — the one conditioning variable §11.5 uses.
///
/// Local activity is **not** an input in this revision (REV-95 §5): it adds ~0.01 AUC on Claude,
/// and its provenance is unresolved (Spike D F10 — `local_usage_events.recorded_at` is the JSONL
/// stamp, and backfill imports late under the original stamp, so a replay can "see" work the
/// running app had not yet ingested). STEP_191 grades it as a candidate column from the faithful
/// `quota_series.last_local_activity_at`, which is not what this enum reads.
public enum ShadowAccountState: String, Sendable, Equatable, CaseIterable {
    /// Used % moved ≥ 1 point in the last 10 minutes.
    case burning
    /// It did not, but it moved ≥ 1 point in the last 30 minutes.
    case paused
    /// Neither.
    case quiet
}

/// Weighted empirical quantiles over `(value, weight)` pairs — the §11.5 range, and a direct port
/// of the reference implementation's `weighted_quantile` (`forecast_models.py`, the worktree
/// experiment REV-95 §1.3 was measured with). Kept as a free function so both the live path and
/// the training fold use one definition. No library, no model file.
enum ShadowQuantile {

    /// The smallest value whose cumulative weight reaches `q` of the total. Empty ⇒ 0.
    static func weighted(_ items: [(value: Double, weight: Double)], _ q: Double) -> Double {
        guard !items.isEmpty else { return 0 }
        let ordered = items.sorted { $0.value < $1.value }
        let total = ordered.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return ordered[ordered.count / 2].value }
        let target = q * total
        var running = 0.0
        for item in ordered {
            running += item.weight
            if running >= target { return item.value }
        }
        return ordered[ordered.count - 1].value
    }

    /// Linear-interpolated quantile over unweighted values — used to compress a training
    /// distribution into representative points. Empty ⇒ 0.
    static func plain(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let ordered = values.sorted()
        let pos = Double(ordered.count - 1) * q
        let low = Int(pos.rounded(.down))
        let high = min(low + 1, ordered.count - 1)
        return ordered[low] + (ordered[high] - ordered[low]) * (pos - Double(low))
    }
}
