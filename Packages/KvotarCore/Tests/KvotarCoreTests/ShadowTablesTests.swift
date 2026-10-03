import XCTest
@testable import KvotarCore

/// §11.5's training half (REV-95 §3.3 — STEP_190): which windows may teach the tables, which
/// origins inside them count, and how the counts turn into a probability, a weight and a range.
final class ShadowTablesTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Builders

    /// One window's worth of polls: `count` samples at `every` seconds ending `endsBefore` seconds
    /// before the reset, rising `step` points per poll.
    private func window(reset: Date, count: Int, every: TimeInterval = 120, step: Double,
                        endsBefore: TimeInterval = 0, startUsed: Double = 0,
                        width: Int? = 18_000) -> [QuotaSeriesPoint] {
        (0..<count).map { index in
            QuotaSeriesPoint(
                polledAt: reset.addingTimeInterval(-endsBefore - Double(count - 1 - index) * every),
                usedPct: startUsed + step * Double(index),
                resetsAt: reset, windowSeconds: width)
        }
    }

    private func exposure(_ reset: Date, recorded: Bool = true,
                          warnedAt: Date? = nil) -> WindowExposure {
        WindowExposure(anchor: reset, recorded: recorded, warningFirstShownAt: warnedAt)
    }

    /// A completed five-hour window, fully observed, burning steadily throughout.
    private func burningWindow(reset: Date) -> [QuotaSeriesPoint] {
        window(reset: reset, count: 100, step: 0.9)
    }

    // MARK: - Eligibility

    func testAWindowNobodyWatchedCloseTeachesNothing() {
        let reset = base.addingTimeInterval(-7200)
        // Last observation an hour before the reset — well past the 15-minute close tolerance.
        let points = window(reset: reset, count: 100, step: 0.9, endsBefore: 3600)
        let tables = ShadowTablesReader.build(tool: .claude, points: points,
                                              exposures: [exposure(reset)], now: base)
        XCTAssertEqual(tables.completedWindows, 0)
        XCTAssertEqual(tables.originCount, 0)
    }

    func testAWindowFromABuildWithoutTheExposureColumnTeachesNothing() {
        // STEP_190 ruling 1: before `v24` a NULL warning stamp meant "could not record", not
        // "nothing was shown", and training on it puts post-warning behaviour back in.
        let reset = base.addingTimeInterval(-7200)
        let tables = ShadowTablesReader.build(
            tool: .claude, points: burningWindow(reset: reset),
            exposures: [exposure(reset, recorded: false)], now: base)
        XCTAssertEqual(tables.completedWindows, 0)
    }

    func testAWindowWithNoExposureRowAtAllTeachesNothing() {
        let reset = base.addingTimeInterval(-7200)
        let tables = ShadowTablesReader.build(tool: .claude, points: burningWindow(reset: reset),
                                              exposures: [], now: base)
        XCTAssertEqual(tables.completedWindows, 0)
    }

    func testTheCurrentWindowTeachesNothing() {
        // Its reset has not passed, so it has no outcome — only a reading.
        let reset = base.addingTimeInterval(3600)
        let points = window(reset: reset, count: 100, step: 0.9, endsBefore: 3600)
        let tables = ShadowTablesReader.build(tool: .claude, points: points,
                                              exposures: [exposure(reset)], now: base)
        XCTAssertEqual(tables.completedWindows, 0)
    }

    func testALongWindowTeachesNothing() {
        let reset = base.addingTimeInterval(-7200)
        let points = window(reset: reset, count: 100, step: 0.9, width: 604_800)
        let tables = ShadowTablesReader.build(tool: .codex, points: points,
                                              exposures: [exposure(reset)], now: base)
        XCTAssertEqual(tables.completedWindows, 0)
    }

    func testAWindowOfUnknownWidthTeachesNothing() {
        // REV-93 §4's rule reused: an unresolved width is excluded, never guessed. Codex, because
        // Claude's primary field resolves to five hours by provider contract.
        let reset = base.addingTimeInterval(-7200)
        let points = window(reset: reset, count: 100, step: 0.9, width: nil)
        let tables = ShadowTablesReader.build(tool: .codex, points: points,
                                              exposures: [exposure(reset)], now: base)
        XCTAssertEqual(tables.completedWindows, 0)
    }

    func testAnObservedCompletedShortWindowTeaches() {
        let reset = base.addingTimeInterval(-7200)
        let tables = ShadowTablesReader.build(tool: .claude, points: burningWindow(reset: reset),
                                              exposures: [exposure(reset)], now: base)
        XCTAssertEqual(tables.completedWindows, 1)
        XCTAssertGreaterThan(tables.originCount, 0)
    }

    // MARK: - Origins

    func testOriginsAreSpacedAtLeastFiveMinutesApart() {
        let reset = base.addingTimeInterval(-7200)
        // 100 polls at 120 s = 198 minutes of window. At one origin per 5 minutes, and needing a
        // 30-minute neighbour behind and a 30-minute outcome ahead, well under 40 can qualify.
        let tables = ShadowTablesReader.build(tool: .claude, points: burningWindow(reset: reset),
                                              exposures: [exposure(reset)], now: base)
        XCTAssertLessThanOrEqual(tables.originCount, 100 * 120 / 300)
    }

    func testPostWarningOriginsAreExcluded() {
        let reset = base.addingTimeInterval(-7200)
        let points = burningWindow(reset: reset)
        let all = ShadowTablesReader.build(tool: .claude, points: points,
                                           exposures: [exposure(reset)], now: base)
        // Warn at the window's midpoint: everything after it is the user's response to the app,
        // not their demand (Spike D F13 / REV-95 §3.2).
        let midpoint = points[points.count / 2].polledAt
        let preWarning = ShadowTablesReader.build(
            tool: .claude, points: points,
            exposures: [exposure(reset, warnedAt: midpoint)], now: base)
        XCTAssertGreaterThan(all.originCount, preWarning.originCount)
        XCTAssertGreaterThan(preWarning.originCount, 0)
        // The window itself still counts — it was eligible; only its later origins were dropped.
        XCTAssertEqual(preWarning.completedWindows, 1)
    }

    func testAWindowWarnedFromItsFirstPollContributesNoOrigins() {
        let reset = base.addingTimeInterval(-7200)
        let points = burningWindow(reset: reset)
        let tables = ShadowTablesReader.build(
            tool: .claude, points: points,
            exposures: [exposure(reset, warnedAt: points[0].polledAt)], now: base)
        XCTAssertEqual(tables.originCount, 0)
    }

    func testAGapWithNoThirtyMinuteNeighbourYieldsNoOrigin() {
        // Five polls over ten minutes: nothing can see back half an hour, so nothing classifies.
        let reset = base.addingTimeInterval(-3600)
        let points = window(reset: reset, count: 5, step: 1)
        let tables = ShadowTablesReader.build(tool: .claude, points: points,
                                              exposures: [exposure(reset)], now: base)
        XCTAssertEqual(tables.originCount, 0)
    }

    func testABurningWindowFillsTheBurningCell() {
        let reset = base.addingTimeInterval(-7200)
        let tables = ShadowTablesReader.build(tool: .claude, points: burningWindow(reset: reset),
                                              exposures: [exposure(reset)], now: base)
        XCTAssertGreaterThan(tables.cells[.burning]?.n ?? 0, 0)
        XCTAssertNil(tables.cells[.quiet])
        // Rising 0.9 points per poll, every origin's next half hour rises well past one point.
        XCTAssertEqual(tables.cells[.burning]?.hits, tables.cells[.burning]?.n)
    }

    func testAFlatWindowFillsTheQuietCellWithNoHits() {
        let reset = base.addingTimeInterval(-7200)
        let points = window(reset: reset, count: 100, step: 0, startUsed: 40)
        let tables = ShadowTablesReader.build(tool: .claude, points: points,
                                              exposures: [exposure(reset)], now: base)
        XCTAssertGreaterThan(tables.cells[.quiet]?.n ?? 0, 0)
        XCTAssertEqual(tables.cells[.quiet]?.hits, 0)
        XCTAssertNil(tables.cells[.burning])
    }

    // MARK: - The formulas

    func testProbabilityIsTheShippedPriorAtZeroObservations() {
        for state in ShadowAccountState.allCases {
            XCTAssertEqual(ShadowTables.empty.probability(for: state),
                           ShadowTables.prior.probability[state]!, accuracy: 0.0001,
                           "a fresh install reads the prior exactly")
        }
    }

    func testProbabilityConvergesToTheCellRateWithEnoughOwnHistory() {
        // 2,000 own origins swamp twenty pseudo-origins of prior: 0.9 pulled down by 0.006.
        let tables = ShadowTables(cells: [.quiet: .init(hits: 1800, n: 2000, alpha: nil, rises: [])],
                                  allStateAlpha: nil, completedWindows: 40)
        XCTAssertEqual(tables.probability(for: .quiet), 0.9, accuracy: 0.01)
        // And the prior still shows through at small n: 2 of 4 with a 0.282 prior sits between.
        let thin = ShadowTables(cells: [.quiet: .init(hits: 2, n: 4, alpha: nil, rises: [])],
                                allStateAlpha: nil, completedWindows: 12)
        XCTAssertGreaterThan(thin.probability(for: .quiet), ShadowTables.prior.probability[.quiet]!)
        XCTAssertLessThan(thin.probability(for: .quiet), 0.5)
    }

    func testAlphaFallsBackFromCellToAllStateToPrior() {
        let full = ShadowTables(cells: [.burning: .init(hits: 1, n: 1, alpha: 0.25, rises: [])],
                                allStateAlpha: 0.75, completedWindows: 12)
        XCTAssertEqual(full.alpha(for: .burning), 0.25)
        let noCell = ShadowTables(cells: [.burning: .init(hits: 1, n: 1, alpha: nil, rises: [])],
                                  allStateAlpha: 0.75, completedWindows: 12)
        XCTAssertEqual(noCell.alpha(for: .burning), 0.75)
        XCTAssertEqual(ShadowTables.empty.alpha(for: .burning),
                       ShadowTables.prior.alpha[.burning]!)
    }

    func testAlphaPicksTheGridWeightThatMinimisesError() {
        // Thirty origins where the long rate is right and the short rate is nonsense.
        let honest = (0..<30).map { _ in
            ShadowTablesReader.Origin(state: .burning, shortRate: 10, longRate: 0.2,
                                      actualRise: 6)   // 0.2 %/min × 30 min = 6 points
        }
        XCTAssertEqual(ShadowTablesReader.bestAlpha(honest), 0)
        // Flip which one is right and the choice flips with it.
        let flipped = (0..<30).map { _ in
            ShadowTablesReader.Origin(state: .burning, shortRate: 0.2, longRate: 10,
                                      actualRise: 6)
        }
        XCTAssertEqual(ShadowTablesReader.bestAlpha(flipped), 1)
    }

    func testAlphaIsNilBelowThirtyFittableOrigins() {
        let thin = (0..<29).map { _ in
            ShadowTablesReader.Origin(state: .burning, shortRate: 1, longRate: 1, actualRise: 30)
        }
        XCTAssertNil(ShadowTablesReader.bestAlpha(thin))
        // An origin missing either rate is not fittable, so it does not count toward the thirty.
        let unfittable = (0..<60).map { _ in
            ShadowTablesReader.Origin(state: .burning, shortRate: nil, longRate: 1, actualRise: 30)
        }
        XCTAssertNil(ShadowTablesReader.bestAlpha(unfittable))
    }

    func testRangeBracketsTheMedianAndIsOrdered() {
        let rises = (0..<200).map { Double($0 % 20) }
        let tables = ShadowTables(cells: [.burning: .init(hits: 150, n: 200, alpha: nil,
                                                          rises: rises)],
                                  allStateAlpha: nil, completedWindows: 40)
        let range = tables.riseRange(for: .burning)
        XCTAssertLessThan(range.p10, range.p90)
        XCTAssertGreaterThanOrEqual(range.p10, 0)
        XCTAssertLessThanOrEqual(range.p90, 19)
    }

    func testRangeIsThePriorsAtZeroObservations() {
        let range = ShadowTables.empty.riseRange(for: .burning)
        XCTAssertEqual(range.p10, ShadowQuantile.plain(ShadowTables.prior.rises, 0.10),
                       accuracy: 0.5)
        XCTAssertGreaterThan(range.p90, range.p10)
    }

    // MARK: - The shipped prior (STEP_190 ruling 2)

    /// Pinned so the offline derivation cannot drift silently — a shadow row is only gradable
    /// against the prior that produced it. Provenance is in `ShadowTables.prior`'s own doc:
    /// 77 completed five-hour windows, 1,862 origins, Claude only, 2026-09-14.
    func testShippedPriorIsExactlyWhatWasDerived() {
        XCTAssertEqual(ShadowTables.prior.probability[.burning], 0.877)
        XCTAssertEqual(ShadowTables.prior.probability[.paused], 0.620)
        XCTAssertEqual(ShadowTables.prior.probability[.quiet], 0.282)
        XCTAssertEqual(ShadowTables.prior.alpha[.burning], 0.0)
        XCTAssertEqual(ShadowTables.prior.alpha[.paused], 0.75)
        XCTAssertEqual(ShadowTables.prior.alpha[.quiet], 1.0)
        XCTAssertEqual(ShadowTables.prior.allStateAlpha, 0.5)
        XCTAssertEqual(ShadowTables.prior.rises.count, 20,
                       "twenty equally-weighted points carry the prior at exactly k = 20")
        XCTAssertEqual(ShadowTables.prior.rises,
                       [0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 2, 3, 4, 5, 6, 7, 8, 11, 15, 24.475])
        // Every grid value used is on the grid.
        for alpha in ShadowTables.prior.alpha.values {
            XCTAssertTrue(ShadowPolicy.alphaGrid.contains(alpha))
        }
    }

    /// The probabilities are the same finding Spike D F9/§4.1 reached independently on the
    /// account-only bits — burning high, paused mid, quiet low, in that order.
    func testShippedPriorOrdersTheStatesTheWaySpikeDDid() {
        XCTAssertGreaterThan(ShadowTables.prior.probability[.burning]!,
                             ShadowTables.prior.probability[.paused]!)
        XCTAssertGreaterThan(ShadowTables.prior.probability[.paused]!,
                             ShadowTables.prior.probability[.quiet]!)
    }
}
