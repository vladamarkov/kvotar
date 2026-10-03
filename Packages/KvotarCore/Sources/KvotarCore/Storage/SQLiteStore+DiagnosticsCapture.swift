import Foundation
import GRDB

// Diagnostics-capture writers (§17.1, REV-52 / STEP_72). Append-only; read by no runtime
// component — this is evidence for a human reading a bundle, never an input to a verdict.
//
// Failures log at WARN and rethrow for the caller's `try?`, the STEP_51 `forecast_log` exception
// to the store's ERROR rule: a lost diagnostic row degrades evidence only and must never read as a
// live-path fault.
//
// Timestamps written as `Int` unix seconds (PATTERNS.md §SQLite rule).
extension SQLiteStore {

    /// Records one safety-filtered provider response for the active 24-hour consent window.
    /// Structural shapes remain durable, but response bodies never do.
    public func writeRawPayload(
        tool: Tool, endpoint: String, body: Data, httpStatus: Int?, capturedAt: Date = Date()
    ) throws {
        // Re-check inside the store actor. A detached capture task can be queued just before the
        // consent window expires; the outer sink gate alone would let it write after cleanup.
        guard DiagnosticsCapture.isEnabled else { return }
        guard let sanitized = DiagnosticsPayloadSanitizer.sanitize(endpoint: endpoint, body: body)
        else {
            Logger.warning("Diagnostics payload rejected by safety filter", component: .sqliteStore,
                           metadata: ["endpoint": endpoint])
            return
        }
        let shape = PayloadShape.of(sanitized)
        let now = Int(capturedAt.timeIntervalSince1970)
        let text = String(decoding: sanitized, as: UTF8.self)
        let pathsJSON = (try? JSONEncoder().encode(shape.fieldPaths))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"

        do {
            try withPool { pool in
                try pool.write { db in
                    // Is this shape new for the endpoint? "New" means *unseen*, not "differs from
                    // the previous row" — an endpoint that alternates between two known shapes
                    // (Claude's nightly null five_hour window, §8.3) must not re-keep on every flip.
                    let known = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM payload_shapes
                            WHERE tool = ? AND endpoint = ? AND shape_hash = ?
                        )
                        """, arguments: [tool.rawValue, endpoint, shape.hash]) ?? false

                    try db.execute(sql: """
                        INSERT INTO payload_shapes
                            (tool, endpoint, shape_hash, first_seen_at, last_seen_at, field_paths)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(tool, endpoint, shape_hash)
                        DO UPDATE SET last_seen_at = excluded.last_seen_at
                        """, arguments: [tool.rawValue, endpoint, shape.hash, now, now, pathsJSON])

                    try insertPayload(db, tool: tool, endpoint: endpoint, capturedAt: now,
                                      httpStatus: httpStatus, body: text, shapeHash: shape.hash,
                                      keepReason: "window")
                    if !known {
                        Logger.info("New diagnostics payload shape observed", component: .sqliteStore,
                                    metadata: ["tool": tool.rawValue, "endpoint": endpoint,
                                               "fields": "\(shape.fieldPaths.count)"])
                    }
                }
            }
        } catch {
            Logger.warning("raw_payloads write failed", component: .sqliteStore,
                           metadata: ["endpoint": endpoint, "error": "\(error)"])
            throw error
        }
    }

    private func insertPayload(
        _ db: Database, tool: Tool, endpoint: String, capturedAt: Int, httpStatus: Int?,
        body: String, shapeHash: String, keepReason: String
    ) throws {
        try db.execute(sql: """
            INSERT INTO raw_payloads
                (tool, endpoint, captured_at, http_status, body, shape_hash, keep_reason)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [tool.rawValue, endpoint, capturedAt, httpStatus, body,
                             shapeHash, keepReason])
    }

    /// Appends one `parse_anomalies` row. Field **names** only — never values (§17).
    public func writeParseAnomaly(_ anomaly: ParseAnomaly) throws {
        guard DiagnosticsCapture.isEnabled else { return }
        let namesJSON = anomaly.fieldNames
            .flatMap { try? JSONEncoder().encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }
        do {
            try withPool { pool in
                try pool.write { db in
                    try db.execute(sql: """
                        INSERT INTO parse_anomalies
                            (tool, source_file, line_number, observed_at, error, field_names)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            anomaly.tool.rawValue,
                            anomaly.sourceFile,
                            anomaly.lineNumber,
                            Int(anomaly.observedAt.timeIntervalSince1970),
                            anomaly.error,
                            namesJSON,
                        ])
                }
            }
        } catch {
            Logger.warning("parse_anomalies write failed", component: .sqliteStore,
                           metadata: ["error": "\(error)"])
            throw error
        }
    }

    /// Appends one `app_lifecycle_events` row. Written **regardless** of the capture setting —
    /// app-lifecycle fact, not provider data, and the frame every other series is read against.
    public func writeLifecycleEvent(
        _ event: AppLifecycleEvent, appVersion: String?, occurredAt: Date = Date()
    ) throws {
        do {
            try withPool { pool in
                try pool.write { db in
                    try db.execute(sql: """
                        INSERT INTO app_lifecycle_events (event, occurred_at, app_version)
                        VALUES (?, ?, ?)
                        """, arguments: [event.rawValue,
                                         Int(occurredAt.timeIntervalSince1970),
                                         appVersion])
                }
            }
        } catch {
            Logger.warning("app_lifecycle_events write failed", component: .sqliteStore,
                           metadata: ["event": event.rawValue, "error": "\(error)"])
            throw error
        }
    }

    /// When the process that was running at `instant` launched — the app-coverage read the
    /// off-machine walk gates its leading slice on (REV-56 §5 — STEP_84). Returns nil when the
    /// history cannot prove one: the newest `launch`/`quit` at or before `instant` is a `quit`,
    /// or no such row exists at all (fresh install, or a database predating this table).
    ///
    /// **Why one row settles it.** Every row here is written by a live process, and a new process
    /// always writes `launch` first. So if the newest `launch`/`quit` at or before `instant` is a
    /// launch `L`, then no other process has started since `L`, and any independent evidence that
    /// *some* process was alive at `instant` makes it `L`'s process — alive continuously from `L`
    /// to `instant`. `sleep`/`wake` rows are deliberately not consulted: the process survives
    /// sleep with its file offsets, so sleep is covered, and the sleep/wake pairs are not a
    /// reliable awake/asleep ledger anyway (a dark wake polls without posting a `wake`).
    ///
    /// **Precondition on the caller:** it must hold that independent liveness evidence for
    /// `instant`. The walk's caller does — it passes the `polled_at` of a `quota_series` row,
    /// which only a running process could have written.
    ///
    /// A crash is handled without a marker of its own: if the process died and relaunched before
    /// `instant`, that relaunch *is* the newest launch and its later timestamp fails the caller's
    /// span check; if it died and did not relaunch, nothing could have written the caller's
    /// evidence row. Read-only.
    public func processRunningSince(at instant: Date) throws -> Date? {
        try withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(db, sql: """
                    SELECT event, occurred_at FROM app_lifecycle_events
                    WHERE event IN ('launch', 'quit') AND occurred_at <= ?
                    ORDER BY occurred_at DESC LIMIT 1
                    """, arguments: [Int(instant.timeIntervalSince1970)])
                guard let row, row["event"] as String? == AppLifecycleEvent.launch.rawValue,
                      let at = row["occurred_at"] as Int? else { return nil }
                return Date(timeIntervalSince1970: TimeInterval(at))
            }
        }
    }

    /// Drops every captured payload, both classes. Called when capture is turned **off**: off
    /// should mean *gone*, not merely "stop appending" (§10.7a). `payload_shapes` survives — it
    /// holds no bodies, and losing the drift history would be a real cost for no privacy gain.
    public func deleteCapturedPayloads() throws {
        do {
            try withPool { pool in
                try pool.write { db in
                    try db.execute(sql: "DELETE FROM raw_payloads")
                }
            }
        } catch {
            Logger.warning("raw_payloads delete failed", component: .sqliteStore,
                           metadata: ["error": "\(error)"])
            throw error
        }
    }
}

/// The four app-lifecycle instants recorded in `app_lifecycle_events` (§17.1).
public enum AppLifecycleEvent: String, Sendable {
    case launch
    case quit
    case sleep
    case wake
}
