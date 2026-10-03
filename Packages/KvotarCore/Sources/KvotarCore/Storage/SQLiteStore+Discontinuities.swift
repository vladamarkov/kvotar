import Foundation
import GRDB

// STEP_52 substrate writers (§17.1): `discontinuity_events` (the moments table) and
// `popover_opens` (the glance log). Append-only; read only by the History window
// (`planChanges` in +History, `discontinuityEvents` below — STEP_109/STEP_114). Failures log
// at WARN — the substrate exception to the store's ERROR rule (the ForecastLog precedent): a
// lost row degrades learning data only and must never read as a live-path fault, nor block
// polling or the popover.
//
// Timestamps written as `Int` unix seconds (PATTERNS.md §SQLite rule).
extension SQLiteStore {

    /// Appends one `discontinuity_events` row per observation, all in one transaction —
    /// a single poll can reveal several moments (e.g. a limit change and a rollover).
    public func writeDiscontinuityEvents(tool: Tool, observedAt: Date,
                                         events: [DiscontinuityObservation]) throws {
        guard !events.isEmpty else { return }
        do {
            try withPool { pool in
                try pool.write { db in
                    for event in events {
                        try db.execute(sql: """
                            INSERT INTO discontinuity_events
                                (tool, event_type, observed_at, window_type,
                                 old_value, new_value, utilization_pct)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [
                                tool.rawValue,
                                event.eventType.rawValue,
                                Int(observedAt.timeIntervalSince1970),
                                event.windowType,
                                event.oldValue,
                                event.newValue,
                                event.utilizationPct,
                            ])
                    }
                }
            }
        } catch {
            Logger.warning("discontinuity_events write failed", component: .sqliteStore,
                           metadata: ["tool": tool.rawValue,
                                      "count": "\(events.count)",
                                      "error": "\(error)"])
            throw error
        }
    }

    /// One `discontinuity_events` row as stored — raw strings at the storage boundary (§17.1:
    /// "typed at read by the owning component"). The History window's marker read (STEP_114).
    public struct DiscontinuityRow: Sendable, Equatable {
        public let at: Date
        public let eventType: String
        public let windowType: String?
        public let oldValue: String?
        public let newValue: String?
        public let utilizationPct: Double?

        public init(at: Date, eventType: String, windowType: String?, oldValue: String?,
                    newValue: String?, utilizationPct: Double?) {
            self.at = at
            self.eventType = eventType
            self.windowType = windowType
            self.oldValue = oldValue
            self.newValue = newValue
            self.utilizationPct = utilizationPct
        }
    }

    /// Rows for `tool` of any of `types` observed in `[since, until)`, oldest first. Read-only.
    public func discontinuityEvents(tool: Tool, since: Date, until: Date,
                                    types: [String]) throws -> [DiscontinuityRow] {
        guard !types.isEmpty else { return [] }
        let start = Int(since.timeIntervalSince1970)
        let end = Int(until.timeIntervalSince1970)
        let placeholders = types.map { _ in "?" }.joined(separator: ", ")
        var arguments: [DatabaseValueConvertible] = [tool.rawValue, start, end]
        arguments.append(contentsOf: types)
        return try withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT observed_at, event_type, window_type, old_value, new_value,
                           utilization_pct
                    FROM discontinuity_events
                    WHERE tool = ? AND observed_at >= ? AND observed_at < ?
                      AND event_type IN (\(placeholders))
                    ORDER BY observed_at ASC, id ASC
                    """, arguments: StatementArguments(arguments))
                .map { row in
                    let at: Int = row["observed_at"]
                    return DiscontinuityRow(
                        at: Date(timeIntervalSince1970: TimeInterval(at)),
                        eventType: row["event_type"], windowType: row["window_type"],
                        oldValue: row["old_value"], newValue: row["new_value"],
                        utilizationPct: row["utilization_pct"])
                }
            }
        }
    }

    /// Appends one `popover_opens` glance row — what the app was showing at the open
    /// (what-was-shown facts, the §17 exception). Nil state = unknown/loading as rendered.
    public func writePopoverOpen(openedAt: Date, tab: String?,
                                 claudeState: String?, claudeUsedPct: Double?,
                                 codexState: String?, codexUsedPct: Double?) throws {
        do {
            try withPool { pool in
                try pool.write { db in
                    try db.execute(sql: """
                        INSERT INTO popover_opens
                            (opened_at, tab, claude_state, claude_primary_used_pct,
                             codex_state, codex_primary_used_pct)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            Int(openedAt.timeIntervalSince1970),
                            tab,
                            claudeState,
                            claudeUsedPct,
                            codexState,
                            codexUsedPct,
                        ])
                }
            }
        } catch {
            Logger.warning("popover_opens write failed", component: .sqliteStore,
                           metadata: ["error": "\(error)"])
            throw error
        }
    }
}
