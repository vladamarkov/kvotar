import Foundation
import KvotarCore

/// When the menu bar shows a long-limit reminder, and which one (UI Spec §1.3 / §5, REV-97 §2.1
/// and §2.3 — STEP_198; the decaying cadence and the episode, REV-98 §2.2 / §2.3 — STEP_202).
///
/// Pure arithmetic over one instant, deliberately: `AppViewModel` holds the clock that asks this,
/// and the view asks `pulses` rather than deciding motion inline. Nothing here holds state,
/// starts a timer or touches AppKit, so the whole cycle — including the exact boundaries a reader
/// would otherwise have to watch a real menu bar for an hour to check — is a unit test.
public enum MenuBarReminder {

    /// How long one reminder stays up (UI Spec §5, `menuReminderSeconds`). Seven seconds since
    /// REV-100 §2.2 (STEP_211; was five): longer than a glance, shorter than ten, because under
    /// variant D the peer tool's row is hidden for exactly this long.
    public static let reminderSeconds: TimeInterval = 7

    /// Where the first, loud hour of a tier ends (UI Spec §5, `reminderDecayAfterSeconds` —
    /// REV-98 §2.2). Measured from `tierAt`.
    public static let decayAfterSeconds: TimeInterval = 3_600

    /// Where the second hour ends and the late interval takes over (UI Spec §5,
    /// `reminderSecondDecayAfterSeconds` — REV-100 §2.2, STEP_211).
    public static let secondDecayAfterSeconds: TimeInterval = 7_200

    /// Reminder-start to reminder-start in each of the three phases (UI Spec §5,
    /// `reminderCadence` — REV-98 §2.2, three phases since REV-100 §2.2).
    public struct Cadence: Sendable, Equatable {
        /// `[0, decayAfterSeconds)`.
        public let first: TimeInterval
        /// `[decayAfterSeconds, secondDecayAfterSeconds)`.
        public let second: TimeInterval
        /// From `secondDecayAfterSeconds` on.
        public let late: TimeInterval

        public init(first: TimeInterval, second: TimeInterval, late: TimeInterval) {
            self.first = first
            self.second = second
            self.late = late
        }
    }

    /// Amber (rank 10): immediately, then every minute for an hour, every ten minutes the second
    /// hour, then hourly (REV-100 §2.2 — STEP_211).
    ///
    /// Loud because it now **stops**: opening the popover acknowledges the episode, so the reader
    /// who looks ends it and the reader who does not look is the one it is for. 160 reminders
    /// over four days unacknowledged, where REV-98's ten-minute opening gave 101.
    public static let amberCadence = Cadence(first: 60, second: 600, late: 3_600)

    /// Which cadence a tier reads. **Amber's, always** — red never reminds: rank 5b and a block
    /// hold their shape in the bar (REV-100 §2.1), and the one red case that still cycled, the
    /// unconfirmed Claude monthly (P1-16b), was retired with REV-102 (STEP_220). The mapping
    /// stays so a red episode, which is still held through escalation, has a total answer.
    public static func cadence(for tier: LongLimitAssessment.Tier) -> Cadence {
        amberCadence
    }

    /// How far the pulse dims the reminding row (UI Spec §5, `menuPulseFloorOpacity` — STEP_199).
    /// The prototype's floor: below it a 9 pt string stops being readable, and a reminder that
    /// cannot be read while it moves is worse than one that does not move.
    public static let pulseFloorOpacity: Double = 0.55
    /// One full down-and-back pulse (UI Spec §5, `menuPulseCycleSeconds` — STEP_199). Four of
    /// them = 6.4 s, which fits inside the seven-second phase and ends at full opacity.
    public static let pulseCycleSeconds: TimeInterval = 1.6
    /// How many cycles one reminder pulses (REV-97 §2.8; four since REV-100 §2.2 — STEP_211).
    public static let pulseCycles: Int = 4

    /// The crossfade between the steady row and the reminder, **both directions** (UI Spec §5,
    /// `menuTransitionSeconds` — REV-98 §2.4a, STEP_203).
    ///
    /// A judgement about a menu bar with no corpus behind it, like every other number in this
    /// revision: 350 ms is long enough to read as deliberate, and 200 ms and an instant cut stay
    /// the prototype's comparisons. **It moves no boundary** — the reminder still starts and ends
    /// at exactly its scheduled instants and the outgoing image merely takes another 350 ms to
    /// disappear, because that tail belongs to the view and not to the clock.
    public static let transitionSeconds: TimeInterval = 0.35

    /// The largest the variant-D headline may grow (UI Spec §5 — REV-98 §2.4, STEP_203).
    ///
    /// A cap, not a size: the headline is *fitted* to the width the item already reserves and
    /// lands wherever that allows between its display mode's base size and this. It is what
    /// stops a short reminder on a wide bar from rendering at poster scale.
    public static let headlineMaxSize: CGFloat = 13

