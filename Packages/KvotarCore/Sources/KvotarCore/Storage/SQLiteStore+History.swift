import Foundation
import GRDB

// Read-side queries for the History window (STEP_109). Read-only; no writes, no schema change.
//
// **Why these read `local_usage_events`, not `session_summaries`.** The receipt table looked like
// the natural source — it already carries project, model, surface and all four token classes, and
// nothing had ever read it. But the §17.2 cleanup job only writes a receipt once a session has been
// idle **more than 24 hours**, so the most recent day of work has no receipts (verified on the live
// database 2026-08-16: the 3 sessions active in the last day were exactly the 3 without one). A
// per-project rollup built on receipts would therefore disagree with the token totals rendered
// directly above it. Every number in the window comes from one source.
extension SQLiteStore {

    /// One project's token totals over a period. `totals.model` is always nil — the token classes
    /// are summed across every model in the project, so `DisplayedTokens.sum` and `CacheHit.ratio`
    /// apply to it unchanged.
    public struct ProjectTokenTotals: Sendable, Equatable {
        public let project: String?
        public let sessionCount: Int
        public let totals: ModelTokenTotals

        public init(project: String?, sessionCount: Int, totals: ModelTokenTotals) {
            self.project = project
            self.sessionCount = sessionCount
            self.totals = totals
        }
    }

    /// One session's token totals over a period. `model` is the session-level value (per-event
    /// models vary within a session, so a session row cannot claim one); nil where never recorded.
    public struct SessionTokenTotals: Sendable, Equatable {
        public let sessionId: String
        public let project: String?
        public let model: String?
        public let lastSeenAt: Date
        public let totals: ModelTokenTotals

        public init(sessionId: String, project: String?, model: String?,
                    lastSeenAt: Date, totals: ModelTokenTotals) {
            self.sessionId = sessionId
            self.project = project
            self.model = model
            self.lastSeenAt = lastSeenAt
            self.totals = totals
        }
    }

    // Shared SELECT list — the same four sums and the same `cache_creation_1h` COALESCE rule as
    // `tokenTotalsByModel`, so the project rows and session rows sum to the period total exactly.
    private static let historySumColumns = """
        SUM(local_usage_events.input_tokens) AS input_tokens,
        SUM(local_usage_events.output_tokens) AS output_tokens,
        SUM(local_usage_events.cache_creation_tokens) AS cache_creation_tokens,
        SUM(COALESCE(local_usage_events.cache_creation_1h_tokens, 0)) AS cache_creation_1h_tokens,
        SUM(local_usage_events.cache_read_tokens) AS cache_read_tokens
        """

    private static func historyTotals(_ row: Row) -> ModelTokenTotals {
        ModelTokenTotals(
            model: nil,
            inputTokens: row["input_tokens"],
            outputTokens: row["output_tokens"],
            cacheCreationTokens: row["cache_creation_tokens"],
            cacheCreation1hTokens: row["cache_creation_1h_tokens"],
            cacheReadTokens: row["cache_read_tokens"])
    }

