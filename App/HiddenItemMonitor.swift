import AppKit
import KvotarCore

/// Watches the status item's own window and says whether macOS is hiding it (REV-99 §2.6 —
/// STEP_206). The AppKit half: it reads frames and occlusion, runs the `confirmSeconds` timer, and
/// does what `HiddenItemDetection.Tracker` — where the rule and the state machine live — tells it.
///
/// It **never** posts a notification and never touches the presenter. `MenuBarController` owns it
/// because it owns the status item, and the composition root decides what a confirmed hidden item
/// means: the §2.7 notice, and the presenter's routing input.
///
/// **Occlusion events alone are not enough.** The item is already occluded before macOS places it,
/// so an item that stays occluded through placement never *changes* occlusion state and the
/// notification never fires again — the moment detection becomes eligible would pass unobserved.
/// Hence three triggers, and hence a timer that re-reads the gates when it fires rather than
/// trusting the reading that armed it.
///
/// **A dark screen is not a hidden item** (D-122 amendment — STEP_229). macOS reports the status
/// window occluded while the display sleeps or the session is locked, without moving it, so the
/// monitor also holds whether the screen is *away* and feeds it into every reading. Each of those
/// signals is a trigger too: going away cancels an armed confirmation at once, and coming back
/// re-arms a genuinely hidden item even if occlusion never changes on wake.
///
/// **Nor is a full-screen app** (D-122 amendment — STEP_234). It covers the bar the same way, and
/// the tell is that no status item of *any* app is on screen, so every reading also carries the
/// number of status-item-level windows in the on-screen window list — read at the moment of the
/// reading, never held. A Space change is the trigger for the exit edge: an item that became
/// hidden while the bar was away never changes occlusion state when the bar returns.
///
/// **The notice is a launch-time hint** (D-122 amendment — STEP_235). The monitor stamps when it
/// started and hands the launch's age to the tracker with each lapsed wait; the tracker decides
/// whether a confirmation is still early enough to announce. Detection itself runs for the whole
/// session — the presenter's routing needs it.
///
/// It reads and never acts on the item: no resize, no reposition, no visibility change. Auto-shrink
/// is out of this revision by decision (REV-99 §4) — it flaps by construction, and on the bar Spike
/// E ran against even a 22 pt item landed under the notch.
@MainActor
final class HiddenItemMonitor {

    /// The status button's window. A closure because the window does not exist at
    /// `MenuBarController.init` time in every launch shape.
    var statusWindow: (() -> NSWindow?)?

    /// A change of the **confirmed** state, never a raw reading. `notice` is true at most once per
    /// launch, and only early in it — the caller posts it; the flag is the tracker's, so the
    /// budget and the window are testable.
    var onChange: ((_ isHidden: Bool, _ notice: Bool) -> Void)?

    /// The presenter's routing input.
    var isConfirmedHidden: Bool { tracker.isHiddenConfirmed }

    private var tracker = HiddenItemDetection.Tracker()
    private var confirmTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// The two halves of "the screen is away". Seeded from the system in `start()` (STEP_235):
    /// a launch into a dark or locked screen **is** a shape Kvotar reaches — a relaunch while the
    /// owner is away posted the notice at one on 2026-10-01 — and the notifications only report
    /// changes, so a state that already holds at launch would never be learned.
    private var displayAsleep = false
    private var sessionLocked = false
    private var isScreenAway: Bool { displayAsleep || sessionLocked }

    /// The count the last reading was built from, for the log line only.
    private var lastStatusWindowCount: Int?

    /// When `start()` ran — the launch, as far as the notice's window is concerned. Wall clock on
    /// purpose: a Mac that sleeps a minute into a launch must not wake to a "launch-time" notice.
    private var startedAt = Date()

