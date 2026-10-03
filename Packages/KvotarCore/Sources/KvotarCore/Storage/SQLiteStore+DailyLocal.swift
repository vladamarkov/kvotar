import Foundation
import GRDB

// The daily local report's one bounded read (STEP_177 — REV-92 / Baseline §15.2). Read-only; no
// writes, no schema change. All three aggregates below come from a **single** `pool.read`, so the
// project × model rows, the surface rows (STEP_197) and the session count describe the same
// snapshot of the corpus — a concurrent flush cannot land between them and leave "3 sessions"
// beside rows that sum to four, or surface rows that sum past their own summary line.
extension SQLiteStore {

    /// One `(project, per-event model)` cell of the day. `totals.model` carries the model
    /// (`COALESCE(event, session)` — per-event first, STEP_93); `project` is the stored working
    /// directory, ungrouped — the reader applies `ProjectGrouping`.
    public struct DailyProjectModelRow: Sendable, Equatable {
        public let project: String?
        public let totals: ModelTokenTotals
        /// The newest event of this cell inside the population.
        public let latestEventAt: Date

        public init(project: String?, totals: ModelTokenTotals, latestEventAt: Date) {
            self.project = project
            self.totals = totals
            self.latestEventAt = latestEventAt
        }
    }

    /// One `(surface bucket, session originator)` cell of the day (STEP_197). The bucket is the
    /// event's own, falling back to its session's (`COALESCE`, the split `tokenTotalsBySurface`
    /// already uses); `originator` is the *session's*, which is how a `Subagent · …` helper is
    /// resolved back to the app that spawned it — `local_usage_events` has no originator column,
    /// and a helper's session carries the originator of its parent surface.
    ///
    /// `totals.model` is always nil here and is never read: the struct is reused only so
    /// `DisplayedTokens.sum` applies the per-tool token rule without a second copy of it.
    public struct DailySurfaceRow: Sendable, Equatable {
        public let bucket: String?
        public let originator: String?
        public let totals: ModelTokenTotals
        /// The newest event of this cell inside the population.
        public let latestEventAt: Date

        public init(bucket: String?, originator: String?, totals: ModelTokenTotals,
                    latestEventAt: Date) {
            self.bucket = bucket
            self.originator = originator
            self.totals = totals
            self.latestEventAt = latestEventAt
        }
    }

    /// The whole read: every cell plus the session count over the same population.
    public struct DailyLocalRead: Sendable, Equatable {
        public let rows: [DailyProjectModelRow]
        /// Distinct sessions with at least one **token-bearing** event inside the population —
        /// a zero-usage placeholder line (`<synthetic>`, Baseline §17.1) is not observed work.
        public let sessionCount: Int
        /// Per-surface cells over the same population (STEP_197). Defaulted so a fixture that
        /// predates the surface rows still drives `fold`.
        public let surfaces: [DailySurfaceRow]

        public init(rows: [DailyProjectModelRow], sessionCount: Int,
                    surfaces: [DailySurfaceRow] = []) {
            self.rows = rows
            self.sessionCount = sessionCount
            self.surfaces = surfaces
        }
    }

