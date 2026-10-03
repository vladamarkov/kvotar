import XCTest
import KvotarCore
@testable import KvotarUI

/// The rules that outlived Summary (STEP_182 — REV-93 / D-115). `HistoryExperienceSummaryTests`
/// retired with the payload it pinned: the §4.2 conclusion ladder, the hero facts and the
/// activity-peak sentence have no successor, and Weekly recap's ladder is a different one over a
/// different period (`HistoryExperienceRecapTests`).
///
/// What survived is what Summary shared with Hard blocks and Explore usage — the REV-72 allowance
/// verdicts and their collapsed change rows, the corrected project ranking, and the provider-safe
/// strip geometry — re-pinned on the surfaces that still draw them.
final class HistoryExperienceAllowanceTests: XCTestCase {

    private func busierWeeks() -> [HistoryReport.Week] {
        [HXFix.week(daysBack: 0, tokens: 2_200_000), HXFix.week(daysBack: 7, tokens: 2_000_000)]
    }

    private func quieterWeeks() -> [HistoryReport.Week] {
        [HXFix.week(daysBack: 0, tokens: 1_700_000), HXFix.week(daysBack: 7, tokens: 2_000_000)]
    }

    /// The panel now lives only under the Hard-blocks investigation (§6.5 item 6).
    private func allowance(_ tools: [HistoryReport.ToolReport],
                           _ provider: HistoryExperience.Provider = .all)
        -> HistoryExperience.AllowancePanel? {
        HXFix.pages(tools, provider).hardBlocks.allowance
    }

    // MARK: - Allowance panel (REV-84 §4.1 item 2, amended 2026-09-01)

    func testAllowancePanelCarriesVerdictsAndChangeRows() {
        let watching = HXFix.now.addingTimeInterval(-25 * 86_400)
        let changeAt = HXFix.now.addingTimeInterval(-4 * 86_400)
        // Earned: ≥3 qualifying cycles ⇒ the one permitted verdict plus its figure row.
        let earned = HXFix.tool(.claude, weeks: busierWeeks(),
                                accountChanges: [HXFix.change(at: changeAt,
                                                              old: "go", new: "plus")],
                                watchingSince: watching,
                                workPerPercent: HXFix.qualifyingSeries(count: 3))
        let single = allowance([earned], .tool(.claude))
        XCTAssertEqual(single?.title, "Allowance history",
                       "Summary's question form retired with Summary")
        XCTAssertEqual(single?.evidence.first?.lede, "Nothing conclusive yet.")
        XCTAssertNotNil(single?.evidence.first?.row,
                        "an earned statement carries its figure row")
        XCTAssertEqual(single?.changes.map(\.row.value), ["go → plus"])
        XCTAssertEqual(single?.changes.map(\.tag), [nil])

        // On All the same evidence is named.
        let all = allowance([earned, HXFix.tool(.codex, weeks: quieterWeeks())])
        XCTAssertEqual(all?.evidence.first?.lede, "Claude — Nothing conclusive yet.")
        XCTAssertEqual(all?.changes.map(\.tag), ["Claude"])

        // Below the cycle floor the panel states how little it has, and carries no figure row.
        let unearned = allowance([HXFix.tool(.claude, weeks: busierWeeks(),
                                             watchingSince: watching,
                                             workPerPercent: HXFix.qualifyingSeries(count: 2))],
                                 .tool(.claude))
        XCTAssertTrue(unearned?.evidence.first?.lede.hasPrefix("Not enough history yet") == true)
        XCTAssertNil(unearned?.evidence.first?.row)
    }

    /// STEP_163 amendment (user decision, live pass): one recorded fact is one row. The live
    /// Codex account resets its weekly window early every other day, and the panel printed the
    /// identical row three times.
    func testRepeatedIdenticalChangesCollapseIntoOneCountedRow() {
        let day: TimeInterval = 86_400
        let early = { (daysBack: Double) in
            HXFix.change(at: HXFix.now.addingTimeInterval(-daysBack * day), kind: .earlyReset,
                         windowType: "weekly")
        }
        let tool = HXFix.tool(.codex, weeks: quieterWeeks(),
                              accountChanges: [early(1), early(3), early(5),
                                               HXFix.change(at: HXFix.now
                                                   .addingTimeInterval(-20 * day),
                                                            old: "go", new: "plus")],
                              watchingSince: HXFix.now.addingTimeInterval(-25 * day))
        let changes = allowance([tool], .tool(.codex))?.changes ?? []

        let oldest = Fmt.monthDay(HXFix.now.addingTimeInterval(-5 * day))
        let newest = Fmt.monthDay(HXFix.now.addingTimeInterval(-1 * day))
        XCTAssertEqual(changes.map(\.row.label).first,
                       "\(HistoryDisplay.resetEarlyLabel) · 3× · \(oldest) – \(newest)",
                       "three identical facts are one row, spanning oldest to newest")
        XCTAssertEqual(changes.count, 2, "the plan change stays its own row")
        XCTAssertEqual(changes.last?.row.value, "go → plus")
        XCTAssertFalse(changes.last?.row.label.contains("×") == true,
                       "a single occurrence keeps the plain `lead · date` form")
    }

    // MARK: - Corrected project ranking (now Explore usage's `30-day breakdown`)

    func testBreakdownShowsCorrectedProjectsWithTagsOnlyWhenShared() {
        let claude = HXFix.tool(
            .claude,
            projects: [HistoryReport.Project(name: "/u/kvotar", sessions: 4, tokens: 900_000),
                       HistoryReport.Project(name: nil, sessions: 1, tokens: 100_000)])
        let codex = HXFix.tool(
            .codex,
            projects: [HistoryReport.Project(name: "/u/api", sessions: 2, tokens: 500_000)])

        let single = HXFix.pages([claude], .tool(.claude)).explore.breakdown
        XCTAssertEqual(single.projects.map(\.row.label), ["kvotar", "(no project)"],
                       "reader order preserved — the display never re-groups")
        XCTAssertEqual(single.projects.map(\.tag), [nil, nil])

        let all = HXFix.pages([claude, codex], .all).explore.breakdown
        XCTAssertEqual(all.projects.map(\.row.label), ["kvotar", "api", "(no project)"],
                       "All merges by tokens and caps at the shared-row limit")
        XCTAssertEqual(all.projects.map(\.tag), ["Claude", "Codex", "Claude"])
    }

    // MARK: - Provider-safe strip geometry (REV-84 §3.1)

    func testAllStripNormalisesEachProviderAgainstItsOwnBusiestDay() {
        let claude = HXFix.tool(.claude, days: HXFix.days([0, 100_000, 1_000_000]))
        let codex = HXFix.tool(.codex, days: HXFix.days([0, 50_000, 10_000]))
        let middle = HXFix.pages([claude, codex], .all).explore.days[1].point.bars
        XCTAssertEqual(middle.first { $0.tool == .claude }?.fraction ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(middle.first { $0.tool == .codex }?.fraction ?? 0, 1.0, accuracy: 0.001,
                       "codex's busiest day fills its own lane — scales are never shared")
    }
}
