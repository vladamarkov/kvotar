import XCTest
import KvotarCore
@testable import KvotarUI

/// The scoped History destination (STEP_178; typed to four modes in STEP_182). The popover's
/// `N more projects ›` opens the window on one provider's own local day; the footer and the
/// status-item menu keep the ordinary Weekly recap opening.
@MainActor
final class HistoryViewModelDestinationTests: XCTestCase {

    nonisolated override func setUp() {
        super.setUp()
        FixtureTimeZone.pin(self)
    }

    private func activeTool() -> HistoryReport.ToolReport {
        HXFix.tool(.claude, days: HXFix.days([0, 200_000, 0, 300_000, 0]))
    }

    private func model() -> HistoryViewModel {
        HistoryViewModel(experience: HXFix.experience([activeTool()]))
    }

    private func page(_ vm: HistoryViewModel,
                      _ provider: HistoryExperience.Provider) -> HistoryExperience.ExplorePage {
        vm.experience!.pages(provider).explore
    }

    func testNoDestinationKeepsTheOrdinaryOpening() {
        let vm = model()
        vm.prepareForOpen()
        XCTAssertEqual(vm.mode, .weeklyRecap)
        XCTAssertEqual(vm.provider, .all)
        XCTAssertNil(vm.selectedDay)
        XCTAssertFalse(vm.hasPendingDay)
    }

    func testDestinationOpensExploreOnItsProviderAndDay() throws {
        let vm = model()
        let tool = Tool.claude
        let day = try XCTUnwrap(page(vm, .tool(tool)).days.last?.id)
        vm.prepareForOpen(destination: .projects(provider: tool, day: day))
        XCTAssertEqual(vm.mode, .exploreUsage)
        XCTAssertEqual(vm.provider, .tool(tool))
        XCTAssertTrue(vm.hasPendingDay, "the day waits for a page to resolve against")
        XCTAssertEqual(vm.selectedEntry(in: page(vm, .tool(tool)))?.id, day)
    }

    /// The provider setter clears the day selection, so the order the destination applies them in
    /// is load-bearing — this is the pin for it.
    func testProviderIsAppliedBeforeTheDay() throws {
        let vm = model()
        let tool = Tool.claude
        let day = try XCTUnwrap(page(vm, .tool(tool)).days.last?.id)
        vm.prepareForOpen(destination: .projects(provider: tool, day: day))
        vm.commitPendingDay(vm.selectedEntry(in: page(vm, .tool(tool)))!.id)
        XCTAssertEqual(vm.selectedDay, day, "the day survived the provider assignment")
    }

    /// The popover's day is local midnight; History's oldest column starts at the report's period
    /// start, at an arbitrary time of day. Matching by instant would silently fall back to the
    /// page's own default, so the match is by calendar day.
    func testTheDayIsMatchedByCalendarDayNotByInstant() throws {
        let vm = model()
        let tool = Tool.claude
        let column = try XCTUnwrap(page(vm, .tool(tool)).days.last?.id)
        let midnightish = column.addingTimeInterval(7 * 3600)   // same local day, different instant
        vm.prepareForOpen(destination: .projects(provider: tool, day: midnightish))
        XCTAssertEqual(vm.selectedEntry(in: page(vm, .tool(tool)))?.id, column)
    }

    /// A date the report does not cover degrades to the page's own initial selection, exactly as a
    /// stale hand selection already did — never an empty detail.
    func testAForeignDateFallsBackToTheInitialSelection() {
        let vm = model()
        let tool = Tool.claude
        vm.prepareForOpen(destination: .projects(provider: tool, day: Date(timeIntervalSince1970: 0)))
        let p = page(vm, .tool(tool))
        XCTAssertEqual(vm.selectedEntry(in: p)?.id, p.initialSelection)
    }

    /// Committing turns the destination into an ordinary selection, so a later reload or refocus
    /// keeps the day the reader was sent to.
    func testCommittingSurvivesAReload() throws {
        let vm = model()
        let tool = Tool.claude
        let day = try XCTUnwrap(page(vm, .tool(tool)).days.last?.id)
        vm.prepareForOpen(destination: .projects(provider: tool, day: day))
        vm.commitPendingDay(vm.selectedEntry(in: page(vm, .tool(tool)))!.id)
        XCTAssertFalse(vm.hasPendingDay)
        vm.reload()                                    // no loader on this init — a no-op reload
        XCTAssertEqual(vm.selectedDay, day)
    }

    /// A recap evidence link is a scoped open of a different mode: the mode and provider it
    /// names, and no day (a week is not a day column). The banner rides along for STEP_183.
    func testARecapEvidenceLinkOpensItsOwnModeWithNoPendingDay() {
        let vm = model()
        let destination = HistoryDestination(
            mode: .exploreQuota, provider: .claude,
            scope: .week(start: HXFix.utcMidnight, end: HXFix.utcMidnight),
            banner: "From weekly recap · Claude · Aug 3 – Aug 9")
        vm.prepareForOpen(destination: destination)
        XCTAssertEqual(vm.mode, .exploreQuota)
        XCTAssertEqual(vm.provider, .tool(.claude))
        XCTAssertFalse(vm.hasPendingDay, "a week scope selects no day column")
        XCTAssertNotNil(destination.week)
        XCTAssertNil(destination.day)
    }

    /// The next ordinary open clears everything the destination set.
    func testAnOrdinaryOpenAfterADestinationResetsIt() throws {
        let vm = model()
        let tool = Tool.claude
        let day = try XCTUnwrap(page(vm, .tool(tool)).days.last?.id)
        vm.prepareForOpen(destination: .projects(provider: tool, day: day))
        vm.prepareForOpen()
        XCTAssertEqual(vm.mode, .weeklyRecap)
        XCTAssertEqual(vm.provider, .all)
        XCTAssertFalse(vm.hasPendingDay)
    }
}
