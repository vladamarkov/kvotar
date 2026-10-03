import Foundation

/// The local calendar day the popover's `LOCAL ACTIVITY · TODAY` section covers (STEP_177 —
/// REV-92 / Baseline §15.2 "Daily local report"). Pure calendar arithmetic over an injected
/// clock and calendar, so the day boundary is testable across DST transitions and timezone
/// changes without touching `Calendar.current` in a test.
///
/// **Never `+ 86 400 s`.** A day is 23 or 25 hours twice a year, and a machine moved between
/// zones has a different midnight than it had an hour ago. Every boundary here comes from the
/// calendar's own date arithmetic.
public enum LocalDayPolicy {

    /// Local midnight at or before `now`.
    public static func dayStart(now: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: now)
    }

    /// The next local midnight strictly after `now` — when the report's population empties and
    /// a fresh read is owed. On the rare calendar that cannot add a day the fallback searches
    /// forward for the next 00:00, and only as a last resort adds a nominal day.
    public static func nextBoundary(after now: Date, calendar: Calendar) -> Date {
        let start = dayStart(now: now, calendar: calendar)
        if let next = calendar.date(byAdding: .day, value: 1, to: start) {
            let midnight = calendar.startOfDay(for: next)
            if midnight > now { return midnight }
        }
        if let next = calendar.nextDate(after: now,
                                        matching: DateComponents(hour: 0, minute: 0, second: 0),
                                        matchingPolicy: .nextTime) {
            return next
        }
        return now.addingTimeInterval(86_400)
    }

    /// The half-open population `[dayStart, now)` the report reads. `now` is the upper bound
    /// so a future-dated event (clock skew, a file written by a machine ahead of ours) is
    /// excluded rather than counted against a day that has not happened yet.
    public static func population(now: Date, calendar: Calendar) -> DateInterval {
        let start = dayStart(now: now, calendar: calendar)
        return DateInterval(start: start, end: max(start, now))
    }
}