    /// Whether a row should pulse right now (REV-97 §2.8 — STEP_199).
    ///
    /// Two conditions and no third: a reminder is up, and the reader has not asked for less
    /// motion. It is a function rather than two `if`s in the view so the rule can be stated once
    /// and pinned by a test — the system setting itself cannot be flipped from a test process,
    /// and a view that decided this inline could only ever be checked by eye.
    ///
    /// **Reduced motion drops the pulse and keeps the colour.** The reminder still appears: it
    /// carries information, and the pulse only draws the eye to it.
    public static func pulses(reminderIndex: Int?, reduceMotion: Bool) -> Bool {
        reminderIndex != nil && !reduceMotion
    }

    /// Whether the step from one render to the next **crossfades** (REV-98 §2.4a — STEP_203).
    ///
    /// Stated here rather than in the view for `pulses`' reason: the three exemptions are a rule,
    /// and a rule decided inline in a `body` can only ever be checked by eye. Four ways to be
    /// false, and each is one sentence of §2.4a:
    ///
    /// 1. **Reduce motion** drops the fade and the pulse together and keeps the colour.
    /// 2. **Nothing about the phase changed.** An identical re-render keeps the layer and the
    ///    pulse it already had — a poll that only moves a percentage must not restart the
    ///    animation, which at a 120 s cadence would fire a fade every other minute.
    /// 3. **A layout change never overlays two differently sized layers**: a tool appearing or
    ///    disappearing swaps outright.
    /// 4. **The three immediate exemptions** — a confirmed block, an urgent state, and a missing
    ///    or pending reading, each carried on the incoming line by the formatter that already
    ///    tested for it. A fade is a softening, and nothing about arriving at a block should be
    ///    soft.
    ///
    /// Everything else fades, in **both** directions: the scheduled edges, a new episode, an
    /// escalation, a recovery, and a first warning with no prior layer to fade from — those
    /// entry paths are the ones the prototype originally skipped, and skipping them is what made
    /// entry read as a glitch while exit read as a transition.
    public static func fades(from: MenuBarRender, to: MenuBarRender, reduceMotion: Bool) -> Bool {
        guard !reduceMotion else { return false }
        let before = from.lines, after = to.lines
        guard before.count == after.count else { return false }
        let changed = zip(before, after).enumerated()
            .filter { $0.element.0.reminderIndex != $0.element.1.reminderIndex }
        guard !changed.isEmpty else { return false }
        return changed.allSatisfy { $0.element.1.transition == .animated }
    }

    // MARK: The schedule (§2.2 / §2.3)

    /// Which phase to draw at `now`, for a tool whose leading warning is `episode` and which has
    /// `reminderCount` reminders to cycle through.
    ///
    /// `nil` = the steady phase. Otherwise an index into the reminder list, **most severe first**
    /// (§2.3): the first reminder of an episode is the worst limit, and successive reminders take
    /// turns. A reminder fires **immediately on entering the tier** — the reader who just crossed
    /// the line is the one who most needs telling, and making them wait would be a strange kind
    /// of politeness.
    ///
    /// Returns `nil` for an empty reminder list (nothing to show), for a `now` before the tier
    /// began (a clock that went backwards is not a reason to flash the bar), while a restored
    /// episode is still waiting to be confirmed by a live reading, and for every reminder that
    /// starts after an amber episode was acknowledged (REV-100 §2.2 — STEP_211). A reminder
    /// already on screen at the acknowledgement is not cut: it ends at its own edge.
    public static func phase(episode: ReminderEpisode, now: Date, reminderCount: Int) -> Int? {
        guard reminderCount > 0, !episode.awaitingResume else { return nil }
        let elapsed = now.timeIntervalSince(episode.tierAt)
        guard elapsed >= 0 else { return nil }
        let c = cadence(for: episode.tier)
        // The scheduled grid first, so alternation survives a resume that happens to land inside
        // a scheduled reminder.
        let start = startOffset(at: elapsed, c)
        if elapsed - start < reminderSeconds, shows(start, episode) {
            return (startCount(upTo: start, c) - 1) % reminderCount
        }
        // The one off-grid reminder a relaunch earns (§2.3). It always shows the worst limit:
        // the reader has been away, and the first thing they should get back is the top of the
        // list, not wherever the alternation happened to be.
        if let resume = resumeOffset(episode), elapsed >= resume,
           elapsed - resume < reminderSeconds, shows(resume, episode) {
            return 0
        }
        return nil
    }

