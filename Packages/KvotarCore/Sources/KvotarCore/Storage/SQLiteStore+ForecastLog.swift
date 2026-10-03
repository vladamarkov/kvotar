import Foundation
import GRDB

// forecast_log prediction writer (§17.1, STEP_51). Append-only; the measurement layer for later
// forecast grading. Called by `PollCoordinator` after each §13 evaluation via
// `ForecastLogRecorder`.
//
// **Since STEP_190 it has one runtime reader** — `forecastLogWindowExposure` below, which the §11.5
// shadow tables consult to find out which windows a warning had already been shown in. Until then
// the table was written and never read by the app (the same first this surface's
// `state_transitions` read was at STEP_158). The reader is bounded, aggregate-only and touches no
// prediction column: it cannot become a path by which a stored conclusion is served back.
//
// Timestamps written as `Int` unix seconds (PATTERNS.md §SQLite rule).
extension SQLiteStore {

    /// Appends one row to `forecast_log`. Failure logs at WARN — the STEP_51 exception to the
    /// store's ERROR rule: a lost prediction row degrades calibration data only and must never
    /// read as a live-path fault — then rethrows for the caller's `try?`.
    public func writeForecastLog(_ entry: ForecastLogEntry) throws {
        do {
            try withPool { pool in
                try pool.write { db in
                    // `trigger` is a reserved SQLite keyword — must stay quoted here.
                    // The five §11.5 shadow columns are bound from STEP_190 on, and all five are
                    // NULL together whenever `entry.shadow` is nil: a null shadow prediction is
                    // gradable, a partially-filled one would not be (REV-95 §3.2).
                    try db.execute(sql: """
                        INSERT INTO forecast_log
                            (tool, computed_at, primary_used_pct, secondary_used_pct,
                             burn_rate_pct_per_min, eta_to_100, primary_resets_at,
                             forecast_tier, "trigger", app_version,
                             displayed_state, warning_first_shown_at,
                             shadow_version, blend_rate_pct_per_min, rise_probability,
                             rise_p10_pct, rise_p90_pct)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            entry.tool.rawValue,
                            Int(entry.computedAt.timeIntervalSince1970),
                            entry.primaryUsedPct,
                            entry.secondaryUsedPct,
                            entry.burnRatePctPerMin,
                            entry.etaTo100.map { Int($0.timeIntervalSince1970) },
                            entry.primaryResetsAt.map { Int($0.timeIntervalSince1970) },
                            entry.forecastTier.rawValue,
                            entry.trigger.rawValue,
                            entry.appVersion,
                            entry.displayedState.rawValue,
                            entry.warningFirstShownAt.map { Int($0.timeIntervalSince1970) },
                            entry.shadow?.version,
                            entry.shadow?.blendRate,
                            entry.shadow?.riseProbability,
                            entry.shadow?.riseP10,
                            entry.shadow?.riseP90,
                        ])
                }
            }
        } catch {
            Logger.warning("forecast_log write failed", component: .sqliteStore,
                           metadata: ["tool": entry.tool.rawValue, "error": "\(error)"])
            throw error
        }
    }

    /// Per-window warning exposure over `[since, until)` — one row per distinct
    /// `primary_resets_at`, with whether a `v24`-era build wrote it and when a warning first
    /// appeared in it (REV-95 §3.2 — STEP_190). Input to `ShadowTablesReader.build`.
    ///
    /// `MAX(displayed_state IS NOT NULL)` is the ruling-1 marker: both that column and
    /// `warning_first_shown_at` arrived in migration `v24`, so a NULL warning stamp on an older row
    /// means *the app could not record one*, not that none was shown — and training on those rows
    /// would put the post-warning behaviour §3.2 excludes straight back into the probability.
    /// SQLite's `MIN` ignores NULLs, so the warning stamp is the earliest one actually recorded.
    ///
    /// Half-open, like `quotaSeriesRange` and `discontinuityEvents`, so two adjacent periods
    /// partition the log without counting a row twice. Rows with no window anchor are skipped:
    /// there is nothing to key an exposure to.
    public func forecastLogWindowExposure(tool: Tool, since: Date,
                                          until: Date) throws -> [WindowExposure] {
        try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT primary_resets_at,
                           MAX(displayed_state IS NOT NULL) AS recorded,
                           MIN(warning_first_shown_at) AS warned_at
                      FROM forecast_log
                    WHERE tool = ? AND computed_at >= ? AND computed_at < ?
                      AND primary_resets_at IS NOT NULL
                    GROUP BY primary_resets_at
                    ORDER BY primary_resets_at ASC
                    """, arguments: [
                        tool.rawValue,
                        Int(since.timeIntervalSince1970), Int(until.timeIntervalSince1970),
                    ])
                .map { row in
                    WindowExposure(
                        anchor: Date(timeIntervalSince1970:
                                        TimeInterval(row["primary_resets_at"] as Int? ?? 0)),
                        recorded: (row["recorded"] as Int? ?? 0) != 0,
                        warningFirstShownAt: (row["warned_at"] as Int?)
                            .map { Date(timeIntervalSince1970: TimeInterval($0)) })
                }
            }
        }
    }
}
