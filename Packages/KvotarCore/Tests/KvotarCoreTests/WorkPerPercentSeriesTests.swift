import XCTest
@testable import KvotarCore

/// REV-69 / STEP_114 — the "Work per 1 % of window" series over `history_rollups` joined with
/// priced hourly local work. Pure computation; the Baseline §19 `rate-step-*` fixtures assert
/// **numbers only** — no notice exists.
final class WorkPerPercentSeriesTests: XCTestCase {

    /// 2026-08-16 00:00 UTC.
    private let base = 1_786_838_400
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let day = 86_400
    private let hourSecs = 3600

    private func rollup(hour: Int, pMax: Double? = nil, pLast: Double? = nil, pAnchor: Int? = nil,
                        sMax: Double? = nil, sLast: Double? = nil, sAnchor: Int? = nil,
                        tool: Tool = .claude) -> HistoryRollup {
        HistoryRollup(
            tool: tool.rawValue, hourStart: base + hour * hourSecs, snapshotCount: 1,
            primaryUsedPctMin: pLast, primaryUsedPctMax: pMax ?? pLast, primaryUsedPctLast: pLast,
            secondaryUsedPctMin: sLast, secondaryUsedPctMax: sMax ?? sLast,
            secondaryUsedPctLast: sLast,
            primaryResetsAtLast: pAnchor.map { base + $0 }, secondaryResetsAtLast: sAnchor.map { base + $0 },
            primaryWindowLimitLast: nil, secondaryWindowLimitLast: nil, rateLimitReachedMax: nil,
            extraUsageIsEnabledLast: nil, spendControlReachedLast: nil,
            rateLimitResetCreditsCountLast: nil, monthlyLimitLast: nil, monthlyUsedLast: nil,
            monthlyResetsAtLast: nil, monthlyCurrencyLast: nil, monthlyExponentLast: nil,
            planType: nil, lastPolledAt: base + hour * hourSecs + 3000)
    }

    private func work(hour: Int, model: String = "claude-opus-5", dollars: Double,
                      tokens: Int = 1000) -> WorkPerPercentSeries.HourlyWork {
        .init(hourStart: Date(timeIntervalSince1970: TimeInterval(base + hour * hourSecs)),
              model: model, dollars: dollars, tokens: tokens)
    }

    private func compute(_ rollups: [HistoryRollup], _ hourly: [WorkPerPercentSeries.HourlyWork],
                         tool: Tool = .claude, markers: [WorkPerPercentSeries.Marker] = [],
                         untilHour: Int = 24 * 30) -> WorkPerPercentSeries {
        WorkPerPercentSeries.compute(
            tool: tool, rollups: rollups, hourly: hourly, markers: markers,
            until: Date(timeIntervalSince1970: TimeInterval(base + untilHour * hourSecs)),
            calendar: utc)
    }

    private func slot(_ s: WorkPerPercentSeries, primary: Bool) -> WorkPerPercentSeries.Slot? {
        s.slots.first { $0.isPrimary == primary }
    }

    // MARK: single cycle

    func testSingleCycleRiseAndDollarsPerPercent() {
        // 5-hour window: 10 → 20 → 35 across three consecutive hours; the first row only seeds.
        let rows = [rollup(hour: 0, pLast: 10, pAnchor: 5 * hourSecs),
                    rollup(hour: 1, pLast: 20, pAnchor: 5 * hourSecs),
                    rollup(hour: 2, pLast: 35, pAnchor: 5 * hourSecs)]
        let s = compute(rows, [work(hour: 1, dollars: 10, tokens: 500),
                               work(hour: 2, dollars: 15, tokens: 700)])
        let p = slot(s, primary: true)!
        XCTAssertEqual(p.windowSeconds, 18_000)
        XCTAssertTrue(p.byDay, "5-hour cycles roll up per local day")
        XCTAssertEqual(p.points.count, 1)
        let point = p.points[0]
        XCTAssertEqual(point.deltaPct, 25)
        XCTAssertEqual(point.dollars, 25)
        XCTAssertEqual(point.tokens, 1200)
        XCTAssertEqual(point.dollarsPerPct, 1.0)
        XCTAssertEqual(point.tokensPerPct, 48)
        XCTAssertEqual(point.coverage, 1.0, "every interval was one model")
        XCTAssertEqual(point.perModel.count, 1)
        XCTAssertEqual(point.perModel[0].dollarsPerPct, 1.0)
        XCTAssertEqual(point.unexplainedShare, 0)
        XCTAssertNil(slot(s, primary: false), "no secondary observations ⇒ no secondary slot")
    }

