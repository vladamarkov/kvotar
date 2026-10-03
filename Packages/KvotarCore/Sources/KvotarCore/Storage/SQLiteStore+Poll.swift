import Foundation
import GRDB

// Typed poll persistence for account adapters (§17, task line 16).
//
// A single poll updates `accounts` (identity), `poll_snapshots` (quota windows + rate-limit
// headers), `model_limit_series` (every model allowance's reported windows, STEP_209) and —
// when the poll carried an active 5-hour window — `quota_series` (the permanent slim series the
// off-machine recompute walks, REV-53) in one transaction so no reader ever
// sees one table newer than another (ARCHITECTURE.md §SQLite access). Called by `PollEngine`;
// adapters never call it.
//
// Timestamps are written as `Int` unix seconds (PATTERNS.md §SQLite rule) — SQLite would
// silently store a `Double` as REAL and break `Int` decoders otherwise.
extension SQLiteStore {

    /// Persists one account-quota poll: upserts `accounts`, appends a `poll_snapshots` row and
    /// (window polls only) a `quota_series` row in a single transaction. Identity columns are
    /// only touched when the snapshot carries a non-nil `email`/`planType` (a poll may succeed
    /// before the startup profile fetch lands). `now` is injectable so the caller's poll clock
    /// and the series row agree to the second (the recompute's newest-pair settlement check
    /// compares them — REV-53/STEP_76). `lastLocalActivityAt` is the §12 liveness timestamp the
    /// caller already holds for this tool; it rides onto the series row so the §12.2 walk and the
    /// `Local source` row read one clock (STEP_173).
    public func writePoll(snapshot: QuotaSnapshot, lastLocalActivityAt: Date? = nil,
                          now nowDate: Date = Date()) throws {
        let tool = snapshot.tool.rawValue
        let now = Int(nowDate.timeIntervalSince1970)
        do {
            try withPool { pool in
            try pool.write { db in
                // accounts — upsert identity only when we actually have it this poll.
                if snapshot.email != nil || snapshot.planType != nil {
                    try db.execute(sql: """
                        INSERT INTO accounts (tool, email, plan_type, updated_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(tool) DO UPDATE SET
                            email = COALESCE(excluded.email, accounts.email),
                            plan_type = COALESCE(excluded.plan_type, accounts.plan_type),
                            updated_at = excluded.updated_at
                        """, arguments: [tool, snapshot.email, snapshot.planType, now])
                }

                // poll_snapshots — one row per poll. Window + reached columns are nullable:
                // Codex healthy-idle leaves them NULL (§13 Null-window, §17.3 D1). Timestamps
                // written as Int (PATTERNS.md §SQLite rule).
                try db.execute(sql: """
                    INSERT INTO poll_snapshots (
                        tool, polled_at,
                        primary_used_pct, primary_resets_at,
                        secondary_used_pct, secondary_resets_at,
                        rate_limit_reached, extra_usage_is_enabled,
                        spend_control_reached, rate_limit_reset_credits_count,
                        ratelimit_limit, ratelimit_remaining, ratelimit_reset,
                        monthly_limit, monthly_used, monthly_remaining_pct, monthly_resets_at,
                        monthly_currency, monthly_exponent,
                        primary_window_seconds
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        tool,
                        now,
                        snapshot.primaryUsedPct,
                        snapshot.primaryResetsAt.map { Int($0.timeIntervalSince1970) },
                        snapshot.secondaryUsedPct,
                        snapshot.secondaryResetsAt.map { Int($0.timeIntervalSince1970) },
                        snapshot.rateLimitReached.map { $0 ? 1 : 0 },
                        snapshot.extraUsage?.isEnabled == true ? 1 : 0,
                        snapshot.spendControlReached.map { $0 ? 1 : 0 },
                        snapshot.rateLimitResetCreditsCount,
                        snapshot.rateLimitLimit,
                        snapshot.rateLimitRemaining,
                        snapshot.rateLimitReset.map { Int($0.timeIntervalSince1970) },
                        snapshot.monthlyLimit?.limitAmount,
                        snapshot.monthlyLimit?.usedAmount,
                        snapshot.monthlyLimit?.remainingPercent,
                        snapshot.monthlyLimit.map { Int($0.resetsAt.timeIntervalSince1970) },
                        // Unit pair (REV-40): written only for `.money`; NULL,NULL ⇒ `.credits`.
                        snapshot.monthlyLimit.flatMap { limit -> String? in
                            if case .money(let currency, _) = limit.unit { return currency }
                            return nil
                        },
                        snapshot.monthlyLimit.flatMap { limit -> Int? in
                            if case .money(_, let exponent) = limit.unit { return exponent }
                            return nil
                        },
                        // The provider-reported window width (P1-28 — STEP_101). NULL on Claude,
                        // which reports none, and on any Codex payload that omits it.
                        snapshot.primaryWindowSeconds,
                    ])

                // quota_series — the permanent off-machine recompute substrate (REV-53). Only
                // window polls land here: a pct without a resets_at can't be attributed to a
                // window. INSERT OR REPLACE because two polls can share a second (tripwire +
                // scheduled) and a PK conflict must not roll back the whole poll write.
                //
                // `last_local_activity_at` (STEP_173) is the §12 liveness timestamp as of this
                // poll — the same value the burn card renders `Local source` from — so the §12.2
                // walk can tell a stretch the user worked through from one they were away for,
                // even when the turn's `token_count` is still twenty minutes from being written
                // (§8.4). Evidence a surface was alive, never an amount: it adds no tokens and
                // moves no rate. Nil is honest and common (nothing observed yet, or a row written
                // before v22) and the walk reads it as no evidence.
                //
                // `primary_window_seconds` (STEP_181) is the provider's own width for this window,
                // the same expression `poll_snapshots` is given above. It is written here because
                // that table is purged at two hours, so a finished window's shape survives nowhere
                // else — and a thirty-day outcome chart that cannot name a width would have to
                // borrow today's, which REV-93 §4 forbids. Nil where the provider reported none
                // (a Codex payload that omits the duration); never invented.
                //
                // The three `secondary_*` columns (STEP_188 — REV-95 §3.1) ride the same row:
                // the weekly window as this poll saw it. The row is still selected by the
                // **primary** window — a poll with no primary anchor writes nothing here, as
                // before — so the weekly is recorded beside its primary, never on its own. Its
                // width is nil on Claude, whose `seven_day` object states none; nothing supplies
                // a constant in its place (REV-93 §4).
                if let usedPct = snapshot.primaryUsedPct,
                   let resetsAt = snapshot.primaryResetsAt {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO quota_series
                            (tool, polled_at, primary_used_pct, primary_resets_at,
                             last_local_activity_at, primary_window_seconds,
                             secondary_used_pct, secondary_resets_at, secondary_window_seconds)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            tool, now, usedPct, Int(resetsAt.timeIntervalSince1970),
                            lastLocalActivityAt.map { Int($0.timeIntervalSince1970) },
                            snapshot.primaryWindowSeconds,
                            snapshot.secondaryUsedPct,
                            snapshot.secondaryResetsAt.map { Int($0.timeIntervalSince1970) },
                            snapshot.secondaryWindowSeconds,
                        ])
                }

                // model_limit_series — every model allowance this poll reported, one row per
                // reported window (STEP_209). Not gated on the main primary window: an allowance is
                // reported whether or not a five-hour window is running. A window with nothing in
                // it writes no row, and an allowance with neither an id nor a name has no key and
                // writes none (the Claude adapter already drops those). INSERT OR REPLACE for the
                // same shared-second reason as `quota_series` above.
                for limit in snapshot.additionalRateLimits {
                    guard let key = limit.id ?? limit.name else { continue }
                    let windows: [(slot: String, window: AdditionalRateLimit.Window?)] = [
                        ("primary", limit.primary), ("secondary", limit.secondary),
                    ]
                    for (slot, window) in windows {
                        guard let window, !window.isEmpty else { continue }
                        try db.execute(sql: """
                            INSERT OR REPLACE INTO model_limit_series
                                (tool, polled_at, limit_key, limit_id, limit_name, window_slot,
                                 used_pct, resets_at, window_seconds)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [
                                tool, now, key, limit.id, limit.name, slot,
                                window.usedPercent,
                                window.resetsAt.map { Int($0.timeIntervalSince1970) },
                                window.windowSeconds,
                            ])
                    }
                }
            }
            }
        } catch {
            Logger.error("Poll write failed", component: .sqliteStore,
                         metadata: ["tool": tool, "error": "\(error)"])
            throw error
        }
    }

    /// The most recent persisted poll for `tool`, restored as a `QuotaSnapshot` + its poll time —
    /// the launch-restore input for the STEP_32 stale-keep display (§9.3). Lossy by design:
    /// columns `poll_snapshots` doesn't carry come back nil/empty (`extraUsage` amounts —
    /// only `extra_usage_is_enabled` is persisted — `source`, `creditsBalance`,
    /// `additionalRateLimits`), which is acceptable for a stale placeholder render.
    ///
    /// **`primaryWindowSeconds` is no longer among the losses** (P1-28 — STEP_101, migration
    /// `v18`). It used to be, and the cost was paid on every launch: with no width,
    /// `primaryWindowLength` falls back to five hours, so the restored card anchored attribution
    /// against a window 144x too short on a 30-day plan, labelled its quota row `Used` instead of
    /// `Weekly used`, and could not evaluate the §11.3 shape backstop at all. Rows written before
    /// `v18` still read NULL and behave as before; Claude rows are NULL permanently.
    /// Returns nil when no poll has ever been persisted.
    public func readLatestPollSnapshot(tool: Tool) throws -> (snapshot: QuotaSnapshot, polledAt: Date)? {
        try withPool { pool in
            try pool.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT ps.polled_at, ps.primary_used_pct, ps.primary_resets_at,
                           ps.secondary_used_pct, ps.secondary_resets_at,
                           ps.rate_limit_reached, ps.extra_usage_is_enabled,
                           ps.spend_control_reached, ps.rate_limit_reset_credits_count,
                           ps.monthly_limit, ps.monthly_used, ps.monthly_remaining_pct,
                           ps.monthly_resets_at, ps.monthly_currency, ps.monthly_exponent,
                           ps.primary_window_seconds,
                           a.email, a.plan_type
                    FROM poll_snapshots ps
                    LEFT JOIN accounts a ON a.tool = ps.tool
                    WHERE ps.tool = ?
                    ORDER BY ps.polled_at DESC, ps.id DESC
                    LIMIT 1
                    """, arguments: [tool.rawValue]) else { return nil }
                // Monthly limit restores only when all four columns are present (they are written
                // together or not at all); `source` is not persisted — nil by design (REV-38).
                var monthlyLimit: MonthlyLimit?
                if let limit = row["monthly_limit"] as Double?,
                   let used = row["monthly_used"] as Double?,
                   let remainingPct = row["monthly_remaining_pct"] as Int?,
                   let resetsAt = row["monthly_resets_at"] as Int? {
                    // Unit pair (REV-40): `.money` iff both columns are present; both NULL is
                    // every Codex/pre-migration row ⇒ `.credits`.
                    let unit: QuotaUnit
                    if let currency = row["monthly_currency"] as String?,
                       let exponent = row["monthly_exponent"] as Int? {
                        unit = .money(currency: currency, exponent: exponent)
                    } else {
                        unit = .credits
                    }
                    monthlyLimit = MonthlyLimit(
                        limitAmount: limit,
                        usedAmount: used,
                        remainingPercent: remainingPct,
                        resetsAt: Date(timeIntervalSince1970: TimeInterval(resetsAt)),
                        unit: unit)
                }
                let snapshot = QuotaSnapshot(
                    tool: tool,
                    primaryUsedPct: row["primary_used_pct"],
                    primaryResetsAt: (row["primary_resets_at"] as Int?)
                        .map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    primaryWindowSeconds: row["primary_window_seconds"],
                    secondaryUsedPct: row["secondary_used_pct"],
                    secondaryResetsAt: (row["secondary_resets_at"] as Int?)
                        .map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    rateLimitReached: (row["rate_limit_reached"] as Int?).map { $0 != 0 },
                    extraUsage: ExtraUsage(isEnabled: (row["extra_usage_is_enabled"] as Int? ?? 0) != 0),
                    spendControlReached: (row["spend_control_reached"] as Int?).map { $0 != 0 },
                    rateLimitResetCreditsCount: row["rate_limit_reset_credits_count"],
                    monthlyLimit: monthlyLimit,
                    email: row["email"],
                    planType: row["plan_type"])
                let polledAt = Date(timeIntervalSince1970: TimeInterval(row["polled_at"] as Int? ?? 0))
                return (snapshot, polledAt)
            }
        }
    }

    /// Recent primary-window observations used to rehydrate `ForecastEngine` after relaunch.
    /// Returns raw, oldest-first evidence; reset/drop validation and width-aware trimming remain
    /// the engine's responsibility so persistence cannot define forecast behaviour.
    public func readForecastSeedSamples(tool: Tool, since: Date) throws -> [ForecastEngine.SeedSample] {
        try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT polled_at, primary_used_pct, primary_resets_at, primary_window_seconds
                    FROM poll_snapshots
                    WHERE tool = ? AND primary_used_pct IS NOT NULL AND polled_at >= ?
                    ORDER BY polled_at ASC, id ASC
                    """, arguments: [tool.rawValue, Int(since.timeIntervalSince1970)])
                .compactMap { row in
                    guard let usedPct = row["primary_used_pct"] as Double?,
                          let polledAt = row["polled_at"] as Int? else { return nil }
                    return ForecastEngine.SeedSample(
                        usedPct: usedPct,
                        polledAt: Date(timeIntervalSince1970: TimeInterval(polledAt)),
                        resetsAt: (row["primary_resets_at"] as Int?)
                            .map { Date(timeIntervalSince1970: TimeInterval($0)) },
                        windowSeconds: row["primary_window_seconds"] as Int?)
                }
            }
        }
    }

    /// Recent monthly-meter readings for the trailing spend rate (REV-47 §2.2 — STEP_65): every
    /// persisted poll since `since` that carried a `monthly_used` value, oldest first. Read-only —
    /// a passive read of already-persisted polls (the ~65-min lookback sits comfortably inside
    /// the 2h `poll_snapshots` retention). Cycle filtering and the rate math live in
    /// `MonthlySpendRate.compute` — this returns raw samples.
    public func readMonthlyUsedSamples(tool: Tool, since: Date) throws -> [MonthlyUsedSample] {
        try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT polled_at, monthly_used, monthly_resets_at FROM poll_snapshots
                    WHERE tool = ? AND monthly_used IS NOT NULL AND polled_at >= ?
                    ORDER BY polled_at ASC, id ASC
                    """, arguments: [tool.rawValue, Int(since.timeIntervalSince1970)])
                .map { row in
                    MonthlyUsedSample(
                        polledAt: Date(timeIntervalSince1970: TimeInterval(row["polled_at"] as Int? ?? 0)),
                        usedAmount: row["monthly_used"] as Double? ?? 0,
                        resetsAt: (row["monthly_resets_at"] as Int?)
                            .map { Date(timeIntervalSince1970: TimeInterval($0)) })
                }
            }
        }
    }
}
