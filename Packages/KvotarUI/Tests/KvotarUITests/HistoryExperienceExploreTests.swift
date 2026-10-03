import XCTest
import KvotarCore
@testable import KvotarUI

/// STEP_159 — the Explore usage contract (REV-84 §5): day selection and the typed selected-day
/// detail, week rows with value, visible provider totals with no combined-token counterpart,
/// and the fixed 30-day breakdown.
final class HistoryExperienceExploreTests: XCTestCase {

    private func explore(_ tools: [HistoryReport.ToolReport],
                         _ provider: HistoryExperience.Provider = .all)
        -> HistoryExperience.ExplorePage {
        HXFix.pages(tools, provider).explore
    }

    // MARK: - Day selection

    func testInitialSelectionIsTheNewestDayWithActivity() {
        let tool = HXFix.tool(.claude, days: HXFix.days([0, 200_000, 0, 300_000, 0]))
        let page = explore([tool], .tool(.claude))
        XCTAssertEqual(page.days.count, 5)
        XCTAssertEqual(page.initialSelection, HXFix.dayStart(index: 3, of: 5),
                       "newest day with activity, not today")
        XCTAssertEqual(page.days.map(\.id),
                       (0..<5).map { HXFix.dayStart(index: $0, of: 5) },
                       "stable day identity, oldest first, aligned with the strip")
    }

    // MARK: - Selected-day detail (REV-84 §5.1)

    private func fullDayFixture() -> (HistoryReport.ToolReport, Date) {
        let target = HXFix.dayStart(index: 3, of: 5)
        let dayTotals = [HXFix.totals(input: 240_000, cacheRead: 60_000),
                         HXFix.totals(model: "claude-opus-4-8", input: 10_000)]
        let days = HXFix.withDay(
            HXFix.days([0, 200_000, 0, 310_000, 0], sessions: [0, 1, 0, 5, 0]), at: 3,
            modelTotals: dayTotals,
            modelValues: [HXFix.mv("claude-sonnet-4-6", 2.1), HXFix.mv("claude-opus-4-8", 0.4)],
            value: 2.5,
            projects: [HistoryReport.DayProject(project: "/Users/u/kvotar", tokens: 300_000),
                       HistoryReport.DayProject(project: nil, tokens: 10_000)])
        let tool = HXFix.tool(
            .claude,
            modelTotals: [HXFix.totals(input: 1_400_000), HXFix.totals(model: "claude-opus-4-8",
                                                                       input: 100_000)],
            modelValues: [HXFix.mv("claude-sonnet-4-6", 11.0), HXFix.mv("claude-opus-4-8", 1.5)],
            accountChanges: [HXFix.change(at: target.addingTimeInterval(4 * 3600),
                                          old: "go", new: "plus")],
            limitBlocks: [HXFix.block(at: target.addingTimeInterval(2 * 3600), lockout: 3600)],
            days: days,
            criticalObservations: [HXFix.observation(at: target.addingTimeInterval(3600),
                                                     .atRisk, util: 92)])
        return (tool, target)
    }

    func testSelectedDayCarriesEveryRecordedFact() {
        let (tool, target) = fullDayFixture()
        let detail = explore([tool], .tool(.claude)).days[3].detail

        XCTAssertEqual(detail.title, Fmt.monthDay(target))
        XCTAssertNil(detail.status)
        XCTAssertEqual(detail.sections.count, 1)
        let section = try! XCTUnwrap(detail.sections.first)
        XCTAssertEqual(section.provider, .claude)
        XCTAssertEqual(section.tokens, Fmt.tokens(310_000))
        XCTAssertEqual(section.value, Fmt.dollarValue(2.5))
        XCTAssertEqual(section.activity, "5 sessions")
        XCTAssertEqual(section.models, [
            LabeledRow(label: DisplayFormatter.modelDisplayName("claude-sonnet-4-6"),
                       value: Fmt.tokens(300_000)),
            LabeledRow(label: DisplayFormatter.modelDisplayName("claude-opus-4-8"),
                       value: Fmt.tokens(10_000)),
        ], "day-grain model rows carry tokens only (§5.1 amended 2026-09-01)")
        // The day's project rows (STEP_178) — where the popover's `N more projects ›` lands.
        XCTAssertEqual(section.projects, [
            LabeledRow(label: "kvotar", value: Fmt.tokens(300_000)),
            LabeledRow(label: HistoryDisplay.noProjectLabel, value: Fmt.tokens(10_000)),
        ], "day-grain project rows, largest first, `(no project)` kept")
        XCTAssertNil(detail.combinedValue, "one provider ⇒ nothing to combine")

        XCTAssertEqual(detail.blocks.map(\.row.value), ["locked out \(Fmt.span(seconds: 3600))"])
        XCTAssertEqual(detail.blocks.map(\.warn), [false],
                       "a recovered reset is an ordinary row")
        XCTAssertEqual(detail.observations.map(\.row.label),
                       ["At risk · \(Fmt.clock(target.addingTimeInterval(3600)))"])
        XCTAssertEqual(detail.observations.map(\.row.value), ["8% left"],
                       "stored utilization 92 renders as remaining (REV-77)")
        XCTAssertEqual(detail.changes.map(\.row.value), ["go → plus"])
        XCTAssertEqual(detail.evidenceNote,
                       "Warnings are shown only when Kvotar recorded them; "
                       + "no warning here does not guarantee headroom.")
    }