    func testResetInsideAnHourSplitsCyclesAndDropsTheBoundaryInterval() {
        // Weekly slot so points are per cycle: A carries 30 → 40; the reset lands inside hour 2
        // (max 45 from A, last 2 from B); B then climbs to 12. Neither cycle counts hour 2.
        let a = 7 * day, b = 14 * day
        let rows = [rollup(hour: 0, sLast: 30, sAnchor: a),
                    rollup(hour: 1, sLast: 40, sAnchor: a),
                    rollup(hour: 2, sMax: 45, sLast: 2, sAnchor: b),
                    rollup(hour: 3, sLast: 12, sAnchor: b)]
        let s = compute(rows, [work(hour: 1, dollars: 5), work(hour: 2, dollars: 9),
                               work(hour: 3, dollars: 4)], untilHour: 10 * 24)
        let w = slot(s, primary: false)!
        XCTAssertFalse(w.byDay)
        XCTAssertEqual(w.points.map(\.deltaPct), [10, 10])
        XCTAssertEqual(w.points.map(\.dollars), [5, 4])
        XCTAssertTrue(w.points[0].isComplete)
        XCTAssertFalse(w.points[1].isComplete, "anchor still ahead of `until`")
        XCTAssertEqual(w.points[0].end, Date(timeIntervalSince1970: TimeInterval(base + a)),
                       "a complete cycle ends at its anchor")
    }

    func testAnchorJitterWithinToleranceIsOneCycle() {
        let rows = [rollup(hour: 0, sLast: 10, sAnchor: 7 * day),
                    rollup(hour: 1, sLast: 12, sAnchor: 7 * day + 1),
                    rollup(hour: 2, sLast: 15, sAnchor: 7 * day)]
        let s = compute(rows, [work(hour: 1, dollars: 2), work(hour: 2, dollars: 3)])
        XCTAssertEqual(slot(s, primary: false)!.points.count, 1)
        XCTAssertEqual(slot(s, primary: false)!.points[0].deltaPct, 5)
    }

    // MARK: gaps

    func testGapBetweenRollupRowsCarriesEveryHoursWork() {
        // Rows at hour 0 and hour 4 (rollups missing for 1–3, e.g. the app was asleep) — the rise
        // is exact and the local corpus for hours 1…4 is complete, so all of it belongs here.
        let rows = [rollup(hour: 0, sLast: 10, sAnchor: 7 * day),
                    rollup(hour: 4, sLast: 30, sAnchor: 7 * day)]
        let s = compute(rows, [work(hour: 1, dollars: 3), work(hour: 2, dollars: 4),
                               work(hour: 3, dollars: 5), work(hour: 4, dollars: 8),
                               work(hour: 5, dollars: 100)])   // after the row — not counted
        let point = slot(s, primary: false)!.points[0]
        XCTAssertEqual(point.deltaPct, 20)
        XCTAssertEqual(point.dollars, 20)
        XCTAssertEqual(point.dollarsPerPct, 1.0)
    }

    func testNullSlotRowsAreSkippedNotCounted() {
        // Claude overnight: primary NULL for hours 1–2 while the weekly stays live; the primary
        // slot sees hours 0 and 3 as consecutive observations of the same cycle.
        let rows = [rollup(hour: 0, pLast: 10, pAnchor: 6 * hourSecs, sLast: 5, sAnchor: 7 * day),
                    rollup(hour: 1, sLast: 5, sAnchor: 7 * day),
                    rollup(hour: 2, sLast: 5, sAnchor: 7 * day),
                    rollup(hour: 3, pLast: 14, pAnchor: 6 * hourSecs, sLast: 6, sAnchor: 7 * day)]
        let s = compute(rows, [work(hour: 3, dollars: 4)])
        XCTAssertEqual(slot(s, primary: true)!.points[0].deltaPct, 4)
        XCTAssertEqual(slot(s, primary: true)!.points[0].dollars, 4)
    }

