import Foundation
import GRDB

// Shared retention cleanup (§17.2) — since v5.17/v5.18 (REV-42 + REV-43) an ordered
// aggregate-before-purge pass: nothing leaves `poll_snapshots` without leaving an hourly
// summary in `history_rollups`, sessions idle >24h leave a `session_summaries` receipt,
// and the raw corpus (`local_sessions` / `local_usage_events`) is never deleted at all.
// Scheduling (launch + every 30 min) lives in `RetentionScheduler`.
//
// Timestamps written as `Int` unix seconds (PATTERNS.md §SQLite rule).

/// One hour-bucket of aggregated `poll_snapshots` rows (§17.1 `history_rollups`).
/// Built from the rows the cleanup pass is about to delete, then merged into the stored
/// bucket row — a bucket is purged across up to three cleanup runs at 2h retention and
/// 30-min cadence, so the write must be a merge, not a replace.
struct HistoryRollup {
    var tool: String
    var hourStart: Int
    var snapshotCount: Int
    var primaryUsedPctMin: Double?
    var primaryUsedPctMax: Double?
    var primaryUsedPctLast: Double?
    var secondaryUsedPctMin: Double?
    var secondaryUsedPctMax: Double?
    var secondaryUsedPctLast: Double?
    var primaryResetsAtLast: Int?
    var secondaryResetsAtLast: Int?
    var primaryWindowLimitLast: Double?
    var secondaryWindowLimitLast: Double?
    var rateLimitReachedMax: Int?
    var extraUsageIsEnabledLast: Int?
    var spendControlReachedLast: Int?
    var rateLimitResetCreditsCountLast: Int?
    var monthlyLimitLast: Double?
    var monthlyUsedLast: Double?
    var monthlyResetsAtLast: Int?
    var monthlyCurrencyLast: String?
    var monthlyExponentLast: Int?
    var planType: String?
    var lastPolledAt: Int

    /// §17.1 merge semantics: `_min` = null-ignoring MIN(stored, incoming), `_max` = MAX,
    /// `snapshot_count` adds, and every `_last` column (plus `last_polled_at` and `plan_type`)
    /// is replaced only when the incoming batch's latest snapshot is newer than the stored one.
    /// `lastWinsOnTie` serves the intra-batch fold, where rows arrive `(polled_at, id)`-ordered
    /// and a same-second later row must win the `_last` group (id tie-break); cross-run merges
    /// keep the strict comparison — a snapshot is rolled up exactly once, so equality there
    /// cannot occur.
    static func merged(
        stored: HistoryRollup?, incoming: HistoryRollup, lastWinsOnTie: Bool = false
    ) -> HistoryRollup {
        guard var result = stored else { return incoming }
        result.snapshotCount += incoming.snapshotCount
        result.primaryUsedPctMin = minIgnoringNil(result.primaryUsedPctMin, incoming.primaryUsedPctMin)
        result.primaryUsedPctMax = maxIgnoringNil(result.primaryUsedPctMax, incoming.primaryUsedPctMax)
        result.secondaryUsedPctMin = minIgnoringNil(result.secondaryUsedPctMin, incoming.secondaryUsedPctMin)
        result.secondaryUsedPctMax = maxIgnoringNil(result.secondaryUsedPctMax, incoming.secondaryUsedPctMax)
        result.rateLimitReachedMax = maxIgnoringNil(result.rateLimitReachedMax, incoming.rateLimitReachedMax)
        if incoming.lastPolledAt > result.lastPolledAt
            || (lastWinsOnTie && incoming.lastPolledAt == result.lastPolledAt) {
            result.primaryUsedPctLast = incoming.primaryUsedPctLast
            result.secondaryUsedPctLast = incoming.secondaryUsedPctLast
            result.primaryResetsAtLast = incoming.primaryResetsAtLast
            result.secondaryResetsAtLast = incoming.secondaryResetsAtLast
            result.primaryWindowLimitLast = incoming.primaryWindowLimitLast
            result.secondaryWindowLimitLast = incoming.secondaryWindowLimitLast
            result.extraUsageIsEnabledLast = incoming.extraUsageIsEnabledLast
            result.spendControlReachedLast = incoming.spendControlReachedLast
            result.rateLimitResetCreditsCountLast = incoming.rateLimitResetCreditsCountLast
            result.monthlyLimitLast = incoming.monthlyLimitLast
            result.monthlyUsedLast = incoming.monthlyUsedLast
            result.monthlyResetsAtLast = incoming.monthlyResetsAtLast
            result.monthlyCurrencyLast = incoming.monthlyCurrencyLast
            result.monthlyExponentLast = incoming.monthlyExponentLast
            result.planType = incoming.planType
            result.lastPolledAt = incoming.lastPolledAt
        }
        return result
    }

