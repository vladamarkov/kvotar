import XCTest
@testable import KvotarCore

/// Exercises the pure trailing spend-rate computation (REV-47 §2.2). The §11.2a discipline
/// throughout: nil means unknown — below the minimum span, cross-rollover, or a negative delta
/// (the SPIKE's eventual-consistency dips) — never zero; a measured zero over a sufficient span
/// is a legitimate 0.
final class MonthlySpendRateTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let reset = Date(timeIntervalSince1970: 1_702_000_000)

    private func sample(_ offset: TimeInterval, _ used: Double,
                        resetsAt: Date? = nil) -> MonthlyUsedSample {
        MonthlyUsedSample(polledAt: base.addingTimeInterval(offset), usedAmount: used,
                          resetsAt: resetsAt ?? reset)
    }

    // MARK: Unknown ≠ zero

    func testBelowMinSpanIsNilNeverZero() {
        // 1799s span — one second under `monthlyRateMinSpan` (1800s, the SPIKE ruling).
        let rate = MonthlySpendRate.compute(samples: [sample(0, 100), sample(1799, 400)])
        XCTAssertNil(rate, "a sub-min-span rate is unknown, not 0")
    }

    func testEmptyAndSingleSampleAreNil() {
        XCTAssertNil(MonthlySpendRate.compute(samples: []))
        XCTAssertNil(MonthlySpendRate.compute(samples: [sample(0, 100)]),
                     "a single sample has zero span — unknown")
    }

    func testNilResetOnNewestSampleIsNil() {
        let s = MonthlyUsedSample(polledAt: base.addingTimeInterval(3600), usedAmount: 500,
                                  resetsAt: nil)
        XCTAssertNil(MonthlySpendRate.compute(samples: [sample(0, 100), s]),
                     "no cycle anchor on the newest sample → no rate claim")
    }

    // MARK: Straight-line math

    func testStraightLineRate() {
        // +3600 raw units over 3600s → 3600/hr.
        let rate = MonthlySpendRate.compute(samples: [sample(0, 1000), sample(3600, 4600)])
        XCTAssertEqual(rate ?? -1, 3600, accuracy: 1e-9)
    }

    func testIntermediateSamplesDoNotChangeEndpointRate() {
        // The rate is endpoint-to-endpoint over the span; lumps in between are smoothed out.
        let rate = MonthlySpendRate.compute(samples: [
            sample(0, 1000), sample(1200, 1000), sample(2400, 2800), sample(3600, 2800),
        ])
        XCTAssertEqual(rate ?? -1, 1800, accuracy: 1e-9)
    }

    func testUnsortedInputIsSortedInternally() {
        let rate = MonthlySpendRate.compute(samples: [sample(3600, 4600), sample(0, 1000)])
        XCTAssertEqual(rate ?? -1, 3600, accuracy: 1e-9)
    }

    // MARK: Cycle filter — cross-rollover samples excluded

    func testCrossRolloverSamplesExcludedFromSpan() {
        // Two old samples from the previous cycle (different resets_at) + two from the current.
        // The previous-cycle pair must not stretch the span or feed the delta — and with only
        // 1200s of current-cycle span, the rate is nil.
        let prevReset = reset.addingTimeInterval(-30 * 86_400)
        let samples = [
            sample(0, 9000, resetsAt: prevReset), sample(600, 9500, resetsAt: prevReset),
            sample(1200, 100), sample(2400, 300),
        ]
        XCTAssertNil(MonthlySpendRate.compute(samples: samples),
                     "current-cycle span (1200s) is below min-span once the old cycle is excluded")
    }

    func testCurrentCycleRateSurvivesPrecedingRolloverSamples() {
        let prevReset = reset.addingTimeInterval(-30 * 86_400)
        let samples = [
            sample(0, 9000, resetsAt: prevReset),
            sample(600, 100), sample(2400, 400), sample(4200, 700),
        ]
        // Current cycle: +600 over 3600s → 600/hr; the 9000-unit old sample is invisible.
        XCTAssertEqual(MonthlySpendRate.compute(samples: samples) ?? -1, 600, accuracy: 1e-9)
    }

    func testResetJitterWithinToleranceIsSameCycle() {
        // The derived reset wobbles ±30s between polls — same cycle, rate still computed.
        let samples = [
            sample(0, 1000, resetsAt: reset.addingTimeInterval(-30)),
            sample(3600, 2000, resetsAt: reset.addingTimeInterval(30)),
        ]
        XCTAssertEqual(MonthlySpendRate.compute(samples: samples) ?? -1, 1000, accuracy: 1e-9)
    }

    // MARK: Negative delta — rollover or eventual-consistency dip

    func testNegativeDeltaIsNilNeverNegative() {
        // The SPIKE's at-rest regression: newest reading below the oldest. nil, never negative.
        let rate = MonthlySpendRate.compute(samples: [sample(0, 500), sample(3600, 490)])
        XCTAssertNil(rate)
    }

    // MARK: Measured zero

    func testMeasuredZeroOverSufficientSpanIsZero() {
        let rate = MonthlySpendRate.compute(samples: [sample(0, 500), sample(3600, 500)])
        XCTAssertEqual(rate ?? -1, 0, accuracy: 1e-9,
                       "a flat meter over a full span is a measured 0, not unknown")
    }

    // MARK: Codex credits (REV-48 — STEP_67)

    /// The computation is unit-blind, so this covers only what is genuinely Codex-shaped: the
    /// 10-credit quantum the P2-15 SPIKE measured on ChatGPT web. The 1800s min-span exists to
    /// smooth exactly this: six lumps across half an hour average out, where any one of them
    /// taken alone over a couple of polls would read as a wild multiple of the real rate.
    func testCodexTenCreditLumpsSmoothOverMinSpan() {
        let samples = (0...6).map { i in
            sample(Double(i) * 300, 2876.213 + Double(i) * 10)
        }
        let rate = MonthlySpendRate.compute(samples: samples)
        XCTAssertEqual(rate ?? -1, 120, accuracy: 1e-9,
                       "60 credits over 1800s = 120 credits/hr")
    }
}
