import Foundation

/// REV-15 (STEP_27): first-launch persistent-429 grace window.
///
/// §13.3's spirit — first-poll timeout → Idle/fallback — extended to persistent rate limiting:
/// a tool that has *never* succeeded and keeps 429ing must not sit on "Connecting…" forever
/// (observed 2026-07-05: an 11-min throttle read as "app broken"). After `grace` (default
/// 10 min, mirroring the §9.3 cached-state TTL) the caller drops the tool to Idle/fallback
/// while the §9.3 ladder keeps retrying quietly; the first success self-heals.
///
/// The grace window is required: the endpoint routinely 429s the *first* poll with
/// `Retry-After: 0` and recovers in seconds — that must not flash the fallback card.
///
/// Pure per-tool state machine so the policy is unit-testable; `PollCoordinator` owns the
/// wiring (calls `rateLimited` only while the tool has never succeeded).
public struct FirstPollGracePolicy: Sendable {
    private let grace: TimeInterval
    private var firstRateLimitedAt: [Tool: Date] = [:]

    public init(grace: TimeInterval = 600) {
        self.grace = grace
    }

    /// Records a 429 for `tool` and reports whether the grace window has expired —
    /// `true` means the caller should show Idle/fallback now.
    public mutating func rateLimited(tool: Tool, now: Date = Date()) -> Bool {
        let first = firstRateLimitedAt[tool] ?? now
        firstRateLimitedAt[tool] = first
        return now.timeIntervalSince(first) >= grace
    }

    /// Clears the window on a successful poll — a later throttle episode starts a fresh grace.
    public mutating func succeeded(tool: Tool) {
        firstRateLimitedAt[tool] = nil
    }
}
