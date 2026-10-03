import Foundation

/// Pure §9.2 turn-boundary alignment one-shot (REV-53 §4, STEP_77) — one instance per tool, owned
/// by the poll driver. Fourth sibling to the STEP_38/STEP_45 trio: the JSONL tripwire fires on the
/// idle→active transition, the reset-boundary one-shot is time-driven, the null-window expedite is
/// observation-driven, and this one is driven by local activity **stopping**.
///
/// Why it exists. STEP_76's off-machine detection is a retrospective recompute whose resolution is
/// the poll interval: an interval with zero local token events banks its whole quota delta as exact
/// off-machine usage. The leading slice of every pause in local work — from the last turn to the
/// next scheduled poll — sits inside a token-bearing interval and is therefore unclassifiable. One
/// extra poll placed just after the activity stops turns that slice into a whole, classifiable
/// interval.
///
/// **Trailing edge, not leading edge.** The driver re-arms a `quietDelay` timer on every local
/// flush and only consults `fire` once that timer survives, so the poll lands at the front edge of
/// a real pause and never mid-burst. Firing on each turn instead would spend the whole per-window
/// cap in the first few minutes of a busy session, before any of the day's pauses happen.
///
/// **This is not A27.** A27 (activity-scaled continuous cadence) carries recorded rejections in
/// `docs/POLLING.md` §6. This is a bounded discrete one-shot on a discrete event — the
/// `ResetBoundaryPolicy` shape on a different trigger. The steady interval is never touched.
///
/// **Bounds, in the order they bind.** A window anchor must exist (no anchor ⇒ no `quota_series`
/// row ⇒ nothing to sharpen, which is what silences the Enterprise monthly layout on both tools);
/// at most one fire between two completed polls; at most `maxFiresPerWindow` per quota window; and
/// the driver's §9.2 floor, which rises to the ladder delay while the transient 429 ladder is
/// elevated (REV-39 Change C — cutting a ladder wait short to re-hit an endpoint that just refused
/// us is the eager re-hit STEP_42 warned about). If the soak ever shows request pressure, the
/// remedy lever is `maxFiresPerWindow`, never the floor.
public struct TurnBoundaryPolicy: Sendable, Equatable {

    /// Quiet stretch that marks a turn as finished. Equal to the §9.2 floor by construction — a
    /// fire may never land sooner than that anyway, so a shorter quiet stretch could only produce
    /// suppressed fires.
    public static let quietDelay: TimeInterval = PollBackoffPolicy.minInterval

    /// Fires allowed per quota window (dogfood-tunable, REV-53 §12). Six extra requests against a
    /// 5-hour window polled at a 60s base is ~2% more traffic.
    public static let maxFiresPerWindow = 6

    /// A flush whose newest event is older than this is a catch-up backlog, not a turn boundary —
    /// the periodic rescan (STEP_32) and per-file promotion both replay history with the line's
    /// own timestamp. Aligning a boundary to activity that ended long ago buys nothing and would
    /// spend a fire, so those flushes are ignored.
    public static let maxActivityAge: TimeInterval = 120

    /// `resets_at` of the window the fire count is counted against. `nil` until the first poll
    /// that observed a window.
    private var anchor: Date?
    /// Fires spent in the window `anchor` identifies.
    private var firesThisWindow = 0
    /// Set by every completed poll, cleared by every fire — "never two alignment polls between
    /// scheduled polls". Starts `false`: nothing may fire before the first poll of the launch,
    /// which is itself delayed to respect the persisted poll clock (R33-5).
    private var armed = false

    public init() {}

    /// One local JSONL flush landed. Returns the quiet delay after which the driver should
    /// consult `fire`, or `nil` when this flush cannot produce an alignment poll at all. Called
    /// on every flush; the driver replaces its pending timer each time, which is what makes the
    /// mechanism trailing-edge.
    ///
    /// - Parameters:
    ///   - now: flush observation time.
    ///   - latestEventAt: newest event timestamp in the flush — see `maxActivityAge`.
    public func activityObserved(now: Date, latestEventAt: Date) -> TimeInterval? {
        guard eligible else { return nil }
        guard now.timeIntervalSince(latestEventAt) <= Self.maxActivityAge else { return nil }
        return Self.quietDelay
    }

    /// The quiet timer survived — decide, and consume the bookkeeping. The eligibility checks are
    /// repeated here because a poll may have landed while the timer ran.
    ///
    /// - Parameters:
    ///   - lastPollAt: most recent poll attempt, or `nil` when none is on record.
    ///   - floor: the driver's §9.2 floor for this tool at `now` — the plain 45s minimum, raised
    ///     to the ladder delay while the transient 429 ladder is elevated.
    public mutating func fire(now: Date, lastPollAt: Date?, floor: TimeInterval) -> Bool {
        guard eligible else { return false }
        if let lastPollAt, now.timeIntervalSince(lastPollAt) < floor { return false }
        armed = false
        firesThisWindow += 1
        return true
    }

    /// Called after every completed poll with the window that poll observed. Re-arms, and re-anchors
    /// the cap: a `resets_at` differing from the anchor by more than the endpoint's jitter is a new
    /// window and refills the allowance. A `nil` window disarms — there is no series to align to.
    public mutating func pollCompleted(primaryResetsAt: Date?) {
        guard let resets = primaryResetsAt else {
            anchor = nil
            armed = false
            return
        }
        let sameWindow = anchor.map {
            abs(resets.timeIntervalSince($0)) <= QuotaSnapshot.resetJitterTolerance
        } ?? false
        if !sameWindow { firesThisWindow = 0 }
        anchor = resets
        armed = true
    }

    /// Fires left in this window, for the log line.
    public var firesSpentThisWindow: Int { firesThisWindow }

    private var eligible: Bool {
        anchor != nil && armed && firesThisWindow < Self.maxFiresPerWindow
    }
}
