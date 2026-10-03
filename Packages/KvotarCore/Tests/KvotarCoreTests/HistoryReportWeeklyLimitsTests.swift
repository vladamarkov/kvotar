import XCTest
@testable import KvotarCore

/// Pins the weekly-limit fold behind the recap's `Weekly limits that reset` lines (STEP_227 —
/// REV-104 §2.4 / §4). The fixture is the owner's live week of Sep 21–27 2026 (REV-104 §3.2),
/// reduced to the readings that decide each outcome.
final class HistoryReportWeeklyLimitsTests: XCTestCase {

    private static let cest = TimeZone(identifier: "Europe/Belgrade")!

    /// `2026-09-25 15:00:00` in local (CEST) time.
    private func at(_ text: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Self.cest
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: text)!
    }

    private var now: Date { at("2026-09-30 12:00:00") }

    private func point(_ polled: String, _ pct: Double, resets: String,
                       width: Int? = nil) -> QuotaSeriesPoint {
        QuotaSeriesPoint(polledAt: at(polled), usedPct: pct, resetsAt: at(resets),
                         windowSeconds: width)
    }

    private func modelRow(_ polled: String, _ pct: Double, resets: String,
                          key: String = "Fable", slot: String = "primary",
                          width: Int? = 604_800) -> SQLiteStore.ModelLimitSeriesRow {
        SQLiteStore.ModelLimitSeriesRow(polledAt: at(polled), limitKey: key, limitName: key,
                                        windowSlot: slot, usedPct: pct, resetsAt: at(resets),
                                        windowSeconds: width)
    }

    private func weekly(_ polled: String, _ type: DiscontinuityObservation.EventType,
                        window: String = "weekly",
                        anchor: String? = nil) -> SQLiteStore.DiscontinuityRow {
        SQLiteStore.DiscontinuityRow(at: at(polled), eventType: type.rawValue, windowType: window,
                                     oldValue: anchor.map { String(Int(at($0).timeIntervalSince1970)) },
                                     newValue: nil, utilizationPct: nil)
    }

    /// Claude's weekly as stored: the endpoint names the reset `14:59:59` and `15:00:00` on
    /// alternate polls. Read ungrouped, the `:59` twin is a second limit at 38 % last seen 36.6 h
    /// out (REV-104 §3.2).
    private var claudeWeekly: [QuotaSeriesPoint] {
        [
            point("2026-09-18 15:42:17", 14, resets: "2026-09-25 14:59:59"),
            point("2026-09-20 11:00:00", 22, resets: "2026-09-25 15:00:00"),
            point("2026-09-24 02:24:36", 38, resets: "2026-09-25 14:59:59"),
            point("2026-09-25 14:08:14", 43, resets: "2026-09-25 15:00:00"),
        ]
    }

    private var fable: [SQLiteStore.ModelLimitSeriesRow] {
        [
            modelRow("2026-09-18 15:00:39", 3, resets: "2026-09-25 15:00:00"),
            modelRow("2026-09-23 10:00:00", 55, resets: "2026-09-25 14:59:59"),
            modelRow("2026-09-25 14:58:00", 61, resets: "2026-09-25 15:00:00"),
        ]
    }

    /// Codex's only window on this account is seven days wide — its main window.
    private var codexMain: [QuotaWindowOutcome] {
        QuotaWindowOutcomes.compute(tool: .codex, points: [
            point("2026-09-19 16:00:00", 2, resets: "2026-09-26 15:27:04", width: 604_800),
            point("2026-09-26 00:45:00", 58, resets: "2026-09-26 15:27:04", width: 604_800),
        ], now: now)
    }

    // MARK: - The owner's week

    func testClaudeWeeklyJitterTwinsAreOneInstance() {
        let out = HistoryReportReader.weeklyLimits(
            tool: .claude, secondary: claudeWeekly, mainWindows: [], modelRows: [],
            discontinuities: [], now: now)
        XCTAssertEqual(out.count, 1, "the :59 / :00 twins are one weekly, not a spurious 38 %")
        XCTAssertEqual(out[0].limit, .overall)
        XCTAssertEqual(out[0].outcome.highWaterPct, 43)
        XCTAssertEqual(out[0].outcome.lastReadingGap / 3600, 0.86, accuracy: 0.01)
        XCTAssertEqual(out[0].outcome.windowSeconds, 604_800)
        XCTAssertEqual(out[0].outcome.widthEvidence, .providerContract,
                       "Claude's seven_day states no width; the contract is seven days, not five hours")
        XCTAssertEqual(out[0].outcome.completion, .completedPartial)
    }

    func testFableIsItsOwnLineBesideTheOverall() {
        let out = HistoryReportReader.weeklyLimits(
            tool: .claude, secondary: claudeWeekly, mainWindows: [], modelRows: fable,
            discontinuities: [], now: now)
        XCTAssertEqual(out.map(\.limit), [.overall, .model(key: "Fable", name: "Fable")])
        XCTAssertEqual(out.map(\.outcome.highWaterPct), [43, 61], "never summed")
        XCTAssertEqual(out[1].outcome.lastReadingGap, 120, accuracy: 1)
        XCTAssertNotEqual(out[0].id, out[1].id, "same reset, two limits, two ids")
    }

    func testCodexSevenDayMainWindowIsTheOverallWeekly() {
        let main = codexMain
        let out = HistoryReportReader.weeklyLimits(
            tool: .codex, secondary: [], mainWindows: main, modelRows: [],
            discontinuities: [], now: now)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].limit, .overall)
        XCTAssertEqual(out[0].outcome, main[0], "reused as folded, never folded twice")
        XCTAssertEqual(out[0].outcome.highWaterPct, 58)
        XCTAssertEqual(out[0].outcome.lastReadingGap / 3600, 14.7, accuracy: 0.01)
    }

    // MARK: - What is and is not a weekly limit

    func testFiveHourWindowsAreNotWeeklyLimits() {
        let fiveHourMain = QuotaWindowOutcomes.compute(tool: .codex, points: [
            point("2026-09-22 10:00:00", 40, resets: "2026-09-22 12:00:00", width: 18_000),
        ], now: now)
        let spark = [modelRow("2026-09-22 10:00:00", 9, resets: "2026-09-22 12:00:00",
                              key: "codex_bengalfox", width: 18_000)]
        let out = HistoryReportReader.weeklyLimits(
            tool: .codex, secondary: [], mainWindows: fiveHourMain, modelRows: spark,
            discontinuities: [], now: now)
        XCTAssertEqual(out, [], "a five-hour-only tool has no weekly limit")
    }

    func testModelWindowsOfOneKeyAreSplitBySlot() {
        let rows = [
            modelRow("2026-09-22 10:00:00", 12, resets: "2026-09-26 10:00:00",
                     key: "codex_bengalfox", slot: "secondary"),
            modelRow("2026-09-22 10:00:00", 30, resets: "2026-09-26 10:00:00",
                     key: "other", slot: "secondary"),
        ]
        let out = HistoryReportReader.weeklyLimits(
            tool: .codex, secondary: [], mainWindows: [], modelRows: rows,
            discontinuities: [], now: now)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map(\.outcome.highWaterPct)), [12, 30])
    }

    // MARK: - Endings

    func testAWeeklySeenAtTheLimitRecordsIt() {
        let out = HistoryReportReader.weeklyLimits(
            tool: .claude,
            secondary: [
                point("2026-09-20 10:00:00", 90, resets: "2026-09-21 15:00:00"),
                point("2026-09-20 22:00:00", 100, resets: "2026-09-21 15:00:00"),
            ],
            mainWindows: [], modelRows: [], discontinuities: [], now: now)
        XCTAssertEqual(out[0].outcome.hitLimitAt, at("2026-09-20 22:00:00"))
        XCTAssertEqual(out[0].outcome.completion, .completedFull, "100 % is an ending, not a floor")
    }

    func testOnlyWeeklyBreaksEndTheSecondary() {
        let secondary = [
            point("2026-09-17 10:00:00", 20, resets: "2026-09-22 10:00:00", width: 604_800),
            point("2026-09-19 10:00:00", 44, resets: "2026-09-22 10:00:00", width: 604_800),
        ]
        let fiveHourBreak = HistoryReportReader.weeklyLimits(
            tool: .codex, secondary: secondary, mainWindows: [], modelRows: [],
            discontinuities: [weekly("2026-09-19 10:02:00", .earlyReset, window: "five_hour",
                                     anchor: "2026-09-22 10:00:00")],
            now: now)
        XCTAssertEqual(fiveHourBreak[0].outcome.ending, .reachedReset)

        let weeklyBreak = HistoryReportReader.weeklyLimits(
            tool: .codex, secondary: secondary, mainWindows: [], modelRows: [],
            discontinuities: [weekly("2026-09-19 10:02:00", .earlyReset,
                                     anchor: "2026-09-22 10:00:00")], now: now)
        XCTAssertEqual(weeklyBreak[0].outcome.ending, .earlyReset)
    }

    /// The owner's Codex weekly, Sep 10–19 (live `kvotar.db`, STEP_228). The provider withdrew the
    /// weekly scheduled for Sep 17 13:53 at 31 % on Sep 12 10:09; the next one started on first
    /// use at 15:25 and reset normally on Sep 19 — where the detector's poll, 35 s past the
    /// anchor, logged a withdrawal too. One early ending, dated when it happened; one normal reset.
    func testCodexWithdrawnWeeklyIsDatedWhenItEnded() {
        let series = [
            point("2026-09-10 13:55:33", 1, resets: "2026-09-17 13:53:57", width: 604_800),
            point("2026-09-12 10:07:45", 31, resets: "2026-09-17 13:53:57", width: 604_800),
            point("2026-09-12 15:27:57", 0, resets: "2026-09-19 15:25:46", width: 604_800),
            point("2026-09-19 15:24:58", 72, resets: "2026-09-19 15:25:46", width: 604_800),
            point("2026-09-19 15:28:26", 0, resets: "2026-09-26 15:27:04", width: 604_800),
        ]
        let breaks = [
            weekly("2026-09-12 10:09:57", .windowDemolished, anchor: "2026-09-17 13:53:57"),
            weekly("2026-09-19 15:26:21", .windowDemolished, anchor: "2026-09-19 15:25:46"),
        ]
        let main = QuotaWindowOutcomes.compute(tool: .codex, points: series,
                                               discontinuities: breaks,
                                               now: at("2026-09-21 00:00:00"))
        let out = HistoryReportReader.weeklyLimits(
            tool: .codex, secondary: [], mainWindows: main, modelRows: [],
            discontinuities: breaks, now: at("2026-09-21 00:00:00"))
        XCTAssertEqual(out.map(\.outcome.ending), [.withdrawn, .reachedReset, .reachedReset])
        XCTAssertEqual(out[0].outcome.endedAt, at("2026-09-12 10:09:57"))
        XCTAssertEqual(out[0].outcome.highWaterPct, 31)
        XCTAssertEqual(out[0].outcome.lastReadingGap, 132)
        XCTAssertEqual(out[1].outcome.endedAt, at("2026-09-19 15:25:46"))
        XCTAssertEqual(out[1].outcome.highWaterPct, 72)
        XCTAssertEqual(out[2].outcome.completion, .current)
    }

    func testTheOpenWeeklyIsCurrent() {
        let out = HistoryReportReader.weeklyLimits(
            tool: .claude,
            secondary: [point("2026-09-29 10:00:00", 21, resets: "2026-10-02 15:00:00")],
            mainWindows: [], modelRows: [], discontinuities: [], now: now)
        XCTAssertEqual(out[0].outcome.completion, .current)
    }

    func testOldestResetFirst() {
        let out = HistoryReportReader.weeklyLimits(
            tool: .claude,
            secondary: claudeWeekly
                + [point("2026-09-29 10:00:00", 21, resets: "2026-10-02 15:00:00")],
            mainWindows: [], modelRows: fable, discontinuities: [], now: now)
        XCTAssertEqual(out.map(\.outcome.resetsAt),
                       out.map(\.outcome.resetsAt).sorted())
        XCTAssertEqual(out.count, 3)
    }
}
