import XCTest
import KvotarCore
@testable import KvotarUI

/// Explore quota (STEP_182 — REV-93 §2.3 / UI Spec §6.3): the per-provider sections, the point
/// types and their copy, the segment breaks, the factual sentence with the current window
/// excluded from it, the sparse and fresh-install states, and the pinned selected-point detail.
final class HistoryExperienceQuotaTests: XCTestCase {

    private func quota(_ tools: [HistoryReport.ToolReport],
                       _ provider: HistoryExperience.Provider = .all)
        -> HistoryExperience.QuotaPage {
        HXFix.pages(tools, provider).quota
    }

    private func claude(_ windows: [QuotaWindowOutcome],
                        blocks: [HistoryReport.LimitBlock] = [],
                        days: [HistoryReport.Day] = []) -> HistoryReport.ToolReport {
        HXFix.tool(.claude, limitBlocks: blocks, days: days, quotaWindows: windows)
    }

    /// Five back-to-back five-hour windows ending on the same day — the dense-short-window case.
    private func contiguousFiveHour(count: Int, used: Double = 62,
                                    tool: Tool = .claude) -> [QuotaWindowOutcome] {
        (0..<count).map { index in
            HXFix.quotaWindow(tool, daysBack: 3, hour: 5 * (index + 1), used: used)
        }
    }

    // MARK: - Sections and provider safety

    func testAllStacksOneSectionPerProvider() {
        let page = quota([claude(contiguousFiveHour(count: 3)),
                          HXFix.tool(.codex, quotaWindows: [
                              HXFix.quotaWindow(.codex, daysBack: 4, width: 604_800, used: 40)])])
        XCTAssertEqual(page.sections.map(\.provider), [.claude, .codex])
        XCTAssertEqual(page.sections[0].title, "Claude · 5-hour windows")
        XCTAssertEqual(page.sections[1].title, "Codex · Weekly windows",
                       "widths are named in the app's own grain vocabulary, never `7-day`")
        XCTAssertEqual(page.eyebrow, "All providers · quota windows")
        XCTAssertNil(page.emptyMessage)
    }

    func testAProviderFilterShowsOnlyThatProvidersSection() {
        let tools = [claude(contiguousFiveHour(count: 3)),
                     HXFix.tool(.codex, quotaWindows: [HXFix.quotaWindow(.codex, daysBack: 4)])]
        XCTAssertEqual(quota(tools, .tool(.claude)).sections.map(\.provider), [.claude])
        XCTAssertEqual(quota(tools, .tool(.claude)).eyebrow, "Claude · quota windows")
    }

    /// Fractions are each window's own utilization on a 0–100 % axis, so two stacked sections
    /// never imply the allowances behind them are comparable.
    func testEachSectionScalesAgainstTheHundredPercentAxisNotItsOwnMaximum() throws {
        let page = quota([claude([HXFix.quotaWindow(.claude, daysBack: 5, hour: 6, used: 20),
                                  HXFix.quotaWindow(.claude, daysBack: 5, hour: 11, used: 40)]),
                          HXFix.tool(.codex, quotaWindows: [
                              HXFix.quotaWindow(.codex, daysBack: 5, used: 90)])])
        let claudeSection = try XCTUnwrap(page.sections.first)
        XCTAssertEqual(claudeSection.points.map(\.fraction), [0.2, 0.4],
                       "40 % is 0.4 of the axis, not 1.0 of its own lane")
        XCTAssertEqual(page.sections[1].points.first?.fraction, 0.9)
    }

    // MARK: - Point types and copy (§6.3)

    func testPointCopyDistinguishesEndedLowerBoundAndSoFar() {
        let windows = [
            HXFix.quotaWindow(.claude, daysBack: 5, hour: 6, used: 87),
            HXFix.quotaWindow(.claude, daysBack: 5, hour: 11, used: 62,
                              lastSeenBefore: 3 * 3600, completion: .completedPartial),
            HXFix.quotaWindow(.claude, daysBack: 5, hour: 16, used: 41, completion: .current),
        ]
        let points = quota([claude(windows)], .tool(.claude)).sections[0].points
        XCTAssertEqual(points.map(\.label),
                       ["Ended at 87% used",
                        "Reached at least 62% used",
                        "So far 41% used"])
        XCTAssertEqual(points.map(\.kind), [.completedFull, .completedPartial, .current])
    }

