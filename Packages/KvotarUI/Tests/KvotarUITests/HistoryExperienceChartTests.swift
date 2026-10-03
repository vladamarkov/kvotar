import XCTest
import KvotarCore
@testable import KvotarUI

/// STEP_160 — the chart, hover, accessibility and REV-72 window-summary pins ported from the
/// deleted legacy `HistoryDisplayTests` suite, retargeted at the experience builders
/// (`experienceDayStrip` / `experienceHourChart` / `windowChangeSummary`). The grammar is the
/// legacy strip's, unchanged; what changed is the geometry (per-provider scales) and the new
/// model-supplied spoken value.
final class HistoryExperienceChartTests: XCTestCase {

    private func strip(_ tools: [HistoryReport.ToolReport],
                       weeks: [HistoryReport.Week] = []) -> HistoryScreen.DayStrip? {
        HistoryDisplay.experienceDayStrip(tools, weeks: weeks)
    }

    private func day(_ start: Date, partial: Bool = false, tokens: Int, sessions: Int,
                     hitLimit: Bool = false) -> HistoryReport.Day {
        HistoryReport.Day(start: start, isPartial: partial, tokens: tokens,
                          sessions: sessions, hitLimit: hitLimit)
    }

    private func withLimit(_ days: [HistoryReport.Day], at index: Int) -> [HistoryReport.Day] {
        var days = days
        let d = days[index]
        days[index] = day(d.start, partial: d.isPartial, tokens: d.tokens,
                          sessions: d.sessions, hitLimit: true)
        return days
    }

    // MARK: - Fmt.tokens billions tier (found on the live corpus)

    func testTokensFormatterHasABillionsTier() {
        XCTAssertEqual(Fmt.tokens(540), "540")
        XCTAssertEqual(Fmt.tokens(980_000), "980k")
        XCTAssertEqual(Fmt.tokens(1_200_000), "1.2M")
        XCTAssertEqual(Fmt.tokens(999_900_000), "999.9M")
        XCTAssertEqual(Fmt.tokens(1_681_427_641), "1.68B")
    }

    // MARK: - Day strip

    func testNoStripWhenNoToolHasWorkInThePeriod() {
        XCTAssertNil(strip([HXFix.tool(.claude, days: HXFix.days([0, 0, 0, 0]))]))
    }

    func testToolStripNormalisesAgainstThatToolsOwnBusiestDay() {
        let s = strip([HXFix.tool(.claude, days: HXFix.days([0, 250_000, 1_000_000, 500_000]))])
        let fractions = s?.points.map { $0.bars.first?.fraction ?? 0 }
        XCTAssertEqual(fractions ?? [], [0, 0.25, 1, 0.5])
        XCTAssertEqual(s?.points.first?.bars.count, 0, "an empty day contributes no bar")
    }

    func testDayHoverNamesTheDayTheTokensAndTheSessions() {
        let days = HXFix.days([0, 88_800_000], sessions: [0, 5])
        let s = strip([HXFix.tool(.claude, days: days)])
        XCTAssertEqual(s?.points.last?.hoverBody,
                       "**\(Fmt.monthDay(days[1].start))** · 88.8M · 5 sessions")
    }

    func testCodexDayHoverCountsThreadsAndSingularisesOne() {
        let days = HXFix.days([0, 1_200_000], sessions: [0, 1])
        let s = strip([HXFix.tool(.codex, days: days)])
        XCTAssertEqual(s?.points.last?.hoverBody,
                       "**\(Fmt.monthDay(days[1].start))** · 1.2M · 1 thread")
    }

    func testAllDayHoverIsOneLinePerToolAndNeverACombinedFigure() {
        let days = HXFix.days([0, 88_800_000], sessions: [0, 5])
        let codexDays = HXFix.days([0, 1_200_000], sessions: [0, 2])
        let s = strip([HXFix.tool(.claude, days: days),
                       HXFix.tool(.codex, days: codexDays)])
        XCTAssertEqual(s?.points.last?.hoverBody,
                       "**\(Fmt.monthDay(days[1].start))**\n"
                       + "Claude 88.8M · 5 sessions\nCodex 1.2M · 2 threads")
        // 90.0M would be the sum; it must appear nowhere.
        XCTAssertFalse(s?.points.contains { $0.hoverBody.contains("90.0M") } ?? true)
        XCTAssertFalse(s?.footer.contains("90.0M") ?? true)
    }

