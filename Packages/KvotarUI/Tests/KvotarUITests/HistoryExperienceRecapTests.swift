import XCTest
import KvotarCore
@testable import KvotarUI

/// Weekly recap (STEP_182 — REV-93 §2.2 / UI Spec §6.2; STEP_228 — REV-104 / D-129): the
/// completed-week population, the lead ladder, the `This week` table, the weekly-limit lines, the
/// observations, the block-gated action, the coverage rules and the typed evidence links.
///
/// The fixture clock is Sunday 2026-08-16 12:00 UTC, so the current week is Aug 10–16 and the
/// latest completed one is Aug 3–9. `HXFix.days` builds back from Aug 16, which makes a 14-day
/// array exactly two weeks: indices 0…6 are the recap week and 7…13 are the current one.
final class HistoryExperienceRecapTests: XCTestCase {

    private let day: TimeInterval = 86_400

    private func recap(_ tools: [HistoryReport.ToolReport]) -> HistoryExperience.RecapSection {
        HXFix.experience(tools).recap
    }

    private func latest(_ tools: [HistoryReport.ToolReport]) -> HistoryExperience.RecapWeek {
        recap(tools).weeks[0]
    }

    /// An instant inside the latest completed week (Aug 3–9).
    private func inRecapWeek(_ dayIndex: Int = 2, hour: Int = 14) -> Date {
        HXFix.dayStart(index: dayIndex, of: 14).addingTimeInterval(TimeInterval(hour) * 3600)
    }

    /// An instant inside the *current* week (Aug 10–16), which no recap may describe.
    private func inCurrentWeek(_ dayIndex: Int = 11, hour: Int = 14) -> Date {
        HXFix.dayStart(index: dayIndex, of: 14).addingTimeInterval(TimeInterval(hour) * 3600)
    }

    private func fortnight(_ recapWeek: [Int], current: [Int]) -> [HistoryReport.Day] {
        HXFix.days(recapWeek + current)
    }

    // MARK: - Population

    func testTheHorizonYieldsCompletedWeeksNewestFirstWithTheOldestClipped() {
        let section = recap([HXFix.tool(.claude, days: fortnight(Array(repeating: 1_000_000, count: 7),
                                                                 current: Array(repeating: 500_000, count: 7)))])
        XCTAssertEqual(section.weeks.count, 4)
        XCTAssertNil(section.emptyMessage)
        XCTAssertEqual(section.weeks[0].title, "Last completed week")
        XCTAssertTrue(section.weeks[0].isLatest)
        XCTAssertFalse(section.weeks[1].isLatest)
        XCTAssertTrue(section.weeks[1].title.hasPrefix("Week of "))
        XCTAssertEqual(section.weeks.last?.coverageNote, HistoryDisplay.recapClippedCoverage,
                       "the oldest week is only partly inside the fixed 30-day horizon")
    }

    /// The whole point of the mode: a recap describes a *completed* week. The current week's
    /// tokens, blocks and changes are outside every population it reads.
    func testCurrentWeekEvidenceReachesNoRecap() {
        let tool = HXFix.tool(
            .claude,
            accountChanges: [HXFix.change(at: inCurrentWeek(), old: "go", new: "plus")],
            limitBlocks: [HXFix.block(at: inCurrentWeek(12), lockout: 7_200)],
            days: fortnight(Array(repeating: 0, count: 7), current: Array(repeating: 900_000, count: 7)))
        for week in recap([tool]).weeks {
            let strings = HXFix.allStrings(of: week)
            for string in strings {
                XCTAssertFalse(string.contains("go → plus"),
                               "a current-week change leaked into \(week.title): \(string)")
                XCTAssertFalse(string.contains("ran out"),
                               "a current-week block leaked into \(week.title): \(string)")
            }
        }
    }

    func testNoCompletedWeekYieldsTheEmptyState() {
        // A report whose whole horizon sits inside the current week.
        let report = HistoryReport(periodStart: HXFix.now.addingTimeInterval(-2 * 86_400),
                                   periodEnd: HXFix.now, tools: [HXFix.tool(.claude)],
                                   pricingVersion: nil, pricingUpdated: nil)
        let section = HistoryDisplay.experience(report, now: HXFix.now,
                                                calendar: HXFix.recapCalendar).recap
        XCTAssertTrue(section.weeks.isEmpty)
        XCTAssertEqual(section.emptyMessage, HistoryDisplay.recapEmptyMessage)
    }

