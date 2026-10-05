import XCTest
import KvotarCore
@testable import KvotarUI

/// STEP_116 — the day strip's hover state. Peek only: a day is data, not a registry element, so
/// there is nothing to pin and nothing to keep open and read. Timings are shrunk here the way
/// `AppViewModel`'s are in the popover's tests.
@MainActor
final class HistoryDayHoverTests: XCTestCase {

    private let clock = ManualClock()

    private func model() -> HistoryViewModel {
        let vm = HistoryViewModel(load: { nil })
        vm.hoverPeekDelay = .milliseconds(20)
        vm.hoverGraceLeave = .milliseconds(20)
        vm.hoverClock = clock
        return vm
    }

    /// Moves the injected clock past both timers; nothing here sleeps on the wall clock (STEP_277).
    private func settle(_ ms: Int = 60) async {
        await clock.advance(ms)
    }

    func testRestingOnADayOpensItsCardAfterTheDelayAndNotBefore() async {
        let vm = model()
        vm.dayHover(4, hovering: true)
        XCTAssertEqual(vm.hoveredDay, .day(4))
        XCTAssertNil(vm.peekedDay, "nothing at rest — the card waits out the peek delay")
        await settle()
        XCTAssertEqual(vm.peekedDay, .day(4))
    }

    func testLeavingBeforeTheDelayNeverOpensACard() async {
        let vm = model()
        vm.dayHover(4, hovering: true)
        vm.dayHover(4, hovering: false)
        await settle()
        XCTAssertNil(vm.peekedDay)
        XCTAssertNil(vm.hoveredDay)
    }

    func testSlidingAlongTheStripSwapsTheCardWithoutPayingTheDelayAgain() async {
        let vm = model()
        vm.dayHover(4, hovering: true)
        await settle()
        vm.dayHover(5, hovering: true)
        XCTAssertEqual(vm.peekedDay, .day(5), "already open — the next day swaps in at once")
    }

    func testLeavingTheStripDismissesAfterTheGrace() async {
        let vm = model()
        vm.dayHover(4, hovering: true)
        await settle()
        vm.dayHover(4, hovering: false)
        await settle()
        XCTAssertNil(vm.peekedDay)
    }

    func testReleaseDropsTheCardAtOnce() async {
        let vm = model()
        vm.dayHover(4, hovering: true)
        await settle()
        vm.releaseDayPeek()
        XCTAssertNil(vm.peekedDay)
        XCTAssertNil(vm.hoveredDay)
    }

    /// Two charts, one card (STEP_120). Column 4 of the day strip and 4 pm of the hour chart are
    /// different places, and moving between them must not leave two cards up.
    func testTheHourChartSharesTheCardWithoutColliding() async {
        let vm = model()
        vm.dayHover(4, hovering: true)
        await settle()
        XCTAssertEqual(vm.peekedDay, .day(4))

        vm.hourHover(4, hovering: true)
        XCTAssertEqual(vm.peekedDay, .hour(4), "the same index in the other chart is another card")

        vm.hourHover(4, hovering: false)
        await settle()
        XCTAssertNil(vm.peekedDay, "one timer, one card — nothing is left behind")
    }
}