    /// The open window stands at its last recorded reading, never at now or at a reset that has
    /// not come; an ended window stands at its reset. The ring says `So far` beside itself and
    /// the detail says the reset is off the chart.
    func testTheOpenWindowStandsAtItsLastReadingAndNamesItself() throws {
        let open = HXFix.quotaWindow(.claude, daysBack: 0, hour: 15, used: 41,
                                     lastSeenBefore: 4 * 3600, completion: .current)
        let ended = HXFix.quotaWindow(.claude, daysBack: 1, hour: 15, used: 60)
        let points = quota([claude([ended, open])], .tool(.claude)).sections[0].points
        XCTAssertEqual(points[1].x, x(open.lastObservedAt))
        XCTAssertLessThan(points[1].x, 1, "the last reading was an hour before now")
        XCTAssertEqual(points[0].x, x(ended.resetsAt))
        XCTAssertEqual(points[1].inPlaceLabel, "So far")
        XCTAssertNil(points[0].inPlaceLabel, "an ordinary ended window carries no words")
        XCTAssertEqual(points[1].hoverBody, "**Last reading Sun Aug 16, 11:00 am**\nSo far 41% used")
        let reset = try XCTUnwrap(points[1].detail.rows.first { $0.label == "Reset" })
        XCTAssertTrue(reset.value.hasSuffix(HistoryDisplay.quotaResetAfterPeriodNote), reset.value)
        let endedReset = try XCTUnwrap(points[0].detail.rows.first { $0.label == "Reset" })
        XCTAssertFalse(endedReset.value.contains(HistoryDisplay.quotaResetAfterPeriodNote))
    }

    /// A diamond names itself where there is room: to the right of the mark when no other mark
    /// stands in the label's way, else to the left, else not at all. The open window's `So far`
    /// always goes right, into the margin the chart reserves for it.
    func testInPlaceLabelsGoWhereTheModelFindsRoom() {
        let lone = HXFix.quotaWindow(.claude, daysBack: 10, hour: 12, used: 100, hitLimit: true)
        let crowdedRight = HXFix.quotaWindow(.claude, daysBack: 3, hour: 10, used: 100,
                                             hitLimit: true)
        let neighbour = HXFix.quotaWindow(.claude, daysBack: 3, hour: 12, used: 50)
        let boxedIn = HXFix.quotaWindow(.claude, daysBack: 2, hour: 10, used: 100, hitLimit: true)
        let before = HXFix.quotaWindow(.claude, daysBack: 2, hour: 8, used: 50)
        let after = HXFix.quotaWindow(.claude, daysBack: 2, hour: 12, used: 50)
        let open = HXFix.quotaWindow(.claude, daysBack: 0, hour: 14, used: 20,
                                     lastSeenBefore: 2 * 3600 + 60, completion: .current)
        let section = quota([claude([lone, crowdedRight, neighbour, before, boxedIn, after, open])],
                            .tool(.claude)).sections[0]
        let sides = section.inPlaceLabelSides(plotWidth: 600)
        XCTAssertEqual(sides[lone.id], .right)
        XCTAssertEqual(sides[crowdedRight.id], .left, "a mark two hours later blocks the right")
        XCTAssertNil(sides[boxedIn.id], "marks on both sides: the diamond keeps its hover and sentence")
        XCTAssertEqual(sides[open.id], .right)
        XCTAssertNil(sides[neighbour.id], "no words on a plain dot")
        XCTAssertEqual(section.points.first { $0.id == lone.id }?.inPlaceLabel, "Hit the limit")
    }

