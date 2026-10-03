import Foundation
import GRDB

// `quota_limit_events` access — user-session quota 429s observed in JSONL (§9.4), the input
// to the self-learning personal ceiling. `ForecastEngine` owns the read and feeds the
// observations into the pure `LimitsDatabaseAdapter.resolveCeiling` (ARCHITECTURE.md
// §Community limits DB). The write side landed in STEP_26 (closes REV-5): `PollCoordinator`
// joins the adapters' JSONL `Quota429Observation`s with poll-side context (utilization%,
// plan_type) and calls `writeQuotaLimitEvent`.
extension SQLiteStore {

    /// Records one user-session quota 429 observed in JSONL (§9.4). Never Kvotar's own
    /// poll 429s — those go to `poll_health_events` (§9.1, PATTERNS.md §Do/don't).
    /// `INSERT OR IGNORE`: the `(tool, source_file, timestamp)` UNIQUE key dedups
    /// re-observations of the same event. Retention is permanent — plan changes reset the
    /// ceiling via the `plan_type` filter in the reader, not by deletion (§17.1).
    ///
    /// **Plausibility floor (STEP_80, REV-54 §6).** An observation below
    /// `LimitsDatabaseAdapter.quotaCeilingObservationFloorPct` cannot be a window exhaustion and
    /// is not written: this is the single choke point every caller passes through, and the table
    /// is permanent, so a bad row here is permanent too. Discards are logged (value + source
    /// **basename** only, §10.6) rather than silently dropped.
    ///
    /// - Returns: `true` when the observation was accepted for insert, `false` when the floor
    ///   discarded it. (An accepted row deduped away by `INSERT OR IGNORE` still returns `true` —
    ///   the caller's observation was plausible; the row simply already existed.)
    @discardableResult
    public func writeQuotaLimitEvent(
        tool: Tool,
        timestamp: Date,
        utilizationPct: Double,
        windowType: WindowType,
        sourceFile: String,
        planType: String
    ) throws -> Bool {
        guard utilizationPct >= LimitsDatabaseAdapter.quotaCeilingObservationFloorPct else {
            Logger.info("Quota 429 below ceiling floor — not recorded", component: .sqliteStore,
                        metadata: ["tool": tool.rawValue,
                                   "util": "\(utilizationPct)",
                                   "floor": "\(LimitsDatabaseAdapter.quotaCeilingObservationFloorPct)",
                                   "source": sourceFile])
            return false
        }
        do {
            try withPool { pool in
                try pool.write { db in
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO quota_limit_events
                            (tool, timestamp, utilization_pct, window_type, source_file, plan_type)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [tool.rawValue, Int(timestamp.timeIntervalSince1970),
                                         utilizationPct, windowType.rawValue, sourceFile, planType])
                }
            }
        } catch {
            Logger.error("Quota limit write failed", component: .sqliteStore,
                         metadata: ["tool": tool.rawValue, "error": "\(error)"])
            throw error
        }
        return true
    }

    /// Utilization percentages at which a quota 429 was observed for this tool/window, on the
    /// *current* plan only — filtering by `plan_type` is how a plan change resets the personal
    /// ceiling without deleting history (§9.4 rule 4, §17.1).
    public func readQuotaLimitUtilizations(
        tool: Tool,
        windowType: WindowType,
        planType: String
    ) throws -> [Double] {
        do {
            return try withPool { pool in
                try pool.read { db in
                    try Double.fetchAll(db, sql: """
                        SELECT utilization_pct FROM quota_limit_events
                        WHERE tool = ? AND window_type = ? AND plan_type = ?
                        """, arguments: [tool.rawValue, windowType.rawValue, planType])
                }
            }
        } catch {
            Logger.error("Quota limit read failed", component: .sqliteStore,
                         metadata: ["tool": tool.rawValue, "error": "\(error)"])
            throw error
        }
    }
}
