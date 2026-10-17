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
                       + "Blocks are recorded only while Notify me ▸ Over quota is on. "
                       + "An unknown reset means an unknown lockout, not zero.")
        XCTAssertFalse(HXFix.allStrings(of: page).contains { $0.contains("Weekly-only") },
                       "a spent weekly reaches the same path now; the old clause is gone")
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

    /// The note says which it is: a claim, drawn as the amber card, or the sample note below
    /// the floor, drawn as an ordinary note — the view never reads the words to decide.
    func testPatternClaimStaysBehindTheFloor() {
        let above = (0..<12).map {
            HXFix.localBlock(daysBack: Double($0) + 1, hour: $0 % 2 == 0 ? 14 : 15)
        }
        let claimed = hardBlocks([HXFix.tool(.claude, limitBlocks: above)],
                                 .tool(.claude)).patternNote
        XCTAssertEqual(claimed?.text, "Most often 2–6 pm")
        XCTAssertEqual(claimed?.state, .claimed)

        let below = (0..<3).map { HXFix.localBlock(daysBack: Double($0) + 1, hour: 14) }
        let note = hardBlocks([HXFix.tool(.claude, limitBlocks: below)],
                              .tool(.claude)).patternNote
        XCTAssertEqual(note?.text, "Not enough recorded blocks to call a typical time.",
                       "below the floor the investigative note states the sample honestly")
        XCTAssertEqual(note?.state, .belowFloor, "and claims nothing")
    }

    func testAllPatternNoteIsProviderScoped() {
        let above = (0..<12).map {
            HXFix.localBlock(daysBack: Double($0) + 1, hour: $0 % 2 == 0 ? 14 : 15)
        }
        let page = hardBlocks([HXFix.tool(.claude, limitBlocks: above),
                               HXFix.tool(.codex,
                                          limitBlocks: [HXFix.localBlock(daysBack: 1, hour: 9)])])
        XCTAssertEqual(page.patternNote?.text, "Claude · Most often 2–6 pm",
                       "the claim is named; the below-floor provider makes no claim")
        XCTAssertEqual(page.patternNote?.state, .claimed)
    }

    // MARK: - The way back to the window

    /// The mirror of Explore quota's `Recorded block` link: a block row leads to its window,
    /// pinned on Explore quota, under a banner naming the block.
    func testABlockRowLinksToItsQuotaWindow() throws {
        let window = HXFix.quotaWindow(.claude, daysBack: 5, hour: 17, used: 100, hitLimit: true)
        let block = HXFix.block(at: window.resetsAt.addingTimeInterval(-1800), lockout: 1800)
        let page = hardBlocks([HXFix.tool(.claude, limitBlocks: [block], quotaWindows: [window])],
                              .tool(.claude))
        let link = try XCTUnwrap(page.rows.first?.link)
        XCTAssertEqual(link.label, "Quota window · \(HistoryDisplay.quotaSpan(window))")
        XCTAssertEqual(link.destination,
                       HistoryDestination(mode: .exploreQuota, provider: .claude,
                                          focus: .quotaWindow(id: window.id),
                                          banner: "From hard block · Claude · "
                                              + "\(Fmt.monthDay(block.firedAt)), "
                                              + "\(Fmt.clock(block.firedAt))"))
        let all = hardBlocks([HXFix.tool(.claude, limitBlocks: [block], quotaWindows: [window]),
                              HXFix.tool(.codex)])
        XCTAssertEqual(all.rows.first?.link?.destination.provider, .claude,
                       "on All the link names the row's own provider")
    }

    /// A five-hour window and the weekly routinely share a reset: the block's own width picks
    /// its window. A block whose reset was never recovered takes the narrowest window holding
    /// its instant.
    func testABlockPicksItsOwnWindowWhereTheWeeklySharesTheReset() {
        let short = HXFix.quotaWindow(.claude, daysBack: 5, hour: 17)
        let weekly = HXFix.weeklyLimit(endedAt: short.resetsAt, used: 80)
        let onShort = HXFix.block(at: short.resetsAt.addingTimeInterval(-1800), lockout: 1800)
        let onWeekly = HXFix.block(at: short.resetsAt.addingTimeInterval(-7200), lockout: 7200,
                                   width: 604_800)
        let unknown = HXFix.block(at: short.resetsAt.addingTimeInterval(-600), lockout: nil)
        let page = hardBlocks([HXFix.tool(.claude, limitBlocks: [onShort, onWeekly, unknown],
                                          quotaWindows: [short], weeklyLimits: [weekly])],
                              .tool(.claude))
        XCTAssertEqual(page.rows.map { $0.link?.destination.quotaWindowID },
                       [short.id, short.id, weekly.outcome.id],
                       "newest first: the unknown-width block, the five-hour one, the weekly one")
    }

    /// A block outside every window on the page, or whose recovered reset is none of theirs,
    /// has no way back — the row still stands.
    func testABlockWhoseWindowIsNotOnThePageCarriesNoLink() {
        let window = HXFix.quotaWindow(.claude, daysBack: 5, hour: 17)
        let outside = HXFix.block(at: window.resetsAt.addingTimeInterval(-86_400), lockout: 1800)
        let otherReset = HXFix.block(at: window.resetsAt.addingTimeInterval(-1800), lockout: 7200)
        let page = hardBlocks([HXFix.tool(.claude, limitBlocks: [outside, otherReset],
                                          quotaWindows: [window])], .tool(.claude))
        XCTAssertEqual(page.rows.count, 2)
        XCTAssertTrue(page.rows.allSatisfy { $0.link == nil })
        let bare = hardBlocks([HXFix.tool(.claude, limitBlocks: [otherReset])], .tool(.claude))
        XCTAssertNil(bare.rows.first?.link, "no quota window recorded at all")
    }

    /// A window that was withdrawn holds time only to its actual end: a block after that
    /// belongs to the replacement window, whatever the withdrawn window was scheduled to reset at.
    func testAWithdrawnWindowHoldsNoBlockAfterItsActualEnd() {
        let scheduled = HXFix.quotaWindow(.claude, daysBack: 5, hour: 14)
        let withdrawn = HXFix.quotaWindow(.claude, daysBack: 5, hour: 14, ending: .withdrawn,
                                          endedAt: scheduled.resetsAt.addingTimeInterval(-4 * 3600))
        let replacement = HXFix.quotaWindow(.claude, daysBack: 5, hour: 15)
        let block = HXFix.block(at: scheduled.resetsAt.addingTimeInterval(-3 * 3600), lockout: nil)
        let page = hardBlocks([HXFix.tool(.claude, limitBlocks: [block],
                                          quotaWindows: [withdrawn, replacement])], .tool(.claude))
        XCTAssertEqual(page.rows.first?.link?.destination.quotaWindowID, replacement.id)
    }

    /// Only a window the Explore quota page draws can be named: a provider with no main window
    /// has no section there, so a surviving weekly alone earns its block no link; and a block
    /// of a known width never points at a window of another width, even one sharing its reset.
    func testOnlyAWindowThePageDrawsCanBeNamed() {
        let weekly = HXFix.weeklyLimit(endedAt: HXFix.now.addingTimeInterval(-3 * 86_400), used: 80)
        let onWeekly = HXFix.block(at: weekly.outcome.resetsAt.addingTimeInterval(-7200),
                                   lockout: 7200, width: 604_800)
        let weeklyOnly = hardBlocks([HXFix.tool(.claude, limitBlocks: [onWeekly],
                                                weeklyLimits: [weekly])], .tool(.claude))
        XCTAssertNil(weeklyOnly.rows.first?.link, "no main window, no section, no link")

        let elsewhere = HXFix.quotaWindow(.claude, daysBack: 9, hour: 9)
        let fiveHour = HXFix.block(at: weekly.outcome.resetsAt.addingTimeInterval(-1800),
                                   lockout: 1800)
        let page = hardBlocks([HXFix.tool(.claude, limitBlocks: [fiveHour],
                                          quotaWindows: [elsewhere], weeklyLimits: [weekly])],
                              .tool(.claude))
        XCTAssertNil(page.rows.first?.link,
                     "a five-hour block is not sent to the weekly it shares a reset with")
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