    func testDayStatusesPartialNoActivityAndEventOnly() {
        let target = HXFix.dayStart(index: 2, of: 4)
        let tool = HXFix.tool(
            .claude,
            limitBlocks: [HXFix.block(at: target.addingTimeInterval(3600), lockout: nil)],
            days: HXFix.days([100_000, 200_000, 0, 0]))
        let days = explore([tool], .tool(.claude)).days

        XCTAssertEqual(days[0].detail.status, "Partial day",
                       "the clipped oldest sliver says so")
        XCTAssertEqual(days[3].detail.status, "No activity")
        XCTAssertTrue(days[3].detail.sections.isEmpty, "a known-zero day has no sections")

        // Event-only: no tokens, but the recorded block still shows — with its honest unknown.
        XCTAssertEqual(days[2].detail.status, "No activity")
        XCTAssertEqual(days[2].detail.blocks.map(\.row.value), ["—"],
                       "unknown duration is —, never an invented lockout")
        XCTAssertEqual(days[2].detail.blocks.map(\.warn), [true],
                       "the unknown lockout is flagged for the warn hue (STEP_163) — the "
                       + "string stays the § 6.1 dash")
    }

    func testUnknownOptionalValuesStayAbsentOrDashed() {
        let target = HXFix.dayStart(index: 1, of: 2)
        let days = HXFix.withDay(
            HXFix.days([0, 50_000]), at: 1,
            modelTotals: [HXFix.totals(output: 50_000)],
            modelValues: [HXFix.mv("claude-sonnet-4-6", 0.75)], value: 0.75)
        let tool = HXFix.tool(
            .claude, days: days,
            criticalObservations: [HXFix.observation(at: target.addingTimeInterval(3600),
                                                     .spendControl)])
        let detail = explore([tool], .tool(.claude)).days[1].detail
        XCTAssertEqual(detail.observations.map(\.row.label).first?.hasPrefix("Spend control ·"),
                       true)
        XCTAssertEqual(detail.observations.map(\.row.value), ["—"],
                       "no stored utilization ⇒ the unknown placeholder")
        XCTAssertTrue(detail.blocks.isEmpty && detail.changes.isEmpty,
                      "absent optional groups are empty, not rows of dashes")
    }

    func testAllDayDetailGroupsByProviderAndCombinesOnlyDollars() {
        let claudeDays = HXFix.withDay(HXFix.days([0, 300_000]), at: 1,
                                       modelTotals: [HXFix.totals(input: 300_000)],
                                       modelValues: [HXFix.mv("claude-sonnet-4-6", 2.4)],
                                       value: 2.4)
        let codexDays = HXFix.withDay(HXFix.days([0, 100_000], sessions: [0, 1]), at: 1,
                                      modelTotals: [HXFix.totals(model: nil, input: 100_000)],
                                      modelValues: [HXFix.mv(nil, 0.3)], value: 0.3)
        let detail = explore([HXFix.tool(.claude, days: claudeDays),
                              HXFix.tool(.codex, sessions: 2, days: codexDays)]).days[1].detail

        XCTAssertEqual(detail.sections.map(\.provider), [.claude, .codex])
        XCTAssertEqual(detail.sections.map(\.tokens),
                       [Fmt.tokens(300_000), Fmt.tokens(100_000)],
                       "provider tokens stay separate — grouped, never combined")
        XCTAssertEqual(detail.sections.map(\.activity), ["1 session", "1 thread"],
                       "provider-native nouns survive the All filter")
        XCTAssertEqual(detail.combinedValue, Fmt.dollarValue(2.7),
                       "dollars combine — once, subordinate")
    }

    // MARK: - Week by week (REV-84 §5.2)

    func testWeekRowsCarryTokensValueOwnScaleAndPartialNote() {
        let tool = HXFix.tool(.claude, weeks: [
            HXFix.week(daysBack: 0, tokens: 900_000, value: 7.5),
            HXFix.week(daysBack: 7, tokens: 600_000, value: 5.0),
            HXFix.week(daysBack: 28, tokens: 0, value: 0, partial: true),
        ])
        let weekly = explore([tool], .tool(.claude)).weekly
        XCTAssertEqual(weekly.count, 1)
        let rows = weekly[0].rows
        XCTAssertEqual(rows.map(\.tokens), [Fmt.tokens(900_000), Fmt.tokens(600_000),
                                            "No activity"])
        XCTAssertEqual(rows.map(\.value), [Fmt.dollarValue(7.5), Fmt.dollarValue(5.0),
                                           Fmt.dollarValue(0)],
                       "every week shows its Est. token value — a known zero is $0.00")
        XCTAssertEqual(rows[0].fraction, 1.0)
        XCTAssertEqual(rows[1].fraction, 600_000.0 / 900_000.0, accuracy: 0.001)
        XCTAssertEqual(rows.map(\.note), [nil, nil, "Partial week"])
    }

