import XCTest
import KvotarCore
@testable import KvotarUI

/// The four-mode window's transient controls (STEP_183 — REV-93 / UI Spec §6.0–§6.3): the
/// **mode-local** provider filter, recap week navigation, following an evidence link inside the
/// window, and the scope banner it arrives with.
///
/// Everything here is presentation state over one precomputed report. Nothing reloads, nothing is
/// persisted, and no figure moves — a scope narrows attention, never a population.
@MainActor
final class HistoryViewModelNavigationTests: XCTestCase {

    private func tools() -> [HistoryReport.ToolReport] {
        // 30 varying days, so consecutive weeks differ enough to earn the §6.2 usage-pattern
        // insight — the one that links to Explore usage.
        [HXFix.tool(.claude,
                    days: HXFix.days((0..<30).map { 400_000 + $0 * 120_000 }),
                    quotaWindows: (0..<12).map { HXFix.quotaWindow(.claude, daysBack: Double($0)) },
                    // Weekly lines are what link a recap to Explore quota (D-129).
                    weeklyLimits: [3, 10, 17].map {
                        HXFix.weeklyLimit(endedAt: HXFix.now.addingTimeInterval(-Double($0) * 86_400),
                                          used: 40)
                    }),
         HXFix.tool(.codex,
                    days: HXFix.days((0..<30).map { 900_000 - $0 * 20_000 }),
                    quotaWindows: (0..<6).map {
                        HXFix.quotaWindow(.codex, daysBack: Double($0), width: 604_800)
                    })]
    }

    private func model() -> HistoryViewModel {
        HistoryViewModel(experience: HXFix.experience(tools()))
    }

    // MARK: - The provider filter is mode-local (§6.0)

    func testEachEvidenceModeKeepsItsOwnProvider() {
        let vm = model()
        vm.mode = .exploreQuota
        vm.provider = .tool(.codex)
        vm.mode = .exploreUsage
        XCTAssertEqual(vm.provider, .all, "a second mode is not silently re-scoped")
        vm.provider = .tool(.claude)
        vm.mode = .exploreQuota
        XCTAssertEqual(vm.provider, .tool(.codex), "the first mode kept its own choice")
    }

    func testOpeningResetsEveryModesProvider() {
        let vm = model()
        vm.mode = .hardBlocks
        vm.provider = .tool(.codex)
        vm.prepareForOpen()
        XCTAssertEqual(vm.mode, .weeklyRecap)
        vm.mode = .hardBlocks
        XCTAssertEqual(vm.provider, .all)
    }

    // MARK: - Recap week navigation (§6.2)

    func testTheRecapOpensOnTheNewestCompletedWeekAndWalksBack() throws {
        let vm = model()
        let section = try XCTUnwrap(vm.experience?.recap)
        XCTAssertTrue(section.weeks.count > 1)
        XCTAssertEqual(vm.recapWeek(in: section)?.id, section.weeks[0].id)
        XCTAssertFalse(vm.canShowNewerRecapWeek(in: section), "nothing is newer than the newest")
        vm.showOlderRecapWeek()
        XCTAssertEqual(vm.recapWeek(in: section)?.id, section.weeks[1].id)
        XCTAssertTrue(vm.canShowNewerRecapWeek(in: section))
        vm.showNewerRecapWeek()
        XCTAssertEqual(vm.recapWeek(in: section)?.id, section.weeks[0].id)
    }

    func testTheOldestWeekIsTheEndOfTheHorizon() throws {
        let vm = model()
        let section = try XCTUnwrap(vm.experience?.recap)
        for _ in 0..<(section.weeks.count * 2) { vm.showOlderRecapWeek() }
        XCTAssertFalse(vm.canShowOlderRecapWeek(in: section))
        XCTAssertEqual(vm.recapWeek(in: section)?.id, section.weeks.last?.id)
    }

    /// A reload can return fewer completed weeks than the reader had walked back to; the index is
    /// clamped rather than trusted.
    func testAWalkedBackIndexIsClampedToWhatAReadCanShow() throws {
        let vm = model()
        let section = try XCTUnwrap(vm.experience?.recap)
        vm.showOlderRecapWeek()
        vm.showOlderRecapWeek()
        XCTAssertEqual(vm.recapWeekIndex, 2)
        let single = HistoryExperience.RecapSection(weeks: [section.weeks[0]])
        XCTAssertEqual(vm.recapWeek(in: single)?.id, section.weeks[0].id)
    }

    func testAnEmptyRecapHasNoWeekAndNoNavigation() {
        let empty = HistoryExperience.RecapSection(emptyMessage: "nothing yet")
        let vm = model()
        XCTAssertNil(vm.recapWeek(in: empty))
        XCTAssertFalse(vm.canShowOlderRecapWeek(in: empty))
        XCTAssertFalse(vm.canShowNewerRecapWeek(in: empty))
    }

    // MARK: - Following an evidence link (§6.2)

