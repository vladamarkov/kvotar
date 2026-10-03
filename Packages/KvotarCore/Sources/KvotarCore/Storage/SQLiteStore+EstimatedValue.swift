import Foundation
import GRDB

// Read-side query for EstimatedValueEngine (§12, task line 10).
extension SQLiteStore {

    /// Summed token counts for one model, within one tool's usage events.
    public struct ModelTokenTotals: Sendable, Equatable {
        public let model: String?
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheCreationTokens: Int
        /// **Claude only** — the part of `cacheCreationTokens` written at the 1-hour cache tier,
        /// which Anthropic charges at 2x input against the 5-minute tier's 1.25x (STEP_96,
        /// Baseline §12.1). The 5-minute amount is `cacheCreationTokens - cacheCreation1hTokens`.
        ///
        /// A **subset**, never a sibling — the same trap that made the pre-STEP_91 Codex count
        /// nearly double. Adding this to a displayed token count counts those tokens twice; only
        /// `EstimatedValueEngine` reads it. Rows predating the v17 migration store NULL and sum
        /// in as 0, which prices their whole write at the 5-minute rate exactly as before.
        public let cacheCreation1hTokens: Int
        public let cacheReadTokens: Int

        public init(model: String?, inputTokens: Int, outputTokens: Int,
                    cacheCreationTokens: Int, cacheCreation1hTokens: Int = 0,
                    cacheReadTokens: Int) {
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.cacheCreation1hTokens = cacheCreation1hTokens
            self.cacheReadTokens = cacheReadTokens
        }

        /// **Codex only** — the cached prompt slice, wherever this row's era happened to put it
        /// (REV-62 §2.5, Baseline §8.4). Rows written before 2026-07-13 hold Codex's
        /// `cached_input_tokens` in `cache_read_tokens`; rows written from 2026-07-13 hold it in
        /// `cache_creation_tokens`. Summing them is a **union over storage conventions, not an
        /// addition of two quantities**: no Codex row has both columns non-zero (verified on the
        /// live database 2026-08-12 — 3,110 pre-boundary rows, 387 post-boundary rows, 0 with
        /// both). Reading only one column renders `Cache hit 0%` on any window containing rows
        /// from the other era, and prices most of the corpus at the full uncached rate.
        ///
        /// Never call this on Claude totals: Claude's `cache_creation` and `cache_read` are
        /// genuinely disjoint quantities (0 of 9,537 messages have `input >= cache_read +
        /// cache_creation`), so summing them there would be an addition, not a union.
        public var codexCachedInputTokens: Int { cacheCreationTokens + cacheReadTokens }
    }

    /// Token totals grouped by model for `tool`, summed over `local_usage_events` rows with
    /// `recorded_at >= windowStart` (and `< until` when given — the off-machine estimator's
    /// forecast-span alignment, REV-18).
    ///
    /// The model is **per-event first, session fallback** (STEP_93, REV-62 §4.3): rows written
    /// since migration v15 carry their own `model`; older rows are NULL and take
    /// `local_sessions.model` — the last-non-null-wins session value whose mis-attribution
    /// (5.3% of tokens priced at the wrong model's rate, `claude-sonnet-5` shown 37× over) this
    /// step exists to end. The one-shot enrichment sweep fills historical rows from the JSONL
    /// corpus, shrinking the fallback population toward files no longer on disk.
    ///
    /// `cache_creation_1h_tokens` is `COALESCE`d to 0 rather than skipped (STEP_96): a row whose
    /// tier split was never recorded contributes nothing to the 1-hour sum and therefore falls
    /// into the 5-minute remainder `cacheCreationTokens - cacheCreation1hTokens`. That is the
    /// per-row rule surviving the `GROUP BY` intact, so a group mixing pre- and post-v17 rows
    /// prices each side correctly instead of averaging them.
    ///
    /// `sessionId` (STEP_109) narrows the same query to one session, so the History window can
    /// price a session per event model rather than at the session-level model — the mis-attribution
    /// STEP_93 removed. Nil (every existing caller) is the whole tool.
    public func tokenTotalsByModel(tool: Tool, since windowStart: Date,
                                   until windowEnd: Date? = nil,
                                   sessionId: String? = nil) throws -> [ModelTokenTotals] {
        let start = Int(windowStart.timeIntervalSince1970)
        // NULL upper bound disables the `<` predicate — one statement covers both call shapes.
        let end = windowEnd.map { Int($0.timeIntervalSince1970) }
        return try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT COALESCE(local_usage_events.model, local_sessions.model) AS model,
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
                      AND (? IS NULL OR local_usage_events.recorded_at < ?)
                      AND (? IS NULL OR local_usage_events.session_id = ?)
                    GROUP BY COALESCE(local_usage_events.model, local_sessions.model)
                    """, arguments: [tool.rawValue, start, end, end, sessionId, sessionId])
                .map { row in
                    ModelTokenTotals(
                        model: row["model"],
                        inputTokens: row["input_tokens"],
                        outputTokens: row["output_tokens"],
                        cacheCreationTokens: row["cache_creation_tokens"],
                        cacheCreation1hTokens: row["cache_creation_1h_tokens"],
                        cacheReadTokens: row["cache_read_tokens"]
                    )
                }
            }
        }
    }

    /// Count of distinct local sessions for `tool` active in the window — those with
    /// `last_seen_at >= windowStart` (active-in-window, **not** started-in-window; REV-44 §2.5a).
    /// Subagents fold in rather than counting separately: their JSONL lines carry the parent's
    /// `sessionId`, so they share a `local_sessions` row. Read-only.
    public func sessionCount(tool: Tool, since windowStart: Date) throws -> Int {
        let start = Int(windowStart.timeIntervalSince1970)
        return try withPool { pool in
            try pool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT session_id) FROM local_sessions
                    WHERE tool = ? AND last_seen_at >= ?
                    """, arguments: [tool.rawValue, start]) ?? 0
            }
        }
    }
}
