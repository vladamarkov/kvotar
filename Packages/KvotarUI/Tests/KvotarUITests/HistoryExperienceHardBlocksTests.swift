import XCTest
import KvotarCore
@testable import KvotarUI

/// STEP_159 — the Hard blocks contract (REV-84 §6): the conclusion strip with its named
/// denominator, the chronological provider merge, the REV-73 pattern floor and its
/// investigative note, the honest coverage note, and per-provider chart scales.
final class HistoryExperienceHardBlocksTests: XCTestCase {

    private func hardBlocks(_ tools: [HistoryReport.ToolReport],
                            _ provider: HistoryExperience.Provider = .all)
        -> HistoryExperience.HardBlocksPage {
        HXFix.pages(tools, provider).hardBlocks
    }

    // MARK: - Conclusion strip

    func testConsequenceCardNamesTheDenominatorWhenDurationsAreMissing() {
        let b1 = HXFix.block(at: HXFix.now.addingTimeInterval(-4 * 86_400), lockout: 3600)
        let b2 = HXFix.block(at: HXFix.now.addingTimeInterval(-3 * 86_400), lockout: 7200)
        let b3 = HXFix.block(at: HXFix.now.addingTimeInterval(-86_400), lockout: nil)
        let page = hardBlocks([HXFix.tool(.claude, limitBlocks: [b1, b2, b3])], .tool(.claude))
        XCTAssertEqual(page.eyebrow, "Claude · hard blocks")
        XCTAssertEqual(page.conclusion,
                       "3 recorded blocks · last \(Fmt.monthDay(b3.firedAt)).")
        let card = page.consequence
        XCTAssertEqual(card?.label, "Known consequence")
        XCTAssertEqual(card?.figure, Fmt.span(seconds: 10_800))
        XCTAssertEqual(card?.caption,
                       "2 of 3 resets recovered. "
                       + "Longest \(Fmt.span(seconds: 7200)) on \(Fmt.monthDay(b2.firedAt)).")
    }

    func testConsequenceCardWithAllDurationsKnownSaysAllRecovered() {
        let b1 = HXFix.block(at: HXFix.now.addingTimeInterval(-4 * 86_400), lockout: 3600)
        let b2 = HXFix.block(at: HXFix.now.addingTimeInterval(-2 * 86_400), lockout: 7200)
        let page = hardBlocks([HXFix.tool(.claude, limitBlocks: [b1, b2])], .tool(.claude))
        XCTAssertEqual(page.conclusion,
                       "2 recorded blocks · last \(Fmt.monthDay(b2.firedAt)).")
        XCTAssertEqual(page.consequence?.figure, Fmt.span(seconds: 10_800))
        XCTAssertEqual(page.consequence?.caption,
                       "All 2 resets recovered. "
                       + "Longest \(Fmt.span(seconds: 7200)) on \(Fmt.monthDay(b2.firedAt)).")
    }

    func testConsequenceCardWithNoRecoveredResetSaysUnknown() {
        let block = HXFix.block(at: HXFix.now.addingTimeInterval(-86_400), lockout: nil)
        let page = hardBlocks([HXFix.tool(.claude, limitBlocks: [block])], .tool(.claude))
        XCTAssertEqual(page.consequence?.figure, "Unknown")
        XCTAssertEqual(page.consequence?.caption, "The reset could not be recovered.")

        let single = HXFix.block(at: HXFix.now.addingTimeInterval(-86_400), lockout: 3600)
        let recovered = hardBlocks([HXFix.tool(.claude, limitBlocks: [single])], .tool(.claude))
        XCTAssertEqual(recovered.consequence?.figure, Fmt.span(seconds: 3600))
        XCTAssertEqual(recovered.consequence?.caption, "The reset was recovered.")
    }

    /// STEP_163 decision 1: an unrecovered reset keeps the `—` §6.1 owns as its value and is
    /// flagged for the warn hue instead — never the prototype's `Reset unknown` string.
    func testUnknownLockoutRowIsFlaggedWarnAndKeepsTheDash() {
        let known = HXFix.block(at: HXFix.now.addingTimeInterval(-3 * 86_400), lockout: 7200)
        let unknown = HXFix.block(at: HXFix.now.addingTimeInterval(-86_400), lockout: nil)
        let page = hardBlocks([HXFix.tool(.claude, limitBlocks: [known, unknown])],
                              .tool(.claude))
        XCTAssertEqual(page.rows.map(\.warn), [true, false], "newest first")
        XCTAssertEqual(page.rows.map(\.row.value),
                       ["—", "locked out \(Fmt.span(seconds: 7200))"])
    }

    func testAllowanceHistoryFollowsTheInvestigation() {
        let watching = HXFix.now.addingTimeInterval(-9 * 86_400)
        let change = HXFix.change(at: HXFix.now.addingTimeInterval(-4 * 86_400),
                                  old: "go", new: "plus")
        let page = hardBlocks([HXFix.tool(.claude, accountChanges: [change],
                                          watchingSince: watching)], .tool(.claude))
        let allowance = page.allowance
        XCTAssertEqual(allowance?.title, "Allowance history")
        XCTAssertEqual(allowance?.changes.map(\.row.value), ["go → plus"])
        XCTAssertEqual(allowance?.evidence.count, 1,
                       "one REV-72 verdict per watched provider — context, never causation")
    }