    // MARK: - Lead ladder (§6.2)

    func testRungOneAHardBlockLeadsWithItsKnownConsequence() {
        let week = latest([HXFix.tool(
            .claude,
            accountChanges: [HXFix.change(at: inRecapWeek(), old: "go", new: "plus")],
            limitBlocks: [HXFix.block(at: inRecapWeek(3), lockout: 3600)],
            days: fortnight(Array(repeating: 800_000, count: 7), current: Array(repeating: 0, count: 7)))])
        XCTAssertEqual(week.lead.kind, .blockConsequence)
        XCTAssertEqual(week.lead.eyebrow, HistoryDisplay.recapCapacityEyebrow)
        XCTAssertEqual(week.lead.sentence, "Claude ran out of its window once.")
        XCTAssertEqual(week.lead.grounding, "Known lockout \(Fmt.span(seconds: 3600)).")
    }

    /// An unrecovered reset is an unknown lockout, never a zero one (REV-73 §4.3) — and the block
    /// still leads, because the outcome happened whether or not its duration survived.
    func testABlockWithNoRecoveredResetStillLeadsAndSaysTheLockoutIsUnknown() {
        let week = latest([HXFix.tool(
            .claude, limitBlocks: [HXFix.block(at: inRecapWeek(3), lockout: nil)],
            days: fortnight(Array(repeating: 800_000, count: 7), current: Array(repeating: 0, count: 7)))])
        XCTAssertEqual(week.lead.kind, .blockConsequence)
        XCTAssertEqual(week.lead.grounding,
                       "The reset could not be recovered, so the lockout is unknown.")
    }

    func testRungTwoAStructuralAllowanceChangeLeadsWhenNothingBlocked() {
        let week = latest([HXFix.tool(
            .claude,
            accountChanges: [HXFix.change(at: inRecapWeek(), old: "go", new: "plus")],
            days: fortnight(Array(repeating: 800_000, count: 7), current: Array(repeating: 0, count: 7)))])
        XCTAssertEqual(week.lead.kind, .allowanceChange)
        XCTAssertEqual(week.lead.sentence, "Claude recorded plan changed · go → plus.")
        XCTAssertEqual(week.lead.grounding, "One recorded change this week.")
    }

    /// The owner's ruling, and the reason for it: this account's Codex weekly window resets early
    /// every other day, so an early reset leading would make every recap say the same thing.
    /// Since D-129 it is said on its own weekly line, never as a free-standing sentence.
    func testAnEarlyResetNeverLeadsAndIsNoLongerAnObservation() {
        let tool = HXFix.tool(
            .codex,
            accountChanges: [HXFix.change(at: inRecapWeek(1), kind: .earlyReset,
                                          windowType: "weekly"),
                             HXFix.change(at: inRecapWeek(4), kind: .earlyReset,
                                          windowType: "weekly")],
            days: fortnight(Array(repeating: 700_000, count: 7), current: Array(repeating: 0, count: 7)))
        let week = latest([tool])
        XCTAssertNotEqual(week.lead.kind, .allowanceChange,
                          "a recurring early reset is a fact about the account, not the week")
        XCTAssertFalse(week.observations.contains { $0.sentence.contains("early") },
                       "the early-reset insight is retired (REV-104 §2.6)")
    }

    func testRungThreeAnUnusualWeekLeadsOnDirectionAgainstItsOwnPriorWeek() {
        // Aug 3–9 carries twice what Jul 27–Aug 2 did; nothing blocked and nothing changed.
        let days = HXFix.days(Array(repeating: 100_000, count: 7) + Array(repeating: 1_000_000, count: 7) + Array(repeating: 0, count: 7))
        let week = latest([HXFix.tool(.claude, days: days)])
        XCTAssertEqual(week.lead.kind, .usagePattern)
        XCTAssertEqual(week.lead.sentence, "Local token use rose 900% on Claude.")
        XCTAssertEqual(week.lead.grounding,
                       "\(Fmt.monthDay(HXFix.dayStart(index: 0, of: 21))) – "
                       + "\(Fmt.monthDay(HXFix.dayStart(index: 6, of: 21))) was unusually light "
                       + "for Claude — \(Fmt.tokens(700_000)).",
                       "a move of half or more names its base")
    }