    func testHitLimitIsItsOwnFlagNotAColour() {
        let points = quota([claude([HXFix.quotaWindow(.claude, daysBack: 5, used: 100,
                                                      hitLimit: true)])],
                           .tool(.claude)).sections[0].points
        XCTAssertEqual(points.map(\.hitLimit), [true])
        XCTAssertTrue(points[0].accessibilityValue.contains("Hit the limit"))
        XCTAssertTrue(points[0].accessibilityValue.contains("Claude"))
        XCTAssertTrue(points[0].accessibilityValue.contains("5-hour window"))
    }

    // MARK: - The factual sentence (§6.3)

    func testTheSummaryCountsOnlyCompletedWindows() {
        var windows = contiguousFiveHour(count: 5, used: 50)
        windows[0] = HXFix.quotaWindow(.claude, daysBack: 3, hour: 5, used: 100, hitLimit: true)
        windows[1] = HXFix.quotaWindow(.claude, daysBack: 3, hour: 10, used: 91)
        // …and one still-open window, which must reach no figure.
        windows.append(HXFix.quotaWindow(.claude, daysBack: 0, hour: 12, used: 100,
                                         completion: .current, hitLimit: true))
        let section = quota([claude(windows)], .tool(.claude)).sections[0]
        XCTAssertEqual(section.summary,
                       "1 of 5 windows seen to the end hit the limit. "
                       + "One more ended at or above 80% used.")
        XCTAssertEqual(section.points.count, 6, "the open window is still drawn")
    }

    /// A partly seen window's figure is a floor, so it reaches neither the limit count nor the
    /// 80 % clause — it may have done either after Kvotar stopped looking. It is counted in its
    /// own clause instead, so the reader knows how much of the strip the first clause covers.
    func testPartlySeenWindowsAreCountedApartFromThoseSeenToTheEnd() {
        var windows = contiguousFiveHour(count: 4, used: 50)
        windows[0] = HXFix.quotaWindow(.claude, daysBack: 3, hour: 5, used: 100,
                                       lastSeenBefore: 3600, completion: .completedPartial,
                                       hitLimit: true)
        windows[1] = HXFix.quotaWindow(.claude, daysBack: 3, hour: 10, used: 85,
                                       lastSeenBefore: 3600, completion: .completedPartial)
        XCTAssertEqual(quota([claude(windows)], .tool(.claude)).sections[0].summary,
                       "None of the 2 windows seen to the end hit the limit. "
                       + "2 windows were only partly seen.")
        windows[1] = HXFix.quotaWindow(.claude, daysBack: 3, hour: 10, used: 85)
        XCTAssertEqual(quota([claude(windows)], .tool(.claude)).sections[0].summary,
                       "None of the 3 windows seen to the end hit the limit. "
                       + "One more ended at or above 80% used. 1 window was only partly seen.")
    }

    func testNoneHitTheLimitReadsAsSuch() {
        let section = quota([claude(contiguousFiveHour(count: 4, used: 55))],
                            .tool(.claude)).sections[0]
        XCTAssertEqual(section.summary, "None of the 4 windows seen to the end hit the limit.")
    }

    func testAnOpenWindowAloneHasNoCompletedFigures() {
        let section = quota([claude([HXFix.quotaWindow(.claude, daysBack: 0, used: 44,
                                                       completion: .current)])],
                            .tool(.claude)).sections[0]
        XCTAssertEqual(section.summary, "No window seen to the end yet.")
        XCTAssertEqual(section.sparseNote, HistoryDisplay.quotaSparseNote)
        XCTAssertEqual(section.points.count, 1)
    }

    // MARK: - Sparse and fresh install (§6.3)

    func testSparseHistoryStillDrawsItsPointsAndSaysSo() {
        let section = quota([claude(contiguousFiveHour(count: 2))], .tool(.claude)).sections[0]
        XCTAssertEqual(section.sparseNote, HistoryDisplay.quotaSparseNote)
        XCTAssertEqual(section.points.count, 2)
        XCTAssertNil(quota([claude(contiguousFiveHour(count: 3))],
                           .tool(.claude)).sections[0].sparseNote,
                     "three completed windows clears the floor")
    }

