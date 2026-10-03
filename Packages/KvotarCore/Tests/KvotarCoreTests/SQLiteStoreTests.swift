import XCTest
import GRDB
@testable import KvotarCore

final class SQLiteStoreTests: XCTestCase {

    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory()
            .appending("kvotar-test-\(UUID().uuidString).db")
    }

    override func tearDown() {
        // Remove the db and any WAL/SHM sidecar files.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    // MARK: - Migration

    /// v21 (REV-78 / D-98) — a database written by an older build can hold `adaptive`,
    /// `compact_glyph` or `hidden`. The runtime already falls back to `both_stacked` because
    /// `init(rawValue:)` returns nil, but the *row* has to be rewritten too, or a diagnostics
    /// bundle keeps reporting a mode the app no longer has.
    func testV21RewritesRetiredMenuBarModes() async throws {
        for retired in ["adaptive", "compact_glyph", "hidden"] {
            let store = try SQLiteStore(path: dbPath)
            // Wind the DB back to v20 holding the retired value, the way an older build left it.
            try await store.withPool { pool in
                try pool.write { db in
                    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                                   arguments: ["v21_retire_menu_bar_modes"])
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO settings (key, value, updated_at)
                        VALUES ('menu_bar_display_mode', ?, 0)
                        """, arguments: [retired])
                    try db.execute(
                        sql: "UPDATE settings SET value = '20' WHERE key = 'schema_version'")
                }
            }

            // Reopening runs v21.
            let reopened = try SQLiteStore(path: dbPath)
            let mode = try await reopened.readSetting(key: "menu_bar_display_mode")
            XCTAssertEqual(mode, "both_stacked", "\(retired) must be rewritten, not just ignored")
            let version = try await reopened.readSetting(key: "schema_version")
            XCTAssertEqual(version, "21")

            // The rewrite is audited: raw migration SQL bypasses `writeSetting`, so v21 inserts
            // the `settings_changes` row itself. Without it a diagnostics bundle would show a
            // mode that silently changed.
            let audit: [String] = try await reopened.withPool { pool in
                try pool.read { db in
                    try String.fetchAll(db, sql: """
                        SELECT old_value || '→' || new_value FROM settings_changes
                         WHERE key = 'menu_bar_display_mode' ORDER BY id DESC LIMIT 1
                        """)
                }
            }
            XCTAssertEqual(audit, ["\(retired)→both_stacked"],
                           "the rewrite must leave an audit row")

            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbPath + suffix)
            }
        }
    }

    /// The surviving modes are never touched by v21.
    func testV21LeavesLiveMenuBarModesAlone() async throws {
        for live in ["both_stacked", "claude_only", "codex_only"] {
            let store = try SQLiteStore(path: dbPath)
            try await store.withPool { pool in
                try pool.write { db in
                    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                                   arguments: ["v21_retire_menu_bar_modes"])
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO settings (key, value, updated_at)
                        VALUES ('menu_bar_display_mode', ?, 0)
                        """, arguments: [live])
                }
            }
            let reopened = try SQLiteStore(path: dbPath)
            let mode = try await reopened.readSetting(key: "menu_bar_display_mode")
            XCTAssertEqual(mode, live)

            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbPath + suffix)
            }
        }
    }

    func testMigrationCreatesAllTablesAndSchemaVersion() async throws {
        let store = try SQLiteStore(path: dbPath)

        let expectedTables = [
            "accounts", "poll_snapshots", "notification_events",
            "local_sessions", "local_usage_events", "poll_health_events",
            "quota_limit_events", "state_transitions", "settings",
            // v7 learning substrate (§17.1 — REV-42 + REV-43, STEP_50).
            "history_rollups", "forecast_log", "session_summaries",
            "discontinuity_events", "popover_opens", "settings_changes",
            // v9 diagnostics capture (§17.1 — REV-52, STEP_72).
            "raw_payloads", "payload_shapes", "parse_anomalies", "app_lifecycle_events",
            // v10 quota series (§17.1 — REV-53, STEP_76).
            "quota_series",
            // v14 unpriced-model signal (§17.1 — REV-62 §5.3, STEP_92).
            "unpriced_models",
            // v25 model limit series (§17.1 — STEP_209).
            "model_limit_series",
        ]

        try await store.withPool { pool in
            try pool.read { db in
                for table in expectedTables {
                    XCTAssertTrue(try db.tableExists(table), "missing table: \(table)")
                }
                let version = try String.fetchOne(
                    db, sql: "SELECT value FROM settings WHERE key = 'schema_version'")
                XCTAssertEqual(version, "25",
                               "v25 model limit series applied (STEP_209)")
                // v2 additive forensic columns on poll_health_events (§9.5 — R31-4).
                let cols = try db.columns(in: "poll_health_events").map(\.name)
                for col in ["response_headers_json", "response_body", "category",
                            "last_primary_used_pct", "last_secondary_used_pct",
                            "last_primary_resets_at", "last_extra_usage_enabled",
                            "null_window_source"] {
                    XCTAssertTrue(cols.contains(col), "missing forensic column: \(col)")
                }
                // v5 additive monthly-limit columns on poll_snapshots (§17 — REV-38, STEP_43)
                // + v6 unit pair (§17 — REV-40, STEP_46)
                // + v18 primary_window_seconds (§17 — P1-28, STEP_101).
                let snapCols = try db.columns(in: "poll_snapshots").map(\.name)
                for col in ["monthly_limit", "monthly_used", "monthly_remaining_pct",
                            "monthly_resets_at", "monthly_currency", "monthly_exponent",
                            "primary_window_seconds"] {
                    XCTAssertTrue(snapCols.contains(col), "missing poll_snapshots column: \(col)")
                }
            }
        }
    }

    // MARK: - Round-trips (raw SQL) for the 4 key tables

    func testAccountsRoundTrip() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO accounts (tool, email, plan_type, updated_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: ["claude", "a@b.c", "max", 1_700_000_000])
            }
            try pool.read { db in
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM accounts WHERE tool = ?", arguments: ["claude"])
                XCTAssertEqual(row?["plan_type"], "max")
                XCTAssertEqual(row?["updated_at"], 1_700_000_000)
            }
        }
    }

    func testPollSnapshotsRoundTrip() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.withPool { pool in
            let id: Int64 = try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO poll_snapshots (tool, polled_at, primary_used_pct)
                    VALUES (?, ?, ?)
                    """, arguments: ["codex", 1_700_000_100, 42.5])
                return db.lastInsertedRowID
            }
            try pool.read { db in
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM poll_snapshots WHERE id = ?", arguments: [id])
                XCTAssertEqual(row?["tool"], "codex")
                XCTAssertEqual(row?["primary_used_pct"], 42.5)
            }
        }
    }

    func testLocalSessionsRoundTrip() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO local_sessions (session_id, tool, last_seen_at)
                    VALUES (?, ?, ?)
                    """, arguments: ["s1", "claude", 1_700_000_200])
            }
            try pool.read { db in
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM local_sessions WHERE session_id = ? AND tool = ?",
                    arguments: ["s1", "claude"])
                XCTAssertEqual(row?["last_seen_at"], 1_700_000_200)
            }
        }
    }

    func testLocalUsageEventsRoundTripWithParent() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO local_sessions (session_id, tool, last_seen_at)
                    VALUES (?, ?, ?)
                    """, arguments: ["s1", "claude", 1_700_000_200])
                try db.execute(sql: """
                    INSERT INTO local_usage_events
                        (session_id, tool, dedup_key, recorded_at, input_tokens, output_tokens)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: ["s1", "claude", "req-1", 1_700_000_300, 100, 200])
            }
            try pool.read { db in
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM local_usage_events WHERE dedup_key = ?",
                    arguments: ["req-1"])
                XCTAssertEqual(row?["input_tokens"], 100)
                XCTAssertEqual(row?["output_tokens"], 200)
                // Defaulted columns should be 0, not null.
                XCTAssertEqual(row?["cache_read_tokens"], 0)
            }
        }
    }

    // MARK: - Foreign key enforcement

    func testUsageEventWithoutParentSessionFails() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.withPool { pool in
            XCTAssertThrowsError(
                try pool.write { db in
                    try db.execute(sql: """
                        INSERT INTO local_usage_events
                            (session_id, tool, dedup_key, recorded_at)
                        VALUES (?, ?, ?, ?)
                        """, arguments: ["ghost", "claude", "req-x", 1_700_000_300])
                },
                "insert without parent local_sessions row must violate the composite FK"
            )
        }
    }

    // MARK: - settings key-value API (STEP_27)

    func testSettingsRoundTripAndAbsentKey() async throws {
        let store = try SQLiteStore(path: dbPath)

        let absent = try await store.readSetting(key: "notification_project_name_enabled")
        XCTAssertNil(absent, "an unwritten key must read nil (callers apply their own default)")

        try await store.writeSetting(key: "notification_project_name_enabled", value: "false")
        let value = try await store.readSetting(key: "notification_project_name_enabled")
        XCTAssertEqual(value, "false")

        try await store.writeSetting(key: "notification_project_name_enabled", value: "true")
        let replaced = try await store.readSetting(key: "notification_project_name_enabled")
        XCTAssertEqual(replaced, "true", "INSERT OR REPLACE must overwrite on the key PK")
    }

    // MARK: - settings_changes audit (§17.1 — REV-43, STEP_50)

    private func auditRows(_ store: SQLiteStore, key: String)
        async throws -> [(old: String?, new: String?)]
    {
        try await store.withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT * FROM settings_changes WHERE key = ? ORDER BY id
                    """, arguments: [key])
                    .map { (old: $0["old_value"], new: $0["new_value"]) }
            }
        }
    }

    func testSettingsWriteAppendsAuditRowWithNullOldValueOnAbsentKey() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeSetting(key: "menu_bar_display_mode", value: "fixture_a")

        let rows = try await auditRows(store, key: "menu_bar_display_mode")
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].old, "absent key must audit old_value NULL")
        XCTAssertEqual(rows[0].new, "fixture_a")
    }

    func testSettingsChangeAuditsOldAndNewValues() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeSetting(key: "menu_bar_display_mode", value: "fixture_a")
        try await store.writeSetting(key: "menu_bar_display_mode", value: "fixture_b")

        let rows = try await auditRows(store, key: "menu_bar_display_mode")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].old, "fixture_a")
        XCTAssertEqual(rows[1].new, "fixture_b")
        let stored = try await store.readSetting(key: "menu_bar_display_mode")
        XCTAssertEqual(stored, "fixture_b")
    }

    func testSettingsNoOpWriteProducesNoAuditRowAndKeepsTimestamp() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeSetting(key: "menu_bar_display_mode", value: "fixture_a")
        try await store.writeSetting(key: "menu_bar_display_mode", value: "fixture_a")

        let rows = try await auditRows(store, key: "menu_bar_display_mode")
        XCTAssertEqual(rows.count, 1, "a no-op write must not append an audit row")
        let stored = try await store.readSetting(key: "menu_bar_display_mode")
        XCTAssertEqual(stored, "fixture_a")
    }
}
