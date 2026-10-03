import XCTest
@testable import KvotarUI

/// The popover's height budget as the view model carries it (STEP_179).
@MainActor
final class AppViewModelViewportTests: XCTestCase {

    /// Unbounded until a real popover measures a real screen — previews, snapshots and every test
    /// that never opened one keep the pre-STEP_179 hug-your-content path.
    func testPopoverHeightIsUnboundedUntilMeasured() {
        XCTAssertNil(AppViewModel().popoverMaxHeight)
    }

    /// A pinned card is not disturbed by the body scrolling: it is drawn inside the scrolling
    /// content, travels with the row it explains, and is released by the gestures §5.1 names —
    /// click-away, Esc, a tab switch, popover close.
    func testScrollingDoesNotDisturbAPinnedCard() {
        let vm = AppViewModel()
        let target = ExplanationTarget(.heroPercent)
        vm.togglePinnedCard(target)
        XCTAssertEqual(vm.activeCard, target)

        vm.activeTab = vm.activeTab == .claude ? .codex : .claude

        XCTAssertNil(vm.pinnedCard, "a tab switch still releases the pin (§5.1)")
    }
}
