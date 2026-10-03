import Foundation

/// Pure §9.2/§9.3 poll-cadence policy — one instance per tool/endpoint, owned by the poll
/// driver. It performs no I/O and takes both the jitter and the clock (`now:`) as arguments, so
/// tests stay deterministic without a fake clock (the same seam `ResetBoundaryPolicy` and
/// `FirstPollGracePolicy` already use).
///
/// **The steady base is a constant** (v5.22 — REV-39 / STEP_45). It is never escalated and never
/// persisted: `defaultBase` (120 s since STEP_169 — see its doc comment) ± jitter, always. The STEP_37/R31-1 model — a `sessionBase`
/// mutated by 429s, written to the `settings` KV table, and demoted one level per 100 clean
/// polls — is gone. It was built as a congestion controller for *our own* volume, and three
/// weeks of forensics show it was mostly fighting something else while pinning this machine at a
/// 5-minute cadence indefinitely, blind spot included at wake. A never-elevated base also
/// *dissolves* the R31-1 restart-thrash bug (there is no durable elevated state left to reset)
/// rather than patching it with persistence.
///
/// **A 429 delays only the next polls** (§9.3): a transient in-memory ladder
/// `[defaultBase, retryCadence]` and **wall-clock recovery** — one rung per `ladderHalfLife`
/// (15 min) without a 429. Since STEP_169 both rungs are 120 s, so the rung no longer slows the
/// cadence; it is the *flag* that a refusal is recent, which is what raises the §9.2 floor for
/// wake / tripwire / alignment (`isElevated`, keyed on the rung, not on the delay). There is
/// deliberately **no** second, success-count-based demotion path: a counter keyed on successes
/// is exactly the poll-count recovery this design removes, and two demotion mechanisms are what
/// would let the cadence oscillate.
///
/// **The zero-`Retry-After` 429 is a shared allowance, not load-shed** (STEP_166, spike A
/// 2026-09-06). The Claude OAuth usage endpoint grants the whole account one successful call per
/// `retryCadence` (120 s) on a fixed clock, banks a few calls while idle, answers everything else
/// `429 Retry-After: 0`, and does not penalise rejected requests. Against that shape the REV-39
/// ladder was wrong at both ends: the 5 s first retry failed in 53 of 55 logged bursts (a wasted
/// request every time) and the 300 s rung surrendered four refills per wait to whoever else was
/// calling (Claude Code polls the same endpoint). So a rate-shaped 429 now waits the refill period
/// straight away, holds it for one half-life, and never climbs past it. Non-zero `Retry-After`
/// values keep their REV-39 shape untouched — the Enterprise `2009` was a real cooldown.
///
/// **Rate-shaped only** (§9.1). Network/decode/5xx failures keep `failed(...)` at the current
/// rung; credential-shaped rejections never reach this type at all (STEP_48 routes them away in
/// `PollCoordinator`, so an expired token can never be read as rate pressure).
public struct PollBackoffPolicy: Sendable, Equatable {