    func testNoBlockStateReportsHonestlyWithoutAChart() {
        let watching = HXFix.now.addingTimeInterval(-8 * 86_400)
        let page = hardBlocks([HXFix.tool(.claude, watchingSince: watching)], .tool(.claude))
        XCTAssertEqual(page.conclusion, "No recorded hard blocks in the last 30 days.")
        XCTAssertNil(page.consequence, "no blocks ⇒ no consequence card, not a zero")
        XCTAssertTrue(page.rows.isEmpty)
        XCTAssertNil(page.chart)
        XCTAssertNil(page.patternNote)
        XCTAssertEqual(page.coverageNote,
                       "Recorded since \(Fmt.monthDay(watching)), when Kvotar began watching. "
                       + "Weekly-only exhaustion may not appear, and an unknown reset means "
                       + "an unknown lockout, not zero.")
    }

    func testNeverWatchedCoverageNoteSaysNothingYet() {
        let page = hardBlocks([HXFix.tool(.claude)], .tool(.claude))
        XCTAssertTrue(page.coverageNote.hasPrefix(
            "Recorded from the day Kvotar starts watching — nothing yet."))
    }

    // MARK: - Provider merge (REV-84 §6 item 2)

    func testAllMergesChronologicallyWithProviderLabelsAndPerProviderCounts() {
        let claudeOld = HXFix.block(at: HXFix.now.addingTimeInterval(-6 * 86_400), lockout: 3600)
        let codexMid = HXFix.block(at: HXFix.now.addingTimeInterval(-4 * 86_400), lockout: nil)
        let claudeNew = HXFix.block(at: HXFix.now.addingTimeInterval(-2 * 86_400), lockout: 7200)
        let page = hardBlocks([HXFix.tool(.claude, limitBlocks: [claudeOld, claudeNew]),
                               HXFix.tool(.codex, limitBlocks: [codexMid])])
        XCTAssertEqual(page.rows.map(\.tag), ["Claude", "Codex", "Claude"],
                       "newest first, one chronology, each row named")
        XCTAssertEqual(page.rows.map(\.row.value),
                       ["locked out \(Fmt.span(seconds: 7200))", "—",
                        "locked out \(Fmt.span(seconds: 3600))"])
        XCTAssertTrue(page.conclusion.hasPrefix("Claude 2 blocks · Codex 1 block · last "),
                      "counts stay per provider — unlike activity, block counts never merge "
                      + "into one figure without their owners")
    }

    // MARK: - Pattern floor (REV-73, preserved)

    func testPatternClaimStaysBehindTheFloor() {
        let above = (0..<12).map {
            HXFix.localBlock(daysBack: Double($0) + 1, hour: $0 % 2 == 0 ? 14 : 15)
        }
        XCTAssertEqual(hardBlocks([HXFix.tool(.claude, limitBlocks: above)],
                                  .tool(.claude)).patternNote,
                       "Most often 2–6 pm")

        let below = (0..<3).map { HXFix.localBlock(daysBack: Double($0) + 1, hour: 14) }
        XCTAssertEqual(hardBlocks([HXFix.tool(.claude, limitBlocks: below)],
                                  .tool(.claude)).patternNote,
                       "Not enough recorded blocks to call a typical time.",
                       "below the floor the investigative note states the sample honestly")
    }

    func testAllPatternNoteIsProviderScoped() {
        let above = (0..<12).map {
            HXFix.localBlock(daysBack: Double($0) + 1, hour: $0 % 2 == 0 ? 14 : 15)
        }
        let page = hardBlocks([HXFix.tool(.claude, limitBlocks: above),
                               HXFix.tool(.codex,
                                          limitBlocks: [HXFix.localBlock(daysBack: 1, hour: 9)])])
        XCTAssertEqual(page.patternNote, "Claude · Most often 2–6 pm",
                       "the claim is named; the below-floor provider makes no claim")
    }

    // MARK: - Chart (REV-84 §6 item 3 — independent scales)

    func testChartNormalisesEachProviderAgainstItsOwnBusiestHour() {
        var claudeHours = [Int](repeating: 0, count: 24)
        claudeHours[10] = 1_000
        var codexHours = [Int](repeating: 0, count: 24)
        codexHours[11] = 100
        let page = hardBlocks([
            HXFix.tool(.claude, limitBlocks: [HXFix.localBlock(daysBack: 1, hour: 10)],
                       workByHour: claudeHours),
            HXFix.tool(.codex, workByHour: codexHours),
        ])
        let chart = try! XCTUnwrap(page.chart)
        XCTAssertEqual(chart.points[10].bars.first { $0.tool == .claude }?.fraction, 1.0)
        XCTAssertEqual(chart.points[11].bars.first { $0.tool == .codex }?.fraction, 1.0,
                       "codex's busiest hour fills its own lane — scales are never shared")
    }

    func testChartStaysGatedOnAShortBlockingWindow() {
        var hours = [Int](repeating: 0, count: 24)
        hours[10] = 1_000
        let weekly = HXFix.block(at: HXFix.now.addingTimeInterval(-86_400), lockout: 7200,
                                 width: 7 * 86_400)
        let page = hardBlocks([HXFix.tool(.claude, limitBlocks: [weekly], workByHour: hours)],
                              .tool(.claude))
        XCTAssertNil(page.chart,
                     "a seven-day block earns the lockout row, not an hour chart (D-80)")
    }
}
