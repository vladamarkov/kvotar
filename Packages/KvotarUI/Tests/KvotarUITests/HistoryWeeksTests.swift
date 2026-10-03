import XCTest
@testable import KvotarUI

/// The recap's week arithmetic (STEP_182 — UI Spec §6.2). Monday–Sunday, local, and never
/// `+ 604 800 s`: the three cases that break naive week maths are a locale whose own week starts
/// on Sunday, a year boundary, and a week holding a DST transition.
final class HistoryWeeksTests: XCTestCase {

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ iso: String, _ zone: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: zone)!
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: iso)!
    }

    private func stamp(_ date: Date, _ zone: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: zone)!
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Monday is pinned, not read

    /// `Calendar.firstWeekday` is Sunday in `en_US` — the dogfood machine's own locale — and §6.2
    /// says Monday–Sunday. Reading the locale's answer would give an American reader a different
    /// week than a European one, off the same data.
    func testWeekStartIsMondayEvenWhenTheLocaleSaysSunday() {
        var american = calendar("America/New_York")
        american.locale = Locale(identifier: "en_US")
        american.firstWeekday = 1                       // Sunday, as en_US really is
        let sunday = date("2026-08-16 12:00", "America/New_York")
        XCTAssertEqual(
            stamp(HistoryWeeks.weekStart(containing: sunday, calendar: american),
                  "America/New_York"),
            "2026-08-10 00:00",
            "a Sunday belongs to the week that began the Monday before it")
    }

    func testEveryWeekdayResolvesToItsOwnMonday() {
        let zone = "Europe/Berlin"
        let cal = calendar(zone)
        for day in 10...16 {
            let noon = date(String(format: "2026-08-%02d 12:00", day), zone)
            XCTAssertEqual(stamp(HistoryWeeks.weekStart(containing: noon, calendar: cal), zone),
                           "2026-08-10 00:00", "Aug \(day)")
        }
        let nextMonday = date("2026-08-17 00:00", zone)
        XCTAssertEqual(stamp(HistoryWeeks.weekStart(containing: nextMonday, calendar: cal), zone),
                       "2026-08-17 00:00", "midnight Monday is its own week's start")
    }

    // MARK: - The three arithmetic traps

    /// A week crossing New Year is still seven days: the week-of-year numbering changes, the
    /// span does not.
    func testWeeksCrossAYearBoundary() {
        let zone = "Europe/Berlin"
        let cal = calendar(zone)
        let newYear = date("2027-01-01 09:00", zone)     // a Friday
        let start = HistoryWeeks.weekStart(containing: newYear, calendar: cal)
        XCTAssertEqual(stamp(start, zone), "2026-12-28 00:00")
        XCTAssertEqual(stamp(HistoryWeeks.nextWeekStart(after: start, calendar: cal), zone),
                       "2027-01-04 00:00")
    }

    /// Europe/Berlin loses an hour on 2026-03-29. `start + 604 800 s` would land at 01:00 on the
    /// following Monday; the week must still end at local midnight.
    func testADaylightSavingWeekStillEndsAtLocalMidnight() {
        let zone = "Europe/Berlin"
        let cal = calendar(zone)
        let start = HistoryWeeks.weekStart(containing: date("2026-03-29 12:00", zone),
                                           calendar: cal)
        XCTAssertEqual(stamp(start, zone), "2026-03-23 00:00")
        let end = HistoryWeeks.nextWeekStart(after: start, calendar: cal)
        XCTAssertEqual(stamp(end, zone), "2026-03-30 00:00")
        XCTAssertEqual(end.timeIntervalSince(start), 7 * 86_400 - 3600,
                       "the spring-forward week really is 167 hours long")
    }

    // MARK: - Which weeks are browsable

    func testCompletedWeeksExcludeTheCurrentOneAndFlagTheClippedOldest() {
        let zone = "Europe/Berlin"
        let cal = calendar(zone)
        let now = date("2026-08-16 12:00", zone)                 // Sunday
        let periodStart = date("2026-07-17 12:00", zone)
        let weeks = HistoryWeeks.completedWeeks(periodStart: periodStart, periodEnd: now,
                                                now: now, calendar: cal)
        XCTAssertEqual(weeks.map { stamp($0.start, zone) },
                       ["2026-08-03 00:00", "2026-07-27 00:00",
                        "2026-07-20 00:00", "2026-07-13 00:00"],
                       "newest first, and the current Aug 10–16 week is absent")
        XCTAssertEqual(weeks.map(\.isClipped), [false, false, false, true])
        XCTAssertEqual(stamp(weeks.last!.observed.start, zone), "2026-07-17 12:00",
                       "the clipped week can only speak for the part inside the horizon")
    }

    /// A horizon shorter than one completed week has nothing to recap — the mode says so rather
    /// than describing a week it cannot see.
    func testAHorizonInsideOneWeekYieldsNoCompletedWeek() {
        let zone = "Europe/Berlin"
        let cal = calendar(zone)
        let now = date("2026-08-13 09:00", zone)                 // Thursday
        let weeks = HistoryWeeks.completedWeeks(
            periodStart: date("2026-08-11 09:00", zone), periodEnd: now, now: now, calendar: cal)
        XCTAssertTrue(weeks.isEmpty)
    }
}
