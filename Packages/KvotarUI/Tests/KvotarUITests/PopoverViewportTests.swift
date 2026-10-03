import XCTest
import CoreGraphics
@testable import KvotarUI

/// The popover's height budget and the two rules hanging off it (Baseline §15.2, UI Spec §REV92
/// *Appearance and fit* — STEP_179).
final class PopoverViewportTests: XCTestCase {

    // MARK: The budget

    /// A tall display: the room under the status item, less the margin that keeps the callout and
    /// shadow off the screen edge.
    func testAvailableHeightIsTheRoomUnderTheStatusItem() {
        let visible = CGRect(x: 0, y: 0, width: 1_512, height: 944)
        let height = PopoverViewport.availableHeight(screenVisibleFrame: visible, anchorMinY: 920)
        XCTAssertEqual(height, 920 - 0 - PopoverViewport.bottomMargin)
    }

    /// A screen whose visible frame starts above zero — a second display below the main one, or a
    /// Dock at the bottom. The budget is measured from that frame, not from the screen's origin.
    func testAvailableHeightMeasuresFromTheVisibleFrameNotTheScreen() {
        let visible = CGRect(x: 0, y: 300, width: 1_512, height: 500)
        let height = PopoverViewport.availableHeight(screenVisibleFrame: visible, anchorMinY: 780)
        XCTAssertEqual(height, 780 - 300 - PopoverViewport.bottomMargin)
    }

    /// A short screen still hands back a usable scrolling box. Nothing is lost by insisting on the
    /// floor — the body scrolls.
    func testAvailableHeightNeverFallsBelowTheFloor() {
        let visible = CGRect(x: 0, y: 0, width: 1_024, height: 200)
        let height = PopoverViewport.availableHeight(screenVisibleFrame: visible, anchorMinY: 180)
        XCTAssertEqual(height, PopoverViewport.minimumHeight)
    }

    /// A nonsensical anchor (below its own screen) cannot produce a negative popover.
    func testAvailableHeightSurvivesAnAnchorBelowTheVisibleFrame() {
        let visible = CGRect(x: 0, y: 500, width: 1_024, height: 400)
        let height = PopoverViewport.availableHeight(screenVisibleFrame: visible, anchorMinY: 100)
        XCTAssertEqual(height, PopoverViewport.minimumHeight)
    }

    // MARK: The window's own budget (REV-99 §2.2 — STEP_204)

    /// The window hangs off nothing, so its budget is the screen's own visible frame less the
    /// title bar and the same bottom margin — not the room under the status item.
    func testWindowBudgetIsTheScreenLessItsChrome() {
        let visible = CGRect(x: 0, y: 0, width: 1_512, height: 944)
        let height = PopoverViewport.windowAvailableHeight(screenVisibleFrame: visible,
                                                           chromeHeight: 28)
        XCTAssertEqual(height, 944 - 28 - PopoverViewport.bottomMargin)
    }

    /// A short display still gets a usable scrolling box. This is the case the whole rule exists
    /// for: without a cap the content grows to its natural height and the recovery window itself
    /// becomes unreachable.
    func testWindowBudgetHoldsTheFloorOnAShortDisplay() {
        let visible = CGRect(x: 0, y: 0, width: 1_024, height: 200)
        let height = PopoverViewport.windowAvailableHeight(screenVisibleFrame: visible,
                                                           chromeHeight: 28)
        XCTAssertEqual(height, PopoverViewport.minimumHeight)
    }

    /// Chrome taller than the screen cannot produce a negative window.
    func testWindowBudgetSurvivesNonsensicalChrome() {
        let visible = CGRect(x: 0, y: 0, width: 1_024, height: 400)
        let height = PopoverViewport.windowAvailableHeight(screenVisibleFrame: visible,
                                                           chromeHeight: 900)
        XCTAssertEqual(height, PopoverViewport.minimumHeight)
    }

    /// **It is never `nil`.** `bodyHeight` reads `nil` as *apply no frame at all*, which removes
    /// the one scroll view's cap — so a budget that could be absent would defeat itself. Swept,
    /// because the failure is silent and only shows up on a display nobody tested on.
    func testWindowBudgetAlwaysCaps() {
        for height in stride(from: CGFloat(0), through: 2_000, by: 97) {
            for chrome in [CGFloat(0), 28, 120] {
                let budget = PopoverViewport.windowAvailableHeight(
                    screenVisibleFrame: CGRect(x: 0, y: 0, width: 1_024, height: height),
                    chromeHeight: chrome)
                XCTAssertGreaterThanOrEqual(budget, PopoverViewport.minimumHeight)
                XCTAssertNotNil(PopoverViewport.bodyHeight(contentHeight: 4_000, tabBarHeight: 32,
                                                           maxHeight: budget))
            }
        }
    }

    // MARK: Hug or cap

    /// Unbounded is the pre-STEP_179 path: no frame at all, the popover hugs its content.
    func testNoMaxHeightLeavesTheBodyUnframed() {
        XCTAssertNil(PopoverViewport.bodyHeight(contentHeight: 1_400, tabBarHeight: 32,
                                                maxHeight: nil))
    }

    /// Before the content has measured itself there is nothing to frame it to.
    func testUnmeasuredContentLeavesTheBodyUnframed() {
        XCTAssertNil(PopoverViewport.bodyHeight(contentHeight: 0, tabBarHeight: 32,
                                                maxHeight: 700))
    }

    /// A short state hugs: its frame is its own content height, not the budget.
    func testShortContentHugs() {
        XCTAssertEqual(PopoverViewport.bodyHeight(contentHeight: 320, tabBarHeight: 32,
                                                  maxHeight: 700), 320)
    }

    /// A long state is capped at what is left after the pinned tab bar — the tabs are outside the
    /// scrolling body, so they are not part of its budget.
    func testLongContentIsCappedBelowTheTabBar() {
        XCTAssertEqual(PopoverViewport.bodyHeight(contentHeight: 1_400, tabBarHeight: 32,
                                                  maxHeight: 700), 668)
    }

    /// A tabless single-tool popover (D-68) spends the whole budget on its body.
    func testNoTabBarSpendsTheWholeBudget() {
        XCTAssertEqual(PopoverViewport.bodyHeight(contentHeight: 1_400, tabBarHeight: 0,
                                                  maxHeight: 700), 700)
    }

    /// A budget smaller than its own tab bar clamps at zero rather than going negative.
    func testBudgetSmallerThanTheTabBarClampsAtZero() {
        XCTAssertEqual(PopoverViewport.bodyHeight(contentHeight: 400, tabBarHeight: 90,
                                                  maxHeight: 40), 0)
    }
}
