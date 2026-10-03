import Foundation

/// One persisted `poll_snapshots` monthly-meter reading — the input to the trailing spend rate
/// (REV-47 §2.2). `usedAmount` is raw units in the meter's native scale; `resetsAt` identifies
/// the cycle the sample belongs to (Claude: derived calendar-month, Codex: server-provided).
public struct MonthlyUsedSample: Sendable, Equatable {
    public let polledAt: Date
    public let usedAmount: Double
    public let resetsAt: Date?

    public init(polledAt: Date, usedAmount: Double, resetsAt: Date?) {
        self.polledAt = polledAt
        self.usedAmount = usedAmount
        self.resetsAt = resetsAt
    }
}

/// Pure trailing spend-rate computation over persisted monthly-meter samples — deliberate
/// lumpiness-armor (REV-47 §2.2): if the server batches spend updates, an instantaneous
/// two-poll rate is noise, a trailing one is still correct.
public enum MonthlySpendRate {

    /// Minimum sample span for a rate claim — below it the rate is nil (unknown, never zero;
    /// the §11.2a discipline). SPIKE ruling 2026-07-21 (REV-48 §7, user ruling): **1800s, one
    /// shared constant for both tools** (supersedes the 900s placeholder).
    public static let monthlyRateMinSpan: TimeInterval = 1800

    /// A sample's `resetsAt` may differ from the newest sample's by this much and still count as
    /// the same cycle (derivation/endpoint wobble — mirrors the estimator's anchor tolerance).
    static let resetJitterTolerance: TimeInterval = 60

    /// The trailing per-hour spend rate in raw units, or nil when unknown (§11.2a: unknown ≠
    /// zero). Only current-cycle samples count (same `resetsAt` as the newest, ±60s); a negative
    /// used-delta disqualifies the span — whether rollover or the SPIKE's eventual-consistency
    /// dips, the rate is nil, never negative. A measured zero over a sufficient span returns 0.
    public static func compute(samples: [MonthlyUsedSample]) -> Double? {
        let ordered = samples.sorted { $0.polledAt < $1.polledAt }
        guard let newest = ordered.last, let anchor = newest.resetsAt else { return nil }
        let cycle = ordered.filter {
            guard let r = $0.resetsAt else { return false }
            return abs(r.timeIntervalSince(anchor)) <= Self.resetJitterTolerance
        }
        guard let oldest = cycle.first, let latest = cycle.last else { return nil }
        let span = latest.polledAt.timeIntervalSince(oldest.polledAt)
        guard span >= Self.monthlyRateMinSpan else { return nil }
        let delta = latest.usedAmount - oldest.usedAmount
        guard delta >= 0 else { return nil }
        return delta / span * 3600
    }
}