    /// Token totals grouped by project for `tool`, over `[since, until)`. Same event population as
    /// `tokenTotalsByModel`. Unordered — the reader sorts.
    public func projectTotals(tool: Tool, since: Date,
                              until: Date? = nil) throws -> [ProjectTokenTotals] {
        let start = Int(since.timeIntervalSince1970)
        let end = until.map { Int($0.timeIntervalSince1970) }
        return try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT local_sessions.project AS project,
                           COUNT(DISTINCT local_usage_events.session_id) AS session_count,
                           \(Self.historySumColumns)
                    FROM local_usage_events
                    JOIN local_sessions
                        ON local_usage_events.session_id = local_sessions.session_id
                       AND local_usage_events.tool = local_sessions.tool
                    WHERE local_usage_events.tool = ? AND local_usage_events.recorded_at >= ?
                      AND (? IS NULL OR local_usage_events.recorded_at < ?)
                    GROUP BY local_sessions.project
                    """, arguments: [tool.rawValue, start, end, end])
                .map { row in
                    ProjectTokenTotals(project: row["project"],
                                       sessionCount: row["session_count"],
                                       totals: Self.historyTotals(row))
                }
            }
        }
    }

    /// One UTC hour's token totals for one project — `projectTotals` at hour grain (STEP_178:
    /// what lets the History window answer *which projects, on this day*, which the popover's
    /// `N more projects ›` sends the reader to). Same bucket floor as
    /// `hourlyTokenTotalsByModel`, so the two fold to the same local days.
    public struct HourlyProjectTokenTotals: Sendable, Equatable {
        public let hourStart: Date
        /// The stored launch working directory, exactly as recorded; `nil` where none was.
        /// Grouping is the reader's job (`ProjectGrouping.canonical`).
        public let project: String?
        public let totals: ModelTokenTotals

        public init(hourStart: Date, project: String?, totals: ModelTokenTotals) {
            self.hourStart = hourStart
            self.project = project
            self.totals = totals
        }
    }

    /// Per-hour, per-project token totals for `tool` over `[since, until)`, oldest hour first.
    /// Same population and join as `projectTotals`, so the hours sum to the period total.
    /// One bounded read per report — never one query per day. Read-only.
    public func hourlyProjectTotals(tool: Tool, since: Date,
                                    until: Date) throws -> [HourlyProjectTokenTotals] {
        let start = Int(since.timeIntervalSince1970)
        let end = Int(until.timeIntervalSince1970)
        return try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT (local_usage_events.recorded_at - local_usage_events.recorded_at % 3600)
                               AS hour_start,
                           local_sessions.project AS project,
                           \(Self.historySumColumns)
                    FROM local_usage_events
                    JOIN local_sessions
                        ON local_usage_events.session_id = local_sessions.session_id
                       AND local_usage_events.tool = local_sessions.tool
                    WHERE local_usage_events.tool = ? AND local_usage_events.recorded_at >= ?
                      AND local_usage_events.recorded_at < ?
                    GROUP BY hour_start, local_sessions.project
                    ORDER BY hour_start ASC
                    """, arguments: [tool.rawValue, start, end])
                .map { row in
                    let hour: Int = row["hour_start"]
                    return HourlyProjectTokenTotals(
                        hourStart: Date(timeIntervalSince1970: TimeInterval(hour)),
                        project: row["project"],
                        totals: Self.historyTotals(row))
                }
            }
        }
    }

    /// Token totals grouped by session for `tool`, over `[since, until)`. `lastSeenAt` is the
    /// newest event **inside the period**, not the session's own `last_seen_at`. Unordered.
    public func sessionTotals(tool: Tool, since: Date,
                              until: Date? = nil) throws -> [SessionTokenTotals] {
        let start = Int(since.timeIntervalSince1970)
        let end = until.map { Int($0.timeIntervalSince1970) }
        return try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT local_usage_events.session_id AS session_id,
                           local_sessions.project AS project,
                           local_sessions.model AS model,
                           MAX(local_usage_events.recorded_at) AS last_seen_at,
                           \(Self.historySumColumns)
                    FROM local_usage_events
                    JOIN local_sessions
                        ON local_usage_events.session_id = local_sessions.session_id
                       AND local_usage_events.tool = local_sessions.tool
                    WHERE local_usage_events.tool = ? AND local_usage_events.recorded_at >= ?
                      AND (? IS NULL OR local_usage_events.recorded_at < ?)
                    GROUP BY local_usage_events.session_id
                    """, arguments: [tool.rawValue, start, end, end])
                .map { row in
                    let lastSeen: Int = row["last_seen_at"]
                    return SessionTokenTotals(
                        sessionId: row["session_id"],
                        project: row["project"],
                        model: row["model"],
                        lastSeenAt: Date(timeIntervalSince1970: TimeInterval(lastSeen)),
                        totals: Self.historyTotals(row))
                }
            }
        }
    }

    /// One recorded plan change (STEP_109 Events section) — a `discontinuity_events` row of type
    /// `plan_changed`, values raw as stored (`go` → `plus`).
    public struct PlanChange: Sendable, Equatable {
        public let at: Date
        public let from: String?
        public let to: String?

        public init(at: Date, from: String?, to: String?) {
            self.at = at
            self.from = from
            self.to = to
        }
    }

    /// Plan changes for `tool` observed in `[since, until)`, oldest first.
    public func planChanges(tool: Tool, since: Date, until: Date) throws -> [PlanChange] {
        let start = Int(since.timeIntervalSince1970)
        let end = Int(until.timeIntervalSince1970)
        return try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT observed_at, old_value, new_value FROM discontinuity_events
                    WHERE tool = ? AND event_type = 'plan_changed'
                      AND observed_at >= ? AND observed_at < ?
                    ORDER BY observed_at ASC
                    """, arguments: [tool.rawValue, start, end])
                .map { row in
                    let at: Int = row["observed_at"]
                    return PlanChange(at: Date(timeIntervalSince1970: TimeInterval(at)),
                                      from: row["old_value"], to: row["new_value"])
                }
            }
        }
    }

    /// How many quota windows the user was blocked in during `[since, until)`, and the most
    /// recent one. Reads `notification_events` of type `over_quota` — the state machine's
    /// server-truth verdict, at most one per window by the §13.2 max-per-window gate, so the count
    /// is "windows in which you hit the limit", not "how many times a banner fired".
    /// STEP_116 widened this from `COUNT(*)`/`MAX(fired_at)` to the timestamps themselves: the day
    /// strip needs to know *which* days were blocked, and the count and the newest are then just
    /// `.count` and `.last` of the same rows — one query, arithmetically identical to what the
    /// Events section printed before. STEP_120 widened it once more, by the same argument: the
    /// block rows need the window key beside the instant, and the dates are then `.map(\.firedAt)`.
    /// The `WHERE` clause has not moved through either widening.
    public func limitHits(tool: Tool, since: Date, until: Date) throws -> [LimitHit] {
        let start = Int(since.timeIntervalSince1970)
        let end = Int(until.timeIntervalSince1970)
        return try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT fired_at, window_start FROM notification_events
                    WHERE tool = ? AND event_type = 'over_quota'
                      AND fired_at >= ? AND fired_at < ?
                    ORDER BY fired_at ASC
                    """, arguments: [tool.rawValue, start, end])
                    .map { row in
                        let firedAt: Int = row["fired_at"]
                        let windowStart: Int = row["window_start"]
                        return LimitHit(firedAt: Date(timeIntervalSince1970: TimeInterval(firedAt)),
                                        windowStart: Date(
                                            timeIntervalSince1970: TimeInterval(windowStart)))
                    }
            }
        }
    }

    /// One recorded block, as stored. `windowStart` is the notification engine's per-window
    /// enforcement key (`resets_at − width` at the moment of the transition, or a coarse clock
    /// bucket when the window had no anchor) — **a fallback source only** for anything about the
    /// window itself: one corpus row keys a 2026-08-01 block to a window starting 2026-08-30,
    /// which is a five-hour default width applied against a monthly reset (REV-73 §2.3).
    public struct LimitHit: Sendable, Equatable, Hashable {
        public let firedAt: Date
        public let windowStart: Date

        public init(firedAt: Date, windowStart: Date) {
            self.firedAt = firedAt
            self.windowStart = windowStart
        }
    }

    /// One session's presence in one UTC hour — the grain the day strip counts sessions at
    /// (STEP_116). Deliberately not a per-day query: the day is a *local* day, and the caller owns
    /// the calendar, exactly as it does for the token buckets.
    public struct SessionHour: Sendable, Equatable, Hashable {
        public let sessionId: String
        public let hourStart: Date

        public init(sessionId: String, hourStart: Date) {
            self.sessionId = sessionId
            self.hourStart = hourStart
        }
    }

    /// Distinct `(session, UTC hour)` pairs for `tool` over `[since, until)`, oldest first. Same
    /// population and the same integer hour floor as `hourlyTokenTotalsByModel`, so the two reads
    /// agree about which events are in the period. Read-only.
    public func sessionActivityHours(tool: Tool, since: Date,
                                     until: Date) throws -> [SessionHour] {
        let start = Int(since.timeIntervalSince1970)
        let end = Int(until.timeIntervalSince1970)
        return try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT DISTINCT session_id,
                           (recorded_at - recorded_at % 3600) AS hour_start
                    FROM local_usage_events
                    WHERE tool = ? AND recorded_at >= ? AND recorded_at < ?
                    ORDER BY hour_start ASC
                    """, arguments: [tool.rawValue, start, end])
                .map { row in
                    let hour: Int = row["hour_start"]
                    return SessionHour(sessionId: row["session_id"],
                                       hourStart: Date(timeIntervalSince1970: TimeInterval(hour)))
                }
            }
        }
    }

    /// One UTC hour's token totals for one model — `tokenTotalsByModel` at hour grain (REV-69 /
    /// STEP_114: the local side of the work-per-1 % series). The bucket is `recorded_at` floored
    /// to the UTC hour by integer arithmetic, the same floor `history_rollups.hour_start` uses, so
    /// the two series share a bucket definition by construction.
    public struct HourlyModelTokenTotals: Sendable, Equatable {
        public let hourStart: Date
        public let totals: ModelTokenTotals

        public init(hourStart: Date, totals: ModelTokenTotals) {
            self.hourStart = hourStart
            self.totals = totals
        }
    }

    /// Per-hour, per-model token totals for `tool` over `[since, until)`, oldest hour first.
    /// Same population, join and `cache_creation_1h` COALESCE rule as `tokenTotalsByModel`, so
    /// the hours sum to the period total. Read-only.
    public func hourlyTokenTotalsByModel(tool: Tool, since: Date,
                                         until: Date) throws -> [HourlyModelTokenTotals] {
        let start = Int(since.timeIntervalSince1970)
        let end = Int(until.timeIntervalSince1970)
        return try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT (local_usage_events.recorded_at - local_usage_events.recorded_at % 3600)
                               AS hour_start,
                           COALESCE(local_usage_events.model, local_sessions.model) AS model,
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
                    GROUP BY hour_start, COALESCE(local_usage_events.model, local_sessions.model)
                    ORDER BY hour_start ASC
                    """, arguments: [tool.rawValue, start, end])
                .map { row in
                    let hour: Int = row["hour_start"]
                    return HourlyModelTokenTotals(
                        hourStart: Date(timeIntervalSince1970: TimeInterval(hour)),
                        totals: ModelTokenTotals(
                            model: row["model"],
                            inputTokens: row["input_tokens"],
                            outputTokens: row["output_tokens"],
                            cacheCreationTokens: row["cache_creation_tokens"],
                            cacheCreation1hTokens: row["cache_creation_1h_tokens"],
                            cacheReadTokens: row["cache_read_tokens"]))
                }
            }
        }
    }

    /// When Kvotar's own polling evidence for `tool` begins — the oldest `history_rollups`
    /// bucket. Events (plan changes, limit hits) can only be recorded from this point, unlike the
    /// token corpus, which the launch backfill reaches 90 days behind. `nil` until the first
    /// cleanup pass has rolled anything up (a machine watched for under two hours).
    public func watchingSince(tool: Tool) throws -> Date? {
        try withPool { pool in
            try pool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT MIN(hour_start) FROM history_rollups WHERE tool = ?
                    """, arguments: [tool.rawValue])
                    .map { Date(timeIntervalSince1970: TimeInterval($0)) }
            }
        }
    }

    /// Timestamp of the oldest local usage event for `tool`, or nil when the corpus is empty. The
    /// History window uses it to say how far back its evidence actually reaches, rather than
    /// implying a full period the backfill horizon may not have covered.
    public func oldestEventDate(tool: Tool) throws -> Date? {
        try withPool { pool in
            try pool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT MIN(recorded_at) FROM local_usage_events WHERE tool = ?
                    """, arguments: [tool.rawValue])
                    .map { Date(timeIntervalSince1970: TimeInterval($0)) }
            }
        }
    }
}