    /// Two providers moving the same way share one verb; opposite moves each keep theirs. A move
    /// under half carries no grounding.
    func testThePatternLeadCarriesEachProvidersPercent() {
        let claude = HXFix.tool(.claude, days: HXFix.days(
            Array(repeating: 1_000_000, count: 7) + Array(repeating: 140_000, count: 7)
                + Array(repeating: 0, count: 7)))
        let codex = HXFix.tool(.codex, days: HXFix.days(
            Array(repeating: 1_000_000, count: 7) + Array(repeating: 570_000, count: 7)
                + Array(repeating: 0, count: 7)))
        let both = latest([claude, codex])
        XCTAssertEqual(both.lead.sentence, "Local token use fell 86% on Claude and 43% on Codex.")
        XCTAssertTrue(both.lead.grounding?.contains("unusually heavy for Claude — 7.0M") == true)
        XCTAssertFalse(both.lead.grounding?.contains("Codex") == true, "43% is under half")

        let rising = HXFix.tool(.codex, days: HXFix.days(
            Array(repeating: 1_000_000, count: 7) + Array(repeating: 1_120_000, count: 7)
                + Array(repeating: 0, count: 7)))
        XCTAssertEqual(latest([claude, rising]).lead.sentence,
                       "Local token use fell 86% on Claude and rose 12% on Codex.")
    }

    /// The owner's week: most of the drop is two outlier days, and the grounding says so.
    func testAHeavyPreviousWeekNamesItsTwoBiggestDays() {
        let prior = [443_000_000, 317_100_000, 30_000_000, 30_000_000, 30_000_000,
                     33_900_000, 33_000_000]
        let week = latest([HXFix.tool(.claude, days: HXFix.days(
            prior + Array(repeating: 19_000_000, count: 7) + Array(repeating: 0, count: 7)))])
        let first = Fmt.monthDay(HXFix.dayStart(index: 0, of: 21))
        let second = Fmt.monthDay(HXFix.dayStart(index: 1, of: 21))
        XCTAssertTrue(week.lead.grounding?.hasSuffix(
            "— 917.0M, 760.1M of it on \(first) and \(second).") == true,
                      week.lead.grounding ?? "nil")
    }

    func testRungFourTheCalmSummaryNamesTokensAndActiveDaysPerProvider() {
        let days = HXFix.days(Array(repeating: 500_000, count: 7) + Array(repeating: 500_000, count: 7) + Array(repeating: 0, count: 7))
        let week = latest([HXFix.tool(.claude, days: days)])
        XCTAssertEqual(week.lead.kind, .calm)
        XCTAssertEqual(week.lead.sentence,
                       "Claude \(Fmt.tokens(3_500_000)) over 7 active days.")
        XCTAssertEqual(week.lead.grounding,
                       "Nothing was blocked and no allowance change was recorded.")
    }

    func testAWeekWithNothingRecordedSaysSo() {
        let week = latest([HXFix.tool(.claude,
                                      watchingSince: HXFix.now.addingTimeInterval(-25 * 86_400),
                                      days: fortnight(Array(repeating: 0, count: 7), current: Array(repeating: 900_000, count: 7)))])
        XCTAssertEqual(week.lead.kind, .calm)
        XCTAssertTrue(week.lead.sentence.hasPrefix("Nothing was recorded this week."))
        XCTAssertTrue(week.lead.sentence.contains("watching since"))
    }

    // MARK: - Content budget (REV-104 §2.1 / §2.5)