    // MARK: - Provider totals (REV-84 §5.2)

    func testProviderTotalsAreSeparateAndOnlyDollarsCombine() {
        let claude = HXFix.tool(.claude, sessions: 133, totalTokens: 2_000_000, value: 20.0)
        let codex = HXFix.tool(.codex, sessions: 16, totalTokens: 400_000, cacheHit: nil,
                               value: 1.5)
        let page = explore([claude, codex])
        XCTAssertEqual(page.totals.map(\.title), ["Claude total", "Codex total"])
        XCTAssertEqual(page.totals.map(\.activity), ["133 sessions", "16 threads"])
        XCTAssertEqual(page.combinedValue, Fmt.dollarValue(21.5))

        XCTAssertNil(explore([claude, HXFix.blank(.codex)]).combinedValue,
                     "one active provider ⇒ its story, no combined figure")
        XCTAssertNil(explore([claude], .tool(.claude)).combinedValue)
    }

    // MARK: - 30-day breakdown (REV-84 §5.3)

    func testBreakdownIsThirtyDayGrainAndNeverCrossesTheDayModels() {
        let (tool, _) = { () -> (HistoryReport.ToolReport, Date) in
            let target = HXFix.dayStart(index: 1, of: 2)
            let days = HXFix.withDay(HXFix.days([0, 300_000]), at: 1,
                                     modelTotals: [HXFix.totals(input: 300_000)],
                                     modelValues: [HXFix.mv("claude-sonnet-4-6", 2.4)],
                                     value: 2.4)
            return (HXFix.tool(.claude,
                               modelTotals: [HXFix.totals(input: 1_400_000),
                                             HXFix.totals(model: "claude-opus-4-8",
                                                          input: 100_000)],
                               modelValues: [HXFix.mv("claude-sonnet-4-6", 11.0),
                                             HXFix.mv("claude-opus-4-8", 1.5)],
                               days: days), target)
        }()
        let page = explore([tool], .tool(.claude))
        XCTAssertEqual(page.breakdown.title, "30-day breakdown")
        XCTAssertEqual(page.breakdown.models.count, 1)
        XCTAssertEqual(page.breakdown.models[0].rows.count, 2,
                       "period grain: both models of the 30 days")
        XCTAssertEqual(page.days[1].detail.sections.first?.models.count, 1,
                       "day grain: only the selected day's model — the grains never mix")
        XCTAssertEqual(page.breakdown.models[0].rows[0].row.value,
                       "\(Fmt.tokens(1_400_000)) · \(Fmt.dollarValue(11.0))",
                       "30-day model rows carry tokens and Est. token value")
        XCTAssertEqual(page.breakdown.models[0].rows[0].fraction, 1.0,
                       "STEP_162: the top model row is the full track")
    }

    func testProjectsAndLargestWorkAreDisplayedWithoutRegrouping() {
        let sessionAt = HXFix.now.addingTimeInterval(-3 * 86_400)
        let claude = HXFix.tool(
            .claude,
            projects: [HistoryReport.Project(name: "/u/kvotar", sessions: 4, tokens: 900_000)],
            topSessions: [HistoryReport.Session(sessionId: "s1", project: "kvotar",
                                                model: nil, lastSeenAt: sessionAt,
                                                tokens: 400_000, value: 3.2)])
        let codex = HXFix.tool(
            .codex,
            projects: [HistoryReport.Project(name: "/u/api", sessions: 2, tokens: 500_000)])
        let breakdown = explore([claude, codex]).breakdown
        XCTAssertEqual(breakdown.projects.map(\.row.label), ["kvotar", "api"],
                       "Core's grouping is displayed, never re-derived")
        XCTAssertEqual(breakdown.projects.map(\.tag), ["Claude", "Codex"])
        XCTAssertEqual(breakdown.largestWork.map(\.row.label),
                       ["\(Fmt.monthDay(sessionAt)) · kvotar"])
        XCTAssertEqual(breakdown.largestWork.map(\.row.value),
                       ["\(Fmt.tokens(400_000)) · \(Fmt.dollarValue(3.2))"])
    }

    // MARK: - Empty state

    func testExploreEmptyStateIsProviderScoped() {
        let watched = HXFix.blank(.codex, watchingSince: HXFix.now.addingTimeInterval(-86_400))
        let page = explore([HXFix.tool(.claude), watched], .tool(.codex))
        XCTAssertEqual(page.emptyMessage, "No local Codex activity in the last 30 days.")
        XCTAssertTrue(page.days.isEmpty)
        XCTAssertNil(page.initialSelection)
    }
}
