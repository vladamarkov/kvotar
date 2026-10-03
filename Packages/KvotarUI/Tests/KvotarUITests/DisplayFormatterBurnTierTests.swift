import XCTest
import KvotarCore
@testable import KvotarUI

/// The burn pill and its rate in the window's own language (UI Spec §2.4 as amended — REV-74 /
/// D-82 + D-83, STEP_123). Two claims are under test and they pull in opposite directions:
/// **nothing five-hour may move**, and **a weekly window must stop being read with five-hour
/// numbers**.
final class DisplayFormatterBurnTierTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private static let fiveHour: TimeInterval = 18_000
    private static let weekly: TimeInterval = 604_800

    // MARK: The five-hour column, proved rather than asserted

    /// The acceptance test of the whole step (REV-74 §4). The bands are now
    /// `multiple × 100 ÷ windowMinutes`; at five hours that arithmetic returns the STEP_27
    /// literals **exactly**, so every existing fixture compares against the same doubles it always
    /// did. Exact equality on purpose — an `accuracy:` here would let a boundary drift silently,
    /// which is the one thing the task forbids.
    func testFiveHourThresholdsAreExactlyTheSTEP27Numbers() {
        let t = DisplayFormatter.burnTierThresholds(windowSeconds: Self.fiveHour)
        XCTAssertEqual(t.none, 0.1)
        XCTAssertEqual(t.mid, 1.0)
        XCTAssertEqual(t.high, 3.0)
    }

    /// And the tiers those thresholds produce, at and around every five-hour boundary.
    func testFiveHourTiersAreUnchanged() {
        let cases: [(Double, String, StatusDot)] = [
            (0, "none", .grey), (0.099, "none", .grey),
            (0.1, "low", .green), (0.4, "low", .green), (0.999, "low", .green),
            (1.0, "mid", .amber), (1.8, "mid", .amber), (2.999, "mid", .amber),
            (3.0, "high", .red), (3.8, "high", .red),
        ]
        for (rate, pill, dot) in cases {
            let tier = DisplayFormatter.burnTier(rate, windowSeconds: Self.fiveHour)
            XCTAssertEqual(tier.0, pill, "\(rate) %/min on a five-hour window")
            XCTAssertEqual(tier.1, dot, "\(rate) %/min on a five-hour window")
        }
    }

    /// A window with no reported width is a five-hour window — `primaryWindowLength`'s own
    /// fallback, which is why every Claude account (Claude reports no width at all) is untouched.
    func testAbsentWidthKeepsTheFiveHourBands() {
        XCTAssertEqual(DisplayFormatter.burnTier(0.4, windowSeconds: QuotaSnapshot(
            tool: .claude, primaryUsedPct: 40, primaryResetsAt: now,
            secondaryUsedPct: nil, secondaryResetsAt: nil,
            rateLimitReached: false).primaryWindowLength).0, "low")
    }

    // MARK: The weekly column

    /// The §2.4 weekly column: < 0.003 / < 0.03 / < 0.089 %/min. Even pace on a week is
    /// 100 ÷ 10 080 = 0.0099 %/min, so these are the same 0.3× / 3× / 9× multiples.
    func testWeeklyBands() {
        let t = DisplayFormatter.burnTierThresholds(windowSeconds: Self.weekly)
        XCTAssertEqual(t.none, 0.002976, accuracy: 1e-6)
        XCTAssertEqual(t.mid, 0.029762, accuracy: 1e-6)
        XCTAssertEqual(t.high, 0.089286, accuracy: 1e-6)

        let cases: [(Double, String, StatusDot)] = [
            (0.0, "none", .grey), (0.002, "none", .grey),
            (0.005, "low", .green), (0.02, "low", .green),
            (0.05, "mid", .amber),
            (0.1, "high", .red), (0.2601, "high", .red),
        ]
        for (rate, pill, dot) in cases {
            let tier = DisplayFormatter.burnTier(rate, windowSeconds: Self.weekly)
            XCTAssertEqual(tier.0, pill, "\(rate) %/min on a weekly window")
            XCTAssertEqual(tier.1, dot, "\(rate) %/min on a weekly window")
        }
    }

    /// The screenshot that started REV-74, at the reading STEP_122's hour of evidence produces for
    /// it: 21 % → 25 % over the hour to 22:19 = 0.0678 %/min = 6.7× even pace. The old fixed table
    /// called this `none` beside a displayed `0.1% / min`.
    func testTheDogfoodEveningReadsMid() {
        XCTAssertEqual(DisplayFormatter.burnTier(0.0678, windowSeconds: Self.weekly).0, "mid")
        XCTAssertEqual(DisplayFormatter.burnTier(0.0678, windowSeconds: Self.fiveHour).0, "none",
                       "the same rate on a five-hour window really is idle — the bands, not the rate")
    }

    // MARK: The rendered fact (D-83 — the unit follows the window)
    //
    // The burn moved from its own card onto the header's `Quota burn` line at the STEP_178
    // cutover. The tier word, the unit rule and the dot are unchanged — only where they render.

    private func codexBurn(windowSeconds: Int, burn: Double?) -> HeaderFact {
        let snapshot = QuotaSnapshot(tool: .codex, primaryUsedPct: 25,
                                     primaryResetsAt: now.addingTimeInterval(12 * 3600),
                                     primaryWindowSeconds: windowSeconds,
                                     secondaryUsedPct: nil, secondaryResetsAt: nil,
                                     rateLimitReached: false, extraUsage: nil,
                                     source: .appServerRPC, planType: "plus")
        let forecast = Forecast(tool: .codex, tier: .fullRunway,
                                runwayMinutes: burn.flatMap { $0 > 0 ? (100 - 25) / $0 : nil },
                                burnRatePerMin: burn, isEstimate: false, pollCount: 10)
        return DisplayFormatter.codex(state: .healthy, snapshot: snapshot, forecast: forecast,
                                      pollAsOf: now, now: now).header!.accountBurn!
    }

    func testWeeklyFactRendersPerHourAndFiveHourDoesNot() {
        let weekly = codexBurn(windowSeconds: 10_080 * 60, burn: 0.0667)
        XCTAssertEqual(weekly.tier, "mid")
        XCTAssertEqual(weekly.value, "Mid · 4.0% / hr")
        XCTAssertEqual(weekly.dot, .amber)

        // The identical rate on a five-hour window keeps both the old unit and the old word.
        let short = codexBurn(windowSeconds: 300 * 60, burn: 0.0667)
        XCTAssertEqual(short.tier, "none")
        XCTAssertEqual(short.value, "Very low · 0.1% / min")
    }

    func testZeroAndSubPrecisionPositiveHaveDistinctReadableCopy() {
        let zero = codexBurn(windowSeconds: 300 * 60, burn: 0)
        XCTAssertEqual(zero.value, "No measurable burn")
        XCTAssertEqual(zero.tier, "none")

        let positive = codexBurn(windowSeconds: 300 * 60, burn: 0.01)
        XCTAssertEqual(positive.value, "Very low · <0.1% / min")
        XCTAssertEqual(positive.tier, "none", "the existing delta ordering key remains stable")
        XCTAssertFalse(positive.value.lowercased().contains("none"))
        XCTAssertFalse(positive.value.contains("0.0"))
    }

    /// The boundary itself is one day (`burnUnitHourFrom`), not "weekly": a 30-day window reads per
    /// hour too, and 5 h 59 m does not.
    func testTheUnitBoundaryIsOneDay() {
        XCTAssertTrue(codexBurn(windowSeconds: 86_400, burn: 0.01).value.contains("0.6% / hr"))
        XCTAssertTrue(codexBurn(windowSeconds: 86_399, burn: 0.01).value.contains("<0.1% / min"))
    }

    func testUnmeasuredRateDoesNotRender() {
        let snapshot = QuotaSnapshot(tool: .codex, primaryUsedPct: 25,
                                     primaryResetsAt: now.addingTimeInterval(12 * 3600),
                                     primaryWindowSeconds: 10_080 * 60,
                                     secondaryUsedPct: nil, secondaryResetsAt: nil,
                                     rateLimitReached: false, source: .appServerRPC,
                                     planType: "plus")
        let forecast = Forecast(tool: .codex, tier: .fullRunway, runwayMinutes: nil,
                                burnRatePerMin: nil, isEstimate: false, pollCount: 10)
        let state = DisplayFormatter.codex(state: .healthy, snapshot: snapshot,
                                           forecast: forecast, pollAsOf: now, now: now)
        XCTAssertNil(state.header?.accountBurn)
    }

    func testSingleQuantizedTickDoesNotRenderAsAnHourlyRate() {
        let snapshot = QuotaSnapshot(tool: .codex, primaryUsedPct: 15,
                                     primaryResetsAt: now.addingTimeInterval(7 * 86_400),
                                     primaryWindowSeconds: 10_080 * 60,
                                     secondaryUsedPct: nil, secondaryResetsAt: nil,
                                     rateLimitReached: false, source: .appServerRPC,
                                     planType: "plus")
        let forecast = Forecast(tool: .codex, tier: .fullRunway, runwayMinutes: 168,
                                burnRatePerMin: 0.5, isEstimate: true, pollCount: 2,
                                burnSpanMinutes: 2)
        let state = DisplayFormatter.codex(state: .healthy, snapshot: snapshot,
                                           forecast: forecast, pollAsOf: now, now: now)
        XCTAssertNil(state.header?.accountBurn)
    }
}
