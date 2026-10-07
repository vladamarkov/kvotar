import Foundation

/// Builds a `DailyLocalReport` from one bounded store read (STEP_177 — REV-92 / Baseline §15.2).
/// Pure over its inputs: the clock and calendar are injected, the population is
/// `LocalDayPolicy.population`, and every rule it applies already exists elsewhere —
/// `ProjectGrouping.canonical` (one row per stored folder), `DisplayedTokens`, `CacheHit`
/// and the engine's own per-model pricing. **Throws** on a store failure: unlike
/// `HistoryReportReader`, which collapses a failed query to an empty section, this report must
/// never let a failed read masquerade as "no local activity observed today".
public struct DailyLocalReportReader: Sendable {
    private let store: SQLiteStore
    private let valueEngine: EstimatedValueEngine

    public init(store: SQLiteStore, valueEngine: EstimatedValueEngine) {
        self.store = store
        self.valueEngine = valueEngine
    }

    public func report(tool: Tool, now: Date, calendar: Calendar) async throws -> DailyLocalReport {
        let population = LocalDayPolicy.population(now: now, calendar: calendar)
        let read = try await store.dailyLocalRead(tool: tool, since: population.start,
                                                  until: population.end)
        return await Self.fold(tool: tool, read: read,
                               population: population, valueEngine: valueEngine)
    }

    /// The grouping and arithmetic, separated from the I/O so a fixture can drive it directly.
    static func fold(tool: Tool, read: SQLiteStore.DailyLocalRead,
                     population: DateInterval, valueEngine: EstimatedValueEngine) async
        -> DailyLocalReport {
        // Group cells by canonical project, then by model, merging every token column so the
        // non-project folders sharing a model fold into one model row.
        var cells: [String?: [String?: (totals: SQLiteStore.ModelTokenTotals, latest: Date)]] = [:]
        for row in read.rows where DisplayedTokens.sum(row.totals, tool: tool) > 0 {
            let key = ProjectGrouping.canonical(row.project)
            let model = row.totals.model
            if let prior = cells[key]?[model] {
                cells[key, default: [:]][model] = (
                    totals: merged(prior.totals, row.totals),
                    latest: max(prior.latest, row.latestEventAt))
            } else {
                cells[key, default: [:]][model] = (totals: row.totals, latest: row.latestEventAt)
            }
        }

        var projects: [DailyLocalReport.Project] = []
        for (name, byModel) in cells {
            var models: [DailyLocalReport.ModelTotal] = []
            var latest = Date.distantPast
            for (model, cell) in byModel {
                let value = await valueEngine.value(for: [cell.totals], tool: tool)
                models.append(DailyLocalReport.ModelTotal(
                    model: model, tokens: DisplayedTokens.sum(cell.totals, tool: tool),
                    value: value))
                latest = max(latest, cell.latest)
            }
            models.sort { a, b in
                a.tokens == b.tokens ? modelSortKey(a.model) < modelSortKey(b.model) : a.tokens > b.tokens
            }
            projects.append(DailyLocalReport.Project(
                name: name,
                tokens: models.reduce(0) { $0 + $1.tokens },
                models: models,
                latestEventAt: latest,
                value: models.reduce(0) { $0 + $1.value }))
        }
        projects.sort { a, b in
            a.tokens == b.tokens ? projectSortKey(a.name) < projectSortKey(b.name) : a.tokens > b.tokens
        }

        return DailyLocalReport(
            tool: tool,
            dayStart: population.start,
            readUntil: population.end,
            totalTokens: projects.reduce(0) { $0 + $1.tokens },
            sessionCount: read.sessionCount,
            cacheHitRatio: CacheHit.ratio(tool: tool, totals: read.rows.map(\.totals)),
            projects: projects,
            lastEventAt: read.rows.map(\.latestEventAt).max(),
            value: projects.reduce(0) { $0 + $1.value },
            surfaces: surfaces(tool: tool, rows: read.surfaces))
    }

    /// The day's work split by local app (STEP_197) — the same events `projects` sums, cut a
    /// second way, so the two totals agree by construction.
    ///
    /// **A helper thread lands in the app that spawned it.** `Subagent · <nickname>` is not a
    /// surface (D-96): it runs *inside* one, and its own session records that surface's
    /// `originator` — every helper session in the dogfood database is `Codex Desktop` /
    /// `codex_work_desktop`, i.e. Desktop's own subagents. Resolving through
    /// `CodexSurface.bucket` puts their tokens on the Desktop row instead of inventing a
    /// `Subagents` row the user cannot act on. A Codex helper whose originator maps nowhere
    /// falls to `Unknown`, which is a visible row, not a dropped one.
    ///
    /// Claude resolves differently and deliberately: its collector observes exactly one surface
    /// (`Claude Code`, REV-81) and stores no originator, so its helpers fold to that name rather
    /// than to `Unknown` — the alternative would invent an `Unknown` row for an ordinary
    /// subagent day. Either way Σ rows = `totalTokens`.
    static func surfaces(tool: Tool, rows: [SQLiteStore.DailySurfaceRow])
        -> [DailyLocalReport.Surface] {
        var byApp: [String: (tokens: Int, latest: Date)] = [:]
        for row in rows {
            let tokens = DisplayedTokens.sum(row.totals, tool: tool)
            guard tokens > 0 else { continue }
            let app = resolvedApp(row.bucket, originator: row.originator, tool: tool)
            if let prior = byApp[app] {
                byApp[app] = (prior.tokens + tokens, max(prior.latest, row.latestEventAt))
            } else {
                byApp[app] = (tokens, row.latestEventAt)
            }
        }
        return byApp
            .map { DailyLocalReport.Surface(bucket: $0.key, tokens: $0.value.tokens,
                                            latestEventAt: $0.value.latest) }
            .sorted { a, b in
                a.tokens == b.tokens ? a.bucket < b.bucket : a.tokens > b.tokens
            }
    }

    /// A stored bucket resolved to the app that owns it. A non-helper bucket is already an app;
    /// a missing bucket predates per-event surface storage (REV-76 §2.4) and reads as unknown.
    private static func resolvedApp(_ bucket: String?, originator: String?, tool: Tool) -> String {
        guard let bucket, !bucket.isEmpty else { return CodexSurface.unknownLabel }
        guard bucket.hasPrefix(SurfaceWorkSplit.subagentPrefix) else { return bucket }
        switch tool {
        case .codex: return CodexSurface.bucket(originator: originator ?? "")
        case .claude: return SurfaceWorkSplit.claudeMainAgent
        }
    }

    /// Stable tie-break keys: a named identity sorts before the `(no project)` / `Unknown model`
    /// group, so two equal-token rows keep their order across reads.
    private static func projectSortKey(_ name: String?) -> String { name.map { "0" + $0 } ?? "1" }
    private static func modelSortKey(_ model: String?) -> String { model.map { "0" + $0 } ?? "1" }

    private static func merged(_ a: SQLiteStore.ModelTokenTotals,
                               _ b: SQLiteStore.ModelTokenTotals) -> SQLiteStore.ModelTokenTotals {
        SQLiteStore.ModelTokenTotals(
            model: a.model,
            inputTokens: a.inputTokens + b.inputTokens,
            outputTokens: a.outputTokens + b.outputTokens,
            cacheCreationTokens: a.cacheCreationTokens + b.cacheCreationTokens,
            cacheCreation1hTokens: a.cacheCreation1hTokens + b.cacheCreation1hTokens,
            cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens)
    }
}
