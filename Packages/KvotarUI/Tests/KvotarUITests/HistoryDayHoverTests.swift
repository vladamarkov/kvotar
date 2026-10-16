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

    // MARK: - Explore quota hover

    private func quotaSection() -> HistoryExperience.QuotaSection {
        let windows = (1...3).map {
            HXFix.quotaWindow(.claude, daysBack: 3, hour: 5 * $0, used: 50)
        }
        return HXFix.pages([HXFix.tool(.claude, quotaWindows: windows)], .tool(.claude))
            .quota.sections[0]
    }

    /// The quota chart's card waits for no timer: the pointer is somewhere over a plot of many
    /// marks, and the card shows the nearest window at once.
    func testAQuotaHoverShowsItsCardAtOnce() {
        let vm = model()
        let section = quotaSection()
        vm.quotaHover(section, atX: section.points[1].x)
        XCTAssertEqual(vm.quotaHover?.pointID, section.points[1].id)
        XCTAssertEqual(vm.peekedDay, .quota(section.points[1].id), "no peek delay")
        XCTAssertEqual(vm.hoveredDay, vm.peekedDay)

        vm.quotaHoverEnded()
        XCTAssertNil(vm.quotaHover)
        XCTAssertNil(vm.peekedDay)
    }

    func testEscDropsAQuotaCardToo() {
        let vm = model()
        let section = quotaSection()
        vm.quotaHover(section, atX: 0.5)
        vm.releaseDayPeek()
        XCTAssertNil(vm.quotaHover)
        XCTAssertNil(vm.peekedDay)
    }

    func testAClickSelectsTheWindowNearestThePointer() {
        let vm = model()
        let section = quotaSection()
        vm.selectQuotaPoint(nearestTo: section, atX: section.points[2].x + 0.001)
        XCTAssertEqual(vm.selectedQuotaPoint, section.points[2].id)
    }

    /// A click on the weekly chart selects a week, and the page resolves it like any point.
    func testAClickOnTheWeeklyChartSelectsTheWeek() {
        let vm = model()
        let end = HXFix.now.addingTimeInterval(-5 * 86_400)
        let page = HXFix.pages([HXFix.tool(.claude, quotaWindows: [HXFix.quotaWindow(daysBack: 2)],
                                           weeklyLimits: [HXFix.weeklyLimit(endedAt: end, used: 40)])],
                               .tool(.claude)).quota
        let section = page.sections[0]
        vm.selectQuotaPoint(nearestTo: section, atX: 0.3, chart: .weekly)
        XCTAssertEqual(vm.selectedQuotaPoint, section.weeklyPoints[0].id)
        XCTAssertEqual(vm.resolvedQuotaPoint(in: page)?.id, section.weeklyPoints[0].id)
        vm.quotaHover(section, atX: 0.3, chart: .weekly)
        XCTAssertEqual(vm.peekedDay, .quota("\(section.weeklyPoints[0].id)@0"))
    }
}