    func testAnEmptyDaySaysNoActivityAndTheClippedFirstDaySaysSo() {
        let days = HXFix.days([4_100_000, 0, 900_000], sessions: [2, 0, 1])
        let s = strip([HXFix.tool(.claude, days: days)])
        XCTAssertEqual(s?.points.first?.hoverBody,
                       "**\(Fmt.monthDay(days[0].start))** · partial day · 4.1M · 2 sessions")
        XCTAssertEqual(s?.points[1].hoverBody,
                       "**\(Fmt.monthDay(days[1].start))** · no activity")
    }

    func testStripFooterNamesTheBusiestDayPerToolNeverACombinedOne() {
        let claudeDays = HXFix.days([0, 88_800_000, 1_000])
        let claude = HXFix.tool(.claude, days: claudeDays)
        XCTAssertEqual(strip([claude])?.footer,
                       "Busiest day \(Fmt.monthDay(claudeDays[1].start)) · 88.8M")

        let codexDays = HXFix.days([3_100_000, 0, 0])
        let both = strip([claude, HXFix.tool(.codex, days: codexDays)])
        XCTAssertEqual(both?.footer,
                       "Busiest day Claude \(Fmt.monthDay(claudeDays[1].start)) · 88.8M · "
                       + "Codex \(Fmt.monthDay(codexDays[0].start)) · 3.1M")
    }

    func testLegendAppearsOnlyWhenItSaysSomething() {
        let claude = HXFix.tool(.claude, days: HXFix.days([0, 5_000_000]))
        XCTAssertEqual(strip([claude])?.legend.count, 0,
                       "one colour on the page ⇒ a legend is decoration")

        let codex = HXFix.tool(.codex, days: HXFix.days([0, 900_000]))
        XCTAssertEqual(strip([claude, codex])?.legend.map(\.label), ["Claude", "Codex"])

        let hit = HXFix.tool(.claude,
                             days: withLimit(HXFix.days([0, 5_000_000]), at: 1))
        let legend = strip([hit])?.legend
        XCTAssertEqual(legend?.map(\.label), ["Hit the limit"])
        XCTAssertEqual(legend?.first?.marker, .limitHit)
    }

    func testLimitHitMarkersSitOnTheirOwnDayInTheirOwnTool() {
        let claude = HXFix.tool(.claude,
                                days: withLimit(HXFix.days([0, 5_000_000, 1_000_000]), at: 2))
        let codex = HXFix.tool(.codex,
                               days: withLimit(HXFix.days([0, 900_000, 0]), at: 1))
        XCTAssertEqual(strip([claude, codex])?.points.map(\.hitLimitTools),
                       [[], [.codex], [.claude]])
    }

    func testTickLabelsSitOnTheReportsOwnWeekStartsAndSkipTheClippedWeek() {
        let days = HXFix.days(Array(repeating: 1_000, count: 15))
        let weeks = [HXFix.week(daysBack: 0, tokens: 1), HXFix.week(daysBack: 7, tokens: 1)]
        let ticks = strip([HXFix.tool(.claude, weeks: weeks, days: days)], weeks: weeks)?
            .points.compactMap(\.tickLabel)
        XCTAssertEqual(ticks?.count, 2)

        let withPartial = weeks + [HXFix.week(daysBack: 12, tokens: 1, partial: true)]
        let clipped = strip([HXFix.tool(.claude, weeks: withPartial, days: days)],
                            weeks: withPartial)?.points.compactMap(\.tickLabel)
        XCTAssertEqual(clipped, ticks, "the clipped oldest week gets no tick")
    }

    func testChangeDaysAreMarkedAndNamedInTheHover() {
        let days = HXFix.days([0, 900_000, 400_000])
        let codex = HXFix.tool(.codex,
                               accountChanges: [HXFix.change(
                                   at: days[1].start.addingTimeInterval(3600),
                                   old: "go", new: "plus")],
                               days: days)
        let single = strip([codex])
        XCTAssertEqual(single?.points.map(\.changeTools), [[], [.codex], []])
        XCTAssertTrue(single?.points[1].hoverBody
            .hasSuffix("\nPlan changed go → plus") == true)
        XCTAssertEqual(single?.legend.map(\.marker), [.accountChange])

        let both = strip([HXFix.tool(.claude, days: HXFix.days([0, 5_000_000, 1_000_000])),
                          codex])
        XCTAssertTrue(both?.points[1].hoverBody
            .hasSuffix("\nCodex · Plan changed go → plus") == true,
            "two tools on one strip: the hover says whose change it was")
    }