    func testAFreshInstallSaysEarlierWindowsCannotBeRecovered() {
        let page = quota([HXFix.tool(.claude), HXFix.tool(.codex)])
        XCTAssertTrue(page.sections.isEmpty)
        XCTAssertEqual(page.emptyMessage, HistoryDisplay.quotaFreshInstallMessage)
        XCTAssertEqual(page.scopeNote, HistoryDisplay.quotaScopeNote)
    }

    /// A quiet stretch is an absent point, never a fabricated 0 % window (REV-93 §7).
    func testNoWindowIsInventedForAQuietStretch() {
        let section = quota([claude([HXFix.quotaWindow(.claude, daysBack: 20, used: 30),
                                     HXFix.quotaWindow(.claude, daysBack: 2, used: 30)])],
                            .tool(.claude)).sections[0]
        XCTAssertEqual(section.points.count, 2, "eighteen quiet days produce no points at all")
    }

    // MARK: - Segments (§6.3)

    func testContiguousSameWidthWindowsAreOneSegment() {
        let section = quota([claude(contiguousFiveHour(count: 4))], .tool(.claude)).sections[0]
        XCTAssertEqual(section.segments.count, 1)
        XCTAssertEqual(section.segments[0].widthLabel, "5-hour windows")
        XCTAssertTrue(section.segments[0].connects)
        XCTAssertNil(section.segments[0].boundaryNote)
        XCTAssertNil(section.segments[0].widthNote)
        XCTAssertEqual(section.segments[0].pointIDs.count, 4)
    }

    /// The legacy corpus: rows written before migration `v23` carry no width, so nothing can
    /// establish that one window abuts the next. They stay one labelled group of **separate**
    /// points — drawing a line through them would be exactly the interpolation §6.3 forbids, and
    /// on the live database that line would have spanned 87 windows and every gap between them.
    func testWindowsWithNoRecordedWidthAreGroupedButNeverJoined() {
        let section = quota([claude([HXFix.quotaWindow(.claude, daysBack: 9, hour: 5, width: nil),
                                     HXFix.quotaWindow(.claude, daysBack: 6, hour: 5, width: nil),
                                     HXFix.quotaWindow(.claude, daysBack: 2, hour: 5, width: nil)])],
                            .tool(.claude)).sections[0]
        XCTAssertEqual(section.segments.count, 1, "alike in having no shape — one group")
        XCTAssertFalse(section.segments[0].connects)
        XCTAssertNil(section.segments[0].widthLabel)
        XCTAssertEqual(section.segments[0].widthNote, HistoryDisplay.quotaUnrecordedWidthNote)
        XCTAssertEqual(section.segments[0].pointIDs.count, 3)
    }

    func testRecoveredLegacyWidthsJoinAndCarryOneEvidenceNote() {
        let windows = (0..<3).map { index in
            HXFix.quotaWindow(.codex, daysBack: 3, hour: 5 * (index + 1), width: 18_000,
                              widthEvidence: .recordedChange)
        }
        let section = quota([HXFix.tool(.codex, quotaWindows: windows)],
                            .tool(.codex)).sections[0]
        XCTAssertTrue(section.segments[0].connects)
        XCTAssertEqual(section.segments[0].widthNote, HistoryDisplay.quotaRecoveredWidthNote)
        XCTAssertEqual(section.segments.compactMap(\.widthNote).count, 1)
    }

    func testMixedRecoveredAndUnknownWidthsNameBothEvidenceLimits() {
        let windows = [
            HXFix.quotaWindow(.codex, daysBack: 9, width: 604_800,
                              widthEvidence: .recordedChange),
            HXFix.quotaWindow(.codex, daysBack: 2, width: nil,
                              widthEvidence: .unknown),
        ]
        let section = quota([HXFix.tool(.codex, quotaWindows: windows)],
                            .tool(.codex)).sections[0]
        XCTAssertEqual(section.segments.first?.widthNote,
                       HistoryDisplay.quotaPartlyRecoveredWidthNote)
        XCTAssertFalse(section.segments.last?.connects ?? true)
    }