    /// Project × per-event-model token totals and the session count for `tool` over the
    /// half-open `[since, until)`. Same join, same `cache_creation_1h` COALESCE rule as
    /// `tokenTotalsByModel`, so the cells sum to what that query would return for the same span.
    /// Throws on a read failure — the caller owns the failed-versus-empty distinction, and an
    /// empty result here is a genuine "nothing observed".
    public func dailyLocalRead(tool: Tool, since: Date, until: Date) throws -> DailyLocalRead {
        let start = Int(since.timeIntervalSince1970)
        let end = Int(until.timeIntervalSince1970)
        guard end > start else { return DailyLocalRead(rows: [], sessionCount: 0) }
        return try withPool { pool in
            try pool.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT local_sessions.project AS project,
                           COALESCE(local_usage_events.model, local_sessions.model) AS model,
                           MAX(local_usage_events.recorded_at) AS latest,
                           SUM(local_usage_events.input_tokens) AS input_tokens,
                           SUM(local_usage_events.output_tokens) AS output_tokens,
                           SUM(local_usage_events.cache_creation_tokens) AS cache_creation_tokens,
                           SUM(COALESCE(local_usage_events.cache_creation_1h_tokens, 0))
                               AS cache_creation_1h_tokens,
                           SUM(local_usage_events.cache_read_tokens) AS cache_read_tokens
                    FROM local_usage_events
                    JOIN local_sessions
                        ON local_usage_events.session_id = local_sessions.session_id
                       AND local_usage_events.tool = local_sessions.tool
                    WHERE local_usage_events.tool = ? AND local_usage_events.recorded_at >= ?
                      AND local_usage_events.recorded_at < ?
                    GROUP BY local_sessions.project,
                             COALESCE(local_usage_events.model, local_sessions.model)
                    """, arguments: [tool.rawValue, start, end])
                .map { row in
                    let latest: Int = row["latest"]
                    return DailyProjectModelRow(
                        project: row["project"],
                        totals: ModelTokenTotals(
                            model: row["model"],
                            inputTokens: row["input_tokens"],
                            outputTokens: row["output_tokens"],
                            cacheCreationTokens: row["cache_creation_tokens"],
                            cacheCreation1hTokens: row["cache_creation_1h_tokens"],
                            cacheReadTokens: row["cache_read_tokens"]),
                        latestEventAt: Date(timeIntervalSince1970: TimeInterval(latest)))
                }
                let surfaces = try Row.fetchAll(db, sql: """
                    SELECT COALESCE(local_usage_events.surface_bucket,
                                    local_sessions.surface_bucket) AS bucket,
                           local_sessions.originator AS originator,
                           MAX(local_usage_events.recorded_at) AS latest,
                           SUM(local_usage_events.input_tokens) AS input_tokens,
                           SUM(local_usage_events.output_tokens) AS output_tokens,
                           SUM(local_usage_events.cache_creation_tokens) AS cache_creation_tokens,
                           SUM(COALESCE(local_usage_events.cache_creation_1h_tokens, 0))
                               AS cache_creation_1h_tokens,
                           SUM(local_usage_events.cache_read_tokens) AS cache_read_tokens
                    FROM local_usage_events
                    JOIN local_sessions
                        ON local_usage_events.session_id = local_sessions.session_id
                       AND local_usage_events.tool = local_sessions.tool
                    WHERE local_usage_events.tool = ? AND local_usage_events.recorded_at >= ?
                      AND local_usage_events.recorded_at < ?
                    GROUP BY COALESCE(local_usage_events.surface_bucket,
                                      local_sessions.surface_bucket),
                             local_sessions.originator
                    """, arguments: [tool.rawValue, start, end])
                .map { row in
                    let latest: Int = row["latest"]
                    return DailySurfaceRow(
                        bucket: row["bucket"],
                        originator: row["originator"],
                        totals: ModelTokenTotals(
                            model: nil,
                            inputTokens: row["input_tokens"],
                            outputTokens: row["output_tokens"],
                            cacheCreationTokens: row["cache_creation_tokens"],
                            cacheCreation1hTokens: row["cache_creation_1h_tokens"],
                            cacheReadTokens: row["cache_read_tokens"]),
                        latestEventAt: Date(timeIntervalSince1970: TimeInterval(latest)))
                }
                let sessions = try Int.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT session_id) FROM local_usage_events
                    WHERE tool = ? AND recorded_at >= ? AND recorded_at < ?
                      AND (input_tokens + output_tokens
                           + cache_creation_tokens + cache_read_tokens) > 0
                    """, arguments: [tool.rawValue, start, end]) ?? 0
                return DailyLocalRead(rows: rows, sessionCount: sessions, surfaces: surfaces)
            }
        }
    }

    /// Every distinct working directory ever stored for `tool` — the **stable** path set
    /// `ProjectGrouping.canonical` groups today's rows against (Baseline §15.2: "a stable set of
    /// known stored paths for the provider"). Grouping against only the day's own paths would let
    /// a repo's identity flip depending on which subfolder happened to be used that day.
    public func distinctProjectPaths(tool: Tool) throws -> [String?] {
        try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT DISTINCT project FROM local_sessions WHERE tool = ?
                    """, arguments: [tool.rawValue])
                .map { $0["project"] as String? }
            }
        }
    }
}
