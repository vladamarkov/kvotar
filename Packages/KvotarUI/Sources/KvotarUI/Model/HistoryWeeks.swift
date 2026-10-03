import Foundation

/// The completed local **Monday–Sunday** weeks Weekly recap may describe (STEP_182 — REV-93 §2.2 /
/// UI Spec §6.2). Pure calendar arithmetic over an injected clock and calendar, modelled on
/// `KvotarCore.LocalDayPolicy`, so a week boundary is testable across a DST transition, a year
/// boundary and a non-UTC zone without touching `Calendar.current` in a test.
///
/// **Never `+ 604 800 s`.** A week holding a DST transition is 167 or 169 hours, and a machine
/// moved between zones has a different Monday midnight than it had an hour ago. Every boundary
/// here comes from the calendar's own date arithmetic.
///
/// **Monday is pinned, not read.** `Calendar.firstWeekday` is locale-dependent — Sunday in
/// `en_US`, which is the dogfood machine's own locale — and §6.2 says Monday–Sunday. Reading the
/// locale's answer would silently give an American reader a different week than a European one,
/// so the week start is forced and the injected calendar supplies only the time zone and the
/// day arithmetic.
enum HistoryWeeks {

    /// One completed week, `[start, end)`, and how much of the report's horizon it sits inside.
    struct Week: Equatable {
        let start: Date
        let end: Date
        /// The week is not wholly inside `[periodStart, periodEnd)` — its oldest days are outside
        /// the evidence the report actually read, so any whole-week conclusion is withheld.
        let isClipped: Bool
        /// The part of the week the report can speak for: `[max(start, periodStart), end)`.
        let observed: DateInterval
    }

    /// A calendar with the same zone as `calendar` but the week pinned to Monday.
    static func mondayCalendar(_ calendar: Calendar) -> Calendar {
        var pinned = calendar
        pinned.firstWeekday = 2
        // A week belongs to the year holding its Thursday (ISO-8601). Irrelevant to the spans
        // below, but it keeps `pinned` internally consistent for any future week-of-year read.
        pinned.minimumDaysInFirstWeek = 4
        return pinned
    }

    /// Local Monday 00:00 at or before `date`.
    static func weekStart(containing date: Date, calendar: Calendar) -> Date {
        let pinned = mondayCalendar(calendar)
        let day = pinned.startOfDay(for: date)
        // `weekday` is 1 = Sunday … 7 = Saturday whatever `firstWeekday` says, so the offset is
        // computed rather than taken from the component — `dateInterval(of: .weekOfYear)` would
        // also work, but it returns nil on a calendar that cannot form the interval and this
        // cannot.
        let weekday = pinned.component(.weekday, from: day)
        let backToMonday = (weekday + 5) % 7      // Mon → 0, Tue → 1, … Sun → 6
        guard backToMonday > 0 else { return day }
        guard let start = pinned.date(byAdding: .day, value: -backToMonday, to: day) else {
            return day
        }
        return pinned.startOfDay(for: start)
    }

    /// The Monday after `start`. Uses day arithmetic and re-normalises to midnight, so a week
    /// containing a DST change still ends at 00:00 local.
    static func nextWeekStart(after start: Date, calendar: Calendar) -> Date {
        let pinned = mondayCalendar(calendar)
        guard let next = pinned.date(byAdding: .day, value: 7, to: start) else {
            return start.addingTimeInterval(7 * 86_400)
        }
        return pinned.startOfDay(for: next)
    }

    /// Every completed Monday–Sunday week that intersects the report's fixed horizon, **newest
    /// first**.
    ///
    /// A week is *completed* when it ended at or before the start of the week holding `now` — the
    /// current partial week is excluded structurally, not filtered out later, which is what makes
    /// "current-week data never appears" a property of the type rather than of the copy.
    ///
    /// A week is *browsable* while it intersects `[periodStart, periodEnd)`; the oldest such week
    /// is normally clipped by the 30-day horizon and says so.
    static func completedWeeks(periodStart: Date, periodEnd: Date, now: Date,
                              calendar: Calendar) -> [Week] {
        let currentStart = weekStart(containing: now, calendar: calendar)
        guard currentStart > periodStart else { return [] }

        var weeks: [Week] = []
        var start = weekStart(containing: periodStart, calendar: calendar)
        // A guard against a pathological calendar returning a non-advancing date rather than a
        // real bound: the horizon is 30 days, so five iterations is already generous.
        var guardCount = 0
        while start < currentStart, guardCount < 64 {
            guardCount += 1
            let end = nextWeekStart(after: start, calendar: calendar)
            guard end > start else { break }
            defer { start = end }
            // Intersects the horizon, and ended before the current week began.
            guard end > periodStart, start < periodEnd else { continue }
            let observedStart = max(start, periodStart)
            weeks.append(Week(start: start, end: end,
                              isClipped: start < periodStart,
                              observed: DateInterval(start: observedStart,
                                                     end: max(observedStart, end))))
        }
        return weeks.reversed()
    }
}
