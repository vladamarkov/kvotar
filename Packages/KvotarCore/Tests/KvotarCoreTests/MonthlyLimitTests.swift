import XCTest
@testable import KvotarCore

/// REV-38 (STEP_43): the normalized monthly-limit model — defensive string parsing and the two
/// engine derivations (`usedPercentExact`, `pacePerDay`). Values are synthetic, in the shape of the
/// 2026-07-15 capture: limit "5000", used "2376.905242651701", reset Aug 1 2026 00:00 UTC.
final class MonthlyLimitTests: XCTestCase {

    /// Aug 1 2026 00:00:00 UTC — start of the next calendar month in the live capture.
    private let augustFirst = Date(timeIntervalSince1970: 1_785_542_400)
    /// Jul 1 2026 00:00:00 UTC — the cycle start `pacePerDay` must derive (31-day month).
    private let julyFirst = Date(timeIntervalSince1970: 1_782_864_000)

    private func limit(used: Double = 2376.905242651701) -> MonthlyLimit {
        MonthlyLimit(limitAmount: 5000, usedAmount: used, remainingPercent: 52,
                     resetsAt: augustFirst, source: "group_based_spend_controls")
    }

    // MARK: Failable string init (locale-safe transport parsing)

    func testParsesStringNumericsIncludingFractionalUsed() throws {
        let m = try XCTUnwrap(MonthlyLimit(
            limitString: "5000", usedString: "2376.905242651701",
            remainingPercent: 52, resetsAtUnixSeconds: 1_785_542_400,
            source: "group_based_spend_controls"))
        XCTAssertEqual(m.limitAmount, 5000)
        XCTAssertEqual(m.usedAmount, 2376.905242651701)
        XCTAssertEqual(m.remainingPercent, 52)
        XCTAssertEqual(m.resetsAt, augustFirst)
        XCTAssertEqual(m.source, "group_based_spend_controls")
    }

    func testAnyMissingOrUnparseableRequiredFieldYieldsNil() {
        XCTAssertNil(MonthlyLimit(limitString: nil, usedString: "1", remainingPercent: 52,
                                  resetsAtUnixSeconds: 1, source: nil))
        XCTAssertNil(MonthlyLimit(limitString: "not-a-number", usedString: "1",
                                  remainingPercent: 52, resetsAtUnixSeconds: 1, source: nil))
        XCTAssertNil(MonthlyLimit(limitString: "5000", usedString: "1,5", remainingPercent: 52,
                                  resetsAtUnixSeconds: 1, source: nil),
                     "comma decimals must not parse — Double(_:) is locale-independent")
        XCTAssertNil(MonthlyLimit(limitString: "5000", usedString: "2376.9", remainingPercent: nil,
                                  resetsAtUnixSeconds: 1, source: nil))
        XCTAssertNil(MonthlyLimit(limitString: "5000", usedString: "2376.9", remainingPercent: 52,
                                  resetsAtUnixSeconds: nil, source: nil))
    }

    // MARK: usedPercentExact (hero input — D-34/E3, 1% precision)

    func testUsedPercentExact() throws {
        let pct = try XCTUnwrap(limit().usedPercentExact)
        XCTAssertEqual(pct, 47.5381, accuracy: 0.0001)
        // Never disagrees with OpenAI's own integer (100 − remainingPercent = 48) by > 1pt.
        XCTAssertLessThanOrEqual(abs(pct - 48), 1.0)
    }

    func testUsedPercentExactNilOnNonPositiveLimit() {
        let zero = MonthlyLimit(limitAmount: 0, usedAmount: 10, remainingPercent: 0,
                                resetsAt: augustFirst)
        XCTAssertNil(zero.usedPercentExact)
    }

    // MARK: pacePerDay (backend used ÷ days elapsed — never local token math)

    func testPaceAfterFifteenDays() throws {
        let now = julyFirst.addingTimeInterval(15 * 86_400)
        let pace = try XCTUnwrap(limit().pacePerDay(now: now))
        XCTAssertEqual(pace, 2376.905242651701 / 15, accuracy: 0.0001)
    }

