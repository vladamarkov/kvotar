import Foundation
import GRDB

// StateEngine transition log (§17.1). Append-only. Written by `StateEngine` on every state
// change; read by exactly one runtime component — the History window's bounded
// critical-observation read below (STEP_158, REV-84), which surfaces recorded entries into the
// four critical states. Everything else about the table stays debugging/dogfood substrate.
//
// Timestamps written as `Int` unix seconds (PATTERNS.md §SQLite rule).
extension SQLiteStore {

    /// Appends one row to `state_transitions`. `from`/`to` are the raw `AppState` strings and
    /// `triggeredBy` the raw `StateTrigger` string, matching the columns' documented value lists.
    public func writeStateTransition(
        tool: Tool,
        from: AppState,
        to: AppState,
        triggeredBy: StateTrigger,
        utilizationPct: Double?
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        do {
            try withPool { pool in
                try pool.write { db in
                    try db.execute(sql: """
                        INSERT INTO state_transitions
                            (tool, timestamp, from_state, to_state, triggered_by, utilization_pct)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            tool.rawValue, now, from.rawValue, to.rawValue,
                            triggeredBy.rawValue, utilizationPct,
                        ])
                }
            }
        } catch {
            Logger.error("State transition write failed", component: .sqliteStore,
                         metadata: ["tool": tool.rawValue, "error": "\(error)"])
            throw error
        }
    }

    /// One `state_transitions` row whose `to_state` is critical, as stored — the raw string at
    /// the storage boundary (§17.1: "typed at read by the owning component"; the History reader
    /// maps it to `HistoryReport.CriticalObservation`). `triggered_by` deliberately does not
    /// cross this boundary.
    public struct CriticalStateEntry: Sendable, Equatable {
        public let at: Date
        public let toState: String
        public let utilizationPct: Double?

        public init(at: Date, toState: String, utilizationPct: Double?) {
            self.at = at
            self.toState = toState
            self.utilizationPct = utilizationPct
        }
    }

    /// The stored `to_state` values the History window reports as critical observations
    /// (STEP_158 — REV-84 §3.2). Filtering happens in SQL, so an unfamiliar stored state simply
    /// never matches — skipped by construction, never a failed report.
    static let criticalToStates = ["at_risk", "bad_timing", "over_quota", "spend_control"]

    /// Transitions **into** a critical state for `tool` in `[since, until)`, oldest first.
    /// Read-only; the bounded History read (STEP_158). Rows older than the table's 90-day
    /// retention are gone by design — absence of a row is absence of retained evidence.
    public func criticalStateEntries(tool: Tool, since: Date,
                                     until: Date) throws -> [CriticalStateEntry] {
        let start = Int(since.timeIntervalSince1970)
        let end = Int(until.timeIntervalSince1970)
        let placeholders = Self.criticalToStates.map { _ in "?" }.joined(separator: ", ")
        var arguments: [DatabaseValueConvertible] = [tool.rawValue, start, end]
        arguments.append(contentsOf: Self.criticalToStates)
        return try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT timestamp, to_state, utilization_pct FROM state_transitions
                    WHERE tool = ? AND timestamp >= ? AND timestamp < ?
                      AND to_state IN (\(placeholders))
                    ORDER BY timestamp ASC, id ASC
                    """, arguments: StatementArguments(arguments))
                .map { row in
                    let at: Int = row["timestamp"]
                    return CriticalStateEntry(at: Date(timeIntervalSince1970: TimeInterval(at)),
                                              toState: row["to_state"],
                                              utilizationPct: row["utilization_pct"])
                }
            }
        }
    }
}
