import Foundation
import KvotarCore
@testable import KvotarUI

/// Shared fixture builders for the STEP_159 experience suites (`HistoryExperience…Tests`).
/// Same fixed clock as `HistoryDisplayTests`; Core types are constructed directly — no store.
/// Time-of-day fixtures come in two flavours on purpose: `days`/`block(at:)` are UTC-anchored
/// (day-bucket identity is by span, so the suite is timezone-independent), while `localBlock`
/// is local-midnight-anchored for the rhythm/hour tests, whose subject *is* the local clock.
enum HXFix {

    /// 2026-08-16 12:00:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_786_881_600)
    /// 2026-08-16 00:00:00 UTC — the anchor `days(_:)` builds back from.
    static let utcMidnight = Date(timeIntervalSince1970: 1_786_838_400)
    /// The zone the UTC-anchored builders work in, so a fixture's instants do not move with the
    /// machine running the suite.
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()
    /// The calendar the recap suites pin, so `experience(_:)`'s week boundaries are fixed.
    static var recapCalendar: Calendar { utcCalendar }

    // MARK: - Core leaves

    static func totals(model: String? = "claude-sonnet-4-6", input: Int = 0, output: Int = 0,
                       cacheCreation: Int = 0, cacheRead: Int = 0) -> SQLiteStore.ModelTokenTotals {
        SQLiteStore.ModelTokenTotals(model: model, inputTokens: input, outputTokens: output,
                                     cacheCreationTokens: cacheCreation, cacheReadTokens: cacheRead)
    }

    static func mv(_ model: String?, _ value: Double,
                   fallback: Bool = false) -> HistoryReport.ModelValue {
        HistoryReport.ModelValue(model: model, value: value, pricedAtFallback: fallback)
    }

    /// `days(_:)` with a value on every day (and optionally a fallback-priced model), so the
    /// recap's `This week` table has something to sum.
    static func valuedDays(_ tokens: [Int], values: [Double],
                           fallbackOn: Set<Int> = [],
                           projects: [Int: [HistoryReport.DayProject]] = [:]) -> [HistoryReport.Day] {
        days(tokens).enumerated().map { index, d in
            HistoryReport.Day(start: d.start, isPartial: d.isPartial, tokens: d.tokens,
                              sessions: d.sessions, hitLimit: d.hitLimit,
                              value: values[index],
                              modelValues: [mv("m", values[index],
                                               fallback: fallbackOn.contains(index))],
                              projects: projects[index] ?? [])
        }
    }

    /// One week bucket ending `daysBack` days before `now` (newest first at `daysBack: 0`).
    static func week(daysBack: Int, tokens: Int, value: Double = 0,
                     partial: Bool = false) -> HistoryReport.Week {
        let end = now.addingTimeInterval(-Double(daysBack) * 86_400)
        return HistoryReport.Week(start: end.addingTimeInterval(-7 * 86_400), end: end,
                                  isPartial: partial, tokens: tokens, value: value)
    }

    /// A run of days ending on `now`'s UTC day, oldest first — the reader's shape. One token
    /// entry per day; the first is flagged partial, as the clipped oldest slot is.
    static func days(_ tokens: [Int], sessions: [Int]? = nil,
                     hitLimitOn: Set<Int> = []) -> [HistoryReport.Day] {
        tokens.enumerated().map { index, count in
            HistoryReport.Day(
                start: dayStart(index: index, of: tokens.count),
                isPartial: index == 0,
                tokens: count,
                sessions: sessions?[index] ?? (count > 0 ? 1 : 0),
                hitLimit: hitLimitOn.contains(index))
        }
    }

    /// The `start` the `days(_:)` builder gives column `index` in a list of `count` days.
    static func dayStart(index: Int, of count: Int) -> Date {
        utcMidnight.addingTimeInterval(-Double(count - 1 - index) * 86_400)
    }

    /// The same list with one day rebuilt to carry the STEP_158/159 extras.
    static func withDay(_ list: [HistoryReport.Day], at index: Int,
                        modelTotals: [SQLiteStore.ModelTokenTotals] = [],
                        modelValues: [HistoryReport.ModelValue] = [],
                        value: Double = 0,
                        projects: [HistoryReport.DayProject] = []) -> [HistoryReport.Day] {
        var days = list
        let d = days[index]
        days[index] = HistoryReport.Day(start: d.start, isPartial: d.isPartial, tokens: d.tokens,
                                        sessions: d.sessions, hitLimit: d.hitLimit,
                                        modelTotals: modelTotals, value: value,
                                        modelValues: modelValues, projects: projects)
        return days
    }