    private static func minIgnoringNil<T: Comparable>(_ a: T?, _ b: T?) -> T? {
        switch (a, b) {
        case let (a?, b?): return min(a, b)
        default: return a ?? b
        }
    }

    private static func maxIgnoringNil<T: Comparable>(_ a: T?, _ b: T?) -> T? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        default: return a ?? b
        }
    }
}

extension SQLiteStore {

    /// The §17.2 retention pass, all steps in one transaction:
    /// 1. `history_rollups` merge-upsert from exactly the `poll_snapshots` rows step 2 deletes
    /// 2. `poll_snapshots` DELETE (2h; most recent row per tool exempt)
    /// 3. `session_summaries` upsert for sessions idle > 24h
    /// 4. time-based deletes — `poll_health_events` / `state_transitions` / `notification_events`
    ///    at 90 days
    /// 5. `raw_payloads` rows at 24 hours — no response body is permanent
    ///    (v5.20/REV-52)
    ///
    /// Permanent tables never touched here: `accounts`, `settings`, `quota_limit_events`,
    /// `local_sessions` + `local_usage_events` (the raw corpus — v5.18/REV-43), the substrate
    /// tables themselves, `payload_shapes` / `parse_anomalies` / `app_lifecycle_events`
    /// (v5.20/REV-52), and `quota_series` (the off-machine recompute + calibration substrate —
    /// v5.21/REV-53).
    public func runRetentionCleanup() throws {
        let now = Int(Date().timeIntervalSince1970)
        do {
            try withPool { pool in
                try pool.write { db in
                    // The DELETE predicate, shared verbatim by steps 1 and 2 so the rollup
                    // covers exactly the rows being purged — including the latest-row-per-tool
                    // exemption (that row is rolled up later, once superseded).
                    let doomedPredicate = """
                        polled_at < ?
                        AND id NOT IN (
                            SELECT MAX(id) FROM poll_snapshots GROUP BY tool
                        )
                        """
                    let snapshotCutoff = now - 7200

                    // 1. history_rollups merge-upsert (aggregate-before-purge).
                    let planTypes = try Self.accountPlanTypes(db)
                    let doomed = try Row.fetchAll(db, sql: """
                        SELECT * FROM poll_snapshots
                        WHERE \(doomedPredicate)
                        ORDER BY polled_at, id
                        """, arguments: [snapshotCutoff])
                    for incoming in Self.rollups(from: doomed, planTypes: planTypes) {
                        let stored = try Self.fetchRollup(
                            db, tool: incoming.tool, hourStart: incoming.hourStart)
                        try Self.upsertRollup(
                            db, HistoryRollup.merged(stored: stored, incoming: incoming))
                    }

                    // 2. poll_snapshots — 2-hour window; most recent row per tool exempt.
                    try db.execute(
                        sql: "DELETE FROM poll_snapshots WHERE \(doomedPredicate)",
                        arguments: [snapshotCutoff])

                    // 3. session_summaries — upsert for sessions idle > 24h. Full-row recompute,
                    // so a session that resumes after being summarized self-corrects next pass.
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO session_summaries
                            (session_id, tool, project, model, originator, surface_bucket,
                             started_at, last_seen_at, event_count, input_tokens, output_tokens,
                             cache_creation_tokens, cache_read_tokens, summarized_at)
                        SELECT s.session_id, s.tool, s.project, s.model, s.originator,
                               s.surface_bucket, s.started_at, s.last_seen_at,
                               COUNT(e.dedup_key),
                               COALESCE(SUM(e.input_tokens), 0),
                               COALESCE(SUM(e.output_tokens), 0),
                               COALESCE(SUM(e.cache_creation_tokens), 0),
                               COALESCE(SUM(e.cache_read_tokens), 0),
                               ?
                        FROM local_sessions s
                        LEFT JOIN local_usage_events e
                            ON e.session_id = s.session_id AND e.tool = s.tool
                        WHERE s.last_seen_at < ?
                        GROUP BY s.session_id, s.tool
                        """, arguments: [now, now - 86400])

                    // 4. Time-based deletes — 90 days (v5.17: poll_health/state_transitions
                    // were 7d; notification_events replaces window-scoped deletion, §13.2).
                    let ninetyDayCutoff = now - 7_776_000
                    try db.execute(
                        sql: "DELETE FROM poll_health_events WHERE timestamp < ?",
                        arguments: [ninetyDayCutoff])
                    try db.execute(
                        sql: "DELETE FROM state_transitions WHERE timestamp < ?",
                        arguments: [ninetyDayCutoff])
                    try db.execute(
                        sql: "DELETE FROM notification_events WHERE fired_at < ?",
                        arguments: [ninetyDayCutoff])

                    // 5. Extended diagnostics never outlive the maximum 24-hour consent window.
                    try db.execute(
                        sql: """
                            DELETE FROM raw_payloads
                            WHERE captured_at < ?
                            """,
                        arguments: [now - 86_400])
                }
            }
        } catch {
            Logger.error("Retention cleanup failed", component: .sqliteStore,
                         metadata: ["error": "\(error)"])
            throw error
        }
    }

    // MARK: - history_rollups helpers

    /// `accounts.plan_type` per tool, read once per pass and stamped on each bucket (§17.1).
    private static func accountPlanTypes(_ db: Database) throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT tool, plan_type FROM accounts") {
            if let planType: String = row["plan_type"] { result[row["tool"]] = planType }
        }
        return result
    }

    /// Groups doomed snapshot rows into per-(tool, hour) incoming buckets. `rows` must be
    /// ordered by `(polled_at, id)` so the final row seen per bucket is its `_last` source
    /// (id breaks polled_at ties).
    static func rollups(from rows: [Row], planTypes: [String: String]) -> [HistoryRollup] {
        var buckets: [String: HistoryRollup] = [:]
        var order: [String] = []
        for row in rows {
            let tool: String = row["tool"]
            let polledAt: Int = row["polled_at"]
            let hourStart = polledAt - polledAt % 3600
            let incoming = HistoryRollup(
                tool: tool,
                hourStart: hourStart,
                snapshotCount: 1,
                primaryUsedPctMin: row["primary_used_pct"],
                primaryUsedPctMax: row["primary_used_pct"],
                primaryUsedPctLast: row["primary_used_pct"],
                secondaryUsedPctMin: row["secondary_used_pct"],
                secondaryUsedPctMax: row["secondary_used_pct"],
                secondaryUsedPctLast: row["secondary_used_pct"],
                primaryResetsAtLast: row["primary_resets_at"],
                secondaryResetsAtLast: row["secondary_resets_at"],
                primaryWindowLimitLast: row["primary_window_limit"],
                secondaryWindowLimitLast: row["secondary_window_limit"],
                rateLimitReachedMax: row["rate_limit_reached"],
                extraUsageIsEnabledLast: row["extra_usage_is_enabled"],
                spendControlReachedLast: row["spend_control_reached"],
                rateLimitResetCreditsCountLast: row["rate_limit_reset_credits_count"],
                monthlyLimitLast: row["monthly_limit"],
                monthlyUsedLast: row["monthly_used"],
                monthlyResetsAtLast: row["monthly_resets_at"],
                monthlyCurrencyLast: row["monthly_currency"],
                monthlyExponentLast: row["monthly_exponent"],
                planType: planTypes[tool],
                lastPolledAt: polledAt)
            let key = "\(tool)#\(hourStart)"
            if let existing = buckets[key] {
                // Rows arrive (polled_at, id)-ordered, so `incoming` is the bucket's newest
                // sample; lastWinsOnTie applies the id tie-break for same-second polls.
                buckets[key] = HistoryRollup.merged(
                    stored: existing, incoming: incoming, lastWinsOnTie: true)
            } else {
                buckets[key] = incoming
                order.append(key)
            }
        }
        return order.compactMap { buckets[$0] }
    }

    private static func fetchRollup(
        _ db: Database, tool: String, hourStart: Int
    ) throws -> HistoryRollup? {
        try Row.fetchOne(db, sql: """
            SELECT * FROM history_rollups WHERE tool = ? AND hour_start = ?
            """, arguments: [tool, hourStart]).map(HistoryRollup.init(row:))
    }

    /// The hourly rollups for `tool` with `hour_start` in `[since, until)`, oldest first — the
    /// permanent poll-side series (REV-69 / STEP_114 reads it for the work-per-1 % computation).
    /// Internal, like `HistoryRollup` itself: Core readers only. Read-only.
    func historyRollups(tool: Tool, since: Date, until: Date) throws -> [HistoryRollup] {
        let start = Int(since.timeIntervalSince1970)
        let end = Int(until.timeIntervalSince1970)
        return try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT * FROM history_rollups
                    WHERE tool = ? AND hour_start >= ? AND hour_start < ?
                    ORDER BY hour_start ASC
                    """, arguments: [tool.rawValue, start, end])
                .map(HistoryRollup.init(row:))
            }
        }
    }