    func testAGapBreaksTheSegment() {
        let section = quota([claude([HXFix.quotaWindow(.claude, daysBack: 9, hour: 5),
                                     HXFix.quotaWindow(.claude, daysBack: 9, hour: 10),
                                     HXFix.quotaWindow(.claude, daysBack: 3, hour: 10)])],
                            .tool(.claude)).sections[0]
        XCTAssertEqual(section.segments.map(\.pointIDs.count), [2, 1])
        XCTAssertEqual(section.segments[1].boundaryNote, "Gap in observation")
    }

    /// Rolling windows commonly start after a short idle pause. That pause is not proof that an
    /// outcome is missing: when a whole same-width window could not fit inside it, the two
    /// observed outcomes remain one trend segment.
    func testShortIdlePauseDoesNotBecomeAMissingHistoryGap() {
        let first = HXFix.quotaWindow(.claude, daysBack: 3, hour: 5)
        let secondReset = first.resetsAt.addingTimeInterval(18_000 + 2 * 3600)
        let second = QuotaWindowOutcome(
            id: "claude-short-idle", tool: .claude, resetsAt: secondReset,
            windowSeconds: 18_000, widthEvidence: .recorded,
            start: secondReset.addingTimeInterval(-18_000),
            firstObservedAt: secondReset.addingTimeInterval(-18_000),
            lastObservedAt: secondReset, observationCount: 12, highWaterPct: 55,
            hitLimitAt: nil, completion: .completedFull, ending: .reachedReset)
        let section = quota([claude([first, second])], .tool(.claude)).sections[0]
        XCTAssertEqual(section.segments.count, 1)
        XCTAssertEqual(section.segments[0].pointIDs.count, 2)
    }

    func testAWidthChangeBeginsANamedSegmentAndNeverBorrowsAWidth() {
        let section = quota([claude([HXFix.quotaWindow(.claude, daysBack: 9, hour: 5),
                                     HXFix.quotaWindow(.claude, daysBack: 8, width: 604_800),
                                     HXFix.quotaWindow(.claude, daysBack: 7, width: nil)])],
                            .tool(.claude)).sections[0]
        XCTAssertEqual(section.segments.map(\.widthLabel),
                       ["5-hour windows", "Weekly windows", nil])
        XCTAssertEqual(section.segments.map(\.connects), [true, true, false])
        XCTAssertEqual(section.segments[1].boundaryNote, "Window width changed")
        XCTAssertEqual(section.segments[2].boundaryNote, "Window width changed")
        XCTAssertEqual(section.title, "Claude · main account window",
                       "mixed widths cannot be named by one of them")
    }

    func testARecordedEndingBreaksTheSegmentAndNamesItself() {
        let section = quota([claude([
            HXFix.quotaWindow(.claude, daysBack: 9, hour: 5, ending: .earlyReset),
            HXFix.quotaWindow(.claude, daysBack: 9, hour: 10),
            HXFix.quotaWindow(.claude, daysBack: 9, hour: 15, ending: .withdrawn),
            HXFix.quotaWindow(.claude, daysBack: 9, hour: 20)])],
                            .tool(.claude)).sections[0]
        XCTAssertEqual(section.segments.map(\.boundaryNote),
                       [nil, "Reset early", "Withdrawn by the provider"])
        XCTAssertEqual(section.segments.map(\.pointIDs.count), [1, 2, 1],
                       "a recorded ending closes the run before it, not the one after")
    }

    // MARK: - Selected-point detail (§6.3)