    func testAtMostTwoObservationsAndNoFactIsSaidTwice() {
        let tool = HXFix.tool(
            .claude,
            accountChanges: [HXFix.change(at: inRecapWeek(), old: "go", new: "plus"),
                             HXFix.change(at: inRecapWeek(5), kind: .earlyReset,
                                          windowType: "weekly")],
            limitBlocks: [HXFix.block(at: inRecapWeek(3), lockout: 3600)],
            days: HXFix.valuedDays(Array(repeating: 100_000, count: 7)
                                    + [9_000_000] + Array(repeating: 100_000, count: 6)
                                    + Array(repeating: 0, count: 7),
                                   values: Array(repeating: 1, count: 7) + [90]
                                    + Array(repeating: 1, count: 6) + Array(repeating: 0, count: 7),
                                   projects: [7: [.init(project: "/u/kvotar", tokens: 9_000_000)]]),
            weeklyLimits: [HXFix.weeklyLimit(endedAt: inRecapWeek(4), used: 92)])
        let week = latest([tool])
        XCTAssertLessThanOrEqual(week.observations.count, HistoryExperience.RecapWeek.maxObservations)
        XCTAssertEqual(week.lead.kind, .blockConsequence)
        XCTAssertFalse(week.observations.contains { $0.sentence.contains("ran out of its window") },
                       "the lead's own fact never repeats as an observation")
        XCTAssertEqual(week.observations.first?.sentence,
                       "Claude recorded plan changed · go → plus. One recorded change this week.",
                       "an allowance change under a block lead keeps the first slot")
        XCTAssertEqual(week.observations.last?.sentence, "Claude came close — 92% of its weekly limit used.")
    }

    func testACalmWeekCarriesNoAction() {
        let week = latest([HXFix.tool(.claude,
                                      days: HXFix.days(Array(repeating: 500_000, count: 7) + Array(repeating: 500_000, count: 7) + Array(repeating: 0, count: 7)))])
        XCTAssertNil(week.action, "the action is omitted when no block supports it")
    }

    /// A window that merely ended high is deliberately not a trigger (owner ruling): a block is.
    func testAHighEndingWindowAloneStillCarriesNoAction() {
        let week = latest([HXFix.tool(
            .claude, days: fortnight(Array(repeating: 500_000, count: 7), current: Array(repeating: 0, count: 7)),
            weeklyLimits: [HXFix.weeklyLimit(endedAt: inRecapWeek(4), used: 97)])])
        XCTAssertNil(week.action)
    }

    func testABlockedWeekCarriesExactlyOneAction() {
        let week = latest([HXFix.tool(
            .claude, limitBlocks: [HXFix.block(at: inRecapWeek(3), lockout: 3600),
                                   HXFix.block(at: inRecapWeek(5), lockout: 1800)],
            days: fortnight(Array(repeating: 500_000, count: 7), current: Array(repeating: 0, count: 7)))])
        let action = try? XCTUnwrap(week.action)
        XCTAssertEqual(action?.title, "Next week")
        XCTAssertEqual(action?.sentence.hasPrefix("Claude ran out 2 times this week."), true)
        XCTAssertEqual(action?.evidence, "Known lockout \(Fmt.span(seconds: 5400)).")
    }

    // MARK: - Coverage (§6.2 evidence quality)

    /// A clipped week cannot make a whole-week claim: direction and the calm totals are both
    /// withheld, because a fraction of a week compared against a whole one manufactures a trend.
    func testAClippedWeekWithholdsWholeWeekConclusions() {
        let oldest = recap([HXFix.tool(.claude, days: HXFix.days(Array(repeating: 400_000, count: 31)))]).weeks.last
        XCTAssertEqual(oldest?.coverageNote, HistoryDisplay.recapClippedCoverage)
        XCTAssertNotEqual(oldest?.lead.kind, .usagePattern)
        XCTAssertNil(oldest?.table, "a clipped week never prints a week total")
        XCTAssertTrue(oldest?.observations.isEmpty == true, "nor a share of a partial week")
    }

    /// The comparison guard runs both ways: a whole week is never compared against a clipped one.
    func testAWeekAfterAClippedWeekCarriesNoComparison() throws {
        let section = recap([HXFix.tool(.claude, days: HXFix.valuedDays(
            Array(repeating: 400_000, count: 31), values: Array(repeating: 2, count: 31)))])
        // Newest first: Aug 3–9, Jul 27–Aug 2, Jul 20–26, then the clipped Jul 13–19.
        XCTAssertEqual(section.weeks.count, 4)
        let afterClipped = try XCTUnwrap(section.weeks[2].table)
        XCTAssertTrue(afterClipped.rows.flatMap(\.cells).allSatisfy { $0.comparison == nil })
        let whole = try XCTUnwrap(section.weeks[1].table)
        XCTAssertEqual(whole.rows[0].cells[0].comparison, "±0% vs \(Fmt.tokens(2_800_000))")
    }

