import XCTest
@testable import KvotarCore

/// STEP_177 — the local-day boundary is calendar arithmetic, never `+ 86 400 s`.
final class LocalDayPolicyTests: XCTestCase {

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    func testSpringForwardDayIsTwentyThreeHours() {
        // Europe/Berlin, 2026-03-29: 02:00 CET jumps to 03:00 CEST.
        let cal = calendar("Europe/Berlin")
        let noon = date("2026-03-29T10:00:00Z")   // 12:00 CEST
        let start = LocalDayPolicy.dayStart(now: noon, calendar: cal)
        let next = LocalDayPolicy.nextBoundary(after: noon, calendar: cal)
        XCTAssertEqual(start, date("2026-03-28T23:00:00Z"))   // 00:00 CET
        XCTAssertEqual(next, date("2026-03-29T22:00:00Z"))    // 00:00 CEST next day
        XCTAssertEqual(next.timeIntervalSince(start), 23 * 3600)
    }

    func testFallBackDayIsTwentyFiveHours() {
        // Europe/Berlin, 2026-10-25: 03:00 CEST falls back to 02:00 CET.
        let cal = calendar("Europe/Berlin")
        let noon = date("2026-10-25T11:00:00Z")   // 12:00 CET
        let start = LocalDayPolicy.dayStart(now: noon, calendar: cal)
        let next = LocalDayPolicy.nextBoundary(after: noon, calendar: cal)
        XCTAssertEqual(start, date("2026-10-24T22:00:00Z"))   // 00:00 CEST
        XCTAssertEqual(next, date("2026-10-25T23:00:00Z"))    // 00:00 CET next day
        XCTAssertEqual(next.timeIntervalSince(start), 25 * 3600)
    }

    func testOrdinaryDayIsTwentyFourHoursAndBoundaryIsStrictlyAfterNow() {
        let cal = calendar("Europe/Berlin")
        let now = date("2026-09-10T12:00:00Z")
        let start = LocalDayPolicy.dayStart(now: now, calendar: cal)
        let next = LocalDayPolicy.nextBoundary(after: now, calendar: cal)
        XCTAssertEqual(next.timeIntervalSince(start), 24 * 3600)
        XCTAssertGreaterThan(next, now)
        // Exactly at midnight the boundary is the *next* midnight, not now itself.
        let atMidnight = LocalDayPolicy.nextBoundary(after: start, calendar: cal)
        XCTAssertEqual(atMidnight, next)
    }

    func testTimezoneChangeMovesTheBoundary() {
        let now = date("2026-09-10T12:00:00Z")
        let berlin = LocalDayPolicy.dayStart(now: now, calendar: calendar("Europe/Berlin"))
        let tokyo = LocalDayPolicy.dayStart(now: now, calendar: calendar("Asia/Tokyo"))
        XCTAssertEqual(berlin, date("2026-09-09T22:00:00Z"))
        XCTAssertEqual(tokyo, date("2026-09-09T15:00:00Z"))
        XCTAssertNotEqual(berlin, tokyo)
    }

    func testPopulationIsHalfOpenAndEndsAtNow() {
        let cal = calendar("UTC")
        let now = date("2026-09-10T14:00:00Z")
        let population = LocalDayPolicy.population(now: now, calendar: cal)
        XCTAssertEqual(population.start, date("2026-09-10T00:00:00Z"))
        XCTAssertEqual(population.end, now)
    }
}
