import XCTest
import KvotarCore
import KvotarUI


/// The one entry point every way into the quota reading goes through (REV-99 §2.3a, contract §3
/// and §6 — STEP_204): which surface a destination lands on, and the close → cleanup → open
/// ordering that keeps the §2.8 line alive across a switch.
///
/// Driven through the presenter with fake surfaces rather than through AppKit — the ordering is
/// the presenter's rule, and a test that needed a real `NSPopover` could not assert it.
@MainActor
final class QuotaSurfacePresenterTests: XCTestCase {

    // MARK: Fakes

    /// Records what happened and in what order, so "close before open" is an assertion rather
    /// than an assumption.
    private final class Log {
        var events: [String] = []
    }

    private final class FakeSurface: QuotaSurface {
        let kind: QuotaSurfaceKind
        private let lifecycle: QuotaSurfaceLifecycle
        private let log: Log
        private var shown = false
        private(set) var opened: [QuotaDestination] = []

        init(kind: QuotaSurfaceKind, lifecycle: QuotaSurfaceLifecycle, log: Log) {
            self.kind = kind
            self.lifecycle = lifecycle
            self.log = log
        }

        var isVisible: Bool { shown }

        func open(_ destination: QuotaDestination) {
            opened.append(destination)
            shown = true
            log.events.append("open:\(kind)")
            lifecycle.willOpen(kind, destination: destination)
            lifecycle.didOpen(kind, destination: destination,
                              isVisible: { [weak self] in self?.shown == true })
        }

        func closeNow() {
            guard shown else { return }
            shown = false
            log.events.append("close:\(kind)")
            lifecycle.closedByApp(kind)
        }

        /// What the real popover does when asked to open onto itself: close through `closeNow`
        /// first, so the cleanup is synchronous rather than deferred past the reopen.
        func reopenOntoItself(_ destination: QuotaDestination) {
            closeNow()
            open(destination)
        }

        /// The popover's *deferred* `didCloseNotification`, arriving after the presenter already
        /// closed this surface by hand. In the app it is two hops late; here it is explicit.
        func deliverLateCloseNotification() {
            lifecycle.didCloseFromNotification(kind)
        }

        /// The user clicking away, or Esc on a transient popover: a close the app did not
        /// initiate, announced only by the notification. A genuine end of reading.
        func closedByTheUser() {
            shown = false
            lifecycle.didCloseFromNotification(kind)
        }
    }

    private struct Fixture {
        let viewModel: AppViewModel
        let lifecycle: QuotaSurfaceLifecycle
        let popover: FakeSurface
        let window: FakeSurface
        let presenter: QuotaSurfacePresenter
        let log: Log
    }

    private func makeFixture() -> Fixture {
        let viewModel = AppViewModel()
        let lifecycle = QuotaSurfaceLifecycle(viewModel: viewModel)
        let log = Log()
        let popover = FakeSurface(kind: .popover, lifecycle: lifecycle, log: log)
        let window = FakeSurface(kind: .window, lifecycle: lifecycle, log: log)
        return Fixture(viewModel: viewModel, lifecycle: lifecycle, popover: popover,
                       window: window,
                       presenter: QuotaSurfacePresenter(popover: popover, window: window),
                       log: log)
    }

    // MARK: Routing (contract §6 item 19)

    /// With the item on screen, the notification action, the Welcome's last button and
    /// `Set up <tool>…` take the popover unless the window is already the open surface.
    func testPresentTakesThePopoverWhileTheWindowIsClosed() {
        let f = makeFixture()
        f.presenter.present()
        XCTAssertTrue(f.popover.isVisible)
        XCTAssertFalse(f.window.isVisible)
    }

    /// The window is the open surface, so everything lands there. This is the row that keeps a
    /// user who recovered through the window from being sent back to the item.
    func testPresentTakesTheWindowWhenTheWindowIsOpen() {
        let f = makeFixture()
        f.presenter.presentWindow()
        f.presenter.present()
        XCTAssertTrue(f.window.isVisible)
        XCTAssertFalse(f.popover.isVisible)
    }

    /// The row STEP_206 made reachable: a known-hidden item routes to the window even with the
    /// window closed — this is what stops the fix sending a stranded user back to the icon they
    /// could not find.
    func testAKnownHiddenItemRoutesToTheWindow() {
        let f = makeFixture()
        f.presenter.isItemKnownHidden = { true }
        f.presenter.present()
        XCTAssertTrue(f.window.isVisible)
        XCTAssertFalse(f.popover.isVisible)
    }

    /// A deliberate cold launch and every reopen: the window, always.
    func testPresentWindowAlwaysTakesTheWindow() {
        let f = makeFixture()
        f.presenter.present()             // popover first
        f.presenter.presentWindow()
        XCTAssertTrue(f.window.isVisible)
        XCTAssertFalse(f.popover.isVisible)
    }

