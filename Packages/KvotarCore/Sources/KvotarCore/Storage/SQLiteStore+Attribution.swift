import Foundation
import GRDB

// Read-side queries for the AttributionEngine (Step 22): the current local session and the
// per-surface token split that back the popover's Local-session section (UI Spec §2.5/§2.6).
extension SQLiteStore {

    /// Summed token count for one surface bucket within a tool's usage window, plus the bucket's
    /// newest event time (STEP_192) — the per-bucket recency `SurfaceWorkSplit.activeSurfaces`
    /// reads, so "active" can mean *burning now* rather than *burnt this window* (§13 rule 8, A28).
    public struct SurfaceTokenTotals: Sendable, Equatable {
        public let surfaceBucket: String
        public let totalTokens: Int
        public let lastEventAt: Date?

        public init(surfaceBucket: String, totalTokens: Int, lastEventAt: Date? = nil) {
            self.surfaceBucket = surfaceBucket
            self.totalTokens = totalTokens
            self.lastEventAt = lastEventAt
        }
    }

    /// The most recently active local session for `tool`, restricted to sessions seen since
    /// `windowStart` so a stale session from a previous day does not surface as "current".
    public struct CurrentSession: Sendable, Equatable {
        public let project: String?
        public let model: String?
        public let surfaceBucket: String?
        public let originator: String?
    }

    /// Total tokens grouped by surface bucket for `tool`, over `local_usage_events` with
    /// `recorded_at >= windowStart`. The bucket is **per-event first, session fallback**
    /// (STEP_93, REV-62 §4.3): Claude sessions mix main-agent and subagent events, and the
    /// session-scoped bucket under a last-writer-wins upsert understated subagent work 24×
    /// (2.3M shown vs 55.2M real). Rows since v15 carry their own bucket; NULL rows take the
    /// session's. Feeds the Codex Desktop/CLI/IDE split bar and the Claude subagent share.
    ///
    /// **The sum forks by tool** (Baseline §4, STEP_91). Claude's four columns are disjoint, so its
    /// displayed count is all four (REV-50). Codex's cached slice is *inside* `input_tokens`, so
    /// its count is `input + output` — summing the cache columns there counts the same tokens
    /// twice. This is a *ratio*, so the error only cancels if every surface has the same cache-hit
    /// rate, which they do not: a Desktop thread with a long re-sent transcript and a one-shot CLI
    /// call carry very different cached shares, and the bar tilted toward whichever surface cached
    /// most.
    public func tokenTotalsBySurface(tool: Tool, since windowStart: Date) throws -> [SurfaceTokenTotals] {
        let start = Int(windowStart.timeIntervalSince1970)
        let tokenSum: String
        switch tool {
        case .claude:
            tokenSum = """
                SUM(local_usage_events.input_tokens
                    + local_usage_events.output_tokens
                    + local_usage_events.cache_creation_tokens
                    + local_usage_events.cache_read_tokens)
                """
        case .codex:
            tokenSum = """
                SUM(local_usage_events.input_tokens
                    + local_usage_events.output_tokens)
                """
        }
        return try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT COALESCE(local_usage_events.surface_bucket,
                                    local_sessions.surface_bucket) AS surface_bucket,
                           \(tokenSum) AS total_tokens,
                           MAX(local_usage_events.recorded_at) AS last_event_at
                    FROM local_usage_events
                    JOIN local_sessions
                        ON local_usage_events.session_id = local_sessions.session_id
                       AND local_usage_events.tool = local_sessions.tool
                    WHERE local_usage_events.tool = ? AND local_usage_events.recorded_at >= ?
                    GROUP BY COALESCE(local_usage_events.surface_bucket,
                                      local_sessions.surface_bucket)
                    """, arguments: [tool.rawValue, start])
                .map { row in
                    SurfaceTokenTotals(
                        surfaceBucket: row["surface_bucket"] ?? "Unknown",
                        totalTokens: row["total_tokens"] ?? 0,
                        lastEventAt: (row["last_event_at"] as Int?)
                            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    )
                }
            }
        }
    }

    /// Start time of the most recently active session for `tool`, or `nil` when no session (or
    /// no start time) is recorded. The §3.3 null-window attribution fallback: when the poll side
    /// cannot supply a real quota-window start, the most recent session's start stands in
    /// (UI Spec §3.3 "most recent JSONL session_meta.timestamp"; STEP_26).
    public func mostRecentSessionStart(tool: Tool) throws -> Date? {
        try withPool { pool in
            try pool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT started_at FROM local_sessions
                    WHERE tool = ? AND started_at IS NOT NULL
                    ORDER BY last_seen_at DESC
                    LIMIT 1
                    """, arguments: [tool.rawValue])
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
            }
        }
    }

    /// Timestamp of the most recent persisted `local_usage_events` row for `tool`, or `nil` when
    /// none exist (REV-30). Unlike `AttributionEngine.lastEventAt` — which is in-memory and only
    /// counts events observed *since launch* (it seeds file offsets to EOF at start) — this reads
    /// across launches, so the burn-card liveness gap survives a restart instead of falsely
    /// reading "Claude Code idle" until the first successful poll. Covered by the
    /// `local_usage_events_tool_recorded_at` index, so it is a cheap MAX lookup.
    public func mostRecentEventAt(tool: Tool) throws -> Date? {
        try withPool { pool in
            try pool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT MAX(recorded_at) FROM local_usage_events
                    WHERE tool = ?
                    """, arguments: [tool.rawValue])
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
            }
        }
    }

    /// The most recently active session for `tool` whose `last_seen_at >= windowStart`, or `nil`
    /// when no session has been seen in that window (nothing to show as the current session).
    public func currentSession(tool: Tool, since windowStart: Date) throws -> CurrentSession? {
        let start = Int(windowStart.timeIntervalSince1970)
        return try withPool { pool in
            try pool.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT project, model, surface_bucket, originator
                    FROM local_sessions
                    WHERE tool = ? AND last_seen_at >= ?
                    ORDER BY last_seen_at DESC
                    LIMIT 1
                    """, arguments: [tool.rawValue, start])
                .map { row in
                    CurrentSession(
                        project: row["project"],
                        model: row["model"],
                        surfaceBucket: row["surface_bucket"],
                        originator: row["originator"]
                    )
                }
            }
        }
    }
}