    func testAWatchingDateInsideTheWeekIsNamedBesideTheConclusion() {
        let watching = inRecapWeek(3)
        let week = latest([HXFix.tool(.claude, watchingSince: watching,
                                      days: fortnight(Array(repeating: 500_000, count: 7), current: Array(repeating: 0, count: 7)))])
        XCTAssertEqual(week.coverageNote, HistoryDisplay.recapWatchingCoverage(watching))
    }

    // MARK: - This week (REV-104 §2.3)

    /// The owner's Sep 21–27 shape, moved onto the fixture clock: two providers, a whole previous
    /// week, per-provider cells with their comparisons, and the combined value once, under the
    /// not-a-bill note.
    func testTheTableCarriesTokensValueAndActiveDaysPerProvider() throws {
        let claude = HXFix.tool(.claude, days: HXFix.valuedDays(
            Array(repeating: 131_000_000, count: 7) + [0] + Array(repeating: 22_150_000, count: 6)
                + Array(repeating: 0, count: 7),
            values: Array(repeating: 100, count: 7) + [0] + Array(repeating: 21.5, count: 6)
                + Array(repeating: 0, count: 7)))
        let codex = HXFix.tool(.codex, days: HXFix.valuedDays(
            Array(repeating: 24_700_000, count: 7) + Array(repeating: 14_100_000, count: 7)
                + Array(repeating: 0, count: 7),
            values: Array(repeating: 41, count: 7) + Array(repeating: 24.9, count: 7)
                + Array(repeating: 0, count: 7),
            fallbackOn: [9]))
        let table = try XCTUnwrap(latest([claude, codex]).table)
        XCTAssertEqual(table.title, "This week")
        XCTAssertEqual(table.columns, [.claude, .codex])
        XCTAssertEqual(table.rows.map(\.label), ["Tokens", "Est. token value", "Active days"])
        XCTAssertEqual(table.rows[0].cells.map(\.text), ["132.9M", "98.7M"])
        XCTAssertEqual(table.rows[0].cells[0].comparison, "↓86% vs 917.0M")
        XCTAssertEqual(table.rows[1].cells.map(\.text), ["$129", "≈$174"])
        XCTAssertEqual(table.rows[1].cells[0].comparison, "↓82%")
        XCTAssertEqual(table.rows[2].cells.map(\.text), ["6", "7"])
        XCTAssertNil(table.rows[2].cells[0].comparison, "active days carry no comparison")
        XCTAssertEqual(table.valueNote,
                       "Together about $303 · Priced at published API rates for each model. Not a bill.")
        XCTAssertEqual(table.fallbackNote, "Codex includes models priced at a fallback rate.")
        XCTAssertFalse(HXFix.allStrings(of: table).contains { $0.contains("231") },
                       "tokens are never summed across providers (REV-84 §3.1)")
    }

    func testOneProviderGetsOneColumnAndNoCombinedLine() throws {
        let table = try XCTUnwrap(latest([HXFix.tool(.claude, days: HXFix.valuedDays(
            Array(repeating: 500_000, count: 14) + Array(repeating: 0, count: 7),
            values: Array(repeating: 3, count: 14) + Array(repeating: 0, count: 7)))]).table)
        XCTAssertEqual(table.columns, [.claude])
        XCTAssertEqual(table.valueNote, HistoryDisplay.recapNotABill)
        XCTAssertNil(table.fallbackNote)
        XCTAssertEqual(table.rows[1].cells.map(\.text), ["$21"])
    }

    // MARK: - Weekly limits (REV-104 §2.4)