    /// Base cadence between successful polls (§9.2), both tools. Fixed — REV-39 removed every
    /// path that could change it. **120 s since STEP_169 (REV-89, 2026-09-08; P1-13 re-resolved).**
    /// The Claude usage endpoint grants the *account* roughly one success per 120–180 s, shared
    /// with every Claude Code process, on top of a ~45-request bank; at 60 s the bank emptied
    /// inside an hour of work and the refusals then ran past the 10-minute TTL into
    /// "Reconnecting…" (the tester's 14-refusal streak, 2026-09-07). Spike C on his Mac, Claude
    /// Code in normal use: 60 s → 35 of 90 refused, 90 s → 10 of 54, **120 s → 1 of 44**,
    /// 180 s → 0 of 30. 120 s is the first cadence inside the refill rate. Freshness at the
    /// moments that matter is carried by the §9.2 one-shots (JSONL tripwire on session start,
    /// reset-boundary refresh), not by the base — which is the idle floor.
    public static let defaultBase: TimeInterval = 120
    /// Age past which the popover's `· Ns ago` freshness stamp turns amber (UI Spec §2.2a, D-21
    /// / D-112): two base ticks — one missed poll — derived from the base so the two cannot
    /// desync. At `defaultBase` itself the stamp would flick amber for the jitter seconds before
    /// every scheduled poll while the popover is open.
    public static let freshnessAmberAge: TimeInterval = defaultBase * 2
    /// Steady-state cadence floor (§9.2). Does not apply to the one-shot post-429 recovery
    /// wait, which is server-sanctioned and immediately followed by normal cadence.
    public static let minInterval: TimeInterval = 45
    /// Steady-state cadence ceiling (§9.2 "never slower than 5 minutes"). Clamp only — no longer
    /// a rung (STEP_166).
    public static let maxInterval: TimeInterval = 300
    /// Floor for a *non-zero* 429 `Retry-After` wait (§9.3). A zero (the Claude usage endpoint's
    /// normal refusal) no longer takes this floor — it takes `retryCadence`; the adapters still
    /// read this constant to classify a 429 as `transient` vs `rate_pressure` (§9.5).
    public static let retryAfterFloor: TimeInterval = 5
    /// The allowance's refill period (STEP_166 — spike A, `docs/spikes/`): with nothing else
    /// calling, `/api/oauth/usage` answered 200 once every ~120 s across twelve runs, whether
    /// probed at 10 s spacing or left alone, and 60 s pacing got exactly every other request. A
    /// zero-`Retry-After` 429 waits this long, and the steady cadence holds here for one
    /// half-life afterwards — returning to 60 s straight away just collected the next refusal
    /// within three polls (the 20-minute cycle in the 2026-09-06 log).
    public static let retryCadence: TimeInterval = 120
    /// Cap on the **first** 429's honored `Retry-After` (§9.3 — R31-2): a singleton
    /// `Retry-After: 3600` once froze the whole Claude side for an hour (confidently-wrong for
    /// ~30 min of it), and the capped probe recovered 55 minutes early because the value was
    /// bogus — an external client's ban, not ours (P1-12). Kept by user ruling 2026-09-08
    /// (STEP_168): the capped probe costs one request per lockout. What changed is that the
    /// wait is now also a **hold** (`holdUntil`) every automatic trigger respects and a relaunch
    /// restores, and that a credential rotation — the only early recovery in the tester's 35
    /// lockouts — is the one sanctioned reason to probe before it elapses.
    public static let retryAfterCap: TimeInterval = 600
    /// Cap on a **repeat** 429's honored `Retry-After` (v5.22 — REV-39 §5.5 / Change E).
    /// When the probe that follows the capped first wait is refused *again* with a non-zero
    /// countdown, the server has said it twice: honor the advertised cooldown in full rather
    /// than probing inside it (the Enterprise tester's `2009` ≈ 33.5 min was genuine — the
    /// endpoint returned 200 only once it elapsed, and repeated in-cooldown probes may extend
    /// provider cooldowns). The ceiling bounds a bogus repeat at one hour rather than a day.
    public static let retryAfterAbsoluteCap: TimeInterval = 3600
    /// The transient 429 ladder (§9.3). Rung 0 **is** the base — the ladder never mutates it.
    /// Two rungs since STEP_166: the 300 s rung is gone (a zero `Retry-After` never waits longer
    /// than the refill period; `maxInterval` survives only as the steady-state clamp). Since
    /// STEP_169 the base equals `retryCadence`, so both rungs read 120 s: rung 1 is kept as the
    /// "refused recently" flag that `isElevated` and `baseIntervalAtTime` report, not as a
    /// slower cadence.
    public static let ladder: [TimeInterval] = [defaultBase, retryCadence]
    /// Wall-clock recovery: one rung down per this much quiet time (§9.3). Chosen against the
    /// `retry-after: 0` short-bucket shape — a bucket that refills at `retryCadence` banks a few
    /// calls again in 15 minutes of silence, enough for a spell at the base. Escalate fast,
    /// demote moderate.
    public static let ladderHalfLife: TimeInterval = 900

