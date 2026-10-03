import Foundation

/// Computes a `HistoryReport` from the permanent local corpus (STEP_109). Pure aggregation over
/// existing store reads and the one pricing engine — nothing here waits on the launch backfill
/// sweep, so a first-run window shows whatever has landed so far and fills in on the next reload.
///
/// **Never throws.** A failed query yields an empty section for that tool (rows are independent —
/// the window degrades to fewer rows, never a blank page). The one thing it will not do is
/// fabricate: a `nil` cache ratio stays nil, a missing project stays nil.
public struct HistoryReportReader: Sendable {
    private let store: SQLiteStore
    private let valueEngine: EstimatedValueEngine

    public init(store: SQLiteStore, valueEngine: EstimatedValueEngine) {
        self.store = store
        self.valueEngine = valueEngine
    }

    /// The last `HistoryReport.periodDays` days ending at `now`, bucketed by week newest-first.
    /// `calendar` decides where a *local* day begins (STEP_116's day strip and STEP_114's 5-hour
    /// day aggregation both need it); injectable so tests are timezone-independent.
    public func report(now: Date = Date(), calendar: Calendar = .current) async -> HistoryReport {
        let periodEnd = now
        let periodStart = now.addingTimeInterval(-TimeInterval(HistoryReport.periodDays) * 86_400)
        var tools: [HistoryReport.ToolReport] = []
        for tool in Tool.allCases {
            tools.append(await toolReport(tool: tool, from: periodStart, until: periodEnd,
                                          calendar: calendar))
        }
        let stamp = await valueEngine.tableStamp()
        return HistoryReport(periodStart: periodStart, periodEnd: periodEnd, tools: tools,
                             pricingVersion: stamp?.version, pricingUpdated: stamp?.updated)
    }

