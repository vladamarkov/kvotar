import Foundation
import GRDB

// The first reader of `model_limit_series` (STEP_227 — REV-104 §4). The table is written in
// `writePoll` (STEP_209); this is a bounded, read-only history read for the History report's
// weekly-limit fold. Grouping into limit instances is `QuotaWindowOutcomes.compute`'s job.
extension SQLiteStore {

    /// One stored reading of one model allowance's window.
    public struct ModelLimitSeriesRow: Sendable, Equatable {
        public let polledAt: Date
        /// Provider id where one exists, else the name (STEP_209).
        public let limitKey: String
        public let limitName: String?
        /// `primary` / `secondary`.
        public let windowSlot: String
        public let usedPct: Double
        public let resetsAt: Date
        public let windowSeconds: Int?

        public init(polledAt: Date, limitKey: String, limitName: String?, windowSlot: String,
                    usedPct: Double, resetsAt: Date, windowSeconds: Int?) {
            self.polledAt = polledAt
            self.limitKey = limitKey
            self.limitName = limitName
            self.windowSlot = windowSlot
            self.usedPct = usedPct
            self.resetsAt = resetsAt
            self.windowSeconds = windowSeconds
        }
    }

    /// Every model-allowance reading for `tool` in `[since, until)`, oldest first. Rows without
    /// a utilization or a reset are skipped — there is no window to fold them into. Half-open,
    /// matching `quotaSeriesRange`.
    public func modelLimitSeriesRange(tool: Tool, since: Date,
                                      until: Date) throws -> [ModelLimitSeriesRow] {
        try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT polled_at, limit_key, limit_name, window_slot, used_pct, resets_at,
                           window_seconds
                      FROM model_limit_series
                    WHERE tool = ? AND polled_at >= ? AND polled_at < ?
                      AND used_pct IS NOT NULL AND resets_at IS NOT NULL
                    ORDER BY polled_at ASC
                    """, arguments: [
                        tool.rawValue,
                        Int(since.timeIntervalSince1970), Int(until.timeIntervalSince1970),
                    ])
                .map { row in
                    ModelLimitSeriesRow(
                        polledAt: Date(timeIntervalSince1970:
                            TimeInterval(row["polled_at"] as Int? ?? 0)),
                        limitKey: row["limit_key"] as String? ?? "",
                        limitName: row["limit_name"] as String?,
                        windowSlot: row["window_slot"] as String? ?? "",
                        usedPct: row["used_pct"] as Double? ?? 0,
                        resetsAt: Date(timeIntervalSince1970:
                            TimeInterval(row["resets_at"] as Int? ?? 0)),
                        windowSeconds: row["window_seconds"] as Int?)
                }
            }
        }
    }
}