    /// When the phase next flips, for a tool whose leading warning is `episode` — or `nil` when
    /// it never will again, which since STEP_211 is an acknowledged amber episode with nothing on
    /// screen.
    ///
    /// The schedule's clock and the tests read **one** rule, so a sleeping task and an assertion
    /// cannot disagree about a boundary. Inside a reminder the next edge is that reminder's end;
    /// in the steady phase it is the next start — the resume's or the grid's, whichever comes
    /// first. A `now` before the tier began — a clock that went backwards — points at `tierAt`
    /// itself, which is that tier's first reminder.
    ///
    /// Every edge is strictly ahead of `now`, so the clock loop can never spin.
    public static func nextEdge(episode: ReminderEpisode, now: Date) -> Date? {
        let elapsed = now.timeIntervalSince(episode.tierAt)
        guard elapsed >= 0 else { return shows(0, episode) ? episode.tierAt : nil }
        let c = cadence(for: episode.tier)
        let start = startOffset(at: elapsed, c)
        var offsets: [TimeInterval] = []
        if elapsed - start < reminderSeconds, shows(start, episode) {
            offsets.append(start + reminderSeconds)
        } else {
            let next = nextStart(after: elapsed, c)
            if shows(next, episode) { offsets.append(next) }
        }
        if let resume = resumeOffset(episode), shows(resume, episode) {
            if elapsed < resume {
                offsets.append(resume)
            } else if elapsed - resume < reminderSeconds {
                offsets.append(resume + reminderSeconds)
            }
        }
        return offsets.min().map { episode.tierAt.addingTimeInterval($0) }
    }

    /// How many reminders a tier fires over `duration` if nobody looks — the figure REV-100 §2.2
    /// states as **160 over four days of amber**, exposed so the claim is asserted rather than
    /// asserted about.
    ///
    /// Half-open, `[0, duration)`: the four days end when the week resets, and a reminder due at
    /// the instant the warning ends is not one the reader ever sees.
    public static func reminderCount(tier: LongLimitAssessment.Tier,
                                     over duration: TimeInterval) -> Int {
        reminderCount(cadence(for: tier), over: duration)
    }

    // MARK: The grid

    /// Whether a reminder starting `offset` after `tierAt` is still owed to the reader: always,
    /// unless the episode is amber and was acknowledged before that reminder began. Inclusive,
    /// so a reminder already drawn at the instant of the click finishes rather than being cut.
    ///
    /// **Amber only** (REV-100 §2.2): the flag rides along on escalation but mutes nothing in
    /// red.
    private static func shows(_ offset: TimeInterval, _ episode: ReminderEpisode) -> Bool {
        guard episode.tier <= .aheadOfPace, let acknowledgedAt = episode.acknowledgedAt else {
            return true
        }
        return offset <= acknowledgedAt.timeIntervalSince(episode.tierAt)
    }

    /// The resume reminder's offset from `tierAt`, or nil when this episode was not restored.
    private static func resumeOffset(_ episode: ReminderEpisode) -> TimeInterval? {
        guard let resumedAt = episode.resumedAt else { return nil }
        let offset = resumedAt.timeIntervalSince(episode.tierAt)
        return offset >= 0 ? offset : nil
    }

    /// The three segments of a cadence as half-open spans, each starting with a reminder at its
    /// own `from`.
    private static func segments(_ c: Cadence)
        -> [(from: TimeInterval, until: TimeInterval, every: TimeInterval)] {
        [(0, decayAfterSeconds, c.first),
         (decayAfterSeconds, secondDecayAfterSeconds, c.second),
         (secondDecayAfterSeconds, .infinity, c.late)]
    }

    /// The segment `elapsed` falls in (elapsed ≥ 0).
    private static func segment(at elapsed: TimeInterval, _ c: Cadence)
        -> (from: TimeInterval, until: TimeInterval, every: TimeInterval) {
        segments(c).last(where: { $0.from <= elapsed }) ?? segments(c)[0]
    }

    /// The most recent scheduled start at or before `elapsed`.
    private static func startOffset(at elapsed: TimeInterval, _ c: Cadence) -> TimeInterval {
        let p = segment(at: elapsed, c)
        return p.from + floor((elapsed - p.from) / p.every) * p.every
    }

    /// The next scheduled start strictly after `elapsed`.
    private static func nextStart(after elapsed: TimeInterval, _ c: Cadence) -> TimeInterval {
        let p = segment(at: elapsed, c)
        // `min` rather than arithmetic luck: every boundary is a whole number of the interval
        // before it for both shipped tiers, and this holds if a future one changes that.
        return Swift.min(p.from + (floor((elapsed - p.from) / p.every) + 1) * p.every, p.until)
    }

    /// How many scheduled starts fall at or before `elapsed`. Drives the alternation index.
    private static func startCount(upTo elapsed: TimeInterval, _ c: Cadence) -> Int {
        guard elapsed >= 0 else { return 0 }
        let p = segment(at: elapsed, c)
        return reminderCount(c, over: p.from) + Int(floor((elapsed - p.from) / p.every)) + 1
    }

    /// `reminderCount(tier:over:)` for a cadence rather than a tier.
    private static func reminderCount(_ c: Cadence, over duration: TimeInterval) -> Int {
        guard duration > 0 else { return 0 }
        return segments(c).reduce(0) { count, p in
            let span = Swift.min(p.until, duration) - p.from
            return span > 0 ? count + Int(ceil(span / p.every)) : count
        }
    }
}