    /// The status item's left click stays on the popover — the user has demonstrably found the
    /// item — and it toggles.
    func testTogglePopoverOpensThenCloses() {
        let f = makeFixture()
        f.presenter.togglePopover()
        XCTAssertTrue(f.popover.isVisible)
        f.presenter.togglePopover()
        XCTAssertFalse(f.popover.isVisible)
    }

    /// The destination rides through unchanged — no caller names a surface, and none of them has
    /// to name a tab either.
    func testTheDestinationIsCarriedThrough() {
        let f = makeFixture()
        f.presenter.present(.setup(.codex))
        XCTAssertEqual(f.popover.opened, [.setup(.codex)])
        XCTAssertEqual(f.viewModel.transientSetupTool, .codex)
    }

    /// The History footer link: whichever quota surface is up gets out of the way.
    func testCloseActiveSurfaceClosesWhicheverIsUp() {
        let f = makeFixture()
        f.presenter.presentWindow()
        f.presenter.closeActiveSurface()
        XCTAssertFalse(f.window.isVisible)
        XCTAssertFalse(f.popover.isVisible)
        XCTAssertNil(f.lifecycle.current)
    }

    // MARK: Never coexist, and the order (contract §3)

    func testOpeningOneSurfaceClosesTheOtherFirst() {
        let f = makeFixture()
        f.presenter.present()
        f.presenter.presentWindow()
        XCTAssertEqual(f.log.events, ["open:popover", "close:popover", "open:window"])
        f.presenter.togglePopover()
        XCTAssertEqual(f.log.events.suffix(2), ["close:window", "open:popover"])
    }

    /// The setup card is the one open that records **no** glance row: the §17.1 row records which
    /// *tab* was shown and a setup card is not a tab.
    func testASetupCardFiresNoOpenHookAndStartsNoFreshnessTimer() {
        let f = makeFixture()
        var opens = 0
        f.lifecycle.onOpen = { opens += 1 }
        f.presenter.present(.setup(.claude))
        XCTAssertEqual(opens, 0)
        XCTAssertFalse(f.lifecycle.isFreshnessTimerRunning)

        f.presenter.togglePopover()      // close
        f.presenter.present()            // an ordinary open
        XCTAssertEqual(opens, 1)
        XCTAssertTrue(f.lifecycle.isFreshnessTimerRunning)
    }

    // MARK: The ordering regression (contract §3 item 9)

    /// **Switching surfaces must not delete the line the new surface just computed.**
    ///
    /// `popoverDidClose()` erases the §2.8 lines *and* bumps `deltaLineGeneration`, which makes an
    /// in-flight boundary read discard its own result on arrival. The popover's cleanup is
    /// deferred twice in the app, so a close followed immediately by an open would land after the
    /// window had already started its read — deleting `Last window ended at [N]% — reset [t]`, the
    /// one line written for a rollover.
    ///
    /// Here the presenter closes synchronously, and the late notification then finds the popover
    /// is no longer the current surface and does nothing.
    func testSwitchingToTheWindowKeepsItsBoundaryLineAcrossALateClose() async {
        let f = makeFixture()
        f.viewModel.loadWindowOutcome = { _, _ in
            // Land *after* the switch, exactly as a real read would.
            await Task.yield()
            return WindowOutcome(resetsAt: Self.origin.addingTimeInterval(2 * 3600),
                                 highWaterPct: 94, hitLimitAt: nil)
        }
        // A first reading, seen in the popover — which stays open.
        Self.applyFirstReading(f)
        f.presenter.present()
        XCTAssertNil(f.viewModel.deltaLines[.claude], "nothing to compare against yet")

        // The window rolls over while the popover is up, and the reader switches to the window.
        // The window's own open is what computes the boundary line.
        Self.applyRolledOverWindow(f)
        f.presenter.presentWindow()
        // The popover's deferred close notification, arriving late.
        f.popover.deliverLateCloseNotification()

        for _ in 0..<20 where f.viewModel.deltaLines[.claude] == nil { await Task.yield() }
        XCTAssertEqual(f.lifecycle.current, .window)
        XCTAssertNotNil(f.viewModel.deltaLines[.claude],
                        "the window's boundary read must survive the popover's late cleanup")
        XCTAssertTrue(f.viewModel.deltaLines[.claude]?.contains("94%") == true)
    }