    func testTheDetailCarriesWidthUsedCoverageAndReset() throws {
        let point = try XCTUnwrap(
            quota([claude([HXFix.quotaWindow(.claude, daysBack: 5, hour: 17, used: 87,
                                             readings: 24)])],
                  .tool(.claude)).sections[0].points.first)
        XCTAssertEqual(point.detail.rows.map(\.label), ["Width", "Used", "Coverage", "Reset"])
        XCTAssertEqual(point.detail.rows.map(\.value).prefix(3).map { $0 },
                       ["5-hour", "87% used", "Seen to the reset · 24 readings"])
        XCTAssertTrue(point.detail.title.hasPrefix("Claude · "))
        XCTAssertNil(point.detail.blockLink)
        XCTAssertNil(point.detail.note, "no local row ⇒ no context disclaimer")
    }

    func testAPartialDetailSaysHowLongBeforeTheResetItWasLastSeen() throws {
        let point = try XCTUnwrap(
            quota([claude([HXFix.quotaWindow(.claude, daysBack: 5, used: 62,
                                             lastSeenBefore: 3 * 3600, readings: 6,
                                             completion: .completedPartial)])],
                  .tool(.claude)).sections[0].points.first)
        XCTAssertEqual(point.detail.rows.first { $0.label == "Used" }?.value,
                       "At least 62% used")
        XCTAssertEqual(point.detail.rows.first { $0.label == "Coverage" }?.value,
                       "Last seen \(Fmt.span(seconds: 3 * 3600)) before the reset · 6 readings")
    }

    /// Local work is a day total named as one — a five-hour window sits inside a day, so calling
    /// the day's tokens the window's would overstate it by a factor nobody could check.
    func testLocalWorkIsLabelledAsContextNotCause() throws {
        let point = try XCTUnwrap(
            quota([claude([HXFix.quotaWindow(.claude, daysBack: 0, hour: 12, used: 50)],
                          days: HXFix.days([100_000, 200_000, 900_000]))],
                  .tool(.claude)).sections[0].points.last)
        let local = try XCTUnwrap(point.detail.rows.first { $0.label.hasPrefix("Local work") })
        XCTAssertTrue(local.value.hasPrefix(Fmt.tokens(900_000)))
        XCTAssertEqual(point.detail.note, HistoryDisplay.quotaLocalContextNote)
    }

    func testARecordedBlockInsideTheWindowBecomesATypedLink() throws {
        let window = HXFix.quotaWindow(.claude, daysBack: 5, hour: 17, used: 100, hitLimit: true)
        let firedAt = window.resetsAt.addingTimeInterval(-1800)
        let point = try XCTUnwrap(
            quota([claude([window], blocks: [HXFix.block(at: firedAt, lockout: 1800)])],
                  .tool(.claude)).sections[0].points.first)
        let link = try XCTUnwrap(point.detail.blockLink)
        XCTAssertEqual(link.destination.mode, .hardBlocks)
        XCTAssertEqual(link.destination.provider, .claude)
        XCTAssertTrue(link.destination.banner?.hasPrefix("From quota window · Claude · ") == true)
    }

    // MARK: - Date axis

    private func x(_ date: Date) -> Double {
        HistoryDisplay.quotaX(date, period: HXFix.report([]))
    }

    /// The axis is labelled at the provider's own weekly resets — weekday and date in the
    /// report's calendar — and every other local midnight is a small unlabelled tick. A model
    /// allowance's weekly resets at its own first use and is not the provider's reset.
    func testTicksLabelTheWeeklyResetsAndMarkEveryOtherMidnight() throws {
        let early = HXFix.quotaWindow(.claude, daysBack: 12, hour: 14).resetsAt
        let late = HXFix.quotaWindow(.claude, daysBack: 5, hour: 14).resetsAt
        let model = HXFix.quotaWindow(.claude, daysBack: 8, hour: 9).resetsAt
        let tool = HXFix.tool(.claude, quotaWindows: contiguousFiveHour(count: 3),
                              weeklyLimits: [
                                  HXFix.weeklyLimit(endedAt: early, used: 40),
                                  HXFix.weeklyLimit(.claude, .model(key: "m", name: "Opus"),
                                                    endedAt: model, used: 10),
                                  HXFix.weeklyLimit(endedAt: late, used: 55),
                              ])
        let ticks = quota([tool], .tool(.claude)).sections[0].ticks
        let labelled = ticks.filter { $0.label != nil }
        XCTAssertEqual(labelled.map(\.label), ["Tue Aug 4", "Tue Aug 11"],
                       "one tick per overall reset; the model weekly is not a tick")
        XCTAssertEqual(labelled.map(\.x), [x(early), x(late)])
        XCTAssertEqual(ticks.filter { $0.label == nil }.count, 30,
                       "every local midnight strictly inside the 30 days, unlabelled")
        XCTAssertEqual(ticks.map(\.x), ticks.map(\.x).sorted(), "ordered by x")
    }

