import Foundation
import GRDB

// Read-only diagnostics used by the `kvotar` CLI (STEP_54 `doctor`). These queries are safe
// on a connection opened via `openReadOnly(path:)` — they only SELECT. The one exception is
// `backup(to:)` (STEP_73), which needs a writable connection to run `VACUUM INTO` even though it
// never modifies the source database.
extension SQLiteStore {
    /// Safety-filtered extended evidence for an open diagnostics window — the payload tables only,
    /// without account rows, project paths, settings or local usage details. Since STEP_136 the
    /// **unfiltered** `VACUUM INTO` copy ships beside this JSON in the same archive (pre-alpha, by
    /// user decision), so this is the filtered view, not the export boundary. Whether the filtered
    /// view still earns its place is the pre-release privacy pass's question.
    public func extendedDiagnosticsJSON() throws -> Data {
        try withPool { pool in
            try pool.read { db in
                let payloads: [[String: Any]] = try Row.fetchAll(db, sql: """
                    SELECT tool, endpoint, captured_at, http_status, body, shape_hash
                    FROM raw_payloads ORDER BY captured_at, id
                    """).map { row in
                        var item: [String: Any] = [
                            "tool": row["tool"] as String,
                            "endpoint": row["endpoint"] as String,
                            "captured_at": row["captured_at"] as Int,
                            "body": row["body"] as String,
                            "shape_hash": row["shape_hash"] as String,
                        ]
                        if let status = row["http_status"] as Int? { item["http_status"] = status }
                        return item
                    }
                let shapes: [[String: Any]] = try Row.fetchAll(db, sql: """
                    SELECT tool, endpoint, shape_hash, first_seen_at, last_seen_at, field_paths
                    FROM payload_shapes ORDER BY first_seen_at, tool, endpoint
                    """).map { row in
                        [
                            "tool": row["tool"] as String,
                            "endpoint": row["endpoint"] as String,
                            "shape_hash": row["shape_hash"] as String,
                            "first_seen_at": row["first_seen_at"] as Int,
                            "last_seen_at": row["last_seen_at"] as Int,
                            "field_paths": row["field_paths"] as String,
                        ]
                    }
                let anomalies: [[String: Any]] = try Row.fetchAll(db, sql: """
                    SELECT tool, source_file, line_number, observed_at, field_names
                    FROM parse_anomalies ORDER BY observed_at, id
                    """).map { row in
                        var item: [String: Any] = [
                            "tool": row["tool"] as String,
                            "source_file": ((row["source_file"] as String) as NSString).lastPathComponent,
                            "observed_at": row["observed_at"] as Int,
                        ]
                        if let line = row["line_number"] as Int? { item["line_number"] = line }
                        if let names = row["field_names"] as String? { item["field_names"] = names }
                        return item
                    }
                return try JSONSerialization.data(
                    withJSONObject: ["payloads": payloads, "shapes": shapes, "anomalies": anomalies],
                    options: [.prettyPrinted, .sortedKeys])
            }
        }
    }

