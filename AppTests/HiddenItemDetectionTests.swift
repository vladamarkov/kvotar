import XCTest

/// The gates over the occlusion signal (REV-99 §2.6, contract §1 and §5 — STEP_206; the fourth,
/// screen-away, is the D-122 amendment — STEP_229; the fifth, the menu bar put away, is STEP_234;
/// the notice's launch window is STEP_235).
///
/// Every number here is Spike E's, read off `docs/evidence/SPIKE_E/probe_run3.log` on a
/// 1710 × 1107 pt notched screen with a 39 pt menu bar: the status window is 38 pt tall, sits at
/// `y = 1069` when it is in the bar (top edge exactly 1107, the screen's own), is parked at
/// `y = −38` before macOS places it, and climbs to 1076 → 1100 → 1107 when the bar auto-hides.
///
/// **Two rows are the point of the table** — the launch transient and the auto-hidden bar must
/// both read "not hidden", and both of them report `occluded = true`.
final class HiddenItemDetectionTests: XCTestCase {

    private let screenMinY: CGFloat = 0
    private let screenMaxY: CGFloat = 1107
    private let windowHeight: CGFloat = 38

    private func reading(y: CGFloat, occluded: Bool, away: Bool = false,
                         barAway: Bool = false) -> HiddenItemDetection.Reading {
        HiddenItemDetection.Reading(isOccluded: occluded, windowMaxY: y + windowHeight,
                                    screenMinY: screenMinY, screenMaxY: screenMaxY,
                                    isScreenAway: away, isMenuBarAway: barAway)
    }

    private func verdict(y: CGFloat, occluded: Bool, placed: Bool = true, away: Bool = false,
                         barAway: Bool = false) -> HiddenItemDetection.Verdict {
        HiddenItemDetection.verdict(reading(y: y, occluded: occluded, away: away, barAway: barAway),
                                    hasBeenPlaced: placed)
    }

    // MARK: The truth table (contract §5 item 25)

    func testPlacedAndOccludedInTheBarIsHidden() {
        XCTAssertEqual(verdict(y: 1069, occluded: true), .hidden)
    }

    func testPlacedAndNotOccludedIsOnScreen() {
        XCTAssertEqual(verdict(y: 1069, occluded: false), .onScreen)
    }

    /// The launch transient — occluded, and on **every** launch. A detector that read occlusion at
    /// startup would always see "hidden".
    func testTheLaunchTransientIsNotHidden() {
        XCTAssertEqual(verdict(y: -38, occluded: true, placed: false), .notPlacedYet)
    }

    /// Auto-hide: occlusion goes false, but the window's top edge leaves the screen. It must never
    /// be reported as a hidden item — and the rule must hold whichever way occlusion happens to
    /// read while the bar is away.
    func testAnAutoHiddenBarIsNotAHiddenItem() {
        for y in [CGFloat(1076), 1100, 1107] {
            XCTAssertEqual(verdict(y: y, occluded: true), .barAutoHidden, "y=\(y)")
            XCTAssertEqual(verdict(y: y, occluded: false), .barAutoHidden, "y=\(y)")
        }
    }

    /// The in-bar top edge lands *exactly* on the screen's, so the comparison has to be inclusive:
    /// an exclusive one would call every hidden item an auto-hidden bar and report nothing, ever.
    func testTheItemInTheBarSitsExactlyOnTheScreensTopEdge() {
        XCTAssertEqual(1069 + windowHeight, screenMaxY)
        XCTAssertTrue(HiddenItemDetection.isInMenuBar(windowMaxY: screenMaxY,
                                                      screenMaxY: screenMaxY))
        XCTAssertFalse(HiddenItemDetection.isInMenuBar(windowMaxY: screenMaxY + 7,
                                                       screenMaxY: screenMaxY))
    }

    // MARK: Placement (contract §5 item 26)