    private static func upsertRollup(_ db: Database, _ r: HistoryRollup) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO history_rollups
                (tool, hour_start, snapshot_count,
                 primary_used_pct_min, primary_used_pct_max, primary_used_pct_last,
                 secondary_used_pct_min, secondary_used_pct_max, secondary_used_pct_last,
                 primary_resets_at_last, secondary_resets_at_last,
                 primary_window_limit_last, secondary_window_limit_last,
                 rate_limit_reached_max, extra_usage_is_enabled_last,
                 spend_control_reached_last, rate_limit_reset_credits_count_last,
                 monthly_limit_last, monthly_used_last, monthly_resets_at_last,
                 monthly_currency_last, monthly_exponent_last,
                 plan_type, last_polled_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                r.tool, r.hourStart, r.snapshotCount,
                r.primaryUsedPctMin, r.primaryUsedPctMax, r.primaryUsedPctLast,
                r.secondaryUsedPctMin, r.secondaryUsedPctMax, r.secondaryUsedPctLast,
                r.primaryResetsAtLast, r.secondaryResetsAtLast,
                r.primaryWindowLimitLast, r.secondaryWindowLimitLast,
                r.rateLimitReachedMax, r.extraUsageIsEnabledLast,
                r.spendControlReachedLast, r.rateLimitResetCreditsCountLast,
                r.monthlyLimitLast, r.monthlyUsedLast, r.monthlyResetsAtLast,
                r.monthlyCurrencyLast, r.monthlyExponentLast,
                r.planType, r.lastPolledAt,
            ])
    }
}