    func testAProviderWithNoWeeklyResetTicksAtMondays() {
        let codex = HXFix.tool(.codex, quotaWindows: [
            HXFix.quotaWindow(.codex, daysBack: 4, width: 604_800, used: 40)])
        let ticks = quota([codex], .tool(.codex)).sections[0].ticks
        XCTAssertEqual(ticks.compactMap(\.label),
                       ["Mon Jul 20", "Mon Jul 27", "Mon Aug 3", "Mon Aug 10"])
        XCTAssertEqual(ticks.filter { $0.label == nil }.count, 26,
                       "a Monday midnight is the labelled tick, not a second mark")
    }

    /// The midnight ticks and the day strip are cut on one calendar: with no weekly reset every
    /// tick is a midnight (the Mondays labelled), and those are exactly the whole days' starts
    /// the report carries.
    func testMidnightTicksAreTheDayStripsDayStarts() {
        let days = HXFix.days(Array(repeating: 1, count: 31))
        let tool = HXFix.tool(.claude, days: days, quotaWindows: contiguousFiveHour(count: 3))
        let ticks = quota([tool], .tool(.claude)).sections[0].ticks
        let dayStarts = Set(days.filter { !$0.isPartial }.map { x($0.start) })
        XCTAssertEqual(Set(ticks.map(\.x)), dayStarts)
        XCTAssertEqual(ticks.count, dayStarts.count)
    }

    /// Two labelled ticks closer than a label's width at the chart's scale print one label; the
    /// later one gives way. Both ticks still stand.
    func testACrowdedTickKeepsItsMarkAndDropsItsLabel() {
        let first = HXFix.quotaWindow(.claude, daysBack: 6, hour: 14).resetsAt
        let second = HXFix.quotaWindow(.claude, daysBack: 5, hour: 14).resetsAt
        let tool = HXFix.tool(.claude, quotaWindows: contiguousFiveHour(count: 3),
                              weeklyLimits: [HXFix.weeklyLimit(endedAt: first, used: 40),
                                             HXFix.weeklyLimit(endedAt: second, used: 55)])
        let section = quota([tool], .tool(.claude)).sections[0]
        let ids = section.ticks.filter { $0.label != nil }.map(\.id)
        XCTAssertEqual(ids.count, 2)
        // One day apart is 1/30 of the plot: 20 pt on a 600 pt plot, 80 pt on a 2400 pt one.
        XCTAssertEqual(section.labelledTickIDs(plotWidth: 600), [ids[0]])
        XCTAssertEqual(section.labelledTickIDs(plotWidth: 2400), Set(ids))
    }

    /// A label at the right edge is pulled in to stay on the plot, so the spacing rule judges
    /// the labels where they are drawn: 75 pt apart by tick, two labels at 0.85 and 1.0 on a
    /// 500 pt plot land 39 pt apart and the later one gives way.
    func testTheSpacingRuleJudgesLabelsWhereTheEdgePlacesThem() {
        typealias Section = HistoryExperience.QuotaSection
        let section = Section(
            provider: .claude, title: "", summary: "",
            ticks: [.init(id: "a", x: 0.85, label: "Sat Oct 10"),
                    .init(id: "b", x: 1, label: "Fri Oct 16")])
        XCTAssertEqual(Section.tickLabelCenter(x: 1, plotWidth: 500), 464, "pulled in by half a label")
        XCTAssertEqual(Section.tickLabelCenter(x: 0, plotWidth: 500), 36)
        XCTAssertEqual(section.labelledTickIDs(plotWidth: 500), ["a"])
        XCTAssertEqual(section.labelledTickIDs(plotWidth: 1000), ["a", "b"])
    }