    // MARK: - Model-supplied accessibility value (STEP_160 — REV-84 §8)

    func testAccessibilityValueSpeaksTheDayWithoutMarkdown() {
        let days = HXFix.days([4_100_000, 0, 88_800_000], sessions: [2, 0, 5])
        let s = strip([HXFix.tool(.claude, days: days)])
        XCTAssertEqual(s?.points[0].accessibilityValue,
                       "\(Fmt.monthDay(days[0].start)) · Partial day · 4.1M · 2 sessions")
        XCTAssertEqual(s?.points[1].accessibilityValue,
                       "\(Fmt.monthDay(days[1].start)) · No activity")
        XCTAssertEqual(s?.points[2].accessibilityValue,
                       "\(Fmt.monthDay(days[2].start)) · 88.8M · 5 sessions")
        XCTAssertFalse(s?.points.contains { $0.accessibilityValue.contains("*") } ?? true,
                       "VoiceOver never reads asterisks")
    }

    func testAccessibilityValueCarriesTheBlockFactTheDotOnlyDraws() {
        let hit = HXFix.tool(.claude, days: withLimit(HXFix.days([0, 5_000_000]), at: 1))
        XCTAssertTrue(strip([hit])?.points[1].accessibilityValue
            .contains("Hit the limit") == true)

        let both = strip([hit, HXFix.tool(.codex, days: HXFix.days([0, 900_000]))])
        XCTAssertTrue(both?.points[1].accessibilityValue
            .contains("Claude hit the limit") == true,
            "two tools on the strip ⇒ the fact is named")
    }

    // MARK: - Hour chart (REV-73 / D-80, per-provider scales)

    private func hourWork(_ shape: [Int]) -> [Int] { shape }

    private var spreadWork: [Int] {
        [9, 5, 0, 0, 0, 0, 0, 0, 0, 3, 4, 2, 1, 0, 1, 1, 0, 1, 1, 3, 4, 7, 6, 7]
    }

    func testTheChartNeedsAShortWindowBlockAndSomeWorkToDrawIt() {
        let watching = HXFix.now.addingTimeInterval(-29 * 86_400)
        let short = HXFix.tool(.claude, limitBlocks: [HXFix.localBlock(daysBack: 2, hour: 15)],
                               watchingSince: watching, workByHour: spreadWork)
        XCTAssertNotNil(HistoryDisplay.experienceHourChart([short]))

        let wide = HXFix.tool(.codex,
                              limitBlocks: [HXFix.block(
                                  at: HXFix.now.addingTimeInterval(-2 * 86_400),
                                  lockout: 3600, width: 604_800)],
                              watchingSince: watching, workByHour: spreadWork)
        XCTAssertNil(HistoryDisplay.experienceHourChart([wide]),
                     "the hour hardly matters when the consequence runs to next Tuesday")

        let noBlocks = HXFix.tool(.claude, watchingSince: watching, workByHour: spreadWork)
        XCTAssertNil(HistoryDisplay.experienceHourChart([noBlocks]))

        let noWork = HXFix.tool(.claude,
                                limitBlocks: [HXFix.localBlock(daysBack: 2, hour: 15)],
                                watchingSince: watching)
        XCTAssertNil(HistoryDisplay.experienceHourChart([noWork]),
                     "there is nothing to draw the marks against")
    }

    func testEveryBlockIsItsOwnMarkAndTheCaptionDescribesTheDrawing() throws {
        let t = HXFix.tool(.claude,
                           limitBlocks: [HXFix.localBlock(daysBack: 6, hour: 15),
                                         HXFix.localBlock(daysBack: 4, hour: 15),
                                         HXFix.localBlock(daysBack: 1, hour: 13)],
                           watchingSince: HXFix.now.addingTimeInterval(-29 * 86_400),
                           workByHour: spreadWork)
        let chart = try XCTUnwrap(HistoryDisplay.experienceHourChart([t]))
        XCTAssertEqual(chart.points.count, 24, "the axis is the clock, not the data")
        XCTAssertEqual(chart.points[15].blockTools, [.claude, .claude], "two blocks, two marks")
        XCTAssertEqual(chart.points[13].blockTools, [.claude])
        XCTAssertEqual(chart.points.compactMap(\.tickLabel), ["12a", "6a", "12p", "6p"])
        XCTAssertEqual(chart.caption,
                       "Every block landed in the afternoon, though you work hardest in the "
                       + "evening.")
        XCTAssertEqual(try XCTUnwrap(chart.points[0].bars.first).fraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(chart.points[21].bars.first).fraction, 7.0 / 9,
                       accuracy: 0.001)
    }

