import Foundation

/// Whether macOS is hiding Kvotar's status item (REV-99 §2.6 — STEP_206). Pure, so `KvotarTests`
/// can pin it without AppKit, on the `LaunchSource` / `SecondInstanceAction` / `OnboardingGate`
/// pattern. `HiddenItemMonitor` is the AppKit half that reads the numbers this rule judges.
///
/// **The signal is the status button window's `occlusionState`,** and Spike E is why: of 675
/// samples on a real machine it agreed with the screen in every one, and the notification fires in
/// ~10 ms. `NSStatusItem.isVisible` never flips at all, and geometry against the notch's aux area
/// never cried wolf but **missed 100 of 555** genuinely hidden samples, because macOS keeps a
/// margin at the notch edge. Geometry is not read here.
///
/// The raw signal alone would be wrong four times, so five gates turn it into a claim:
///
/// 1. **Not before first placement.** For the first ~0.7–1.5 s of every launch the window is
///    parked below the screen's bottom edge — the observed frame is `(0, −38)` on a 38 pt window —
///    reporting `occluded = true`. That transient happens on *every* launch.
/// 2. **The window must still be in the bar.** With the menu bar auto-hidden, occlusion also goes
///    false, but the window's top edge climbs off the screen (1069 → 1076 → 1100 → 1107 on a
///    1107 pt screen, against a top edge that sits exactly at 1107 when the bar is showing).
///    **Auto-hide must never be reported as a hidden item.**
/// 3. **Sustained for `confirmSeconds`** — owned by the monitor, because a duration is not
///    arithmetic over one reading.
/// 4. **Not while the screen is away** (D-122 amendment — STEP_229) — checked **first**. A
///    sleeping display or a locked session reports the window occluded without moving it, so
///    gates 1 and 2 pass and the sustain is no defence: a dark screen holds for minutes. On
///    2026-09-30 that posted the notice at a dark screen with the item plainly in the bar.
/// 5. **Not while the menu bar is put away** (D-122 amendment — STEP_234). An app in full screen
///    covers the bar and the window reports occluded without moving, so every gate above passes
///    and a film outlasts the sustain. What tells it apart is that **no status item of any app is
///    on screen**: the count was 14 on the desktop and 0 in every full-screen stretch the probe
///    saw (`docs/evidence/STEP_234/`). `NSApp.currentSystemPresentationOptions` reads nothing
///    from a menu-bar app and is not used. Unlike gate 4 this one **holds** a confirmation that
///    already stands — see `Tracker.observe`.
///
/// **The gates decide what is *known*; the notice is narrower** (D-122 amendment — STEP_235). A
/// confirmation routes whenever it stands, but it is *announced* only inside the first
/// `noticeWindowSeconds` of a launch — see that constant.
enum HiddenItemDetection {

    // MARK: Constants (UI Spec §5)

    /// How long a hidden reading must hold before Kvotar acts on it. **A debounce, not a proof:**
    /// the bar churns while other apps claim their slots — the probe logged the item moving four
    /// times in the first minute after a sign-in — and five seconds filters that without making
    /// the notice late. It says the reading is stable; the *cause* comes from the gates above.
    static let confirmSeconds: TimeInterval = 5

    /// The notice is a recovery hint, not a monitor. Twice is nagging about something the user has
    /// already been told and may have chosen to live with.
    static let noticePerLaunch = 1

    /// The notice belongs to the launch (owner ruling 2026-10-01 — STEP_235): it answers "I
    /// started Kvotar and nothing appeared", and a user hours into a session already knows the
    /// app is running. A confirmation that lands later than this after launch still stands and
    /// still routes; it is never announced. Of 626 confirmations in the owner's log (2026-09-15 →
    /// 10-01) only five landed inside the first minute — the four known to be genuine among them,
    /// 5–39 s in — and every other one came after two minutes: a dark screen, a full-screen app
    /// or an open popover wherever the cause is known (`docs/evidence/STEP_235/`).
    static let noticeWindowSeconds: TimeInterval = 60

    /// Float slack on both edge comparisons. The top edge lands *exactly* on the screen's when the
    /// item is in the bar, so the tolerance guards wobble, not a real margin.
    static let edgeTolerance: CGFloat = 1

    // MARK: The reading

    /// What one evaluation sees. Numbers and booleans only — never an `NSWindow`.
    struct Reading: Equatable {
        /// The status button window's own report. AppKit's statement about *window visibility*,
        /// not about menu-bar capacity — which is exactly why the gates are needed.
        let isOccluded: Bool
        /// The status window's top edge, in screen coordinates.
        let windowMaxY: CGFloat
        /// Its screen's bottom and top edges.
        let screenMinY: CGFloat
        let screenMaxY: CGFloat
        /// The display is asleep or the login session is locked or switched away. The rule never
        /// learns which — only that nothing read now says anything about the menu bar.
        let isScreenAway: Bool
        /// No status item of any app is on screen: the bar is put away, in practice under a
        /// full-screen app. The rule never sees a window list and never learns why.
        let isMenuBarAway: Bool
    }

    enum Verdict: Equatable {
        /// Placed, still in the bar, and the window reports occluded.
        case hidden
        /// The launch transient: macOS has not placed the item yet.
        case notPlacedYet
        /// The whole menu bar is auto-hidden. Not our problem and never reported as one.
        case barAutoHidden
        /// Placed, in the bar, and on screen.
        case onScreen
        /// Nobody can see the bar at all: the display is asleep or the session is locked.
        case screenAway
        /// Placed, in the bar and occluded — but so is every other app's item. The occlusion is
        /// about the bar, not about this item.
        case menuBarAway

        var isHidden: Bool { self == .hidden }
    }

