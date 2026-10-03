import Foundation

/// Pure §9.2 null-after-hiatus expedite (REV-39 Change D, STEP_45) — one instance per tool, owned
/// by the poll driver. Third sibling to the STEP_38 pair: the JSONL tripwire is activity-driven,
/// the reset-boundary one-shot is time-driven, and this one is **observation**-driven.
///
/// The case it exists for, observed live 2026-07-16: the first poll after a long sleep came back
/// with a **null 5-hour window** at 09:31:10, the window had populated to 2% by 09:36:12, and the
/// app — parked at an elevated base — showed nothing at all for the whole 302-second gap. A null
/// window right after a hiatus is usually the provider not having re-materialized it yet, and it
/// is worth exactly one quick look, not a faster cadence.
///
/// **State-shaped, never rate-shaped** (§9.1). A null window is a benign "no window yet" signal,
/// not a rate limit: this policy must never advance, read, or be gated on the 429 ladder. It is
/// bounded by construction — exactly one expedited poll per hiatus, after which the loop falls
/// back to the base interval until a populated window re-arms it. Never a loop.
public struct NullWindowExpeditePolicy: Sendable, Equatable {

    /// A gap this long since the last *successful* poll marks the next poll as cold — a wake, a
    /// launch after a stretch away, or recovery from a run of failures. Mirrors
    /// `ClaudeAccountAdapter.coldPollThreshold` (STEP_42), which is set above the jittered
    /// steady-state maximum so an ordinary slow poll is never mistaken for a wake.
    public static let coldGap: TimeInterval = 330
    /// The expedited delay: the §9.2 floor, the fastest we may ever poll. **Exactly one** poll
    /// per hiatus — this fires at the most contended moment (wake, on a shared credential), so
    /// the guardrail is the count, not the interval.
    ///
    /// REV-39 Change D floated an optional bounded ladder (45s → 120s → base) as an alternative
    /// to a single shot. It is dropped, on arithmetic: with the base now fixed at 60s a second
    /// rung of 120s would be *slower* than simply waiting for the next scheduled poll. That
    /// ladder only ever made sense against the elevated persistent base this same step deletes.
    public static let expedite: TimeInterval = PollBackoffPolicy.minInterval

    /// Whether this hiatus has already spent its one expedited poll.
    private var fired = false

    public init() {}

    /// Called after a successful poll with the window the poll observed and the gap that
    /// preceded it. Returns the expedited delay to use instead of `plannedDelay`, or `nil` to
    /// keep the plan.
    ///
    /// - Parameters:
    ///   - primaryWindowIsNull: the poll returned no 5-hour window.
    ///   - gapSinceLastSuccess: `now − ` the previous *successful* poll (successes only, matching
    ///     the STEP_42 anchor). `nil` means there was no previous success — a first-ever poll on
    ///     a fresh install, which STEP_42 deliberately does not treat as a wake, so neither do we.
    ///   - plannedDelay: the steady-state delay the loop would otherwise sleep.
    public mutating func expediteDelay(primaryWindowIsNull: Bool,
                                       gapSinceLastSuccess: TimeInterval?,
                                       plannedDelay: TimeInterval) -> TimeInterval? {
        // A populated window ends the hiatus and re-arms the policy for the next one.
        guard primaryWindowIsNull else {
            fired = false
            return nil
        }
        guard !fired else { return nil }
        // Only a *cold* null is interesting. A null window on a warm poll is either an idle
        // account (the normal shape) or something no extra poll will resolve.
        guard let gap = gapSinceLastSuccess, gap > Self.coldGap else { return nil }
        // Nothing to expedite if the loop is already going back sooner than this.
        guard Self.expedite < plannedDelay else { return nil }
        fired = true
        return Self.expedite
    }
}