    func testBlocksSpreadAcrossTheDayGetTheWeakerSentence() throws {
        let t = HXFix.tool(.claude,
                           limitBlocks: [HXFix.localBlock(daysBack: 6, hour: 11),
                                         HXFix.localBlock(daysBack: 4, hour: 15),
                                         HXFix.localBlock(daysBack: 1, hour: 19)],
                           watchingSince: HXFix.now.addingTimeInterval(-29 * 86_400),
                           workByHour: spreadWork)
        let chart = try XCTUnwrap(HistoryDisplay.experienceHourChart([t]))
        XCTAssertEqual(chart.caption,
                       "Blocks landed across the day; you work hardest in the evening.")
    }

    func testTheAllChartKeepsLanesSeparateAndNamesNoCombinedFigure() throws {
        let watching = HXFix.now.addingTimeInterval(-29 * 86_400)
        let claude = HXFix.tool(.claude,
                                limitBlocks: [HXFix.localBlock(daysBack: 2, hour: 15)],
                                watchingSince: watching,
                                workByHour: Array(repeating: 8_000_000, count: 24))
        let codex = HXFix.tool(.codex,
                               limitBlocks: [HXFix.localBlock(daysBack: 3, hour: 21)],
                               watchingSince: watching,
                               workByHour: Array(repeating: 2_000_000, count: 24))
        let chart = try XCTUnwrap(HistoryDisplay.experienceHourChart([claude, codex]))
        XCTAssertEqual(chart.points[0].bars.map(\.tool), [.claude, .codex])
        XCTAssertEqual(chart.points[0].bars.map(\.fraction), [1.0, 1.0],
                       "flat work fills each provider's own lane — scales never shared")
        XCTAssertEqual(chart.points[15].blockTools, [.claude])
        XCTAssertEqual(chart.points[21].blockTools, [.codex])
        XCTAssertEqual(chart.legend.map(\.label), ["Claude", "Codex", "Hit the limit"])
        XCTAssertEqual(chart.points[0].hoverBody, "**12 am**\nClaude 8.0M\nCodex 2.0M")
        let text = chart.points.map(\.hoverBody).joined(separator: " ") + chart.caption
        XCTAssertFalse(text.contains("10.0M"), "no combined figure anywhere")
    }

    // MARK: - REV-72 window summary (helpers survive the cutover unchanged)

    private func point(startDaysBack: Double, days: Double = 7, complete: Bool = true,
                       delta: Double = 20, dollars: Double = 248, tokens: Int = 78_000_000,
                       unexplained: Double? = 0) -> WorkPerPercentSeries.Point {
        let start = HXFix.now.addingTimeInterval(-startDaysBack * 86_400)
        return WorkPerPercentSeries.Point(
            start: start, end: start.addingTimeInterval(days * 86_400), isComplete: complete,
            deltaPct: delta, dollars: dollars, tokens: tokens, perModel: [],
            coverage: 1, unexplainedShare: unexplained, crossWindowRatio: nil)
    }

    private func claudeSlots(_ weekly: [WorkPerPercentSeries.Point]) -> WorkPerPercentSeries {
        WorkPerPercentSeries(slots: [
            .init(isPrimary: true, windowSeconds: 18_000, byDay: true, points: []),
            .init(isPrimary: false, windowSeconds: 604_800, byDay: false, points: weekly),
        ], markers: [])
    }

    /// The dogfood corpus's five weekly cycles (REV-72 §3.1). Two do not qualify: 23 % unseen
    /// fails `≤ 20 %`, and Δ = 2 pt fails `≥ 10` — each would otherwise widen the range.
    private var liveWeeklyCycles: [WorkPerPercentSeries.Point] {
        [point(startDaysBack: 29, delta: 60, dollars: 545.4, unexplained: 0.03),   // → 9.37
         point(startDaysBack: 23, delta: 13, dollars: 104.1, unexplained: 0.23),
         point(startDaysBack: 16, delta: 2, dollars: 13.3, unexplained: 0.50),
         point(startDaysBack: 8, delta: 63, dollars: 730.8, unexplained: 0.08),    // → 12.61
         point(startDaysBack: 2, complete: false, delta: 43, dollars: 474.3,
               unexplained: 0.05)]                                                 // → 11.61
    }

