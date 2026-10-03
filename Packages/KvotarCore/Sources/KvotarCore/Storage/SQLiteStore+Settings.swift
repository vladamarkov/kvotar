import Foundation
import GRDB

// `settings` key-value store access (§17.1). STEP_27: first runtime consumer is the
// notification project-name opt-out key (`notification_project_name_enabled`, absent ⇒ true).
// STEP_144: the four notification-group switches (`NotificationGroup.settingsKey` —
// `notification_at_risk_enabled` / `_fast_burn_` / `_over_quota_` / `_window_reset_`,
// `"true"`/`"false"`, absent ⇒ on / on / on / off), written by the first-run window's screen 4
// and the right-click **Notify me ▸** submenu, read by `NotificationEngine` arbitration.
//
// Timestamps written as `Int` unix seconds (PATTERNS.md §SQLite rule).
extension SQLiteStore {

    /// The stored value for `key`, or nil when the key has never been written.
    public func readSetting(key: String) throws -> String? {
        try withPool { pool in
            try pool.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?",
                                    arguments: [key])
            }
        }
    }

    /// Upserts `value` for `key` (`INSERT OR REPLACE` on the key PK). A nil `value` stores SQL
    /// NULL — the key exists with no value; use it to reset a setting to "unset" semantics.
    ///
    /// Every effective write also appends a `settings_changes` audit row (old → new) in the same
    /// transaction — the REPLACE no longer erases the trail (§17.1, v5.18/REV-43). A no-op write
    /// (key exists, stored value equals the new one) is skipped entirely: no settings write, no
    /// audit row.
    public func writeSetting(key: String, value: String?) throws {
        let now = Int(Date().timeIntervalSince1970)
        do {
            try withPool { pool in
                try pool.write { db in
                    let existing = try Row.fetchOne(
                        db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
                    let oldValue: String? = existing?["value"]
                    if existing != nil, oldValue == value { return }
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)",
                        arguments: [key, value, now])
                    // Sensitive-key rule (§17.1): if a key ever holds sensitive material, log the
                    // change with both value columns null — the fact survives, the content never
                    // lands. No Pre-Alpha key is sensitive, so no branch exists yet.
                    try db.execute(sql: """
                        INSERT INTO settings_changes (changed_at, key, old_value, new_value)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [now, key, oldValue, value])
                }
            }
        } catch {
            Logger.error("Setting write failed", component: .sqliteStore,
                         metadata: ["key": key, "error": "\(error)"])
            throw error
        }
    }
}