    func testWeeklyLimitLinesNameTheLimitTheDateAndTheUse() throws {
        let reset = inRecapWeek(3, hour: 15)
        let claude = HXFix.tool(
            .claude, days: fortnight(Array(repeating: 500_000, count: 7), current: Array(repeating: 0, count: 7)),
            weeklyLimits: [
                HXFix.weeklyLimit(.claude, .overall, endedAt: reset, used: 43, gap: 3_240),
                HXFix.weeklyLimit(.claude, .model(key: "Fable", name: "Fable"), endedAt: reset,
                                  used: 61, gap: 60),
            ])
        let codex = HXFix.tool(
            .codex, days: fortnight(Array(repeating: 500_000, count: 7), current: Array(repeating: 0, count: 7)),
            weeklyLimits: [HXFix.weeklyLimit(.codex, endedAt: inRecapWeek(4, hour: 15), used: 58,
                                             gap: 14.7 * 3_600)])
        let week = latest([claude, codex])
        let limits = try XCTUnwrap(week.weeklyLimits)
        XCTAssertEqual(limits.title, "Weekly limits that reset \(week.span)")
        XCTAssertEqual(limits.lines.map(\.label), [
            "Claude overall · \(Fmt.monthDay(reset))",
            "Claude Fable · \(Fmt.monthDay(reset))",
            "Codex · \(Fmt.monthDay(inRecapWeek(4)))",
        ])
        XCTAssertEqual(limits.lines.map(\.value), ["43% used", "61% used", "58% used*"])
        XCTAssertEqual(limits.footnotes,
                       ["* Last reading 15 h before the reset — final use may be a little higher."])
        XCTAssertFalse(HXFix.allStrings(of: week).contains { $0.contains("at least") },
                       "never `at least` (owner ruling)")
        XCTAssertEqual(week.observations.first?.sentence,
                       "Fable was the tightest weekly limit — 61%, against 43% overall.")
    }

    /// A weekly the provider took back early belongs to the week it **ended** in, dated then, and
    /// says so — the Codex weekly scheduled for Sep 17 and withdrawn on Sep 12 (STEP_228).
    func testAnEarlyEndedWeeklyIsDatedWhenItEnded() throws {
        let ended = inRecapWeek(2, hour: 10)
        let codex = HXFix.tool(
            .codex, days: fortnight(Array(repeating: 500_000, count: 7), current: Array(repeating: 0, count: 7)),
            weeklyLimits: [
                HXFix.weeklyLimit(.codex, endedAt: ended, used: 31, gap: 132, ending: .withdrawn,
                                  scheduled: inCurrentWeek(10)),
                HXFix.weeklyLimit(.codex, endedAt: inRecapWeek(5), used: 72, gap: 48,
                                  ending: .reachedReset),
            ])
        let limits = try XCTUnwrap(latest([codex]).weeklyLimits)
        XCTAssertEqual(limits.lines.map(\.label), [
            "Codex · \(Fmt.monthDay(ended)) (reset early)",
            "Codex · \(Fmt.monthDay(inRecapWeek(5)))",
        ])
        XCTAssertEqual(limits.lines.map(\.value), ["31% used", "72% used"])
        XCTAssertTrue(limits.footnotes.isEmpty)
    }

    func testAReachedLimitSaysSoInsteadOfANumber() throws {
        let limits = try XCTUnwrap(latest([HXFix.tool(
            .claude, days: fortnight(Array(repeating: 500_000, count: 7), current: Array(repeating: 0, count: 7)),
            weeklyLimits: [HXFix.weeklyLimit(endedAt: inRecapWeek(4), used: 100, gap: 50_000,
                                             hitLimit: true)])]).weeklyLimits)
        XCTAssertEqual(limits.lines.map(\.value), ["reached the limit"])
        XCTAssertTrue(limits.footnotes.isEmpty, "100 % is an ending, not a floor")
    }

    /// A week before weekly readings began has no block and no empty heading; a limit still open,
    /// or one that ended in another week, is not this week's.
    func testNoWeeklyBlockWithoutALimitThatEndedInTheWeek() {
        let days = fortnight(Array(repeating: 500_000, count: 7), current: Array(repeating: 0, count: 7))
        XCTAssertNil(latest([HXFix.tool(.claude, days: days)]).weeklyLimits)
        XCTAssertNil(latest([HXFix.tool(.claude, days: days, weeklyLimits: [
            HXFix.weeklyLimit(endedAt: inCurrentWeek(), used: 20),
            HXFix.weeklyLimit(endedAt: inCurrentWeek(13, hour: 20), used: 20),
        ])]).weeklyLimits)
    }

    // MARK: - Observations (REV-104 §2.5)