    // MARK: per model, coverage, unexplained

    func testDominantIntervalAttributionAndCoverage() {
        // Interval 1: opus 95 % of $ → its 10 pts. Interval 2: 50/50 → mixed, no attribution.
        let rows = [rollup(hour: 0, sLast: 0, sAnchor: 7 * day),
                    rollup(hour: 1, sLast: 10, sAnchor: 7 * day),
                    rollup(hour: 2, sLast: 20, sAnchor: 7 * day)]
        let s = compute(rows, [work(hour: 1, model: "claude-opus-5", dollars: 9.5),
                               work(hour: 1, model: "claude-fable-5", dollars: 0.5),
                               work(hour: 2, model: "claude-opus-5", dollars: 5),
                               work(hour: 2, model: "claude-fable-5", dollars: 5)])
        let point = slot(s, primary: false)!.points[0]
        XCTAssertEqual(point.deltaPct, 20)
        XCTAssertEqual(point.dollarsPerPct, 1.0)
        XCTAssertEqual(point.coverage, 0.5)
        XCTAssertEqual(point.perModel.map(\.model), ["claude-opus-5"])
        XCTAssertEqual(point.perModel[0].deltaPct, 10)
        XCTAssertEqual(point.perModel[0].dollars, 9.5)
    }

    func testUnexplainedShareCountsRiseWithNoLocalWorkInIntervalOrHourBefore() {
        // Interval (0,1]: $ present. (1,2]: no $ in hour 2, but $ in hour 1 (the hour before) —
        // write lag, explained. (2,3]: no $ in hours 3 or 2 — unexplained.
        let rows = [rollup(hour: 0, sLast: 0, sAnchor: 7 * day),
                    rollup(hour: 1, sLast: 5, sAnchor: 7 * day),
                    rollup(hour: 2, sLast: 10, sAnchor: 7 * day),
                    rollup(hour: 3, sLast: 15, sAnchor: 7 * day)]
        let s = compute(rows, [work(hour: 1, dollars: 5)])
        let point = slot(s, primary: false)!.points[0]
        XCTAssertEqual(point.deltaPct, 15)
        XCTAssertEqual(point.unexplainedShare!, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testCrossWindowRatioIsWeeklyOverFiveHour() {
        let rows = [rollup(hour: 0, pLast: 0, pAnchor: 5 * hourSecs, sLast: 10, sAnchor: 7 * day),
                    rollup(hour: 1, pLast: 20, pAnchor: 5 * hourSecs, sLast: 11, sAnchor: 7 * day),
                    rollup(hour: 2, pLast: 40, pAnchor: 5 * hourSecs, sLast: 12, sAnchor: 7 * day)]
        let s = compute(rows, [work(hour: 1, dollars: 1), work(hour: 2, dollars: 1)])
        XCTAssertEqual(slot(s, primary: true)!.points[0].crossWindowRatio!, 0.05, accuracy: 1e-9)
        XCTAssertEqual(slot(s, primary: false)!.points[0].crossWindowRatio!, 0.05, accuracy: 1e-9)
    }

    // MARK: day rollup and width

    func testFiveHourCyclesRollUpPerLocalDay() {
        // Two cycles on day 0 (hours 1–2, 6–7) and one on day 1 (hours 25–26): two points.
        let rows = [rollup(hour: 0, pLast: 0, pAnchor: 5 * hourSecs),
                    rollup(hour: 1, pLast: 10, pAnchor: 5 * hourSecs),
                    rollup(hour: 2, pLast: 20, pAnchor: 5 * hourSecs),
                    rollup(hour: 5, pLast: 0, pAnchor: 10 * hourSecs),
                    rollup(hour: 6, pLast: 5, pAnchor: 10 * hourSecs),
                    rollup(hour: 7, pLast: 15, pAnchor: 10 * hourSecs),
                    rollup(hour: 24, pLast: 0, pAnchor: 29 * hourSecs),
                    rollup(hour: 25, pLast: 30, pAnchor: 29 * hourSecs),
                    rollup(hour: 26, pLast: 40, pAnchor: 29 * hourSecs)]
        let s = compute(rows, (1...26).map { work(hour: $0, dollars: 1) }, untilHour: 48)
        let p = slot(s, primary: true)!
        XCTAssertTrue(p.byDay)
        XCTAssertEqual(p.points.map(\.deltaPct), [35, 40])
        XCTAssertEqual(p.points.map(\.dollars), [4, 2])
        XCTAssertEqual(p.points[0].start, Date(timeIntervalSince1970: TimeInterval(base)))
        XCTAssertTrue(p.points[0].isComplete)
        XCTAssertTrue(p.points[1].isComplete, "until = hour 48 = end of day 1")
    }

    func testCodexWidthIsTheReportedOneAndSupersededCyclesAreComplete() {
        let rows = [rollup(hour: 0, pLast: 5, pAnchor: 3 * day, tool: .codex),
                    rollup(hour: 1, pLast: 6, pAnchor: 3 * day, tool: .codex),
                    rollup(hour: 3 * 24, pLast: 0, pAnchor: 10 * day, tool: .codex),
                    rollup(hour: 3 * 24 + 1, pLast: 1, pAnchor: 10 * day, tool: .codex),
                    rollup(hour: 10 * 24, pLast: 0, pAnchor: 40 * day, tool: .codex),
                    rollup(hour: 10 * 24 + 1, pLast: 1, pAnchor: 40 * day, tool: .codex)]
        let s = WorkPerPercentSeries.compute(
            tool: .codex, rollups: rows, hourly: [], markers: [],
            until: Date(timeIntervalSince1970: TimeInterval(base + 20 * day)),
            primaryWindowSeconds: 604_800, calendar: utc)
        let p = slot(s, primary: true)!
        XCTAssertEqual(p.windowSeconds, 7 * day, "the reported width, not a derived one")
        XCTAssertFalse(p.byDay)
        XCTAssertEqual(p.points.count, 3)
        XCTAssertEqual(p.points.map(\.isComplete), [true, true, false],
                       "anchor passed · superseded by a later cycle · still running")
        XCTAssertEqual(p.points[0].dollars, 0)
    }

    func testCodexWithoutAReportedWidthHasNone() {
        let rows = [rollup(hour: 0, pLast: 5, pAnchor: 3 * day, tool: .codex),
                    rollup(hour: 1, pLast: 6, pAnchor: 3 * day, tool: .codex)]
        XCTAssertNil(slot(compute(rows, [], tool: .codex), primary: true)!.windowSeconds)
    }

    func testMarkersPassThroughSorted() {
        let m1 = WorkPerPercentSeries.Marker(at: Date(timeIntervalSince1970: 200), eventType: "window_removed",
                                             windowType: "five_hour", oldValue: "18000", newValue: nil)
        let m2 = WorkPerPercentSeries.Marker(at: Date(timeIntervalSince1970: 100), eventType: "plan_changed",
                                             windowType: nil, oldValue: "go", newValue: "plus")
        let s = compute([], [], markers: [m1, m2])
        XCTAssertEqual(s.markers, [m2, m1])
        XCTAssertFalse(s.isEmpty)
        XCTAssertTrue(compute([], []).isEmpty)
    }

    // MARK: Baseline §19 rate-step fixtures (numbers only — there is no notice)

    /// Two weekly cycles; every model needs 1.45× the dollars per 1 % in the second.
    private func twoCycles(secondFactorOpus: Double, secondFactorFable: Double,
                           unexplainedInSecond: Bool = false) -> WorkPerPercentSeries {
        var rows: [HistoryRollup] = []
        var hourly: [WorkPerPercentSeries.HourlyWork] = []
        // Cycle 1 (anchor day 7): hours 0…4, alternating opus / fable intervals at $1 per pt.
        rows.append(rollup(hour: 0, sLast: 0, sAnchor: 7 * day))
        for h in 1...4 {
            rows.append(rollup(hour: h, sLast: Double(h) * 10, sAnchor: 7 * day))
            hourly.append(work(hour: h, model: h % 2 == 0 ? "claude-opus-5" : "claude-fable-5",
                               dollars: 10))
        }
        // Cycle 2 (anchor day 14): hours 24…28, same rises, dollars scaled per model.
        rows.append(rollup(hour: 24, sLast: 0, sAnchor: 14 * day))
        for h in 25...28 {
            rows.append(rollup(hour: h, sLast: Double(h - 24) * 10, sAnchor: 14 * day))
            let opus = h % 2 == 0
            hourly.append(work(hour: h, model: opus ? "claude-opus-5" : "claude-fable-5",
                               dollars: 10 * (opus ? secondFactorOpus : secondFactorFable)))
        }
        if unexplainedInSecond {
            // Three more rises with no local work: the first is still covered by the
            // hour-before (write-lag) rule, the next two are unexplained.
            rows.append(rollup(hour: 30, sLast: 60, sAnchor: 14 * day))
            rows.append(rollup(hour: 31, sLast: 80, sAnchor: 14 * day))
            rows.append(rollup(hour: 32, sLast: 100, sAnchor: 14 * day))
        }
        return compute(rows, hourly, untilHour: 24 * 20)
    }

    func testRateStepAllModels() {
        // §19 rate-step-all-models: both per-model rates step ×1.45 together.
        let s = twoCycles(secondFactorOpus: 1.45, secondFactorFable: 1.45)
        let points = slot(s, primary: false)!.points
        XCTAssertEqual(points.count, 2)
        for model in ["claude-opus-5", "claude-fable-5"] {
            let r1 = points[0].perModel.first { $0.model == model }!.dollarsPerPct
            let r2 = points[1].perModel.first { $0.model == model }!.dollarsPerPct
            XCTAssertEqual(r2 / r1, 1.45, accuracy: 1e-9)
        }
        XCTAssertEqual(points[1].dollarsPerPct! / points[0].dollarsPerPct!, 1.45, accuracy: 1e-9)
        XCTAssertEqual(points[1].coverage, 1.0)
        XCTAssertEqual(points[1].unexplainedShare, 0)
    }

    func testRateStepOneModel() {
        // §19 rate-step-one-model: opus steps, fable does not — the all-models rate moves less
        // than either story alone; the per-model rows are what tells them apart.
        let s = twoCycles(secondFactorOpus: 1.45, secondFactorFable: 1.0)
        let points = slot(s, primary: false)!.points
        let opus = points.map { $0.perModel.first { $0.model == "claude-opus-5" }!.dollarsPerPct }
        let fable = points.map { $0.perModel.first { $0.model == "claude-fable-5" }!.dollarsPerPct }
        XCTAssertEqual(opus[1] / opus[0], 1.45, accuracy: 1e-9)
        XCTAssertEqual(fable[1] / fable[0], 1.0, accuracy: 1e-9)
        XCTAssertEqual(points[1].dollarsPerPct! / points[0].dollarsPerPct!, 1.225, accuracy: 1e-9)
    }

    func testRateStepUnexplained() {
        // §19 rate-step-unexplained: much of the second cycle's rise is usage nobody local can
        // explain — its all-models rate *drops* while both per-model rates hold at ×1.
        let s = twoCycles(secondFactorOpus: 1.0, secondFactorFable: 1.0, unexplainedInSecond: true)
        let points = slot(s, primary: false)!.points
        XCTAssertEqual(points[1].deltaPct, 100)
        XCTAssertEqual(points[1].unexplainedShare!, 0.4, accuracy: 1e-9)
        XCTAssertEqual(points[1].coverage!, 0.4, accuracy: 1e-9)
        XCTAssertEqual(points[1].dollarsPerPct!, 0.4, accuracy: 1e-9)
        for model in ["claude-opus-5", "claude-fable-5"] {
            let r1 = points[0].perModel.first { $0.model == model }!.dollarsPerPct
            let r2 = points[1].perModel.first { $0.model == model }!.dollarsPerPct
            XCTAssertEqual(r2 / r1, 1.0, accuracy: 1e-9)
        }
    }
}