    private func watched(_ series: WorkPerPercentSeries) -> HistoryReport.ToolReport {
        HXFix.tool(.claude, watchingSince: HXFix.now.addingTimeInterval(-29 * 86_400),
                   workPerPercent: series)
    }

    func testSummaryStatesTheVerdictWithACorrectedRangeOverQualifyingCyclesOnly() {
        let watching = Fmt.monthDay(HXFix.now.addingTimeInterval(-29 * 86_400))
        let summary = HistoryDisplay.windowChangeSummary(watched(claudeSlots(liveWeeklyCycles)))
        XCTAssertEqual(summary.verdict, "Nothing conclusive yet.")
        XCTAssertEqual(summary.row?.label, "Weekly · 3 cycles since \(watching)")
        XCTAssertEqual(summary.row?.value, "$9 – $13 of work per 1%",
                       "corrected rates — raw would read $9 – $12")
    }

    func testEqualRoundedBoundsReadAsASingleFigure() {
        let cycles = [point(startDaysBack: 25, delta: 40, dollars: 432),
                      point(startDaysBack: 15, delta: 40, dollars: 448),
                      point(startDaysBack: 5, delta: 40, dollars: 440)]
        XCTAssertEqual(HistoryDisplay.windowChangeSummary(watched(claudeSlots(cycles)))
            .row?.value,
            "about $11 of work per 1%")
    }

    func testTooFewQualifyingCyclesCountThemAndShowNoFigure() {
        let watching = Fmt.monthDay(HXFix.now.addingTimeInterval(-29 * 86_400))
        let two = HistoryDisplay.windowChangeSummary(
            watched(claudeSlots(Array(liveWeeklyCycles.prefix(4)))))
        XCTAssertEqual(two.verdict,
                       "Not enough history yet — 2 usable cycles since \(watching).")
        XCTAssertNil(two.row)

        let none = HistoryDisplay.windowChangeSummary(
            watched(claudeSlots(Array(liveWeeklyCycles[1...2]))))
        XCTAssertEqual(none.verdict,
                       "Not enough history yet — no usable cycle since \(watching).")
    }

    func testNeverWatchedSaysSoWithoutADate() {
        let summary = HistoryDisplay.windowChangeSummary(HXFix.tool(.claude))
        XCTAssertEqual(summary.verdict,
                       "Not enough history yet — Kvotar has not watched a full window.")
        XCTAssertNil(summary.row)
    }

    // MARK: - Copy bans, swept over the whole experience

    func testNoPayloadEverSaysSteadyOrNamesPollingInternals() {
        let watching = HXFix.now.addingTimeInterval(-29 * 86_400)
        let claude = HXFix.tool(
            .claude,
            accountChanges: [HXFix.change(at: HXFix.now.addingTimeInterval(-4 * 86_400),
                                          old: "go", new: "plus")],
            limitBlocks: [HXFix.localBlock(daysBack: 6, hour: 15),
                          HXFix.localBlock(daysBack: 1, hour: 11)],
            watchingSince: watching,
            workPerPercent: claudeSlots(liveWeeklyCycles),
            days: HXFix.days([0, 500_000, 1_000_000]),
            workByHour: spreadWork)
        let codex = HXFix.tool(.codex, watchingSince: watching,
                               workPerPercent: claudeSlots(liveWeeklyCycles),
                               days: HXFix.days([0, 100_000, 300_000]))
        let experience = HXFix.experience([claude, codex])
        var strings = HXFix.allStrings(of: experience)
        for provider in experience.providers {
            strings += HXFix.allStrings(of: experience.pages(provider))
        }
        let lower = strings.joined(separator: " ").lowercased()
        for banned in ["steady", "no sign of change", "throttl", "backing off", "rate limit",
                       "poll", "reduced your limit", "tokens limit",
                       // D-80: the chart draws a rhythm, it does not assert one, and it never
                       // blames the reader for the hour they were cut off in.
                       "usually", "always hit", "you tend to", "too much"] {
            XCTAssertFalse(lower.contains(banned), "copy ban: \(banned)")
        }
    }
}