    private func toolReport(tool: Tool, from start: Date, until end: Date,
                            calendar: Calendar) async -> HistoryReport.ToolReport {
        let modelTotals = (try? await store.tokenTotalsByModel(tool: tool, since: start, until: end)) ?? []
        // Each period model row priced on its own through the one engine (STEP_159 — REV-84
        // §5.3): the same per-row formula `value` reduces over, so the list sums to it.
        var modelValues: [HistoryReport.ModelValue] = []
        for totals in modelTotals {
            modelValues.append(HistoryReport.ModelValue(
                model: totals.model, value: await valueEngine.value(for: [totals], tool: tool)))
        }
        // Active-in-period, subagents folded in — the same semantics as the popover's Sessions row.
        let sessions = (try? await store.sessionCount(tool: tool, since: start)) ?? 0
        let value = (try? await valueEngine.value(for: tool, from: start, until: end)) ?? 0

        // Project rows are grouped by `ProjectGrouping` **before** truncation: sub-folders of a
        // stored path roll into it, temp/home directories fold into one nil ("no project") row.
        // Grouping after the top-N cut could drop a child whose parent survived.
        let rawProjects = (try? await store.projectTotals(tool: tool, since: start, until: end)) ?? []
        let allPaths = rawProjects.map(\.project)
        var grouped: [String?: (sessions: Int, tokens: Int)] = [:]
        for row in rawProjects {
            let key = ProjectGrouping.canonical(row.project, among: allPaths)
            let tokens = DisplayedTokens.sum(row.totals, tool: tool)
            let prior = grouped[key] ?? (0, 0)
            grouped[key] = (prior.sessions + row.sessionCount, prior.tokens + tokens)
        }
        let projects = grouped
            .map { HistoryReport.Project(name: $0.key, sessions: $0.value.sessions, tokens: $0.value.tokens) }
            .filter { $0.tokens > 0 }
            .sorted { $0.tokens > $1.tokens }
            .prefix(HistoryReport.topRowLimit)

        // Session values are priced **per event model** (the session-level `model` is display
        // only — pricing at it is the mis-attribution STEP_93 removed), and only for the top N, so
        // this is ≤5 session-scoped queries, not one per session in the corpus.
        let sessionRows = ((try? await store.sessionTotals(tool: tool, since: start, until: end)) ?? [])
            .map { ($0, DisplayedTokens.sum($0.totals, tool: tool)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(HistoryReport.topRowLimit)
        var topSessions: [HistoryReport.Session] = []
        for (row, tokens) in sessionRows {
            let byModel = (try? await store.tokenTotalsByModel(
                tool: tool, since: start, until: end, sessionId: row.sessionId)) ?? []
            let sessionValue = await valueEngine.value(for: byModel, tool: tool)
            // Same grouping as the project rows, so a session's label names the row its
            // tokens were counted under.
            topSessions.append(HistoryReport.Session(
                sessionId: row.sessionId,
                project: ProjectGrouping.canonical(row.project, among: allPaths),
                model: row.model,
                lastSeenAt: row.lastSeenAt, tokens: tokens, value: sessionValue))
        }

        let weeks = await weekBuckets(tool: tool, from: start, until: end)
        let evidenceFrom = (try? await store.oldestEventDate(tool: tool)) ?? nil

        // Events — poll-side evidence, recorded from the day the app starts watching.
        let accountChanges = await accountChanges(tool: tool, from: start, until: end)
        // One read, three uses: the block rows, the Events count/newest date derived from them,
        // and the strip's blocked days.
        let hits = (try? await store.limitHits(tool: tool, since: start, until: end)) ?? []
        let limitBlocks = await limitBlocks(tool: tool, hits: hits)
        let watchingSince = (try? await store.watchingSince(tool: tool)) ?? nil
        // Recorded entries into the four critical states (STEP_158 — REV-84 §3.2). The raw
        // string is typed here, the reader being the owning component; an unfamiliar stored
        // state never matches the query's IN-list, and this guard is the second belt.
        let criticalObservations = ((try? await store.criticalStateEntries(
            tool: tool, since: start, until: end)) ?? [])
            .compactMap { entry in
                HistoryReport.CriticalObservation.State(rawValue: entry.toState).map {
                    HistoryReport.CriticalObservation(at: entry.at, state: $0,
                                                      utilizationPct: entry.utilizationPct)
                }
            }
        let workPerPercent = await workPerPercentSeries(
            tool: tool, from: max(start, watchingSince ?? start), until: end, calendar: calendar)
        // One hourly read, two folds: local calendar days (the strip) and local clock hours (the
        // limits chart). Both are Swift-side, because both grains are the caller's calendar's.
        let hourly = (try? await store.hourlyTokenTotalsByModel(tool: tool, since: start,
                                                                until: end)) ?? []
        // The day's project rows (STEP_178) — a second bounded hourly read, folded on the same
        // calendar, and grouped against the **provider-wide** stored path set rather than this
        // period's, so a day here and the popover's own daily report name a repo the same way
        // (Baseline §15.2: the destination payload is what reconciles the two lists).
        let hourlyProjects = (try? await store.hourlyProjectTotals(tool: tool, since: start,
                                                                   until: end)) ?? []
        let allProjectPaths = (try? await store.distinctProjectPaths(tool: tool)) ?? []
        let days = await dayBuckets(tool: tool, hourly: hourly, hourlyProjects: hourlyProjects,
                                    allProjectPaths: allProjectPaths, from: start, until: end,
                                    limitHits: hits.map(\.firedAt), calendar: calendar)
        let workByHour = Self.hourProfile(hourly: hourly, tool: tool, calendar: calendar)
        // Provider-observed quota windows (STEP_181/186 — REV-93 §4). One bounded series read plus
        // durable discontinuity facts: three types can end a window early, while a recorded width
        // switch can recover the width of legacy Codex rows on either side. `end` is the report
        // clock, so a window whose reset has not passed classifies as current here and nowhere else.
        // Absence of rows is absence of observation: the fold invents nothing for a period the app
        // did not watch.
        let quotaSeries = (try? await store.quotaSeriesRange(tool: tool, since: start,
                                                             until: end)) ?? []
        let quotaBreaks = (try? await store.discontinuityEvents(
            tool: tool, since: start, until: end,
            types: QuotaWindowOutcomes.evidenceEventTypes)) ?? []
        let quotaWindows = QuotaWindowOutcomes.compute(
            tool: tool, points: quotaSeries, discontinuities: quotaBreaks, now: end)
        // Weekly limits (STEP_227 — REV-104 §4): the secondary window and every model allowance's
        // weekly, through the same fold. Two more bounded reads; a failure is an empty list.
        let secondarySeries = (try? await store.quotaSeriesSecondaryRange(
            tool: tool, since: start, until: end)) ?? []
        let modelLimitRows = (try? await store.modelLimitSeriesRange(
            tool: tool, since: start, until: end)) ?? []
        let weeklyLimits = Self.weeklyLimits(
            tool: tool, secondary: secondarySeries, mainWindows: quotaWindows,
            modelRows: modelLimitRows, discontinuities: quotaBreaks, now: end)

        return HistoryReport.ToolReport(
            tool: tool, sessions: sessions,
            totalTokens: DisplayedTokens.total(modelTotals, tool: tool),
            modelTotals: modelTotals,
            cacheHitRatio: CacheHit.ratio(tool: tool, totals: modelTotals),
            value: value,
            projects: Array(projects), topSessions: topSessions,
            weeks: weeks, evidenceFrom: evidenceFrom,
            accountChanges: accountChanges, limitBlocks: limitBlocks,
            watchingSince: watchingSince,
            workPerPercent: workPerPercent, days: days, workByHour: workByHour,
            criticalObservations: criticalObservations, modelValues: modelValues,
            quotaWindows: quotaWindows, weeklyLimits: weeklyLimits)
    }

    // MARK: - Weekly limits (STEP_227 — REV-104 §4)

    /// Folds one tool's weekly readings into limit instances, oldest reset first. Pure.
    ///
    /// - The **overall** weekly is the secondary window (Claude's `seven_day`, a Codex plan's
    ///   second window) folded with the seven-day provider contract and the `weekly` breaks only,
    ///   plus any main window that is itself seven days wide — Codex's, on a plan whose only
    ///   window is weekly — taken from `mainWindows` as already folded, never folded twice.
    /// - Each **model** allowance's seven-day window is folded per `(limit_key, window_slot)`.
    ///   No discontinuity facts are recorded for model allowances, so none end one early.
    /// - Five-hour model windows and monthly limits are not weekly limits and are left out.
    static func weeklyLimits(tool: Tool, secondary: [QuotaSeriesPoint],
                             mainWindows: [QuotaWindowOutcome],
                             modelRows: [SQLiteStore.ModelLimitSeriesRow],
                             discontinuities: [SQLiteStore.DiscontinuityRow],
                             now: Date) -> [WeeklyLimitOutcome] {
        let weekly = QuotaWindowOutcomes.weeklyContractSeconds
        let weeklyBreaks = discontinuities.filter { $0.windowType == "weekly" }

        var result = QuotaWindowOutcomes.compute(
            tool: tool, points: secondary, discontinuities: weeklyBreaks, now: now,
            providerContractSeconds: weekly)
            .map { WeeklyLimitOutcome(limit: .overall, outcome: $0) }
        result += mainWindows
            .filter { $0.windowSeconds == weekly }
            .map { WeeklyLimitOutcome(limit: .overall, outcome: $0) }

        let byLimit = Dictionary(grouping: modelRows.filter { $0.windowSeconds == weekly }) {
            "\($0.limitKey)\u{1F}\($0.windowSlot)"
        }
        for rows in byLimit.values {
            guard let key = rows.first?.limitKey else { continue }
            let name = rows.last(where: { $0.limitName != nil })?.limitName
            let points = rows.map {
                QuotaSeriesPoint(polledAt: $0.polledAt, usedPct: $0.usedPct,
                                 resetsAt: $0.resetsAt, windowSeconds: $0.windowSeconds)
            }
            result += QuotaWindowOutcomes.compute(
                tool: tool, points: points, now: now, providerContractSeconds: weekly)
                .map { WeeklyLimitOutcome(limit: .model(key: key, name: name), outcome: $0) }
        }

        // On a shared reset the overall reads before the model limits beneath it.
        func rank(_ w: WeeklyLimitOutcome) -> Int { w.limit == .overall ? 0 : 1 }
        return result.sorted {
            ($0.outcome.resetsAt, rank($0), $0.id) < ($1.outcome.resetsAt, rank($1), $1.id)
        }
    }

    // MARK: - Account changes (REV-73 / D-81 — STEP_121)

    /// Plan changes and the four observable window facts for the period, oldest first — the rows
    /// the *What changed* sub-heading draws, and the days the strip's second marker lands on.
    ///
    /// **Plan rows are collapsed on the way out** (`PlanChangeStability.settled`). The stored rows
    /// are permanent and none of them is deleted; what the collapse withholds is the *claim* that a
    /// pair of names trading places three times or more inside the period was an account changing.
    /// On the dogfood corpus that turns 232 rows into the three real ones.
    ///
    /// `window_demolished` and `limit_changed` are deliberately **not** here: D-81 names the five
    /// kinds this block re-homes, and the withdrawn window is REV-64's own event with its own story.
    /// They stay on the developer surfaces that already print them.
    func accountChanges(tool: Tool, from start: Date,
                        until end: Date) async -> [HistoryReport.AccountChange] {
        let rows = (try? await store.discontinuityEvents(
            tool: tool, since: start, until: end,
            types: HistoryReport.AccountChange.Kind.allCases.map(\.rawValue))) ?? []
        let plans = PlanChangeStability.settled(
            rows.filter { $0.eventType == HistoryReport.AccountChange.Kind.planChanged.rawValue }
                .map { PlanTransition(at: $0.at, from: $0.oldValue, to: $0.newValue) })
        let kept = Set(plans.map(\.at))
        return rows.compactMap { row in
            guard let kind = HistoryReport.AccountChange.Kind(rawValue: row.eventType) else {
                return nil
            }
            // A collapsed plan row keeps its instant, so identity by instant is enough — and two
            // plan rows at the same second would be the same disagreement anyway.
            if kind == .planChanged, !kept.contains(row.at) { return nil }
            return HistoryReport.AccountChange(at: row.at, kind: kind, windowType: row.windowType,
                                               oldValue: row.oldValue, newValue: row.newValue)
        }
    }

    // MARK: - Limit blocks (REV-73 / D-80 — STEP_120)

    /// Every recorded block, joined to the permanent hourly rollups for the window that blocked and
    /// when it reset. No new column and no migration: `notification_events` stores the instant, and
    /// `history_rollups` stores the reset.
    ///
    /// The join is not a lookup, because `primary_resets_at_last` is the **last** value seen in the
    /// hour. Three rules, all of them earned from the live corpus (REV-73 §2, §4.3):
    ///
    /// 1. **Candidates** come from the fired hour *and the one before it*, keeping only resets at or
    ///    after the block. The earliest is the block's own — a later one belongs to a later window.
    /// 2. **The rollover guard.** If the primary dropped inside the fired hour, that hour's `_last`
    ///    already holds the *next* window's reset, and the blocking reset must lie inside the hour.
    ///    Where it does not, the value was overwritten and the reset is **unknown** — on the corpus
    ///    that is one Codex block whose naive reading is `7d` for a lockout that really lasted four
    ///    minutes, the same class of error REV-73 §2.2 found on the Claude side.
    /// 3. **The width sanity-checks the reset.** `resetAt − windowStart` must be positive and no
    ///    smaller than the lockout it implies. That is what catches the one unusable stored key
    ///    (§2.3). Fail it and both the reset and the width go nil together: without a width there is
    ///    nothing left to check the reset against, and a guessed duration is worse than none.
    func limitBlocks(tool: Tool, hits: [SQLiteStore.LimitHit]) async -> [HistoryReport.LimitBlock] {
        guard let first = hits.first, let last = hits.last else { return [] }
        // One range read covering every block's hour and the hour before it.
        let rollups = (try? await store.historyRollups(
            tool: tool,
            since: first.firedAt.addingTimeInterval(-2 * Self.hour),
            until: last.firedAt.addingTimeInterval(Self.hour))) ?? []
        var byHour: [Int: HistoryRollup] = [:]
        for rollup in rollups { byHour[rollup.hourStart] = rollup }
        return hits.map { Self.limitBlock(hit: $0, rollupsByHour: byHour) }
    }

    static let hour: TimeInterval = 3600

    static func limitBlock(hit: SQLiteStore.LimitHit,
                           rollupsByHour: [Int: HistoryRollup]) -> HistoryReport.LimitBlock {
        let fired = Int(hit.firedAt.timeIntervalSince1970)
        let firedHour = fired - fired % 3600
        let hourRollup = rollupsByHour[firedHour]
        let candidates = [rollupsByHour[firedHour - 3600], hourRollup]
            .compactMap { $0?.primaryResetsAtLast }
            .filter { $0 >= fired }
        guard let reset = candidates.min() else { return .init(firedAt: hit.firedAt, resetAt: nil,
                                                               windowSeconds: nil) }

        // Rule 2 — the fired hour rolled over, so the blocking reset happened inside it.
        if let rollup = hourRollup, let last = rollup.primaryUsedPctLast,
           let max = rollup.primaryUsedPctMax, last < max, reset >= firedHour + 3600 {
            return .init(firedAt: hit.firedAt, resetAt: nil, windowSeconds: nil)
        }

        // Rule 3 — the stored window key is the only width source history keeps, so it is used
        // only to check the reset, never to produce one.
        let width = reset - Int(hit.windowStart.timeIntervalSince1970)
        guard width > 0, reset - fired <= width else {
            return .init(firedAt: hit.firedAt, resetAt: nil, windowSeconds: nil)
        }
        // The reset is a rollup value observed to the second, so a width derived from it carries
        // that jitter — a five-hour window measures 17 999 s on one corpus block. Rounded to the
        // minute here, once, rather than leaving every grain vocabulary downstream to cope.
        return .init(firedAt: hit.firedAt,
                     resetAt: Date(timeIntervalSince1970: TimeInterval(reset)),
                     windowSeconds: Int((Double(width) / 60).rounded()) * 60)
    }

    /// Displayed tokens per **local** clock hour — 24 entries, hour 0 first. Same rows and the same
    /// hour-start convention as the day fold beside it, so the two charts on the page cannot
    /// disagree about which events are in the period.
    static func hourProfile(hourly: [SQLiteStore.HourlyModelTokenTotals], tool: Tool,
                            calendar: Calendar) -> [Int] {
        var profile = [Int](repeating: 0, count: 24)
        for row in hourly {
            let hour = calendar.component(.hour, from: row.hourStart)
            guard hour >= 0, hour < 24 else { continue }
            profile[hour] += DisplayedTokens.sum(row.totals, tool: tool)
        }
        return profile
    }

    /// The `discontinuity_events` types the "Work per 1 % of window" panel places on its timeline
    /// (REV-69 §5, task file): the four window facts, the withdrawn window, the monthly limit and
    /// plan changes — a plan change being the likeliest explanation of a rate step.
    static let markerEventTypes = ["window_added", "window_removed", "window_width_changed",
                                   "early_reset", "window_demolished", "limit_changed",
                                   "plan_changed"]

    /// The REV-69 series over `[start, end)` — the poll-side rollups joined with the hourly local
    /// corpus **priced through this reader's one engine** (a second pricing path is the failure
    /// mode STEP_109 named). Never throws; a failed read yields `.empty`. `calendar` picks the
    /// local day for the 5-hour rollup; injectable so tests are timezone-independent.
    func workPerPercentSeries(tool: Tool, from start: Date, until end: Date,
                              calendar: Calendar = .current) async -> WorkPerPercentSeries {
        guard start < end,
              let rollups = try? await store.historyRollups(tool: tool, since: start, until: end),
              let hourly = try? await store.hourlyTokenTotalsByModel(tool: tool, since: start,
                                                                     until: end)
        else { return .empty }
        var work: [WorkPerPercentSeries.HourlyWork] = []
        work.reserveCapacity(hourly.count)
        for row in hourly {
            let dollars = await valueEngine.value(for: [row.totals], tool: tool)
            work.append(.init(hourStart: row.hourStart, model: row.totals.model, dollars: dollars,
                              tokens: DisplayedTokens.sum(row.totals, tool: tool)))
        }
        let markers = ((try? await store.discontinuityEvents(
            tool: tool, since: start, until: end, types: Self.markerEventTypes)) ?? [])
            .map { WorkPerPercentSeries.Marker(at: $0.at, eventType: $0.eventType,
                                               windowType: $0.windowType,
                                               oldValue: $0.oldValue, newValue: $0.newValue) }
        // The width the provider currently reports for the primary window — Codex carries one on
        // every poll and the rollups do not keep it (STEP_101/P1-28: `poll_snapshots` does).
        let width = (try? await store.readLatestPollSnapshot(tool: tool))??.snapshot.primaryWindowSeconds
        return WorkPerPercentSeries.compute(tool: tool, rollups: rollups, hourly: work,
                                            markers: markers, until: end,
                                            primaryWindowSeconds: width, calendar: calendar)
    }

    /// One entry per **local calendar day** the period touches, oldest first (STEP_116).
    ///
    /// **31 slots, not 30.** The period is `now − 30×24h`, an arbitrary time of day, so it spans 31
    /// local days and the oldest is a sliver — clipped at `start` and flagged, exactly as the
    /// oldest `Week` is. The population is *exactly* `[start, end)`, which is what makes the day
    /// sums equal `totalTokens` and the weekly rows by construction rather than by coincidence.
    /// (Reading a day of slack would complete the oldest day at the price of that identity.)
    ///
    /// **A row is assigned by the hour it starts in** — the STEP_114 convention. In a whole-hour
    /// zone that is exact. In a half-hour zone (UTC+5:30) the hour straddling local midnight lands
    /// wholly in the day its start falls in: up to an hour of skew, never a lost or duplicated
    /// token.
    private func dayBuckets(tool: Tool, hourly: [SQLiteStore.HourlyModelTokenTotals],
                            hourlyProjects: [SQLiteStore.HourlyProjectTokenTotals] = [],
                            allProjectPaths: [String?] = [],
                            from start: Date, until end: Date,
                            limitHits: [Date], calendar: Calendar) async -> [HistoryReport.Day] {
        guard start < end else { return [] }
        var tokens: [Date: Int] = [:]
        // Project rows, folded on the same calendar and grouped once per raw path.
        var projectTokens: [Date: [String?: Int]] = [:]
        var canonicalCache: [String: String?] = [:]
        for row in hourlyProjects {
            let day = calendar.startOfDay(for: row.hourStart)
            let key: String?
            if let raw = row.project {
                if let cached = canonicalCache[raw] {
                    key = cached
                } else {
                    let resolved = ProjectGrouping.canonical(raw, among: allProjectPaths)
                    canonicalCache[raw] = resolved
                    key = resolved
                }
            } else {
                key = nil
            }
            projectTokens[day, default: [:]][key, default: 0] +=
                DisplayedTokens.sum(row.totals, tool: tool)
        }
        // The same rows folded once more, keeping the model dimension (STEP_158): the selected-day
        // detail needs per-model totals and a day value, and both must reconcile with the strip by
        // construction — one population, two folds, never a second query or pricing path.
        var modelTotals: [Date: [String?: SQLiteStore.ModelTokenTotals]] = [:]
        for row in hourly {
            let day = calendar.startOfDay(for: row.hourStart)
            tokens[day, default: 0] += DisplayedTokens.sum(row.totals, tool: tool)
            modelTotals[day, default: [:]][row.totals.model] =
                Self.merged(modelTotals[day]?[row.totals.model], row.totals)
        }

        let hours = (try? await store.sessionActivityHours(tool: tool, since: start,
                                                           until: end)) ?? []
        var sessions: [Date: Set<String>] = [:]
        for hour in hours {
            sessions[calendar.startOfDay(for: hour.hourStart), default: []].insert(hour.sessionId)
        }

        let blocked = Set(limitHits.map { calendar.startOfDay(for: $0) })

        var days: [HistoryReport.Day] = []
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)
        var cursor = firstDay
        // `byAdding: .day` rather than +86_400, so a DST day is still one day.
        while cursor <= lastDay {
            let dayTotals = (modelTotals[cursor]?.values).map(Array.init) ?? []
            let sortedTotals = dayTotals.sorted {
                let (a, b) = (DisplayedTokens.sum($0, tool: tool),
                              DisplayedTokens.sum($1, tool: tool))
                return a == b ? ($0.model ?? "") < ($1.model ?? "") : a > b
            }
            // Each model row priced on its own (STEP_159 — REV-84 §5.1): the day value is
            // their sum in the same order, so the detail rows and their total cannot disagree.
            var dayModelValues: [HistoryReport.ModelValue] = []
            for totals in sortedTotals {
                dayModelValues.append(HistoryReport.ModelValue(
                    model: totals.model, value: await valueEngine.value(for: [totals], tool: tool),
                    pricedAtFallback: await valueEngine.isPricedAtFallback(model: totals.model,
                                                                           tool: tool)))
            }
            let dayProjects = (projectTokens[cursor] ?? [:])
                .map { HistoryReport.DayProject(project: $0.key, tokens: $0.value) }
                .sorted { $0.tokens == $1.tokens ? ($0.project ?? "") < ($1.project ?? "")
                                                 : $0.tokens > $1.tokens }
            days.append(HistoryReport.Day(
                start: cursor == firstDay ? start : cursor,
                isPartial: cursor == firstDay,
                tokens: tokens[cursor] ?? 0,
                sessions: sessions[cursor]?.count ?? 0,
                hitLimit: blocked.contains(cursor),
                modelTotals: sortedTotals,
                value: dayModelValues.reduce(0) { $0 + $1.value },
                modelValues: dayModelValues,
                projects: dayProjects))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// Sums two per-model totals rows — the pure fold behind the day-grain model grouping
    /// (STEP_158). Every column adds, including the 1-hour cache subset, so the per-row tier
    /// rule survives the grouping exactly as it survives SQL's `GROUP BY` in the period reads.
    private static func merged(_ a: SQLiteStore.ModelTokenTotals?,
                               _ b: SQLiteStore.ModelTokenTotals) -> SQLiteStore.ModelTokenTotals {
        guard let a else { return b }
        return SQLiteStore.ModelTokenTotals(
            model: b.model,
            inputTokens: a.inputTokens + b.inputTokens,
            outputTokens: a.outputTokens + b.outputTokens,
            cacheCreationTokens: a.cacheCreationTokens + b.cacheCreationTokens,
            cacheCreation1hTokens: a.cacheCreation1hTokens + b.cacheCreation1hTokens,
            cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens)
    }

    /// 7-day buckets walking back from `end`; the last one is clipped at `start` and flagged
    /// partial. For the 30-day period that is four full weeks and one 2-day remainder.
    private func weekBuckets(tool: Tool, from start: Date,
                             until end: Date) async -> [HistoryReport.Week] {
        var weeks: [HistoryReport.Week] = []
        var bucketEnd = end
        while bucketEnd > start {
            let fullStart = bucketEnd.addingTimeInterval(-HistoryReport.weekSeconds)
            let bucketStart = max(fullStart, start)
            let isPartial = fullStart < start
            let totals = (try? await store.tokenTotalsByModel(tool: tool, since: bucketStart,
                                                               until: bucketEnd)) ?? []
            let value = (try? await valueEngine.value(for: tool, from: bucketStart, until: bucketEnd)) ?? 0
            weeks.append(HistoryReport.Week(start: bucketStart, end: bucketEnd, isPartial: isPartial,
                                            tokens: DisplayedTokens.total(totals, tool: tool),
                                            value: value))
            bucketEnd = bucketStart
        }
        return weeks
    }
}
