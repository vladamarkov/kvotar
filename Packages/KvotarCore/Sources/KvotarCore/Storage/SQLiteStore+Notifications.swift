import Foundation
import GRDB

// Fired-notification log (§17.1, §13.2). Append-only per tool per 5-hour window. The only
// post-insert mutation is setting `dismissed_at`. `NotificationEngine` enforces cooldown, re-arm
// eligibility, and max-per-window entirely from `COUNT(*)` and `dismissed_at` queries against
// these rows — there is no in-DB `rearm_triggered` flag (§13.2). Rows are learning substrate
// (v5.17 — REV-42): they survive window resets and age out at 90 days on `fired_at` via the
// shared cleanup job (§17.2); prior-window rows are invisible to enforcement because every
// query below scopes `window_start = :current`.
//
// Timestamps written as `Int` unix seconds (PATTERNS.md §SQLite rule).
extension SQLiteStore {

    /// Appends one fired-notification row. `eventType`/`copyVariant` are raw strings matching the
    /// column's documented value list (§17.1). `dismissed_at` starts null.
    public func writeNotificationEvent(
        tool: Tool,
        eventType: NotificationEventType,
        firedAt: Int,
        windowStart: Int,
        copyVariant: String?
    ) throws {
        do {
            try withPool { pool in
                try pool.write { db in
                    try db.execute(sql: """
                        INSERT INTO notification_events
                            (tool, event_type, fired_at, window_start, dismissed_at, copy_variant)
                        VALUES (?, ?, ?, ?, NULL, ?)
                        """, arguments: [
                            tool.rawValue, eventType.rawValue, firedAt, windowStart, copyVariant,
                        ])
                }
            }
        } catch {
            Logger.error("Notification event write failed", component: .sqliteStore,
                         metadata: ["tool": tool.rawValue, "event": eventType.rawValue,
                                    "error": "\(error)"])
            throw error
        }
    }

    /// Number of rows already fired for this tool/event/window — the max-per-window gate.
    public func countNotificationEvents(
        tool: Tool,
        eventType: NotificationEventType,
        windowStart: Int
    ) throws -> Int {
        try withPool { pool in
            try pool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM notification_events
                    WHERE tool = ? AND event_type = ? AND window_start = ?
                    """, arguments: [tool.rawValue, eventType.rawValue, windowStart]) ?? 0
            }
        }
    }

    /// Most recent fire for this tool/event/window — its `fired_at` drives cooldown checks and
    /// `dismissed_at` drives re-arm eligibility. `nil` if none fired yet in this window.
    public func lastNotificationEvent(
        tool: Tool,
        eventType: NotificationEventType,
        windowStart: Int
    ) throws -> (firedAt: Int, dismissedAt: Int?)? {
        try withPool { pool in
            try pool.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT fired_at, dismissed_at FROM notification_events
                    WHERE tool = ? AND event_type = ? AND window_start = ?
                    ORDER BY fired_at DESC LIMIT 1
                    """, arguments: [tool.rawValue, eventType.rawValue, windowStart]) else {
                    return nil
                }
                return (firedAt: row["fired_at"], dismissedAt: row["dismissed_at"])
            }
        }
    }

    /// Marks the most recent fire for this tool/event/window as dismissed (re-arm eligibility).
    /// No-op if there is no matching row.
    public func markNotificationDismissed(
        tool: Tool,
        eventType: NotificationEventType,
        windowStart: Int,
        dismissedAt: Int
    ) throws {
        do {
            try withPool { pool in
                try pool.write { db in
                    try db.execute(sql: """
                        UPDATE notification_events SET dismissed_at = ?
                        WHERE id = (
                            SELECT id FROM notification_events
                            WHERE tool = ? AND event_type = ? AND window_start = ?
                            ORDER BY fired_at DESC LIMIT 1
                        )
                        """, arguments: [dismissedAt, tool.rawValue, eventType.rawValue, windowStart])
                }
            }
        } catch {
            Logger.error("Notification dismissal write failed", component: .sqliteStore,
                         metadata: ["tool": tool.rawValue, "event": eventType.rawValue,
                                    "error": "\(error)"])
            throw error
        }
    }
}