    func start() {
        guard observers.isEmpty else { return }
        startedAt = Date()
        // Observed with `object: nil` and filtered on identity below: the status window may not
        // exist yet, and registering against a nil object would silently observe **everything**.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMoveNotification] {
            let trigger = name == NSWindow.didMoveNotification ? "moved" : "occlusion"
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in
                    guard let self, let window = self.statusWindow?(),
                          note.object as AnyObject? === window else { return }
                    self.evaluate(trigger: trigger)
                }
            })
        }
        // A display added, removed or resized moves every item in the bar, and can make room or
        // take it away without the window moving on its own.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate(trigger: "screens") }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        // The one event the probe showed reading the new count on every full-screen entry and
        // exit, swipes included (STEP_234).
        observers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate(trigger: "space") }
        })
        // Fast user switching reads the same way a lock does, so it shares the flag.
        observeScreen(workspace, NSWorkspace.screensDidSleepNotification, "screensDidSleep") {
            $0.displayAsleep = true
        }
        observeScreen(workspace, NSWorkspace.screensDidWakeNotification, "screensDidWake") {
            $0.displayAsleep = false
        }
        observeScreen(workspace, NSWorkspace.sessionDidResignActiveNotification,
                      "sessionDidResignActive") { $0.sessionLocked = true }
        observeScreen(workspace, NSWorkspace.sessionDidBecomeActiveNotification,
                      "sessionDidBecomeActive") { $0.sessionLocked = false }
        let distributed = DistributedNotificationCenter.default()
        observeScreen(distributed, Notification.Name("com.apple.screenIsLocked"),
                      "screenIsLocked") { $0.sessionLocked = true }
        observeScreen(distributed, Notification.Name("com.apple.screenIsUnlocked"),
                      "screenIsUnlocked") { $0.sessionLocked = false }
        seedScreenState()
        evaluate(trigger: "start")
    }

    /// Where the screen stands right now, read once, after the observers are up so no edge falls
    /// between the read and the listening. A session dictionary that cannot be read is not a
    /// locked session. Both read true on a locked, sleeping display on macOS 15.6
    /// (`docs/evidence/STEP_235/`).
    private func seedScreenState() {
        displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        sessionLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        guard isScreenAway else { return }
        // INFO, not DEBUG like the edges: debug logging is switched on after this runs, and a
        // launch that starts dark is the one a tester's bundle has to be able to show.
        Logger.info("Status item screen away at launch", component: .appLifecycle,
                    metadata: ["displayAsleep": String(displayAsleep),
                               "sessionLocked": String(sessionLocked)])
    }

    /// One sleep/lock signal: set its flag, log the edge, and re-evaluate — every signal is a
    /// trigger as well as an input.
    private func observeScreen(_ center: NotificationCenter, _ name: Notification.Name,
                               _ signal: String,
                               _ set: @escaping @MainActor @Sendable (HiddenItemMonitor) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let before = (self.displayAsleep, self.sessionLocked)
                set(self)
                guard before != (self.displayAsleep, self.sessionLocked) else { return }
                Logger.debug(self.isScreenAway ? "Status item screen away" : "Status item screen back",
                             component: .appLifecycle,
                             metadata: ["signal": signal,
                                        "displayAsleep": String(self.displayAsleep),
                                        "sessionLocked": String(self.sessionLocked)])
                self.evaluate(trigger: self.isScreenAway ? "screen-away" : "screen-back")
            }
        })
    }

    // MARK: Evaluation

    private func evaluate(trigger: String) {
        guard let reading = currentReading() else { return }
        let before = tracker.lastVerdict
        let effect = tracker.observe(reading)
        if tracker.lastVerdict != before {
            // One DEBUG line per **edge**, never one per reading: a line that fires every time
            // stops meaning anything (the defect STEP_203 found in its own transition logging).
            Logger.debug("Status item reading changed", component: .appLifecycle,
                         metadata: ["verdict": tracker.lastVerdict.map { "\($0)" } ?? "none",
                                    "trigger": trigger, "placed": String(tracker.hasBeenPlaced),
                                    "statusWindows": lastStatusWindowCount.map(String.init) ?? "unreadable"])
        }
        apply(effect, trigger: trigger)
    }

    /// The gates are re-checked here against the **current** reading (REV-99 §2.6), never against
    /// the one that armed the timer.
    private func confirmationLapsed() {
        confirmTimer = nil
        apply(tracker.confirmationLapsed(currentReading(),
                                         sinceLaunch: Date().timeIntervalSince(startedAt)),
              trigger: "confirm")
    }

    private func apply(_ effect: HiddenItemDetection.Tracker.Effect, trigger: String) {
        switch effect {
        case .nothing:
            break
        case .armConfirmation:
            Logger.debug("Status item may be hidden — confirming", component: .appLifecycle,
                         metadata: ["seconds": String(Int(HiddenItemDetection.confirmSeconds)),
                                    "trigger": trigger])
            confirmTimer?.invalidate()
            confirmTimer = Timer.scheduledTimer(
                withTimeInterval: HiddenItemDetection.confirmSeconds, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.confirmationLapsed() }
            }
        case .cancelConfirmation:
            Logger.debug("Status item confirmation cancelled", component: .appLifecycle,
                         metadata: ["verdict": tracker.lastVerdict.map { "\($0)" } ?? "none"])
            confirmTimer?.invalidate()
            confirmTimer = nil
        case .confirmed(let notice):
            Logger.info("Status item confirmed hidden", component: .appLifecycle,
                        metadata: ["held": "\(Int(HiddenItemDetection.confirmSeconds))s",
                                   "notice": String(notice),
                                   "sinceLaunch": "\(Int(Date().timeIntervalSince(startedAt)))s"])
            onChange?(true, notice)
        case .cleared:
            Logger.info("Status item is back on screen", component: .appLifecycle,
                        metadata: ["verdict": tracker.lastVerdict.map { "\($0)" } ?? "none"])
            onChange?(false, false)
        }
    }

    /// AppKit in, one reading out. `nil` when there is nothing to read — no window or no screen —
    /// which is a reading we do not have rather than a state we may claim.
    private func currentReading() -> HiddenItemDetection.Reading? {
        guard let window = statusWindow?(),
              let screen = window.screen ?? NSScreen.main else { return nil }
        lastStatusWindowCount = statusWindowsOnScreen()
        return HiddenItemDetection.Reading(
            isOccluded: !window.occlusionState.contains(.visible),
            windowMaxY: window.frame.maxY,
            screenMinY: screen.frame.minY,
            screenMaxY: screen.frame.maxY,
            isScreenAway: isScreenAway,
            isMenuBarAway: HiddenItemDetection.isMenuBarAway(
                statusWindowsOnScreen: lastStatusWindowCount))
    }

    /// How many status-item-level windows — every app's menu-bar items — the on-screen window
    /// list holds right now. **Only the layer is read**: no owner, name, bounds or content, so
    /// Kvotar learns one number about the menu bar and nothing about any app, and the call needs
    /// no permission. `nil` when the list cannot be read.
    private func statusWindowsOnScreen() -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let level = Int(CGWindowLevelForKey(.statusWindow))
        return list.filter { ($0[kCGWindowLayer as String] as? Int) == level }.count
    }
}