    /// One block at an absolute instant. `lockout` nil is the honest unknown and takes the
    /// width with it — the reader's shape when the rollups cannot supply the reset.
    static func block(at firedAt: Date, lockout: Int? = 3600,
                      width: Int? = 18_000) -> HistoryReport.LimitBlock {
        HistoryReport.LimitBlock(
            firedAt: firedAt,
            resetAt: lockout.map { firedAt.addingTimeInterval(Double($0)) },
            windowSeconds: lockout == nil ? nil : width)
    }

    /// A block `daysBack` days before `now` at a given **local** clock hour — for the
    /// rhythm/hour tests, whose subject is the local clock.
    static func localBlock(daysBack: Double, hour: Int, minute: Int = 0, lockout: Int? = 3600,
                           width: Int? = 18_000) -> HistoryReport.LimitBlock {
        let midnight = Calendar.current.startOfDay(for: now)
        return block(at: midnight.addingTimeInterval(-daysBack * 86_400 + Double(hour) * 3600
                                                     + Double(minute) * 60),
                     lockout: lockout, width: width)
    }

    static func observation(at: Date, _ state: HistoryReport.CriticalObservation.State,
                            util: Double? = nil) -> HistoryReport.CriticalObservation {
        HistoryReport.CriticalObservation(at: at, state: state, utilizationPct: util)
    }

    static func change(at: Date, kind: HistoryReport.AccountChange.Kind = .planChanged,
                       windowType: String? = nil, old: String? = nil,
                       new: String? = nil) -> HistoryReport.AccountChange {
        HistoryReport.AccountChange(at: at, kind: kind, windowType: windowType,
                                    oldValue: old, newValue: new)
    }

    /// A weekly slot with `count` qualifying cycles (Δ 20 pts, fully seen, $248 each) — enough
    /// for the REV-72 summary to earn its figure row at `count >= 3`.
    static func qualifyingSeries(count: Int = 3) -> WorkPerPercentSeries {
        let points = (0..<count).map { index -> WorkPerPercentSeries.Point in
            let start = now.addingTimeInterval(-Double(index + 1) * 7 * 86_400)
            return WorkPerPercentSeries.Point(
                start: start, end: start.addingTimeInterval(7 * 86_400), isComplete: true,
                deltaPct: 20, dollars: 248, tokens: 78_000_000, perModel: [],
                coverage: 1, unexplainedShare: 0, crossWindowRatio: nil)
        }
        return WorkPerPercentSeries(slots: [.init(isPrimary: false, windowSeconds: 604_800,
                                                  byDay: false, points: points)], markers: [])
    }

    // MARK: - Tool reports

    static func tool(_ tool: Tool = .claude, sessions: Int = 3, totalTokens: Int = 1_500_000,
                     modelTotals: [SQLiteStore.ModelTokenTotals]? = nil,
                     modelValues: [HistoryReport.ModelValue]? = nil,
                     cacheHit: Double? = 0.71, value: Double = 12.5,
                     projects: [HistoryReport.Project] = [],
                     topSessions: [HistoryReport.Session] = [],
                     weeks: [HistoryReport.Week] = [],
                     evidenceFrom: Date? = nil,
                     accountChanges: [HistoryReport.AccountChange] = [],
                     limitBlocks: [HistoryReport.LimitBlock] = [],
                     watchingSince: Date? = nil,
                     workPerPercent: WorkPerPercentSeries = .empty,
                     days: [HistoryReport.Day] = [],
                     workByHour: [Int] = [],
                     criticalObservations: [HistoryReport.CriticalObservation] = [],
                     quotaWindows: [QuotaWindowOutcome] = [],
                     weeklyLimits: [WeeklyLimitOutcome] = [])
        -> HistoryReport.ToolReport {
        let defaultModel = tool == .codex ? nil : "claude-sonnet-4-6"
        return HistoryReport.ToolReport(
            tool: tool, sessions: sessions, totalTokens: totalTokens,
            modelTotals: modelTotals ?? [totals(model: defaultModel, input: totalTokens)],
            cacheHitRatio: cacheHit, value: value, projects: projects, topSessions: topSessions,
            weeks: weeks, evidenceFrom: evidenceFrom,
            accountChanges: accountChanges, limitBlocks: limitBlocks,
            watchingSince: watchingSince, workPerPercent: workPerPercent, days: days,
            workByHour: workByHour, criticalObservations: criticalObservations,
            modelValues: modelValues ?? [mv(defaultModel, value)],
            quotaWindows: quotaWindows, weeklyLimits: weeklyLimits)
    }