    func testTheValueLabelsComeFromTheModel() {
        let labels = quota([claude(contiguousFiveHour(count: 3))], .tool(.claude))
            .sections[0].valueLabels
        XCTAssertEqual(labels.map(\.label), ["100", "50", "0"])
        XCTAssertEqual(labels.map(\.fraction), [1, 0.5, 0])
        XCTAssertEqual(labels.map(\.prominent), [true, false, true])
    }

    // MARK: - Hover

    func testTheHoverCardNamesTheSpanAndTheResultForEachKindOfWindow() {
        let windows = [
            HXFix.quotaWindow(.claude, daysBack: 5, hour: 6, used: 87),
            HXFix.quotaWindow(.claude, daysBack: 5, hour: 11, used: 62,
                              lastSeenBefore: 3 * 3600, completion: .completedPartial),
            HXFix.quotaWindow(.claude, daysBack: 5, hour: 16, used: 41, completion: .current),
            HXFix.quotaWindow(.claude, daysBack: 4, hour: 2, used: 100, hitLimit: true),
        ]
        let points = quota([claude(windows)], .tool(.claude)).sections[0].points
        XCTAssertEqual(points.map(\.hoverBody), [
            "**Tue Aug 11, 1:00 am – 6:00 am**\nEnded at 87% used",
            "**Tue Aug 11, 6:00 am – 11:00 am**\nReached at least 62% used",
            "**Last reading Tue Aug 11, 4:00 pm**\nSo far 41% used",
            "**Tue Aug 11, 9:00 pm – Wed Aug 12, 2:00 am**\nEnded at 100% used · Hit the limit",
        ])
    }

    /// The pointer anywhere over the plot rests on the nearest window on x, ringed, with the
    /// cursor snapped to its mark — even far from any mark, so the card never goes blank.
    func testHoverResolvesToTheNearestWindow() throws {
        let windows = [
            HXFix.quotaWindow(.claude, daysBack: 3, hour: 5, used: 30),
            HXFix.quotaWindow(.claude, daysBack: 2, hour: 20, used: 70),
        ]
        let section = quota([claude(windows)], .tool(.claude)).sections[0]

        let nearFirst = try XCTUnwrap(
            HistoryDisplay.quotaHover(section, atX: section.points[0].x - 0.01))
        XCTAssertEqual(nearFirst.pointID, section.points[0].id)
        XCTAssertEqual(nearFirst.cursorX, section.points[0].x, "the cursor snaps to the mark")
        XCTAssertEqual(nearFirst.body, section.points[0].hoverBody)

        let farLeft = try XCTUnwrap(HistoryDisplay.quotaHover(section, atX: 0))
        XCTAssertEqual(farLeft.pointID, section.points[0].id, "the nearest, however far")

        XCTAssertEqual(HistoryDisplay.quotaNearestPoint(section, atX: 1)?.id,
                       section.points[1].id, "a click at the right edge selects the last window")
    }

    func testNoNewQuotaCopyNamesPollingInternals() {
        let open = HXFix.quotaWindow(.claude, daysBack: 0, hour: 15, used: 41,
                                     lastSeenBefore: 4 * 3600, completion: .current)
        let tool = HXFix.tool(.claude, quotaWindows: contiguousFiveHour(count: 3) + [open],
                              weeklyLimits: [HXFix.weeklyLimit(
                                  endedAt: HXFix.now.addingTimeInterval(-5 * 86_400), used: 40)])
        let page = quota([tool], .tool(.claude))
        for string in HXFix.allStrings(of: page) {
            XCTAssertNil(UserCopyRules.pollingWord(in: string), "copy ban in: \(string)")
        }
    }
}