    /// Consecutive 429s since the last successful poll (§9.3 ladder position). Transient — a
    /// restart correctly starts at 0, and nothing about the ladder outlives the process.
    public private(set) var consecutive429s: Int = 0
    /// Position in `ladder`. 0 = the fixed base; never persisted.
    private var rung: Int = 0
    /// When the current rung was entered — the anchor wall-clock recovery decays against.
    private var rungEnteredAt: Date?
    /// The server-advertised cooldown in force (STEP_168 / REV-88): set by a **non-zero**
    /// `Retry-After` to the scheduled probe time (the capped first wait, the full repeat wait),
    /// cleared by a success. Unlike the rung it is a deadline, not a cadence: every automatic
    /// trigger (wake, tripwire, turn-boundary alignment) is gated on `isHeld` before its floor
    /// comparison, and the coordinator persists it so a relaunch waits it out instead of polling
    /// at once. A zero `Retry-After` never sets one — that refusal is the refill clock, not a ban.
    public private(set) var holdUntil: Date?

    /// One ladder step after a 429. `waitSeconds` is the exact recovery wait (exempt from
    /// `minInterval`); the counts feed `poll_health_events` (§9.5).
    public struct RateLimitStep: Sendable, Equatable {
        public let waitSeconds: TimeInterval
        public let consecutiveCount: Int
        /// The poll interval in effect when the 429 arrived — since REV-39 this is the
        /// **transient rung**, not a persisted base. The column's meaning in `poll_health_events`
        /// is unchanged, so the 90-day corpus stays comparable.
        public let baseIntervalAtTime: Int
    }

    /// Next delay after a successful poll. `recovered` is true on the first success after
    /// one or more 429s — log the recovery (§9.3 step 4), once.
    public struct SuccessStep: Sendable, Equatable {
        public let delay: TimeInterval
        public let recovered: Bool
    }

    public init() {}

    /// Advances the ladder for one received 429 and returns the recovery wait.
    ///
    /// Two shapes (§9.1 taxonomy, STEP_166):
    ///
    /// - **Rate-shaped — `Retry-After` zero or absent** (the Claude usage endpoint's normal
    ///   refusal; the adapter maps an absent header to 120 before it reaches here). The shared
    ///   allowance is empty and refills on a ~120 s clock, so the wait is `retryCadence` from the
    ///   *first* refusal — never the 5 s floor (failed in 53 of 55 bursts), never 300 s (four
    ///   refills surrendered per wait). The rung is entered at once and decays on the wall clock.
    /// - **A non-zero advertised countdown** keeps the REV-39 shape byte-for-byte: the first 429
    ///   honors `min(value, retryAfterCap)` and does not elevate the steady interval; from the
    ///   second consecutive 429 the rung floors the wait (burst damping) and the advertised value
    ///   is honored up to `retryAfterAbsoluteCap` (Change E — the genuine Enterprise `2009`).
    public mutating func rateLimited(retryAfter: Int, now: Date) -> RateLimitStep {
        decay(now: now)              // weigh recovery earned so far before adding this evidence
        consecutive429s += 1
        let rateShaped = retryAfter <= 0
        let holdsTheRung = rateShaped || consecutive429s >= 2
        if holdsTheRung { rung = Self.ladder.count - 1 }
        if rung > 0 { rungEnteredAt = now }
        let cap = consecutive429s == 1 ? Self.retryAfterCap : Self.retryAfterAbsoluteCap
        var wait = max(Self.retryAfterFloor, min(TimeInterval(retryAfter), cap))
        if holdsTheRung { wait = max(wait, Self.ladder[rung]) }
        // The hold is the scheduled probe time (STEP_168): the tester's 35 lockouts all carried a
        // countdown that held to the second, and the in-cooldown probes the trigger paths sent
        // (1–7 per lockout) bought nothing. A zero refusal clears any hold rather than extending it.
        holdUntil = rateShaped ? nil : now.addingTimeInterval(wait)
        return RateLimitStep(waitSeconds: wait,
                             consecutiveCount: consecutive429s,
                             baseIntervalAtTime: Int(Self.ladder[rung]))
    }

    /// Resets the consecutive count, applies wall-clock recovery, and returns the next
    /// steady-state delay. A success by itself does **not** demote a rung — only elapsed quiet
    /// time does (see the type doc: one demotion mechanism, not two).
    public mutating func succeeded(jitter: TimeInterval, now: Date) -> SuccessStep {
        let recovered = consecutive429s > 0
        consecutive429s = 0
        holdUntil = nil
        decay(now: now)
        return SuccessStep(delay: Self.clamped(Self.ladder[rung] + jitter), recovered: recovered)
    }