    /// One weekly limit instance (STEP_227/228). `endedAt` is when it ended — its scheduled reset
    /// unless `ending` says the provider ended it early, in which case `scheduled` is the reset it
    /// was due at. `gap` is how long before the end the last reading landed.
    static func weeklyLimit(_ tool: Tool = .claude,
                            _ limit: WeeklyLimitOutcome.Limit = .overall,
                            endedAt: Date, used: Double, gap: TimeInterval = 0,
                            ending: QuotaWindowOutcome.Ending = .reachedReset,
                            scheduled: Date? = nil, hitLimit: Bool = false,
                            now: Date = HXFix.now) -> WeeklyLimitOutcome {
        let resetsAt = scheduled ?? endedAt
        let last = endedAt.addingTimeInterval(-gap)
        let outcome = QuotaWindowOutcome(
            id: "\(tool.rawValue)-\(Int(resetsAt.timeIntervalSince1970))",
            tool: tool, resetsAt: resetsAt, windowSeconds: 604_800, widthEvidence: .recorded,
            start: resetsAt.addingTimeInterval(-604_800),
            firstObservedAt: resetsAt.addingTimeInterval(-604_800), lastObservedAt: last,
            observationCount: 40, highWaterPct: used, hitLimitAt: hitLimit ? last : nil,
            completion: now < endedAt ? .current
                : (gap <= QuotaWindowOutcomes.fullObservationTolerance || hitLimit
                    ? .completedFull : .completedPartial),
            ending: ending, endedAt: endedAt)
        return WeeklyLimitOutcome(limit: limit, outcome: outcome)
    }

    // MARK: - Quota windows (STEP_181 outcomes, STEP_182 display)

    /// One provider-observed window. `daysBack` places its **reset**; the width places its start.
    /// `lastSeenBefore` is how long before the reset the last reading landed — the one input that
    /// decides completed-full versus completed-partial, so a fixture never has to guess.
    static func quotaWindow(_ tool: Tool = .claude, daysBack: Double, hour: Int = 12,
                            width: Int? = 18_000, used: Double = 62,
                            widthEvidence: QuotaWindowOutcome.WidthEvidence? = nil,
                            lastSeenBefore: TimeInterval = 0,
                            readings: Int = 12,
                            completion: QuotaWindowOutcome.Completion = .completedFull,
                            ending: QuotaWindowOutcome.Ending = .reachedReset,
                            hitLimit: Bool = false) -> QuotaWindowOutcome {
        var components = utcCalendar.dateComponents(
            [.year, .month, .day], from: now.addingTimeInterval(-daysBack * 86_400))
        components.hour = hour
        let resetsAt = utcCalendar.date(from: components) ?? now
        let start = width.map { resetsAt.addingTimeInterval(-TimeInterval($0)) }
        let last = resetsAt.addingTimeInterval(-lastSeenBefore)
        return QuotaWindowOutcome(
            id: "\(tool.rawValue)-\(Int(resetsAt.timeIntervalSince1970))",
            tool: tool, resetsAt: resetsAt, windowSeconds: width,
            widthEvidence: widthEvidence ?? (width == nil ? .unknown : .recorded), start: start,
            firstObservedAt: start ?? last.addingTimeInterval(-3600), lastObservedAt: last,
            observationCount: readings, highWaterPct: used,
            hitLimitAt: hitLimit ? last : nil, completion: completion, ending: ending)
    }

    /// A tool with no work at all — the empty-corpus shape.
    static func blank(_ tool: Tool = .codex, watchingSince: Date? = nil,
                      accountChanges: [HistoryReport.AccountChange] = [],
                      limitBlocks: [HistoryReport.LimitBlock] = [])
        -> HistoryReport.ToolReport {
        HXFix.tool(tool, sessions: 0, totalTokens: 0, modelTotals: [], modelValues: [],
                   cacheHit: nil, value: 0, accountChanges: accountChanges,
                   limitBlocks: limitBlocks, watchingSince: watchingSince)
    }

    static func report(_ tools: [HistoryReport.ToolReport],
                       pricing: (String, String)? = ("1.4", "2026-08-11")) -> HistoryReport {
        HistoryReport(periodStart: now.addingTimeInterval(-30 * 86_400), periodEnd: now,
                      tools: tools, pricingVersion: pricing?.0, pricingUpdated: pricing?.1)
    }

    // MARK: - Experience accessors

    static func experience(_ tools: [HistoryReport.ToolReport],
                           pricing: (String, String)? = ("1.4", "2026-08-11"))
        -> HistoryExperience {
        HistoryDisplay.experience(report(tools, pricing: pricing), now: now,
                                  calendar: recapCalendar)
    }

    static func pages(_ tools: [HistoryReport.ToolReport],
                      _ provider: HistoryExperience.Provider)
        -> HistoryExperience.ProviderPages {
        experience(tools).pages(provider)
    }

    /// Every `String` reachable from a value, via reflection — the banned-copy sweep walks the
    /// whole payload rather than trusting a hand-kept list of fields.
    static func allStrings(of value: Any) -> [String] {
        var result: [String] = []
        func walk(_ any: Any) {
            if let string = any as? String {
                result.append(string)
                return
            }
            for child in Mirror(reflecting: any).children { walk(child.value) }
        }
        walk(value)
        return result
    }
}