// The memberwise initializer must survive (the retention fold builds rollups field by field),
// so the row mapping lives in an extension.
extension HistoryRollup {
    /// One row of `history_rollups`, every column by name (the single mapping shared by the
    /// merge fetch and the series read).
    init(row: Row) {
        self.init(
            tool: row["tool"],
            hourStart: row["hour_start"],
            snapshotCount: row["snapshot_count"],
            primaryUsedPctMin: row["primary_used_pct_min"],
            primaryUsedPctMax: row["primary_used_pct_max"],
            primaryUsedPctLast: row["primary_used_pct_last"],
            secondaryUsedPctMin: row["secondary_used_pct_min"],
            secondaryUsedPctMax: row["secondary_used_pct_max"],
            secondaryUsedPctLast: row["secondary_used_pct_last"],
            primaryResetsAtLast: row["primary_resets_at_last"],
            secondaryResetsAtLast: row["secondary_resets_at_last"],
            primaryWindowLimitLast: row["primary_window_limit_last"],
            secondaryWindowLimitLast: row["secondary_window_limit_last"],
            rateLimitReachedMax: row["rate_limit_reached_max"],
            extraUsageIsEnabledLast: row["extra_usage_is_enabled_last"],
            spendControlReachedLast: row["spend_control_reached_last"],
            rateLimitResetCreditsCountLast: row["rate_limit_reset_credits_count_last"],
            monthlyLimitLast: row["monthly_limit_last"],
            monthlyUsedLast: row["monthly_used_last"],
            monthlyResetsAtLast: row["monthly_resets_at_last"],
            monthlyCurrencyLast: row["monthly_currency_last"],
            monthlyExponentLast: row["monthly_exponent_last"],
            planType: row["plan_type"],
            lastPolledAt: row["last_polled_at"])
    }
}
