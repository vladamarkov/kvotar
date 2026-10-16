import Foundation
import GRDB

// Read side of `quota_series` — the permanent per-poll account-utilization series the
// off-machine recompute walks (REV-53 §3, STEP_76). The write side lives inside
// `writePoll` (SQLiteStore+Poll.swift) so a poll's three tables commit in one transaction.
// STEP_78's calibration fit reads the same table through this seam.
//
// Timestamps are stored as `Int` unix seconds (PATTERNS.md §SQLite rule).

/// One persisted poll of an active 5-hour window: when it was observed, the exact account
/// utilization, and the window's endpoint-reported reset time.
public struct QuotaSeriesPoint: Sendable, Equatable {
    public let polledAt: Date
    public let usedPct: Double
    public let resetsAt: Date
    /// The §12 liveness timestamp as of this poll — the newest of {last local file write,
    /// in-memory token event, persisted token event} (STEP_170), which is the same value the burn
    /// card rendered its `Local source` row from. The §12.2 walk reads it as evidence that a local
    /// surface was alive across the interval ending here, never as an amount (STEP_173). Nil on
    /// every row written before `v22_quota_series_local_activity`, and on any poll where no local
    /// activity had ever been observed — both read as "no evidence".
    public let lastLocalActivityAt: Date?
    /// The provider-reported width of the window this poll belongs to, in seconds — 18 000 on
    /// Claude, the plan's own span on Codex (STEP_181). This is what lets a *finished* window be
    /// named: `poll_snapshots` carries the same number but is purged at two hours. Nil on every
    /// row written before `v23_quota_series_window_seconds`, and on any Codex payload that
    /// reported no duration. A nil width is unknown, never a neighbour's and never today's —
    /// REV-93 §4.
    public let windowSeconds: Int?

    public init(polledAt: Date, usedPct: Double, resetsAt: Date,
                lastLocalActivityAt: Date? = nil, windowSeconds: Int? = nil) {
        self.polledAt = polledAt
        self.usedPct = usedPct
        self.resetsAt = resetsAt
        self.lastLocalActivityAt = lastLocalActivityAt
        self.windowSeconds = windowSeconds
    }
}

/// How a finished window ended (STEP_112): its anchor, its high-water utilization, and — when it
/// crossed 100 — the first poll that saw it there.
public struct WindowOutcome: Sendable, Equatable {
    public let resetsAt: Date
    public let highWaterPct: Double
    public let hitLimitAt: Date?

    public init(resetsAt: Date, highWaterPct: Double, hitLimitAt: Date?) {
        self.resetsAt = resetsAt
        self.highWaterPct = highWaterPct
        self.hitLimitAt = hitLimitAt
    }
}

extension SQLiteStore {