    func testADayCarryingTheWeekAndATopProjectAreObserved() {
        let week = latest([HXFix.tool(.claude, days: HXFix.valuedDays(
            Array(repeating: 1_000_000, count: 7) + [6_000_000] + Array(repeating: 1_000_000, count: 6)
                + Array(repeating: 0, count: 7),
            values: Array(repeating: 10, count: 7) + [64] + Array(repeating: 6, count: 6)
                + Array(repeating: 0, count: 7),
            projects: [7: [.init(project: "/u/src/kvotar", tokens: 6_000_000)]]))])
        let weekday = { () -> String in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = HXFix.recapCalendar.timeZone
            f.dateFormat = "EEEE"
            return f.string(from: HXFix.dayStart(index: 7, of: 21))
        }()
        XCTAssertEqual(week.observations.map(\.sentence), [
            "\(weekday) was 64% of Claude's value this week.",
            "kvotar was 50% of Claude's tokens.",
        ])
    }

    // MARK: - Evidence links (§6.2)

    func testEveryEvidenceLinkCarriesItsModeProviderWeekAndRemovableBanner() throws {
        let tool = HXFix.tool(
            .claude, limitBlocks: [HXFix.block(at: inRecapWeek(3), lockout: 3600)],
            days: fortnight(Array(repeating: 500_000, count: 7), current: Array(repeating: 0, count: 7)),
            weeklyLimits: [HXFix.weeklyLimit(endedAt: inRecapWeek(4), used: 88)])
        let week = latest([tool])
        let links = week.links
        XCTAssertFalse(links.isEmpty)
        for link in links {
            XCTAssertNotEqual(link.destination.mode, .weeklyRecap,
                              "a recap link points out at evidence, never back at itself")
            let scope = try XCTUnwrap(link.destination.week)
            XCTAssertEqual(scope.start, week.id)
            XCTAssertEqual(scope.end, week.end)
            let banner = try XCTUnwrap(link.destination.banner)
            XCTAssertTrue(banner.hasPrefix("From weekly recap · "))
            XCTAssertTrue(banner.hasSuffix(week.span))
        }
        XCTAssertEqual(week.table?.link.destination.mode, .exploreUsage)
        XCTAssertEqual(week.weeklyLimits?.link.destination.mode, .exploreQuota)
        XCTAssertEqual(links.first?.destination.provider, .claude)

        // An allowance change under a block lead links to where allowance history lives.
        let calmerWeek = latest([HXFix.tool(
            .claude,
            accountChanges: [HXFix.change(at: inRecapWeek(), old: "go", new: "plus")],
            limitBlocks: [HXFix.block(at: inRecapWeek(3), lockout: 3600)],
            days: fortnight(Array(repeating: 500_000, count: 7),
                            current: Array(repeating: 0, count: 7)))])
        XCTAssertEqual(calmerWeek.lead.kind, .blockConsequence)
        XCTAssertTrue(calmerWeek.links.contains { $0.destination.mode == .hardBlocks })
    }

    /// A cross-provider fact names no provider — in the sentence or in the destination.
    func testACrossProviderInsightIsNotScopedToOneProvider() throws {
        let blocked = { (tool: Tool) in
            HXFix.tool(tool, limitBlocks: [HXFix.block(at: self.inRecapWeek(3), lockout: 3600)],
                       days: self.fortnight(Array(repeating: 500_000, count: 7), current: Array(repeating: 0, count: 7)))
        }
        let week = latest([blocked(.claude), blocked(.codex)])
        XCTAssertEqual(week.lead.kind, .blockConsequence)
        XCTAssertEqual(week.lead.sentence,
                       "Work stopped 2 times — Claude 1 time, Codex 1 time.")
        let action = try XCTUnwrap(week.action)
        XCTAssertTrue(action.sentence.hasPrefix("Claude and Codex ran out 2 times this week."))
        XCTAssertNil(week.table?.link.destination.provider,
                     "a table of both accounts is scoped to neither")
        for insight in week.observations where insight.link != nil {
            if insight.sentence.contains("Claude") && insight.sentence.contains("Codex") {
                XCTAssertNil(insight.link?.destination.provider,
                             "a fact about both accounts is scoped to neither")
            }
        }
    }
}
