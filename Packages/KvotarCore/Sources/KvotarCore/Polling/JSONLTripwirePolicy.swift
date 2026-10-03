import Foundation

/// Pure §9.2 JSONL-tripwire policy (REV-31, STEP_38) — one instance per tool, owned by the poll
/// driver. Decides whether a `LocalDeltaSignal` marks the idle→active transition that should cut
/// the inter-poll sleeper short, so fresh account data lands seconds after the first turn of a
/// session instead of up to a full base interval later.
///
/// The transition is keyed off the gap between consecutive *delta signals* — a delta arriving
/// after ≥ `LocalAttribution.idleGap` of silence (or the first ever) trips. It is deliberately
/// not keyed off `AttributionEngine`'s `lastActivityAt`: the attribution ingestion task races the
/// delta task (separate streams), so at handling time that value may already include the batch
/// that produced the signal and read "active" — the tripwire would silently never fire. Gap
/// tracking can only over-fire (a busy session emitting no meaningful delta for the whole gap
/// trips once — a single floored poll), never under-fire.
///
/// The 45s floor (`PollBackoffPolicy.minInterval`) is checked against the previous poll so a
/// burst of flushes cannot hammer the (throttle-sensitive, REV-14) account endpoints; a trip
/// suppressed by the floor is not deferred — the next scheduled poll is already near.
public struct JSONLTripwirePolicy: Sendable, Equatable {

    /// Idle stretch that re-arms the tripwire — the REV-23 liveness gap (8 min).
    public static let idleGap: TimeInterval = LocalAttribution.idleGap

    /// Arrival time of the previous delta signal. `nil` until the first delta this launch.
    private var lastDeltaAt: Date?

    public init() {}

    /// Records one delta-signal arrival and returns whether the poll sleeper should be cancelled
    /// now. `lastPollAt` is the most recent poll attempt (falling back to the restored snapshot's
    /// poll time before the first in-process poll, so the R33-5 launch delay is not defeated).
    public mutating func deltaArrived(now: Date, lastPollAt: Date?) -> Bool {
        let idleBefore = lastDeltaAt.map { now.timeIntervalSince($0) >= Self.idleGap } ?? true
        lastDeltaAt = now
        guard idleBefore else { return false }
        if let lastPollAt, now.timeIntervalSince(lastPollAt) < PollBackoffPolicy.minInterval {
            return false
        }
        return true
    }
}
