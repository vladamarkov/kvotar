import XCTest
import KvotarCore
@testable import KvotarUI

/// STEP_160 — the view model's transient mode/provider/day selection over the precomputed
/// `HistoryExperience` (REV-84 §2): every open starts on Summary · All, switches read memory
/// and never the database, and a selection is a raw day id the pages re-resolve safely.
@MainActor
final class HistoryViewModelSelectionTests: XCTestCase {

    private func model(_ tools: [HistoryReport.ToolReport]) -> HistoryViewModel {
        HistoryViewModel(experience: HistoryDisplay.experience(HXFix.report(tools),
                                                               now: HXFix.now))
    }

    private func activeTool() -> HistoryReport.ToolReport {
        HXFix.tool(.claude, days: HXFix.days([0, 200_000, 0, 300_000, 0]))
    }

    func testDefaultsAreWeeklyRecapAllAndTheModelsOwnDaySelection() {
        let vm = model([activeTool()])
        XCTAssertEqual(vm.mode, .weeklyRecap)
        XCTAssertEqual(vm.provider, .all)
        XCTAssertNil(vm.selectedDay, "nil defers to the page's initialSelection")
        let page = vm.experience!.pages(.all).explore
        XCTAssertEqual(vm.selectedEntry(in: page)?.id, page.initialSelection)
    }

    func testPrepareForOpenResetsModeProviderSelectionAndThePeek() {
        let vm = model([activeTool()])
        vm.mode = .hardBlocks
        vm.provider = .tool(.claude)
        vm.selectDay(HXFix.dayStart(index: 1, of: 5))
        vm.dayHover(3, hovering: true)

        vm.prepareForOpen()
        XCTAssertEqual(vm.mode, .weeklyRecap)
        XCTAssertEqual(vm.provider, .all)
        XCTAssertNil(vm.selectedDay)
        XCTAssertNil(vm.hoveredDay)
        XCTAssertNil(vm.peekedDay)
    }

    func testProviderChangeClearsTheDaySelectionAndModeChangeKeepsIt() {
        let vm = model([activeTool()])
        let day = HXFix.dayStart(index: 1, of: 5)
        vm.selectDay(day)

        vm.mode = .exploreUsage
        XCTAssertEqual(vm.selectedDay, day, "a mode is a lens, not a different period")

        vm.provider = .tool(.claude)
        XCTAssertNil(vm.selectedDay,
                     "a new provider page re-resolves to its own initial selection")
    }

    func testSelectDayNeverTouchesTheHoverStateMachine() async {
        let vm = model([activeTool()])
        vm.hoverPeekDelay = .milliseconds(1)
        vm.dayHover(2, hovering: true)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(vm.peekedDay)

        vm.selectDay(HXFix.dayStart(index: 3, of: 5))
        XCTAssertNotNil(vm.peekedDay,
                        "selection updates only the detail — the card the pointer opened stays")
    }

    func testSelectedEntryFallsBackToInitialSelectionForAForeignDate() {
        let vm = model([activeTool()])
        vm.selectDay(Date(timeIntervalSince1970: 0))
        let page = vm.experience!.pages(.all).explore
        XCTAssertEqual(vm.selectedEntry(in: page)?.id, page.initialSelection,
                       "a stale id from another page resolves to the page's own default")
    }

    func testReloadWithANilReportKeepsThePriorExperience() async {
        let experience = HistoryDisplay.experience(HXFix.report([activeTool()]), now: HXFix.now)
        let vm = HistoryViewModel(experience: experience)
        vm.reload(now: HXFix.now)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(vm.experience, "loading never blanks the window")
        XCTAssertFalse(vm.isLoading)
    }
}