    func testPlacementReadsTheParkedFrameAsUnplaced() {
        XCTAssertFalse(HiddenItemDetection.isPlaced(windowMaxY: -38 + windowHeight,
                                                    screenMinY: screenMinY))
        XCTAssertTrue(HiddenItemDetection.isPlaced(windowMaxY: 1069 + windowHeight,
                                                   screenMinY: screenMinY))
    }

    /// Placement is a latch: an item macOS later hides keeps its position, and the first gate must
    /// not re-open underneath it. The reading below is the *hidden* one — same frame, still placed.
    func testAPlacedItemStaysPlacedOnceHidden() {
        XCTAssertEqual(verdict(y: 1069, occluded: true, placed: true), .hidden)
    }

    /// Placement is deliberately independent of the menu bar's thickness — that measurement goes
    /// to zero while the bar is auto-hidden, and a gate must not depend on something that can
    /// vanish. An auto-hidden bar is judged by gate 2, and it still counts as placed.
    func testAnAutoHiddenBarIsStillPlaced() {
        XCTAssertTrue(HiddenItemDetection.isPlaced(windowMaxY: 1107 + windowHeight,
                                                   screenMinY: screenMinY))
    }

    // MARK: The sustain (contract §5 item 27)

    /// The bar churns while other apps claim their slots — the probe logged the item moving four
    /// times in the first minute after a sign-in. A reading that flips back before the wait is up
    /// confirms nothing.
    func testAReadingThatFlipsBackConfirmsNothing() {
        var tracker = HiddenItemDetection.Tracker()
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .armConfirmation)
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: false)), .cancelConfirmation)
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: false)), .nothing)
        XCTAssertFalse(tracker.isHiddenConfirmed)
    }

    /// Armed on the **edge into hidden**: a stream of hidden readings must not keep pushing the
    /// confirmation out, which is how a churning bar would delay the notice forever.
    func testRepeatedHiddenReadingsDoNotRearmTheWait() {
        var tracker = HiddenItemDetection.Tracker()
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .armConfirmation)
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .nothing)
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .nothing)
    }

    /// The whole launch, in order: parked and occluded, placed and occluded, still occluded five
    /// seconds later. The first reading must not arm anything — it is the transient every launch
    /// has — and the latch set by the second is what lets the third be judged at all.
    func testTheLaunchSequenceArmsOnlyAfterPlacement() {
        var tracker = HiddenItemDetection.Tracker()
        XCTAssertEqual(tracker.observe(reading(y: -38, occluded: true)), .nothing)
        XCTAssertFalse(tracker.hasBeenPlaced)
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .armConfirmation)
        XCTAssertTrue(tracker.hasBeenPlaced)
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true)),
                       .confirmed(notice: true))
        XCTAssertTrue(tracker.isHiddenConfirmed)
    }

    /// The gates are re-checked against the **current** reading, not the one that armed the timer.
    func testTheWaitIsJudgedOnTheCurrentReading() {
        var tracker = HiddenItemDetection.Tracker()
        _ = tracker.observe(reading(y: 1069, occluded: true))
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1100, occluded: true)), .nothing,
                       "the bar auto-hid while we waited")
        XCTAssertFalse(tracker.isHiddenConfirmed)
    }

    /// A reading we could not take is not a state we may claim.
    func testAnUnreadableWaitConfirmsNothing() {
        var tracker = HiddenItemDetection.Tracker()
        _ = tracker.observe(reading(y: 1069, occluded: true))
        XCTAssertEqual(tracker.confirmationLapsed(nil), .nothing)
        XCTAssertFalse(tracker.isHiddenConfirmed)
    }

    /// The item coming back clears the confirmation — the routing input is live truth, so a user
    /// who frees a menu-bar slot gets their popover back.
    func testAConfirmationClearsWhenTheItemReturns() {
        var tracker = HiddenItemDetection.Tracker()
        _ = tracker.observe(reading(y: 1069, occluded: true))
        _ = tracker.confirmationLapsed(reading(y: 1069, occluded: true))
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: false)), .cleared)
        XCTAssertFalse(tracker.isHiddenConfirmed)
    }

    // MARK: The notice budget (contract §5 item 28)

    /// Two confirmations, one notice — and the second confirmation **still routes**. Twice is
    /// nagging about something the user has already been told and may have chosen to live with;
    /// leaving the routing capped with it would send them back to an icon that is still not there.
    func testASecondConfirmationRoutesButDoesNotNoticeAgain() {
        var tracker = HiddenItemDetection.Tracker()
        _ = tracker.observe(reading(y: 1069, occluded: true))
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true)),
                       .confirmed(notice: true))
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: false)), .cleared)

        _ = tracker.observe(reading(y: 1069, occluded: true))
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true)),
                       .confirmed(notice: false))
        XCTAssertTrue(tracker.isHiddenConfirmed)
    }

    // MARK: The screen is away (STEP_229 contract §5 items 13–14)

    /// A sleeping display or a locked session reports the status window occluded without moving
    /// it — the reading that fired a notice at a dark screen on 2026-09-30. Screen-away wins over
    /// **every** other combination, including the exact reading that is `.hidden` without it.
    func testAScreenThatIsAwayIsNeverAHiddenItem() {
        XCTAssertEqual(verdict(y: 1069, occluded: true), .hidden)
        for y in [CGFloat(-38), 1069, 1076, 1107] {
            for occluded in [true, false] {
                for placed in [true, false] {
                    let result = verdict(y: y, occluded: occluded, placed: placed, away: true)
                    XCTAssertEqual(result, .screenAway, "y=\(y) occluded=\(occluded) placed=\(placed)")
                    XCTAssertFalse(result.isHidden)
                }
            }
        }
    }

    /// The frame is not trustworthy while the screen is dark, so placement is learned from a real
    /// reading: the same frame latches the moment the screen is back.
    func testAScreenAwayReadingDoesNotLatchPlacement() {
        var tracker = HiddenItemDetection.Tracker()
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true, away: true)), .nothing)
        XCTAssertFalse(tracker.hasBeenPlaced)
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .armConfirmation)
        XCTAssertTrue(tracker.hasBeenPlaced)
    }

    /// The screen went away inside the wait: the signal cancels at once, and the timer's own
    /// re-check would have stopped it anyway.
    func testAScreenThatGoesAwayDuringTheWaitConfirmsNothing() {
        var tracker = HiddenItemDetection.Tracker()
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .armConfirmation)
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true, away: true)),
                       .cancelConfirmation)
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true, away: true)),
                       .nothing)
        XCTAssertFalse(tracker.isHiddenConfirmed)
    }

    /// Occlusion first, the sleep/lock signal second, and no evaluation in between — the ordering
    /// nobody has measured. The wait is judged on the current reading, so the notice still does
    /// not post.
    func testOccludedThenAwayInsideTheWaitGivesNoNotice() {
        var tracker = HiddenItemDetection.Tracker()
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .armConfirmation)
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true, away: true)),
                       .nothing)
        XCTAssertFalse(tracker.isHiddenConfirmed)
    }

    /// A genuinely hidden item is un-confirmed while the screen is away — routing follows live
    /// truth, and nobody is clicking a dark screen.
    func testAConfirmationClearsWhenTheScreenGoesAway() {
        var tracker = HiddenItemDetection.Tracker()
        _ = tracker.observe(reading(y: 1069, occluded: true))
        _ = tracker.confirmationLapsed(reading(y: 1069, occluded: true))
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true, away: true)), .cleared)
        XCTAssertFalse(tracker.isHiddenConfirmed)
    }

    /// …and it is re-confirmed once the screen is back, silently: the launch's one notice was
    /// spent before the lock.
    func testAHiddenItemIsReconfirmedSilentlyWhenTheScreenComesBack() {
        var tracker = HiddenItemDetection.Tracker()
        _ = tracker.observe(reading(y: 1069, occluded: true))
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true)),
                       .confirmed(notice: true))
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true, away: true)), .cleared)

        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .armConfirmation)
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true)),
                       .confirmed(notice: false))
        XCTAssertTrue(tracker.isHiddenConfirmed)
    }

    // MARK: The menu bar is put away (STEP_234 contract §5 items 17–20)

    /// An app in full screen covers the bar and the status window reports occluded without
    /// moving — the reading that posted a notice over a full-screen Terminal on 2026-10-01. What
    /// tells it apart is that no other app's item is on screen either.
    func testAnOccludedItemUnderABarThatIsAwayIsNotHidden() {
        XCTAssertEqual(verdict(y: 1069, occluded: true), .hidden)
        let result = verdict(y: 1069, occluded: true, barAway: true)
        XCTAssertEqual(result, .menuBarAway)
        XCTAssertFalse(result.isHidden)
    }

    /// Only the last line of the rule changes: every gate above it keeps its verdict and its
    /// order, and an item that is plainly on screen stays on screen whatever the count said.
    func testABarThatIsAwayChangesNoOtherVerdict() {
        XCTAssertEqual(verdict(y: 1069, occluded: false, barAway: true), .onScreen)
        XCTAssertEqual(verdict(y: -38, occluded: true, placed: false, barAway: true), .notPlacedYet)
        XCTAssertEqual(verdict(y: 1100, occluded: true, barAway: true), .barAutoHidden)
        XCTAssertEqual(verdict(y: 1069, occluded: true, away: true, barAway: true), .screenAway)
    }

    /// The row that separates this gate from screen-away: the frame is real under a full-screen
    /// app — the item never moved in the probe — so placement is learned from it.
    func testABarAwayReadingLatchesPlacement() {
        var tracker = HiddenItemDetection.Tracker()
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true, barAway: true)), .nothing)
        XCTAssertTrue(tracker.hasBeenPlaced)
    }

    /// The measured entry order: occlusion first, the count a moment later (under 0.35 s in the
    /// probe), carried by the Space change.
    func testABarThatGoesAwayDuringTheWaitConfirmsNothing() {
        var tracker = HiddenItemDetection.Tracker()
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .armConfirmation)
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true, barAway: true)),
                       .cancelConfirmation)
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true, barAway: true)),
                       .nothing)
        XCTAssertFalse(tracker.isHiddenConfirmed)
    }

    /// …and if no event came between, the wait is judged on the current reading.
    func testOccludedThenBarAwayInsideTheWaitGivesNoNotice() {
        var tracker = HiddenItemDetection.Tracker()
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .armConfirmation)
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true, barAway: true)),
                       .nothing)
        XCTAssertFalse(tracker.isHiddenConfirmed)
    }

    func testABarAwayReadingNeverArms() {
        var tracker = HiddenItemDetection.Tracker()
        _ = tracker.observe(reading(y: 1069, occluded: false))
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true, barAway: true)), .nothing)
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true, barAway: true)), .nothing)
        XCTAssertFalse(tracker.isHiddenConfirmed)
    }

    /// Where this gate parts from screen-away (owner ruling 2026-10-01). People click
    /// notifications over a full-screen app, so a user whose item is genuinely hidden must keep
    /// landing in the window: the confirmation stands through the film, and the hidden reading
    /// when it ends announces nothing new.
    func testAStandingConfirmationHoldsWhileTheBarIsAway() {
        var tracker = HiddenItemDetection.Tracker()
        _ = tracker.observe(reading(y: 1069, occluded: true))
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true)),
                       .confirmed(notice: true))

        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true, barAway: true)), .nothing)
        XCTAssertTrue(tracker.isHiddenConfirmed)
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .nothing)
        XCTAssertTrue(tracker.isHiddenConfirmed)
    }

    /// A held confirmation still ends the ordinary way: the bar slid down with the item in it,
    /// or full screen ended and the item has room.
    func testAHeldConfirmationClearsWhenTheItemIsSeen() {
        var tracker = HiddenItemDetection.Tracker()
        _ = tracker.observe(reading(y: 1069, occluded: true))
        _ = tracker.confirmationLapsed(reading(y: 1069, occluded: true))
        _ = tracker.observe(reading(y: 1069, occluded: true, barAway: true))
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: false, barAway: true)), .cleared)
        XCTAssertFalse(tracker.isHiddenConfirmed)
    }

    /// Screen-away still wins: a lock during a film clears, as STEP_229 says.
    func testAHeldConfirmationClearsWhenTheScreenGoesAway() {
        var tracker = HiddenItemDetection.Tracker()
        _ = tracker.observe(reading(y: 1069, occluded: true))
        _ = tracker.confirmationLapsed(reading(y: 1069, occluded: true))
        _ = tracker.observe(reading(y: 1069, occluded: true, barAway: true))
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true, away: true, barAway: true)),
                       .cleared)
        XCTAssertFalse(tracker.isHiddenConfirmed)
    }

    /// An item that became hidden while the bar was away — a launch inside full screen onto a
    /// full bar — is the user the notice is for. It is armed when the bar returns and told once.
    func testAnItemHiddenUnderABarThatWasAwayIsConfirmedWhenTheBarReturns() {
        var tracker = HiddenItemDetection.Tracker()
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true, barAway: true)), .nothing)
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .armConfirmation)
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true)),
                       .confirmed(notice: true))
    }

    /// …and silently once the launch's notice is spent.
    func testTheSameRecoveryIsSilentOnASpentBudget() {
        var tracker = HiddenItemDetection.Tracker()
        _ = tracker.observe(reading(y: 1069, occluded: true))
        _ = tracker.confirmationLapsed(reading(y: 1069, occluded: true))
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: false)), .cleared)

        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true, barAway: true)), .nothing)
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .armConfirmation)
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true)),
                       .confirmed(notice: false))
    }

    /// Leaving full screen: for up to 0.55 s in the probe the other apps' items were back while
    /// this one still read occluded. Armed, then cancelled — a tenth of the wait.
    func testTheExitTransitionArmsAndCancels() {
        var tracker = HiddenItemDetection.Tracker()
        _ = tracker.observe(reading(y: 1069, occluded: true, barAway: true))
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .armConfirmation)
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: false)), .cancelConfirmation)
        XCTAssertFalse(tracker.isHiddenConfirmed)
    }

    /// The count's mapping. A list that cannot be read is not a bar that is away.
    func testOnlyAZeroCountMeansTheBarIsAway() {
        XCTAssertTrue(HiddenItemDetection.isMenuBarAway(statusWindowsOnScreen: 0))
        XCTAssertFalse(HiddenItemDetection.isMenuBarAway(statusWindowsOnScreen: 14))
        XCTAssertFalse(HiddenItemDetection.isMenuBarAway(statusWindowsOnScreen: 1))
        XCTAssertFalse(HiddenItemDetection.isMenuBarAway(statusWindowsOnScreen: nil))
    }

    // MARK: The constants (UI Spec §5)

    // MARK: The notice belongs to the launch (STEP_235 contract §3 items 9–12)

    /// The shape that posted the notice at 23:44 on 2026-10-01, 36 minutes into a launch: the
    /// popover open under a full-screen app, the bar slid away, one status-level window left on
    /// screen. The confirmation stands — and nothing is announced.
    func testAConfirmationLongAfterLaunchIsNeverAnnounced() {
        var tracker = HiddenItemDetection.Tracker()
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .armConfirmation)
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true),
                                                  sinceLaunch: 2189),
                       .confirmed(notice: false))
        XCTAssertTrue(tracker.isHiddenConfirmed, "the routing input still follows it")
    }

    /// The window's edge is inclusive, and it is judged when the wait lapses.
    func testTheNoticeWindowIsInclusiveAtItsEdge() {
        let window = HiddenItemDetection.noticeWindowSeconds
        var atTheEdge = HiddenItemDetection.Tracker()
        _ = atTheEdge.observe(reading(y: 1069, occluded: true))
        XCTAssertEqual(atTheEdge.confirmationLapsed(reading(y: 1069, occluded: true),
                                                    sinceLaunch: window),
                       .confirmed(notice: true))

        var justPast = HiddenItemDetection.Tracker()
        _ = justPast.observe(reading(y: 1069, occluded: true))
        XCTAssertEqual(justPast.confirmationLapsed(reading(y: 1069, occluded: true),
                                                   sinceLaunch: window + 0.1),
                       .confirmed(notice: false))
    }

    /// The four genuine launch-time confirmations in the owner's log landed 5.0 s (three times)
    /// and 39.2 s in.
    func testAHiddenItemAtLaunchIsAnnounced() {
        for age: TimeInterval in [5.0, 39.2] {
            var tracker = HiddenItemDetection.Tracker()
            _ = tracker.observe(reading(y: 1069, occluded: true))
            XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true),
                                                      sinceLaunch: age),
                           .confirmed(notice: true), "at \(age) s")
        }
    }

    /// One at launch, and the later one is silent twice over — the budget and the window.
    func testALateConfirmationAfterALaunchNoticeIsSilent() {
        var tracker = HiddenItemDetection.Tracker()
        _ = tracker.observe(reading(y: 1069, occluded: true))
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true), sinceLaunch: 5),
                       .confirmed(notice: true))
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: false)), .cleared)

        _ = tracker.observe(reading(y: 1069, occluded: true))
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true),
                                                  sinceLaunch: 900),
                       .confirmed(notice: false))
    }

    /// A late confirmation does not make an early one possible, and does not block one either:
    /// the gate is the launch's age alone. (Time only runs forward; this pins that the rule holds
    /// no state of its own.)
    func testALateConfirmationSpendsNoBudget() {
        var tracker = HiddenItemDetection.Tracker()
        _ = tracker.observe(reading(y: 1069, occluded: true))
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true),
                                                  sinceLaunch: 900),
                       .confirmed(notice: false))
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: false)), .cleared)

        _ = tracker.observe(reading(y: 1069, occluded: true))
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true), sinceLaunch: 5),
                       .confirmed(notice: true))
    }

    /// An item that became hidden under a full-screen app is still confirmed when the bar
    /// returns — silently, if that is after the launch's first minute (the trade STEP_235 takes
    /// against STEP_234's "announced when the menu bar returns").
    func testAnItemHiddenUnderABarThatWasAwayIsConfirmedSilentlyOnceTheLaunchHasPassed() {
        var tracker = HiddenItemDetection.Tracker()
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true, barAway: true)), .nothing)
        XCTAssertEqual(tracker.observe(reading(y: 1069, occluded: true)), .armConfirmation)
        XCTAssertEqual(tracker.confirmationLapsed(reading(y: 1069, occluded: true),
                                                  sinceLaunch: 1800),
                       .confirmed(notice: false))
        XCTAssertTrue(tracker.isHiddenConfirmed)
    }

    // MARK: The constants (UI Spec §5)

    func testTheConstantsAreTheSpecsNumbers() {
        XCTAssertEqual(HiddenItemDetection.confirmSeconds, 5)
        XCTAssertEqual(HiddenItemDetection.noticePerLaunch, 1)
        XCTAssertEqual(HiddenItemDetection.noticeWindowSeconds, 60)
    }
}

private extension HiddenItemDetection.Tracker {
    /// Every sequence written before STEP_235 is about a confirmation at launch, inside the
    /// notice's window; the rows above are the ones that move the clock.
    mutating func confirmationLapsed(_ reading: HiddenItemDetection.Reading?) -> Effect {
        confirmationLapsed(reading, sinceLaunch: 0)
    }
}
