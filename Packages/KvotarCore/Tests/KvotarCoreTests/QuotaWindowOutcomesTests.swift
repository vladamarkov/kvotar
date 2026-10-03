import XCTest
@testable import KvotarCore

/// Pins the quota-window fold behind Explore quota (REV-93 §4 / D-115 — STEP_181).
///
/// Every case here is a claim the classifier must refuse to make: it must not merge two windows,
/// must not lend one window's width to another, must not call a half-watched window finished, and
/// must not invent a window for a stretch nobody polled.
final class QuotaWindowOutcomesTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private var resetsAt: Date { base.addingTimeInterval(18_000) }

    private func point(_ offset: TimeInterval, _ pct: Double, resetsAt: Date,
                       width: Int? = 18_000) -> QuotaSeriesPoint {
        QuotaSeriesPoint(polledAt: base.addingTimeInterval(offset), usedPct: pct,
                         resetsAt: resetsAt, windowSeconds: width)
    }

    private func discontinuity(_ offset: TimeInterval,
                               _ type: DiscontinuityObservation.EventType,
                               oldValue: String? = nil, newValue: String? = nil)
    -> SQLiteStore.DiscontinuityRow {
        SQLiteStore.DiscontinuityRow(at: base.addingTimeInterval(offset), eventType: type.rawValue,
                                     windowType: "five_hour", oldValue: oldValue,
                                     newValue: newValue,
                                     utilizationPct: nil)
    }

    // MARK: - Anchor grouping

    /// The endpoint wobbles `resets_at` by a second or two and the twins interleave in time, so a
    /// naive fold reports one window twice, each copy under-observed.
    func testAnchorWobbleGroupsAsOneWindow() {
        let points = [
            point(0, 10, resetsAt: resetsAt),
            point(120, 22, resetsAt: resetsAt.addingTimeInterval(1)),
            point(240, 35, resetsAt: resetsAt.addingTimeInterval(-60)),
            point(17_900, 48, resetsAt: resetsAt),
        ]
        let out = QuotaWindowOutcomes.compute(tool: .claude, points: points,
                                              now: resetsAt.addingTimeInterval(600))
        XCTAssertEqual(out.count, 1, "±1 s and ±60 s wobble is one window, not four")
        XCTAssertEqual(out[0].observationCount, 4)
        XCTAssertEqual(out[0].highWaterPct, 48)
    }

    /// The other half of the same rule: proximity must not become a merge of genuinely
    /// consecutive windows, which would erase a whole window's outcome from the chart.
    func testTwoDistinctAdjacentResetsDoNotMerge() {
        let next = resetsAt.addingTimeInterval(18_000)
        let points = [
            point(0, 10, resetsAt: resetsAt),
            point(17_950, 60, resetsAt: resetsAt),
            point(18_100, 4, resetsAt: next),
            point(35_950, 71, resetsAt: next),
        ]
        let out = QuotaWindowOutcomes.compute(tool: .claude, points: points,
                                              now: next.addingTimeInterval(600))
        XCTAssertEqual(out.map(\.highWaterPct), [60, 71], "two windows, oldest first")
        XCTAssertEqual(out.map(\.resetsAt), [resetsAt, next])
    }

    /// A drift of small steps must not accumulate into a group of unbounded width, or it would
    /// eventually swallow the next real window. A group spans at most the ±60 s one
    /// `quotaSeries(resetsAtNear:)` call selects.
    func testGroupingDoesNotChainBeyondTheSelectableSpan() {
        let points = (0...4).map { i in
            point(Double(i) * 120, Double(i) * 10,
                  resetsAt: resetsAt.addingTimeInterval(Double(i) * 40))
        }
        let out = QuotaWindowOutcomes.compute(tool: .claude, points: points,
                                              now: resetsAt.addingTimeInterval(20_000))
        XCTAssertEqual(out.count, 2, "0…120 s is one selectable span; 160 s opens a second group")
        XCTAssertEqual(out.map(\.observationCount), [4, 1])
        XCTAssertEqual(out[0].resetsAt, resetsAt.addingTimeInterval(120),
                       "the group is anchored on the provider's latest word")
    }

    // MARK: - Width

    func testStoredWidthsStayDistinctAcrossWindows() {
        let weekly = resetsAt.addingTimeInterval(604_800)
        let monthly = weekly.addingTimeInterval(2_592_000)
        let points = [
            point(0, 10, resetsAt: resetsAt, width: 18_000),
            point(100, 20, resetsAt: weekly, width: 604_800),
            point(200, 30, resetsAt: monthly, width: 2_592_000),
        ]
        let out = QuotaWindowOutcomes.compute(tool: .codex, points: points,
                                              now: monthly.addingTimeInterval(60))
        XCTAssertEqual(out.map(\.windowSeconds), [18_000, 604_800, 2_592_000])
        XCTAssertEqual(out[0].start, resetsAt.addingTimeInterval(-18_000))
        XCTAssertEqual(out[2].start, monthly.addingTimeInterval(-2_592_000))
    }

    /// A Codex row written before `v23` remains unknown when no recorded width-change fact can
    /// identify its era. A later row may not lend it today's width.
    func testUnprovenLegacyCodexWidthNeverInheritsANeighboursWidth() {
        let next = resetsAt.addingTimeInterval(18_000)
        let points = [
            point(0, 10, resetsAt: resetsAt, width: nil),
            point(240, 30, resetsAt: resetsAt, width: nil),
            point(18_100, 5, resetsAt: next, width: 18_000),
        ]
        let out = QuotaWindowOutcomes.compute(tool: .codex, points: points,
                                              now: next.addingTimeInterval(600))
        XCTAssertNil(out[0].windowSeconds, "a pre-v23 window stays unknown-width")
        XCTAssertNil(out[0].start, "and therefore has no derivable start")
        XCTAssertEqual(out[0].widthEvidence, .unknown)
        XCTAssertEqual(out[1].windowSeconds, 18_000)
        XCTAssertEqual(out[1].widthEvidence, .recorded)
    }

    /// A window that spans the migration takes the width from its newest row that has one — that
    /// is this window's own evidence, not a neighbour's.
    func testWidthComesFromTheNewestRowThatCarriesOne() {
        let points = [
            point(0, 10, resetsAt: resetsAt, width: nil),
            point(240, 30, resetsAt: resetsAt, width: 18_000),
        ]
        let out = QuotaWindowOutcomes.compute(tool: .claude, points: points,
                                              now: resetsAt.addingTimeInterval(600))
        XCTAssertEqual(out[0].windowSeconds, 18_000)
        XCTAssertEqual(out[0].widthEvidence, .recorded)
    }

    /// Claude's primary field is structurally the five-hour field. Its adapter supplies 18 000
    /// seconds on every current snapshot, so legacy rows can recover that width without plan or
    /// neighbouring-window inference.
    func testClaudeLegacyWidthComesFromProviderContract() {
        let out = QuotaWindowOutcomes.compute(
            tool: .claude,
            points: [point(0, 10, resetsAt: resetsAt, width: nil),
                     point(17_900, 55, resetsAt: resetsAt, width: nil)],
            now: resetsAt.addingTimeInterval(600))
        XCTAssertEqual(out[0].windowSeconds, 18_000)
        XCTAssertEqual(out[0].start, resetsAt.addingTimeInterval(-18_000))
        XCTAssertEqual(out[0].widthEvidence, .providerContract)
    }

    /// One recorded Codex width switch proves both adjacent eras: oldValue describes the polls
    /// before the switch and newValue the polls after it. The database rows stay untouched.
    func testCodexLegacyWidthsComeFromRecordedChangeBoundary() {
        let switchAt: TimeInterval = 20_000
        let weeklyReset = base.addingTimeInterval(10_000)
        let shortReset = base.addingTimeInterval(38_000)
        let points = [
            point(0, 25, resetsAt: weeklyReset, width: nil),
            point(9_900, 74, resetsAt: weeklyReset, width: nil),
            point(20_100, 8, resetsAt: shortReset, width: nil),
            point(37_900, 62, resetsAt: shortReset, width: nil),
        ]
        let change = discontinuity(switchAt, .windowWidthChanged,
                                   oldValue: "604800", newValue: "18000")
        let out = QuotaWindowOutcomes.compute(tool: .codex, points: points,
                                              discontinuities: [change],
                                              now: shortReset.addingTimeInterval(600))
        XCTAssertEqual(out.map(\.windowSeconds), [604_800, 18_000])
        XCTAssertEqual(out.map(\.widthEvidence), [.recordedChange, .recordedChange])
    }

    func testMalformedWidthChangeDoesNotInventCodexWidth() {
        let change = discontinuity(20_000, .windowWidthChanged,
                                   oldValue: "weekly", newValue: "five-hour")
        let out = QuotaWindowOutcomes.compute(
            tool: .codex,
            points: [point(0, 25, resetsAt: resetsAt, width: nil)],
            discontinuities: [change], now: resetsAt.addingTimeInterval(600))
        XCTAssertNil(out[0].windowSeconds)
        XCTAssertEqual(out[0].widthEvidence, .unknown)
    }

    func testRecordedWidthWinsOverAConflictingChangeBoundary() {
        let change = discontinuity(20_000, .windowWidthChanged,
                                   oldValue: "604800", newValue: "18000")
        let out = QuotaWindowOutcomes.compute(
            tool: .codex,
            points: [point(0, 25, resetsAt: resetsAt, width: 2_592_000)],
            discontinuities: [change], now: resetsAt.addingTimeInterval(600))
        XCTAssertEqual(out[0].windowSeconds, 2_592_000)
        XCTAssertEqual(out[0].widthEvidence, .recorded)
    }

    // MARK: - Completion

    func testCompletedFullWhenObservedInsideTheTolerance() {
        let points = [point(0, 10, resetsAt: resetsAt),
                      point(17_880, 62, resetsAt: resetsAt)]  // 120 s before the reset
        let out = QuotaWindowOutcomes.compute(tool: .claude, points: points,
                                              now: resetsAt.addingTimeInterval(600))
        XCTAssertEqual(out[0].completion, .completedFull)
        XCTAssertEqual(out[0].highWaterPct, 62, "an ending value, not a floor")
    }

    func testCompletedPartialWhenObservationStoppedEarly() {
        let points = [point(0, 10, resetsAt: resetsAt),
                      point(9_000, 44, resetsAt: resetsAt)]   // 2.5 h before the reset
        let out = QuotaWindowOutcomes.compute(tool: .claude, points: points,
                                              now: resetsAt.addingTimeInterval(600))
        XCTAssertEqual(out[0].completion, .completedPartial,
                       "unwatched at its close — 44% is a lower bound")
    }

    /// Utilization is monotone inside a window (§9.3), so a reading at the ceiling cannot be a
    /// floor under anything higher. This is the one sparse window that still has an outcome.
    func testHundredPercentIsCompleteHoweverEarlyWatchingStopped() {
        let points = [point(0, 40, resetsAt: resetsAt),
                      point(3_600, 100, resetsAt: resetsAt)]  // four hours before the reset
        let out = QuotaWindowOutcomes.compute(tool: .claude, points: points,
                                              now: resetsAt.addingTimeInterval(600))
        XCTAssertEqual(out[0].completion, .completedFull)
        XCTAssertEqual(out[0].hitLimitAt, base.addingTimeInterval(3_600))
    }

    func testOpenWindowIsCurrentAndKeepsItsRunningReading() {
        let points = [point(0, 10, resetsAt: resetsAt),
                      point(240, 26, resetsAt: resetsAt)]
        let out = QuotaWindowOutcomes.compute(tool: .claude, points: points,
                                              now: resetsAt.addingTimeInterval(-3_600))
        XCTAssertEqual(out[0].completion, .current)
        XCTAssertEqual(out[0].highWaterPct, 26)
        XCTAssertNil(out[0].hitLimitAt)
    }

    /// The tolerance is two base poll ticks, and it is the freshness constant rather than a
    /// number chosen for this chart (STEP_181).
    func testToleranceIsTwoBasePollTicks() {
        XCTAssertEqual(QuotaWindowOutcomes.fullObservationTolerance, 240)
        XCTAssertEqual(QuotaWindowOutcomes.fullObservationTolerance,
                       PollBackoffPolicy.freshnessAmberAge)
    }

    // MARK: - Endings

    private func unix(_ date: Date) -> String { String(Int(date.timeIntervalSince1970)) }

    /// An early reset is recorded on the poll that first sees the replacement anchor — a row that
    /// belongs to the *new* window. It must end the old one, and leave the new one alone
    /// (STEP_228; the time-span test gave it to the replacement).
    func testEarlyResetRecordedOnTheNextPollEndsTheOldWindow() {
        let next = base.addingTimeInterval(9_300 + 18_000)
        let points = [point(0, 10, resetsAt: resetsAt),
                      point(9_200, 44, resetsAt: resetsAt),
                      point(9_300, 0, resetsAt: next)]
        let out = QuotaWindowOutcomes.compute(
            tool: .codex, points: points,
            discontinuities: [discontinuity(9_300, .earlyReset, oldValue: unix(resetsAt),
                                            newValue: unix(base.addingTimeInterval(9_300)))],
            now: next.addingTimeInterval(600))
        XCTAssertEqual(out.map(\.ending), [.earlyReset, .reachedReset])
        XCTAssertEqual(out[0].endedAt, base.addingTimeInterval(9_300))
        XCTAssertEqual(out[0].completion, .completedFull, "seen 100 s before it ended")
        XCTAssertEqual(out[0].lastReadingGap, 100)
        XCTAssertEqual(out[1].endedAt, next)
    }

    /// A withdrawal writes no series row: the break lands after the window's last reading and
    /// names the withdrawn anchor. The live shape — Codex's weekly scheduled for Sep 17, taken
    /// back on Sep 12 at 31 %, 132 s after the last reading.
    func testWithdrawnWindowKeepsItsEvidenceAndIsNotMergedForward() {
        let weekly = base.addingTimeInterval(604_800)
        let next = base.addingTimeInterval(20_000 + 604_800)
        let points = [point(0, 3, resetsAt: weekly, width: 604_800),
                      point(10_000, 31, resetsAt: weekly, width: 604_800),
                      point(20_000, 0, resetsAt: next, width: 604_800)]
        let out = QuotaWindowOutcomes.compute(
            tool: .codex, points: points,
            discontinuities: [discontinuity(10_132, .windowDemolished, oldValue: unix(weekly))],
            now: next.addingTimeInterval(-60))
        XCTAssertEqual(out.count, 2, "the replacement is its own window, never a continuation")
        XCTAssertEqual(out[0].ending, .withdrawn)
        XCTAssertEqual(out[0].highWaterPct, 31, "a withdrawn window keeps what was observed")
        XCTAssertEqual(out[0].endedAt, base.addingTimeInterval(10_132))
        XCTAssertEqual(out[0].completion, .completedFull,
                       "it ended days before its schedule, and was seen to that end")
        XCTAssertEqual(out[0].lastReadingGap, 132)
        XCTAssertEqual(out[1].ending, .reachedReset)
    }

    /// The detector logs a natural reset as a withdrawal when its poll lands inside the jitter
    /// allowance after the anchor (Codex, Sep 19 15:26:21 — 35 s past 15:25:46). Not early.
    func testDemolitionJustAfterTheScheduledResetIsANormalReset() {
        let points = [point(0, 10, resetsAt: resetsAt),
                      point(17_990, 72, resetsAt: resetsAt)]
        let out = QuotaWindowOutcomes.compute(
            tool: .codex, points: points,
            discontinuities: [discontinuity(18_035, .windowDemolished, oldValue: unix(resetsAt))],
            now: resetsAt.addingTimeInterval(600))
        XCTAssertEqual(out[0].ending, .reachedReset)
        XCTAssertEqual(out[0].endedAt, resetsAt)
    }

    /// `window_removed` carries a width, not an anchor: it goes to the window read last before it.
    func testRemovalGoesToTheWindowReadLastBeforeIt() {
        let points = [point(0, 10, resetsAt: resetsAt),
                      point(9_000, 81, resetsAt: resetsAt)]
        let out = QuotaWindowOutcomes.compute(
            tool: .codex, points: points,
            discontinuities: [discontinuity(9_120, .windowRemoved, oldValue: "18000")],
            now: resetsAt.addingTimeInterval(600))
        XCTAssertEqual(out[0].ending, .withdrawn)
        XCTAssertEqual(out[0].endedAt, base.addingTimeInterval(9_120))
    }

    /// The provider dropped a window and restored it under the same anchor; readings went on
    /// after the drop, so the drop did not end it (Codex, Sep 9 18:57, back two minutes later).
    func testADropFollowedByMoreReadingsOfTheSameAnchorEndsNothing() {
        let points = [point(0, 21, resetsAt: resetsAt),
                      point(9_000, 21, resetsAt: resetsAt),
                      point(9_300, 40, resetsAt: resetsAt),
                      point(17_950, 73, resetsAt: resetsAt)]
        let out = QuotaWindowOutcomes.compute(
            tool: .codex, points: points,
            discontinuities: [discontinuity(9_130, .windowDemolished, oldValue: unix(resetsAt))],
            now: resetsAt.addingTimeInterval(600))
        XCTAssertEqual(out[0].ending, .reachedReset)
        XCTAssertEqual(out[0].endedAt, resetsAt)
    }

    /// A break naming some other anchor ends nothing here.
    func testBreakNamingAnotherAnchorIsIgnored() {
        let points = [point(0, 10, resetsAt: resetsAt),
                      point(17_900, 55, resetsAt: resetsAt)]
        let out = QuotaWindowOutcomes.compute(
            tool: .codex, points: points,
            discontinuities: [discontinuity(9_000, .windowDemolished,
                                            oldValue: unix(resetsAt.addingTimeInterval(86_400)))],
            now: resetsAt.addingTimeInterval(600))
        XCTAssertEqual(out[0].ending, .reachedReset)
    }

    func testUnrelatedDiscontinuityDoesNotChangeAnEnding() {
        let points = [point(0, 10, resetsAt: resetsAt),
                      point(17_880, 62, resetsAt: resetsAt)]
        let out = QuotaWindowOutcomes.compute(
            tool: .claude, points: points,
            discontinuities: [discontinuity(120, .planChanged),
                              discontinuity(240, .windowWidthChanged)],
            now: resetsAt.addingTimeInterval(600))
        XCTAssertEqual(out[0].ending, .reachedReset,
                       "only early reset, demolition and removal end a window early")
    }

    // MARK: - Gaps

    /// The chart's honesty rule, at the data layer: a stretch nobody polled produces no entry, so
    /// the gap is the absence. Nothing here fabricates a quiet 0% window (REV-93 §7).
    func testUnobservedStretchProducesNoWindowAndNoZero() {
        let later = resetsAt.addingTimeInterval(5 * 18_000)
        let points = [point(0, 10, resetsAt: resetsAt),
                      point(17_900, 55, resetsAt: resetsAt),
                      point(5 * 18_000, 12, resetsAt: later)]
        let out = QuotaWindowOutcomes.compute(tool: .claude, points: points,
                                              now: later.addingTimeInterval(600))
        XCTAssertEqual(out.count, 2, "the four unpolled windows between them are simply absent")
        XCTAssertFalse(out.contains { $0.highWaterPct == 0 })
    }

    func testEmptySeriesProducesNoWindows() {
        XCTAssertTrue(QuotaWindowOutcomes.compute(tool: .claude, points: [], now: base).isEmpty)
    }

    func testIdentityIsProviderScoped() {
        let claude = QuotaWindowOutcomes.compute(
            tool: .claude, points: [point(0, 10, resetsAt: resetsAt)],
            now: resetsAt.addingTimeInterval(600))
        let codex = QuotaWindowOutcomes.compute(
            tool: .codex, points: [point(0, 10, resetsAt: resetsAt)],
            now: resetsAt.addingTimeInterval(600))
        XCTAssertNotEqual(claude[0].id, codex[0].id,
                          "two providers observing the same instant are two windows")
    }

    // MARK: - Provider-contract width (STEP_227)

    /// Claude's `seven_day` states no width, so its weekly rows store none; the weekly fold passes
    /// the seven-day contract. The default stays the five-hour one, so the primary fold is unmoved.
    func testProviderContractWidthIsTheCallersField() {
        let points = [point(0, 10, resetsAt: resetsAt, width: nil)]
        let weekly = QuotaWindowOutcomes.compute(
            tool: .claude, points: points, now: resetsAt.addingTimeInterval(600),
            providerContractSeconds: QuotaWindowOutcomes.weeklyContractSeconds)
        XCTAssertEqual(weekly[0].windowSeconds, 604_800)
        XCTAssertEqual(weekly[0].widthEvidence, .providerContract)

        let primary = QuotaWindowOutcomes.compute(tool: .claude, points: points,
                                                  now: resetsAt.addingTimeInterval(600))
        XCTAssertEqual(primary[0].windowSeconds, 18_000)
    }

    func testLastReadingGapIsResetMinusLastObservation() {
        let out = QuotaWindowOutcomes.compute(
            tool: .claude, points: [point(0, 10, resetsAt: resetsAt),
                                    point(14_400, 30, resetsAt: resetsAt)],
            now: resetsAt.addingTimeInterval(600))
        XCTAssertEqual(out[0].lastReadingGap, 3_600)
    }
}