    /// All series rows belonging to the window whose reset time is within `tolerance` of
    /// `resetsAt`, oldest first. Rows are selected by `primary_resets_at` proximity — never by
    /// a `polled_at` range — because each row records the reset the endpoint itself attributed
    /// the reading to, which stays correct across the rollover edge and endpoint ±1s wobble
    /// (REV-53/STEP_76; tolerance mirrors `OffMachineEstimator.resetJitterToleranceUnix`).
    public func quotaSeries(tool: Tool, resetsAtNear resetsAt: Date,
                            tolerance: TimeInterval = 60) throws -> [QuotaSeriesPoint] {
        let target = Int(resetsAt.timeIntervalSince1970)
        return try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT polled_at, primary_used_pct, primary_resets_at, last_local_activity_at,
                           primary_window_seconds
                      FROM quota_series
                    WHERE tool = ? AND primary_resets_at BETWEEN ? AND ?
                    ORDER BY polled_at ASC
                    """, arguments: [
                        tool.rawValue, target - Int(tolerance), target + Int(tolerance),
                    ])
                .map(Self.seriesPoint(from:))
            }
        }
    }

    /// The newest series row for `tool` — the anchor for the lazy last-window recompute after
    /// a restart (REV-53/STEP_76: a nil-window poll must still be able to return the last
    /// window's attribution, which the REV-46 idle retrospective renders). Returns nil when no
    /// window poll was ever persisted.
    public func latestQuotaSeriesPoint(tool: Tool) throws -> QuotaSeriesPoint? {
        try withPool { pool in
            try pool.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT polled_at, primary_used_pct, primary_resets_at, last_local_activity_at,
                           primary_window_seconds
                      FROM quota_series
                    WHERE tool = ?
                    ORDER BY polled_at DESC
                    LIMIT 1
                    """, arguments: [tool.rawValue])
                .map(Self.seriesPoint(from:))
            }
        }
    }

    /// Every series row for `tool` observed in `[since, until)`, oldest first — the bounded
    /// history read behind Explore quota's thirty-day outcome chart (REV-93 §4 / D-115, STEP_181).
    ///
    /// This is the one reader on this table bounded by `polled_at` rather than by anchor
    /// proximity, and deliberately so: it does not know which windows it is looking for, it is
    /// asking what the provider reported across a span. Grouping the rows it returns into windows
    /// is `QuotaWindowOutcomes.compute`'s job, which applies the same ±60 s anchor rule
    /// `quotaSeries(resetsAtNear:)` uses — kept in one pure place so a chart and a recompute can
    /// never disagree about where one window ends and the next begins.
    ///
    /// Half-open on both sides, matching `discontinuityEvents(tool:since:until:types:)`, so two
    /// adjacent periods partition the series without double-counting a poll.
    public func quotaSeriesRange(tool: Tool, since: Date, until: Date) throws -> [QuotaSeriesPoint] {
        try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT polled_at, primary_used_pct, primary_resets_at, last_local_activity_at,
                           primary_window_seconds
                      FROM quota_series
                    WHERE tool = ? AND polled_at >= ? AND polled_at < ?
                    ORDER BY polled_at ASC
                    """, arguments: [
                        tool.rawValue,
                        Int(since.timeIntervalSince1970), Int(until.timeIntervalSince1970),
                    ])
                .map(Self.seriesPoint(from:))
            }
        }
    }

    /// The boundaries of the most recent *ended* 5-hour window on record — the anchor the idle
    /// "last window" retrospective re-anchors §2.5a/§2.5b to (REV-46/D-41 — STEP_64).
    /// `start = resets_at − 5h`, mirroring the reset-anchor the live path uses.
    ///
    /// Reads `quota_series` through `latestQuotaSeriesPoint` — the same accessor
    /// `OffMachineEstimator.lastKnown` resolves a null poll through — so the display gate and the
    /// estimate can never disagree about *which* window is being recapped *(source corrected
    /// v5.21, REV-55/STEP_82)*. It previously read `poll_snapshots`, which is purged at 2 hours
    /// (§17.2) with only the newest row per tool exempt — and during an idle stretch that exempt
    /// row *is* the null poll, so every row proving a window existed was gone two hours after it
    /// was polled. That gave the retrospective a ~2h half-life and excluded the overnight idle it
    /// was written for; live 2026-07-25 it rendered "this 5-hour window" over 101 hours of rows.
    ///
    /// **Narrower than the retired query, deliberately:** `writePoll` appends a `quota_series` row
    /// only when the poll carried *both* a utilization and a reset time, where the old one needed
    /// only `primary_resets_at`. A reading that cannot be attributed to a window is not an anchor.
    ///
    /// **The five hours here is a documented fallback, not an oversight** *(REV-60 — STEP_90)*.
    /// Everywhere else the app now derives a window start from the width the provider reported;
    /// `quota_series` carried no width column, and widening the schema was out of that step's
    /// scope. STEP_181 has since added `primary_window_seconds`, but this reader is deliberately
    /// left on the fallback: only rows written after `v23` carry a width, so repointing it would
    /// change the retrospective's anchor on new rows and leave it on five hours for old ones — a
    /// behaviour split that needs its own evidence, not a free ride on a storage step.
    /// It is safe where it lands: the only consumer is the REV-46 idle retrospective, which
    /// fires on a null non-monthly window, and on Codex `PollCoordinator.localDayGrain` already
    /// wins that anchor with local midnight — so in practice this is Claude's path, where five
    /// hours is the truth. A wide-window retrospective would need the width persisted here first.
    ///
    /// The `resets_at <= now` guard is required because `quota_series` is permanent: its newest
    /// row can name a window that has not ended yet, and recapping that would put a future clock
    /// time in the `Window` row. Returning nil lands on D-41's specced no-prior-window path.
    /// Read-only — a passive read of already-persisted polls; no write, no refresh. Returns nil
    /// when no active window was ever persisted (fresh install).
    public func lastActiveWindow(tool: Tool, now: Date = Date()) throws -> DateInterval? {
        guard let latest = try latestQuotaSeriesPoint(tool: tool),
              latest.resetsAt <= now else { return nil }
        return DateInterval(start: latest.resetsAt.addingTimeInterval(-18_000), end: latest.resetsAt)
    }

    /// How the newest window that ended *before* `before` (or before `now`, when `before` is nil)
    /// finished — the "Since you last looked" window-boundary read (REV-68/D-75 — STEP_112).
    /// `[N]` in `New window since [t] — last one ended at [N]%` is the window's high-water
    /// `primary_used_pct`; `hitLimitAt` is the poll that first saw it at or past 100 (the
    /// `— hit the limit at [t₁]` form). The previous window is the one the *most recent* poll
    /// with a reset at least the jitter tolerance before `before` belonged to — its stamp is the
    /// anchor (the endpoint alternates `1:59:59` / `2:00:00` across a window, and the newest poll's
    /// stamp is what the header last showed) — then every row attributed to that anchor through
    /// `quotaSeries(tool:resetsAtNear:)`, the same ±60s proximity rule as every other reader, so
    /// the wobble never splits a window.
    ///
    /// `before` = the current window's `resets_at` on the populated form; nil on the fresh
    /// provider-null form (`Last window ended at [N]% — reset [t]`), where the previous window is
    /// simply the newest one that has ended — the window `lastActiveWindow` names. Read-only.
    /// nil when no earlier window was ever persisted (fresh install, or only null polls).
    public func previousWindowOutcome(tool: Tool, before: Date?, now: Date = Date(),
                                      tolerance: TimeInterval = 60) throws -> WindowOutcome? {
        var ceiling = Int(now.timeIntervalSince1970)
        if let before {
            ceiling = min(ceiling, Int(before.timeIntervalSince1970) - Int(tolerance))
        }
        let anchor: Int? = try withPool { pool in
            try pool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT primary_resets_at FROM quota_series
                    WHERE tool = ? AND primary_resets_at <= ?
                    ORDER BY polled_at DESC
                    LIMIT 1
                    """, arguments: [tool.rawValue, ceiling])
            }
        }
        guard let anchor else { return nil }
        let resetsAt = Date(timeIntervalSince1970: TimeInterval(anchor))
        let rows = try quotaSeries(tool: tool, resetsAtNear: resetsAt, tolerance: tolerance)
        guard let highWater = rows.map(\.usedPct).max() else { return nil }
        return WindowOutcome(resetsAt: resetsAt, highWaterPct: highWater,
                             hitLimitAt: rows.first { $0.usedPct >= 100 }?.polledAt)
    }

    /// The **secondary (weekly)** window's readings for `tool` in `[since, until)`, oldest first
    /// (STEP_227 — REV-104 §4), shaped as `QuotaSeriesPoint` so the one outcome fold reads them.
    /// Only rows that carried a secondary (`v24` onward, and only where the provider reported
    /// one). `lastLocalActivityAt` is the row's own stamp; the width is the wire's, which Claude's
    /// `seven_day` never states — the fold's provider contract supplies it.
    public func quotaSeriesSecondaryRange(tool: Tool, since: Date,
                                          until: Date) throws -> [QuotaSeriesPoint] {
        try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT polled_at, secondary_used_pct, secondary_resets_at,
                           last_local_activity_at, secondary_window_seconds
                      FROM quota_series
                    WHERE tool = ? AND polled_at >= ? AND polled_at < ?
                      AND secondary_used_pct IS NOT NULL AND secondary_resets_at IS NOT NULL
                    ORDER BY polled_at ASC
                    """, arguments: [
                        tool.rawValue,
                        Int(since.timeIntervalSince1970), Int(until.timeIntervalSince1970),
                    ])
                .map { row in
                    QuotaSeriesPoint(
                        polledAt: Date(timeIntervalSince1970:
                            TimeInterval(row["polled_at"] as Int? ?? 0)),
                        usedPct: row["secondary_used_pct"] as Double? ?? 0,
                        resetsAt: Date(timeIntervalSince1970:
                            TimeInterval(row["secondary_resets_at"] as Int? ?? 0)),
                        lastLocalActivityAt: (row["last_local_activity_at"] as Int?)
                            .map { Date(timeIntervalSince1970: TimeInterval($0)) },
                        windowSeconds: row["secondary_window_seconds"] as Int?)
                }
            }
        }
    }

    private static func seriesPoint(from row: Row) -> QuotaSeriesPoint {
        QuotaSeriesPoint(
            polledAt: Date(timeIntervalSince1970: TimeInterval(row["polled_at"] as Int? ?? 0)),
            usedPct: row["primary_used_pct"] as Double? ?? 0,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(row["primary_resets_at"] as Int? ?? 0)),
            lastLocalActivityAt: (row["last_local_activity_at"] as Int?)
                .map { Date(timeIntervalSince1970: TimeInterval($0)) },
            windowSeconds: row["primary_window_seconds"] as Int?)
    }
}