    /// **Re-opening onto the surface that is already up is a switch too.** A notification's
    /// **Open Kvotar** while the popover is showing, and `Set up <tool>…` from the same place,
    /// both land here — and a bare `performClose` before the reopen leaves its deferred handler to
    /// erase the line the reopen has just computed. Same defect as the switch above, one surface.
    func testReopeningOntoTheSamePopoverKeepsItsBoundaryLine() async {
        let f = makeFixture()
        f.viewModel.loadWindowOutcome = { _, _ in
            await Task.yield()
            return WindowOutcome(resetsAt: Self.origin.addingTimeInterval(2 * 3600),
                                 highWaterPct: 94, hitLimitAt: nil)
        }
        Self.applyFirstReading(f)
        f.presenter.present()
        Self.applyRolledOverWindow(f)

        f.popover.reopenOntoItself(.defaultTab)
        f.popover.deliverLateCloseNotification()

        for _ in 0..<20 where f.viewModel.deltaLines[.claude] == nil { await Task.yield() }
        XCTAssertEqual(f.lifecycle.current, .popover)
        XCTAssertNotNil(f.viewModel.deltaLines[.claude],
                        "the reopen's boundary read must survive its own late cleanup")
    }

    /// The same guard from the other side: a genuine close still clears the line. The fix must not
    /// turn `didClose` into a no-op.
    func testAGenuineCloseStillClearsTheLine() async {
        let f = makeFixture()
        f.viewModel.loadWindowOutcome = { _, _ in
            WindowOutcome(resetsAt: Self.origin.addingTimeInterval(2 * 3600), highWaterPct: 94,
                          hitLimitAt: nil)
        }
        Self.takeFirstReading(f)
        Self.applyRolledOverWindow(f)
        f.presenter.present()
        for _ in 0..<20 where f.viewModel.deltaLines[.claude] == nil { await Task.yield() }
        XCTAssertNotNil(f.viewModel.deltaLines[.claude])

        f.presenter.closeActiveSurface()
        XCTAssertNil(f.viewModel.deltaLines[.claude], "a real close still clears it")
    }

    /// And the close the app did **not** initiate — the user clicking away from a transient
    /// popover — must still clear the reading. The suppression consumes exactly one notification
    /// per app-initiated close and no more; over-swallowing would leave a stale line behind the
    /// next open.
    func testAUserInitiatedCloseAfterASwitchStillClearsTheLine() async {
        let f = makeFixture()
        f.viewModel.loadWindowOutcome = { _, _ in
            WindowOutcome(resetsAt: Self.origin.addingTimeInterval(2 * 3600), highWaterPct: 94,
                          hitLimitAt: nil)
        }
        Self.applyFirstReading(f)
        f.presenter.present()
        Self.applyRolledOverWindow(f)
        f.presenter.presentWindow()          // app-initiated close, one notification owed
        f.popover.deliverLateCloseNotification()
        for _ in 0..<20 where f.viewModel.deltaLines[.claude] == nil { await Task.yield() }
        XCTAssertNotNil(f.viewModel.deltaLines[.claude])

        // Now the reader dismisses the window's content the ordinary way.
        f.window.closedByTheUser()
        XCTAssertNil(f.viewModel.deltaLines[.claude])
        XCTAssertNil(f.lifecycle.current)
    }

    // MARK: Fixture data

    /// The lifecycle calls `selectDefaultTab()` on the **real** clock — as it must in the app — so
    /// the fixture is anchored to now rather than to a fixed epoch, and the second reading lands
    /// at about the instant the test runs.
    private static let origin = Date().addingTimeInterval(-3 * 3600)

    /// The reading a later one is compared against.
    private static func applyFirstReading(_ f: Fixture) {
        f.viewModel.apply(tool: .claude, snapshot: snapshot(used: 40, resetsIn: 2 * 3600),
                          forecast: forecast, state: .healthy,
                          localAttribution: attribution(subagents: 0), now: origin)
    }

    /// A first reading, seen and closed, so the next open has something to compare against.
    private static func takeFirstReading(_ f: Fixture) {
        applyFirstReading(f)
        f.presenter.present()
        f.presenter.togglePopover()
    }

    /// Three hours on: the old window's reset has passed and a new one is running.
    private static func applyRolledOverWindow(_ f: Fixture) {
        f.viewModel.apply(tool: .claude, snapshot: snapshot(used: 3, resetsIn: 7 * 3600),
                          forecast: forecast, state: .healthy,
                          localAttribution: attribution(subagents: 5),
                          now: origin.addingTimeInterval(3 * 3600))
    }

    private static func snapshot(used: Double, resetsIn: TimeInterval) -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: used,
                      primaryResetsAt: origin.addingTimeInterval(resetsIn),
                      primaryWindowSeconds: 18_000,
                      secondaryUsedPct: 14, secondaryResetsAt: nil,
                      rateLimitReached: false, extraUsage: .disabled, planType: "Pro")
    }

    private static var forecast: Forecast {
        Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: nil, burnRatePerMin: 0.4,
                 isEstimate: false, pollCount: 5)
    }

    private static func attribution(subagents: Int) -> LocalAttribution {
        LocalAttribution(project: "/p", model: nil, surfaceBucket: nil, subagentCount: subagents,
                         cacheHitRatio: nil,
                         estValue: EstimatedValueEngine.WindowValue(weekly: 0, thirtyDay: 0),
                         surfaceShares: [], tokensPerMinute: nil, lastActivityAt: nil)
    }
}