    func testPaceNilUnderOneDayElapsed() {
        // A fresh cycle's divisor would assert an absurd pace — the E6 gate wants a placeholder.
        let now = julyFirst.addingTimeInterval(0.5 * 86_400)
        XCTAssertNil(limit().pacePerDay(now: now))
    }

    func testPaceAtExactlyOneDay() throws {
        let now = julyFirst.addingTimeInterval(86_400)
        let pace = try XCTUnwrap(limit(used: 100).pacePerDay(now: now))
        XCTAssertEqual(pace, 100, accuracy: 0.0001)
    }

    // MARK: runwayDays ((limit − used) ÷ pace — the E8 slot / forecast-tier / verdict input)

    func testRunwayDaysAtLiveCaptureValues() throws {
        // Day 15: pace ≈ 158.46/day, remaining ≈ 2623.09 ⇒ ~16.55d runway.
        let now = julyFirst.addingTimeInterval(15 * 86_400)
        let runway = try XCTUnwrap(limit().runwayDays(now: now))
        XCTAssertEqual(runway, (5000 - 2376.905242651701) / (2376.905242651701 / 15),
                       accuracy: 0.0001)
    }

    func testRunwayDaysNilWhilePaceUnavailable() {
        let now = julyFirst.addingTimeInterval(0.5 * 86_400)
        XCTAssertNil(limit().runwayDays(now: now), "no pace ⇒ no runway — never a guess")
    }

    func testRunwayDaysFlooredAtZeroWhenOverLimit() throws {
        let now = julyFirst.addingTimeInterval(15 * 86_400)
        let runway = try XCTUnwrap(limit(used: 5250).runwayDays(now: now))
        XCTAssertEqual(runway, 0, "past the limit the runway is spent, not negative or unknown")
    }

    // MARK: QuotaUnit (REV-40, STEP_46 — unit generalization)

    func testUnitDefaultsToCreditsOnBothInits() throws {
        XCTAssertEqual(limit().unit, .credits, "the default keeps Codex behaviour identical")
        let transport = try XCTUnwrap(MonthlyLimit(
            limitString: "5000", usedString: "2376.9", remainingPercent: 52,
            resetsAtUnixSeconds: 1_785_542_400, source: nil))
        XCTAssertEqual(transport.unit, .credits)
    }

    func testDerivationsAreUnitIndependent() throws {
        let money = MonthlyLimit(limitAmount: 12000, usedAmount: 6916, remainingPercent: 42,
                                 resetsAt: augustFirst,
                                 unit: .money(currency: "USD", exponent: 2))
        let pct = try XCTUnwrap(money.usedPercentExact)
        XCTAssertEqual(pct, 57.63, accuracy: 0.01)
        let now = julyFirst.addingTimeInterval(15 * 86_400)
        let pace = try XCTUnwrap(money.pacePerDay(now: now))
        XCTAssertEqual(pace, 6916.0 / 15, accuracy: 0.0001, "pace stays in raw minor units")
    }

    // MARK: nextCalendarMonthStartUTC (REV-40 — the derived Claude Enterprise reset, §8.0.4)

    func testNextCalendarMonthStartMidMonth() {
        // Jul 16 2026 12:00 UTC → Aug 1 2026 00:00 UTC.
        let midJuly = julyFirst.addingTimeInterval(15 * 86_400 + 12 * 3_600)
        XCTAssertEqual(MonthlyLimit.nextCalendarMonthStartUTC(after: midJuly), augustFirst)
    }

    func testNextCalendarMonthStartAcrossYearBoundary() {
        // Dec 31 2026 23:59:59 UTC → Jan 1 2027 00:00:00 UTC.
        let janFirst2027 = Date(timeIntervalSince1970: 1_798_761_600)
        let lateDecember = janFirst2027.addingTimeInterval(-1)
        XCTAssertEqual(MonthlyLimit.nextCalendarMonthStartUTC(after: lateDecember), janFirst2027)
    }

    func testNextCalendarMonthStartAtExactBoundary() {
        // Exactly Jul 1 00:00:00 UTC belongs to July — the next start is Aug 1, not itself.
        XCTAssertEqual(MonthlyLimit.nextCalendarMonthStartUTC(after: julyFirst), augustFirst)
    }
}