    // MARK: Advertised cooldown — the hold (§9.3, STEP_168 / REV-88)

    /// True while a server-advertised cooldown is pending. Automatic triggers must not poll.
    public func isHeld(now: Date) -> Bool {
        guard let holdUntil else { return false }
        return holdUntil > now
    }

    /// Seconds left on the hold; 0 when none is pending.
    public func holdRemaining(now: Date) -> TimeInterval {
        guard let holdUntil else { return 0 }
        return max(0, holdUntil.timeIntervalSince(now))
    }

    /// Drops the hold without touching the rung — the credential rotated, which is the one
    /// sanctioned reason to probe before the deadline (the tester's only early recovery in 35).
    public mutating func clearHold() { holdUntil = nil }

    /// Launch restore: re-arms a hold the previous process persisted. A past value is a no-op; a
    /// future one is clamped to `retryAfterAbsoluteCap` from `now` (a hand-edited or skewed row
    /// can cost at most an hour, never a day). Never touches the rung or the consecutive count —
    /// those are the transient ladder and correctly start at zero (REV-39).
    public mutating func seedHold(until: Date, now: Date) {
        guard until > now else { return }
        holdUntil = min(until, now.addingTimeInterval(Self.retryAfterAbsoluteCap))
    }

    /// Next delay after a non-429 failure. The consecutive-429 count is deliberately kept — a
    /// network/decode/5xx error between two 429s must not reset the ladder; only a success does.
    /// Wall-clock recovery still applies: the rung decays with *time*, not with poll outcomes.
    public mutating func failed(jitter: TimeInterval, now: Date) -> TimeInterval {
        decay(now: now)
        return Self.clamped(Self.ladder[rung] + jitter)
    }

    /// The steady interval currently in effect, with recovery applied but nothing mutated —
    /// read by `PollCoordinator.wakeRefresh` so a wake never cuts short a post-429 ladder wait
    /// and re-hits the contended endpoint (§9.2 wake floor, STEP_42's lesson).
    public func steadyDelay(now: Date) -> TimeInterval {
        var probe = self
        probe.decay(now: now)
        return Self.ladder[probe.rung]
    }

    /// True while the transient ladder is on a rung above the base — the only trigger for the
    /// §9.2 wake / tripwire / alignment floor. Keyed on the **rung**, not on the delay (STEP_169):
    /// with the base at `retryCadence` the two rungs carry the same delay, and a delay comparison
    /// would go permanently false — letting a tripwire fire 45 s into an endpoint that just
    /// refused us, the exact re-hit the floor exists to prevent.
    public func isElevated(now: Date) -> Bool {
        var probe = self
        probe.decay(now: now)
        return probe.rung > 0
    }

    /// R33-5 (§9.2 "the poll clock is durable too"): delay for the *first* poll after launch.
    /// A relaunch once polled 4 seconds after the outgoing process (which had just 429'd) and
    /// collected three more 429s. `age` is `now − polled_at` of the tool's newest persisted
    /// snapshot; poll immediately when none exists (first run) or when `age ≥ base` (the app was
    /// closed a while). A negative age (clock skew) waits the full base rather than trusting it.
    /// The delayed first poll costs nothing: the popover is already rendering the restored
    /// snapshot. Unchanged by REV-39 — only the `base` it is called with is now always
    /// `defaultBase`.
    public static func firstPollDelay(age: TimeInterval?, base: TimeInterval) -> TimeInterval {
        guard let age else { return 0 }
        return max(0, min(base, base - age))
    }

    /// One rung down per `ladderHalfLife` of quiet. The anchor advances by exactly one half-life
    /// per step (not to `now`), so a long gap drops several rungs in one call and no remainder
    /// time is silently discarded.
    private mutating func decay(now: Date) {
        while rung > 0, let entered = rungEnteredAt,
              now.timeIntervalSince(entered) >= Self.ladderHalfLife {
            rung -= 1
            rungEnteredAt = entered.addingTimeInterval(Self.ladderHalfLife)
        }
        if rung == 0 { rungEnteredAt = nil }
    }

    private static func clamped(_ interval: TimeInterval) -> TimeInterval {
        min(maxInterval, max(minInterval, interval))
    }
}