    /// `hasBeenPlaced` is the latch as it stands, held by the `Tracker` below: once macOS has
    /// placed the item it never becomes unplaced, and an item it later hides keeps its position.
    static func verdict(_ reading: Reading, hasBeenPlaced: Bool) -> Verdict {
        guard !reading.isScreenAway else { return .screenAway }
        let placed = hasBeenPlaced
            || isPlaced(windowMaxY: reading.windowMaxY, screenMinY: reading.screenMinY)
        guard placed else { return .notPlacedYet }
        guard isInMenuBar(windowMaxY: reading.windowMaxY, screenMaxY: reading.screenMaxY) else {
            return .barAutoHidden
        }
        guard reading.isOccluded else { return .onScreen }
        return reading.isMenuBarAway ? .menuBarAway : .hidden
    }

    /// The fifth gate's input, from the number of status-item-level windows the on-screen window
    /// list holds. `nil` is a list we could not read, which is not a state we may claim.
    static func isMenuBarAway(statusWindowsOnScreen count: Int?) -> Bool {
        count == 0
    }

    /// Has macOS positioned the item yet? Before it does, the window is parked one window-height
    /// below its screen's bottom edge — `(0, −38)` for a 38 pt window — so its **whole frame** is
    /// at or below that edge. Deliberately independent of the menu bar's thickness: that
    /// measurement goes to zero while the bar is auto-hidden, and placement must not depend on
    /// something that can vanish.
    static func isPlaced(windowMaxY: CGFloat, screenMinY: CGFloat) -> Bool {
        windowMaxY > screenMinY + edgeTolerance
    }

    /// Is the item still drawn in the menu bar, as opposed to riding an auto-hidden bar off the
    /// top of the screen? In the bar the window's top edge sits at the screen's; auto-hidden it
    /// goes above it.
    static func isInMenuBar(windowMaxY: CGFloat, screenMaxY: CGFloat) -> Bool {
        windowMaxY <= screenMaxY + edgeTolerance
    }

    // MARK: The third gate, as a state machine

    /// Gate 3 and the notice budget, kept **pure**: the sustain is a sequence of readings and one
    /// "the wait is over" event, and a `Timer` is the only part of it AppKit needs to own
    /// (PATTERNS: *a schedule is pure; a timer is not*). `HiddenItemMonitor` holds one of these
    /// and does what the effect says.
    struct Tracker {
        /// Whether macOS is confirmed to be hiding the item **right now**. Live truth: a user who
        /// frees a menu-bar slot gets their popover back.
        private(set) var isHiddenConfirmed = false
        /// The placement latch (gate 1).
        private(set) var hasBeenPlaced = false
        /// The verdict the last reading produced, for the log line.
        private(set) var lastVerdict: Verdict?

        private var isConfirming = false
        private var noticesPosted = 0

        /// What the caller must do about a reading or a lapsed wait.
        enum Effect: Equatable {
            case nothing
            /// Start the `confirmSeconds` wait.
            case armConfirmation
            /// The reading stopped being hidden before the wait was up.
            case cancelConfirmation
            /// Confirmed. `notice` is false once the launch's one notice has been given, and
            /// for every confirmation that lands after `noticeWindowSeconds` — the confirmation
            /// still stands and still routes, it is simply not announced.
            case confirmed(notice: Bool)
            /// A confirmed hidden item came back on screen.
            case cleared
        }

        mutating func observe(_ reading: Reading) -> Effect {
            // A screen-away reading never latches placement: the frame is not trustworthy while
            // the screen is dark, and placement must be learned from a real one.
            hasBeenPlaced = hasBeenPlaced
                || (!reading.isScreenAway
                    && isPlaced(windowMaxY: reading.windowMaxY, screenMinY: reading.screenMinY))
            let current = HiddenItemDetection.verdict(reading, hasBeenPlaced: hasBeenPlaced)
            lastVerdict = current

            guard current.isHidden else {
                if isConfirming {
                    isConfirming = false
                    return .cancelConfirmation
                }
                // A bar that is away **holds** a standing confirmation (STEP_234, owner ruling):
                // people click notifications over a full-screen app, and a user whose item is
                // genuinely hidden must keep landing in the window. It ends the ordinary way —
                // on the first reading that is not occluded.
                guard isHiddenConfirmed, current != .menuBarAway else { return .nothing }
                isHiddenConfirmed = false
                return .cleared
            }
            // Armed on the **edge into hidden**, not on every hidden reading: a stream of them
            // must not keep pushing the confirmation out.
            guard !isHiddenConfirmed, !isConfirming else { return .nothing }
            isConfirming = true
            return .armConfirmation
        }

        /// The wait is over. The gates are re-checked against the reading passed in — the
        /// **current** one, never the one that armed the timer (REV-99 §2.6). `nil` is a reading
        /// we could not take, which is not a state we may claim.
        ///
        /// `sinceLaunch` is the age of the launch **now**, as the wait lapses: the notice is
        /// judged on when the confirmation lands, not on when the reading began. A late
        /// confirmation leaves the budget unspent — there is nothing later to spend it on.
        mutating func confirmationLapsed(_ reading: Reading?, sinceLaunch: TimeInterval) -> Effect {
            isConfirming = false
            guard let reading,
                  HiddenItemDetection.verdict(reading, hasBeenPlaced: hasBeenPlaced).isHidden,
                  !isHiddenConfirmed else { return .nothing }
            isHiddenConfirmed = true
            let notice = noticesPosted < noticePerLaunch && sinceLaunch <= noticeWindowSeconds
            if notice { noticesPosted += 1 }
            return .confirmed(notice: notice)
        }
    }
}