    private func firstLink(_ vm: HistoryViewModel,
                           mode: HistoryExperience.Mode) throws -> HistoryExperience.RecapLink {
        let weeks = try XCTUnwrap(vm.experience?.recap.weeks)
        let link = weeks.flatMap { $0.links }
            .first { $0.destination.mode == mode }
        return try XCTUnwrap(link, "the fixture produced no \(mode.label) evidence link")
    }

    func testAnEvidenceLinkOpensItsModeWithARemovableBanner() throws {
        let vm = model()
        let link = try firstLink(vm, mode: .exploreQuota)
        vm.navigate(to: link.destination)
        XCTAssertEqual(vm.mode, .exploreQuota)
        XCTAssertEqual(vm.scope?.banner, link.destination.banner)
        XCTAssertEqual(vm.scope?.weekStart, link.destination.week?.start)
        XCTAssertTrue(vm.scope?.hasWeek == true)
        vm.clearScope()
        XCTAssertNil(vm.scope)
        XCTAssertEqual(vm.mode, .exploreQuota, "clearing the scope keeps the mode and provider")
    }

    func testBackToWeeklyRecapReturnsToTheWeekTheLinkCameFrom() throws {
        let vm = model()
        vm.showOlderRecapWeek()
        let origin = try XCTUnwrap(vm.currentRecapWeek?.id)
        let link = try firstLink(vm, mode: .exploreUsage)
        vm.navigate(to: link.destination)
        XCTAssertNotEqual(vm.mode, .weeklyRecap)
        vm.backToWeeklyRecap()
        XCTAssertEqual(vm.mode, .weeklyRecap)
        XCTAssertNil(vm.scope)
        XCTAssertEqual(vm.currentRecapWeek?.id, origin)
    }

    /// A quota detail's block link carries a banner and no week — the banner is where the reader
    /// came from, not a span to narrow to.
    func testAScopeWithoutAWeekNarrowsNothing() {
        let vm = model()
        vm.navigate(to: HistoryDestination(mode: .hardBlocks, provider: .claude,
                                           banner: "From quota window · Claude · Aug 3"))
        XCTAssertEqual(vm.mode, .hardBlocks)
        XCTAssertEqual(vm.provider, .tool(.claude))
        XCTAssertFalse(vm.scope?.hasWeek ?? true)
        XCTAssertFalse(vm.scope?.contains(HXFix.now) ?? true)
    }

    // MARK: - What a scoped week narrows

    func testAScopedWeekPinsTheFirstQuotaWindowInsideIt() throws {
        let vm = model()
        let link = try firstLink(vm, mode: .exploreQuota)
        vm.navigate(to: link.destination)
        let page = try XCTUnwrap(vm.experience?.pages(vm.provider).quota)
        let scope = try XCTUnwrap(vm.scope)
        let pinned = try XCTUnwrap(vm.resolvedQuotaPoint(in: page))
        XCTAssertTrue(scope.contains(pinned.at))
        XCTAssertEqual(pinned.id,
                       page.sections.flatMap(\.points).first { scope.contains($0.at) }?.id)
    }

    func testTheReadersOwnSelectionOutranksTheScope() throws {
        let vm = model()
        let link = try firstLink(vm, mode: .exploreQuota)
        vm.navigate(to: link.destination)
        let page = try XCTUnwrap(vm.experience?.pages(vm.provider).quota)
        let last = try XCTUnwrap(page.sections.flatMap(\.points).last)
        vm.selectQuotaPoint(last.id)
        XCTAssertEqual(vm.resolvedQuotaPoint(in: page)?.id, last.id)
    }

    func testAPinnedWindowTheReportNoLongerHoldsIsDroppedNotStranded() throws {
        let vm = model()
        vm.mode = .exploreQuota
        vm.selectQuotaPoint("a-window-from-an-older-read")
        let page = try XCTUnwrap(vm.experience?.pages(.all).quota)
        XCTAssertNil(vm.resolvedQuotaPoint(in: page))
    }

    func testAScopedWeekSelectsADayInsideItOnExploreUsage() throws {
        let vm = model()
        let link = try firstLink(vm, mode: .exploreUsage)
        vm.navigate(to: link.destination)
        let page = try XCTUnwrap(vm.experience?.pages(vm.provider).explore)
        let day = try XCTUnwrap(vm.selectedEntry(in: page)?.id)
        let scope = try XCTUnwrap(vm.scope)
        XCTAssertTrue(scope.contains(day), "the selection landed inside the scoped week")
    }

    /// Switching either control drops a pinned point: the identity is shared across pages, but a
    /// window the new page never drew is not the reader's selection.
    func testChangingModeOrProviderReleasesThePinnedWindow() {
        let vm = model()
        vm.mode = .exploreQuota
        vm.selectQuotaPoint("anything")
        vm.mode = .hardBlocks
        XCTAssertNil(vm.selectedQuotaPoint)
        vm.mode = .exploreQuota
        vm.selectQuotaPoint("anything")
        vm.provider = .tool(.codex)
        XCTAssertNil(vm.selectedQuotaPoint)
    }
}
