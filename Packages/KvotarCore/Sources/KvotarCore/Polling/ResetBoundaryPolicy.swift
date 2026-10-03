import Foundation

/// Pure §9.2 reset-boundary one-shot policy (REV-32, STEP_38) — one instance per tool, owned by
/// the poll driver. After each successful poll: if a known window reset lands before the next
/// scheduled tick, the normal sleep is replaced with a single one-shot that fires at
/// `max(resets_at + 30s, now + 5s)` — the rollover is the one moment a scheduled-cadence poll is
/// systematically late, and a deterministic single request at the boundary beats polling faster
/// near it. Replacing the sleeper (rather than adding a timer) preserves the §9.2
/// single-timer-per-endpoint invariant.
///
/// Each boundary is attempted once. `pending` is set when a one-shot is scheduled; any later
/// call whose poll time has passed the pending boundary marks it consumed — however that poll
/// was triggered — so a post-rollover payload still carrying the old `resets_at` (the R33-7
/// shape) cannot loop the one-shot, while a tripwire/wake poll that cut the one-shot short
/// *before* the boundary leaves it pending and the one-shot re-arms.
public struct ResetBoundaryPolicy: Sendable, Equatable {

    /// Poll this long after the boundary so a lagging payload has rolled over server-side.
    public static let postResetDelay: TimeInterval = 30
    /// Minimum lead time when the boundary is already at hand.
    public static let minLead: TimeInterval = 5

    /// Boundary a one-shot has been scheduled for but not yet polled past.
    private var pending: Date?
    /// Boundary a poll has landed past — never scheduled again.
    private var consumed: Date?

    public init() {}

    /// Called after a successful poll at `now`, with the snapshot's reset times and the planned
    /// steady-state delay. Returns the one-shot delay to use instead, or `nil` to keep the plan.
    /// The candidate boundary is the sooner non-nil of the 5-hour primary and the weekly reset.
    public mutating func oneShotDelay(primaryResetsAt: Date?, weeklyResetsAt: Date?,
                                      now: Date, plannedDelay: TimeInterval) -> TimeInterval? {
        if let pending, now >= pending {
            consumed = pending
            self.pending = nil
        }
        guard let boundary = [primaryResetsAt, weeklyResetsAt].compactMap({ $0 }).min() else {
            return nil
        }
        guard boundary.timeIntervalSince(now) < plannedDelay else { return nil }
        if let consumed,
           abs(boundary.timeIntervalSince(consumed)) <= QuotaSnapshot.resetJitterTolerance {
            return nil
        }
        pending = boundary
        let delay = max(boundary.timeIntervalSince(now) + Self.postResetDelay, Self.minLead)
        // 45s floor against the previous poll — which is `now`, this being a post-success call.
        return max(delay, PollBackoffPolicy.minInterval)
    }
}