    /// Identifier of the most recently applied migration (GRDB's own `grdb_migrations` ledger),
    /// e.g. `"v8_credential_expired_nullable"`. `nil` on a database with no migrations recorded.
    /// Proves the CLI can actually *query* the shared DB, not merely open the connection.
    public func latestSchemaMigration() throws -> String? {
        try withPool { pool in
            try pool.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1")
            }
        }
    }

    /// Writes a **checkpointed** copy of the database to `path` — the one operation a diagnostics
    /// bundle cannot get from a file copy (REV-52 §6.1, STEP_73).
    ///
    /// The database is WAL by deliberate design (app and CLI share the file), so a bare `.db` copy
    /// alone omits everything still in `-wal` — the most recent and most interesting activity —
    /// **silently and with no error**, and a copy taken mid-write can open cleanly and report
    /// plausible wrong numbers. `VACUUM INTO` folds the WAL in and emits a single consistent file.
    ///
    /// Runs on `writeWithoutTransaction`: `VACUUM` cannot execute inside a transaction, and both
    /// `pool.read` and `pool.write` open one. `path` must not already exist (SQLite refuses to
    /// overwrite) — callers stage into a fresh directory.
    public func backup(to path: String) throws {
        do {
            try withPool { pool in
                try pool.writeWithoutTransaction { db in
                    try db.execute(sql: "VACUUM INTO ?", arguments: [path])
                }
            }
        } catch {
            Logger.error("Database backup failed", component: .sqliteStore,
                         metadata: ["error": "\(error)"])
            throw error
        }
    }

    /// The row counts and coverage window a diagnostics manifest reports (REV-52 §6.1, STEP_73).
    /// One read; every field is a fact about the database, never a derived verdict.
    public func diagnosticsSummary() throws -> DiagnosticsSummary {
        try withPool { pool in
            try pool.read { db in
                func count(_ table: String) -> Int {
                    ((try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")) ?? nil) ?? 0
                }
                let windowPayloads = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM raw_payloads WHERE keep_reason = 'window'") ?? 0
                let shapeKeeps = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM raw_payloads WHERE keep_reason = 'shape_change'") ?? 0
                let bounds = try Row.fetchOne(
                    db, sql: "SELECT MIN(captured_at) AS lo, MAX(captured_at) AS hi FROM raw_payloads")
                let earliest: Int? = bounds?["lo"]
                let latest: Int? = bounds?["hi"]
                let captureSetting = try String.fetchOne(
                    db, sql: "SELECT value FROM settings WHERE key = ?",
                    arguments: [DiagnosticsCapture.settingsKey])
                let toggles = try Row.fetchAll(db, sql: """
                    SELECT changed_at, old_value, new_value FROM settings_changes
                    WHERE key = ? ORDER BY changed_at
                    """, arguments: [DiagnosticsCapture.settingsKey])
                    .map { row in
                        DiagnosticsSummary.CaptureToggle(
                            changedAt: row["changed_at"],
                            from: row["old_value"], to: row["new_value"])
                    }
                return DiagnosticsSummary(
                    schemaMigration: try String.fetchOne(
                        db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1"),
                    capturedPayloadsWindow: windowPayloads,
                    capturedPayloadsShapeKeeps: shapeKeeps,
                    earliestPayloadAt: earliest,
                    latestPayloadAt: latest,
                    payloadShapes: count("payload_shapes"),
                    parseAnomalies: count("parse_anomalies"),
                    lifecycleEvents: count("app_lifecycle_events"),
                    pollSnapshots: count("poll_snapshots"),
                    forecastLogRows: count("forecast_log"),
                    localSessions: count("local_sessions"),
                    unpricedModels: try Row.fetchAll(db, sql: """
                        SELECT provider, model, first_seen_at, last_seen_at, observation_count
                        FROM unpriced_models ORDER BY first_seen_at, provider, model
                        """).map { row in
                            UnpricedModelObservation(
                                provider: row["provider"], model: row["model"],
                                firstSeenAt: row["first_seen_at"], lastSeenAt: row["last_seen_at"],
                                observationCount: row["observation_count"])
                        },
                    captureSettingValue: captureSetting,
                    captureToggles: toggles)
            }
        }
    }
}

/// What the diagnostics manifest reports about the copied database (§17.1, REV-52 §6.1).
public struct DiagnosticsSummary: Codable, Sendable {
    public struct CaptureToggle: Codable, Sendable {
        public let changedAt: Int
        public let from: String?
        public let to: String?
    }

    public let schemaMigration: String?
    public let capturedPayloadsWindow: Int
    public let capturedPayloadsShapeKeeps: Int
    /// Unix seconds; the **period covered** by captured payloads. Nil when nothing was captured —
    /// which the manifest's capture flag is what disambiguates ("off" vs "nothing happened").
    public let earliestPayloadAt: Int?
    public let latestPayloadAt: Int?
    public let payloadShapes: Int
    public let parseAnomalies: Int
    public let lifecycleEvents: Int
    public let pollSnapshots: Int
    public let forecastLogRows: Int
    public let localSessions: Int
    /// The `unpriced_models` rows themselves, not a count (§17.1 — REV-62 §5.3, STEP_92): the
    /// table exists so someone can be told *which* pricing row is missing, and a count would
    /// send the reader into the copied database for the name. Expected empty; tiny when not.
    public let unpricedModels: [UnpricedModelObservation]
    /// The persisted `diagnostics_capture_enabled` row (`"1"`/`"0"`/absent).
    public let captureSettingValue: String?
    /// Toggle history from `settings_changes` — free per §6.1, and what makes a mid-week change
    /// readable rather than misleading.
    public let captureToggles: [CaptureToggle]
}
