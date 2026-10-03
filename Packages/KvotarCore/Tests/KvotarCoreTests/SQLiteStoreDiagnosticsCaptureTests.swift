import XCTest
import GRDB
@testable import KvotarCore

/// §17.1 diagnostics-capture writers + §17.2 pruning (REV-52, STEP_72).
///
/// Row assertions run **inside** `withPool` (the shipped store-test pattern): GRDB's `Row` is not
/// `Sendable`, so it cannot cross the actor boundary.
final class SQLiteStoreDiagnosticsCaptureTests: XCTestCase {

    private var dbPath: String!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        DiagnosticsCapture.setEnabled(
            true, expiresAt: Date().addingTimeInterval(DiagnosticsCapture.maximumDuration))
        dbPath = NSTemporaryDirectory().appending("kvotar-capture-\(UUID().uuidString).db")
    }

    override func tearDown() {
        DiagnosticsCapture.setEnabled(false)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    private func count(_ store: SQLiteStore, _ sql: String) async throws -> Int {
        try await store.withPool { pool in
            try pool.read { db in try Int.fetchOne(db, sql: sql) ?? -1 }
        }
    }

    // MARK: - Time-limited, safety-filtered capture

    func testFirstCaptureWritesOneExpiringRowAndOneDurableShape() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeRawPayload(
            tool: .claude, endpoint: DiagnosticsEndpoint.claudeUsage,
            body: Data(#"{"five_hour":{"used_pct":12}}"#.utf8), httpStatus: 200, capturedAt: t0)

        let t0Stamp = Int(t0.timeIntervalSince1970)
        try await store.withPool { pool in
            try pool.read { db in
                let rows = try Row.fetchAll(
                    db, sql: "SELECT * FROM raw_payloads ORDER BY keep_reason")
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["keep_reason"], "window")
                XCTAssertEqual(rows[0]["http_status"], 200)
                XCTAssertEqual(rows[0]["endpoint"], "claude_usage")
                XCTAssertEqual(rows[0]["captured_at"], t0Stamp)

                let shape = try Row.fetchOne(db, sql: "SELECT * FROM payload_shapes")
                XCTAssertEqual(shape?["first_seen_at"], t0Stamp)
                XCTAssertEqual(shape?["last_seen_at"], t0Stamp)
            }
        }
    }

    func testRepeatedShapeWritesOnlyTheWindowRowAndBumpsLastSeen() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeRawPayload(
            tool: .claude, endpoint: "claude_usage",
            body: Data(#"{"five_hour":{"used_pct":12}}"#.utf8), httpStatus: 200, capturedAt: t0)
        // Same shape, different value — the case that must NOT produce a second permanent keep.
        try await store.writeRawPayload(
            tool: .claude, endpoint: "claude_usage",
            body: Data(#"{"five_hour":{"used_pct":88}}"#.utf8), httpStatus: 200,
            capturedAt: t0.addingTimeInterval(60))

        let payloads = try await count(store, "SELECT COUNT(*) FROM raw_payloads")
        XCTAssertEqual(payloads, 2)

        let t0Stamp = Int(t0.timeIntervalSince1970)
        try await store.withPool { pool in
            try pool.read { db in
                let shape = try Row.fetchOne(db, sql: "SELECT * FROM payload_shapes")
                XCTAssertEqual(shape?["first_seen_at"], t0Stamp)
                XCTAssertEqual(shape?["last_seen_at"], t0Stamp + 60)
            }
        }
    }

    func testGenuineDriftAddsASecondShapeWithoutPermanentBody() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeRawPayload(tool: .codex, endpoint: "account/read",
                                        body: Data(#"{"plan":"pro"}"#.utf8),
                                        httpStatus: nil, capturedAt: t0)
        try await store.writeRawPayload(tool: .codex, endpoint: "account/read",
                                        body: Data(#"{"plan":"pro","new_field":1}"#.utf8),
                                        httpStatus: nil, capturedAt: t0.addingTimeInterval(60))

        let shapes = try await count(store, "SELECT COUNT(*) FROM payload_shapes")
        let payloads = try await count(store, "SELECT COUNT(*) FROM raw_payloads")
        XCTAssertEqual(shapes, 2)
        XCTAssertEqual(payloads, 2)

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT * FROM raw_payloads LIMIT 1")
                XCTAssertNil(row?["http_status"] as Int?, "the RPC path has no HTTP status")
            }
        }
    }

    func testAlternatingKnownShapesKeepBodiesOnlyInsideTheWindow() async throws {
        let store = try SQLiteStore(path: dbPath)
        let withWindow = Data(#"{"five_hour":{"used_pct":10}}"#.utf8)
        let without = Data(#"{}"#.utf8)
        for (i, body) in [withWindow, without, withWindow, without].enumerated() {
            try await store.writeRawPayload(
                tool: .claude, endpoint: "claude_usage", body: body, httpStatus: 200,
                capturedAt: t0.addingTimeInterval(Double(i) * 60))
        }
        let payloads = try await count(store, "SELECT COUNT(*) FROM raw_payloads")
        let shapes = try await count(store, "SELECT COUNT(*) FROM payload_shapes")
        XCTAssertEqual(payloads, 4)
        XCTAssertEqual(shapes, 2)
    }

    // MARK: - Retention

    func testRetentionDropsEveryBodyPastTwentyFourHours() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeRawPayload(tool: .claude, endpoint: "claude_usage",
                                        body: Data(#"{"a":1}"#.utf8), httpStatus: 200,
                                        capturedAt: Date().addingTimeInterval(-90_000))  // > 24h
        try await store.writeRawPayload(tool: .claude, endpoint: "claude_usage",
                                        body: Data(#"{"a":2}"#.utf8), httpStatus: 200,
                                        capturedAt: Date().addingTimeInterval(-3_600))
        try await store.runRetentionCleanup()

        try await store.withPool { pool in
            try pool.read { db in
                let rows = try Row.fetchAll(
                    db, sql: "SELECT keep_reason FROM raw_payloads ORDER BY captured_at")
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["keep_reason"], "window")
            }
        }
    }

    func testRetentionNeverTouchesShapesAnomaliesOrLifecycle() async throws {
        let store = try SQLiteStore(path: dbPath)
        let old = Date().addingTimeInterval(-40 * 86_400)
        try await store.writeRawPayload(tool: .claude, endpoint: "claude_usage",
                                        body: Data(#"{"a":1}"#.utf8), httpStatus: 200,
                                        capturedAt: old)
        try await store.writeParseAnomaly(ParseAnomaly(
            tool: .claude, sourceFile: "s.jsonl", lineNumber: nil, observedAt: old,
            error: "boom", fieldNames: ["type"]))
        try await store.writeLifecycleEvent(.launch, appVersion: "0.1.2 (3) beta", occurredAt: old)
        try await store.runRetentionCleanup()

        let shapes = try await count(store, "SELECT COUNT(*) FROM payload_shapes")
        let anomalies = try await count(store, "SELECT COUNT(*) FROM parse_anomalies")
        let lifecycle = try await count(store, "SELECT COUNT(*) FROM app_lifecycle_events")
        XCTAssertEqual(shapes, 1)
        XCTAssertEqual(anomalies, 1)
        XCTAssertEqual(lifecycle, 1)
    }

    // MARK: - Off means gone

    func testStorageBoundaryRejectsCaptureQueuedAfterConsentEnds() async throws {
        let store = try SQLiteStore(path: dbPath)
        DiagnosticsCapture.setEnabled(false)

        try await store.writeRawPayload(
            tool: .claude, endpoint: DiagnosticsEndpoint.claudeUsage,
            body: Data(#"{"usage":42}"#.utf8), httpStatus: 200, capturedAt: t0)
        try await store.writeParseAnomaly(ParseAnomaly(
            tool: .claude, sourceFile: "session.jsonl", lineNumber: 1, observedAt: t0,
            error: "late task", fieldNames: ["type"]))

        let payloads = try await count(store, "SELECT COUNT(*) FROM raw_payloads")
        let anomalies = try await count(store, "SELECT COUNT(*) FROM parse_anomalies")
        XCTAssertEqual(payloads, 0)
        XCTAssertEqual(anomalies, 0)
    }

    func testDeleteCapturedPayloadsDropsBodiesButKeepsShapes() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeRawPayload(tool: .claude, endpoint: "claude_usage",
                                        body: Data(#"{"a":1}"#.utf8), httpStatus: 200,
                                        capturedAt: t0)
        try await store.deleteCapturedPayloads()

        let payloads = try await count(store, "SELECT COUNT(*) FROM raw_payloads")
        let shapes = try await count(store, "SELECT COUNT(*) FROM payload_shapes")
        XCTAssertEqual(payloads, 0, "off means gone, not merely 'stop appending'")
        XCTAssertEqual(shapes, 1,
                       "shapes hold no bodies — losing drift history would be cost for no gain")
    }

    // MARK: - parse_anomalies / lifecycle

    func testParseAnomalyStoresNamesNotValues() async throws {
        let store = try SQLiteStore(path: dbPath)
        let line = Data(#"{"type":"assistant","secret":"prompt text"}"#.utf8)
        try await store.writeParseAnomaly(ParseAnomaly(
            tool: .claude, sourceFile: "session.jsonl", lineNumber: nil, observedAt: t0,
            error: "RawEvent decode failed", fieldNames: ParseAnomaly.fieldNames(of: line)))

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT * FROM parse_anomalies")
                let names = row?["field_names"] as String? ?? ""
                XCTAssertTrue(names.contains("secret"), "names travel")
                XCTAssertFalse(names.contains("prompt text"), "values never do")
                XCTAssertNil(row?["line_number"] as Int?,
                             "a chunk-relative index would read as a false absolute")
                XCTAssertEqual(row?["source_file"], "session.jsonl")
            }
        }
    }

    func testFieldNamesOfNonObjectLineIsNil() {
        XCTAssertNil(ParseAnomaly.fieldNames(of: Data("not json at all".utf8)))
        XCTAssertNil(ParseAnomaly.fieldNames(of: Data("[1,2,3]".utf8)))
    }

    func testLifecycleEventRoundTrip() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeLifecycleEvent(.sleep, appVersion: "0.1.2 (3) beta", occurredAt: t0)
        let stamp = Int(t0.timeIntervalSince1970)
        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT * FROM app_lifecycle_events")
                XCTAssertEqual(row?["event"], "sleep")
                XCTAssertEqual(row?["occurred_at"], stamp)
                XCTAssertEqual(row?["app_version"], "0.1.2 (3) beta")
            }
        }
    }

    // MARK: - App coverage (REV-56 §5 — STEP_84)

    /// `processRunningSince` answers "which process was alive here, and since when" from the one
    /// row that settles it: the newest `launch`/`quit` at or before the instant. The off-machine
    /// walk gates its leading slice on the answer.
    func testProcessRunningSinceReadsTheNewestLaunchOrQuit() async throws {
        let store = try SQLiteStore(path: dbPath)
        func write(_ e: AppLifecycleEvent, _ offset: TimeInterval) async throws {
            try await store.writeLifecycleEvent(e, appVersion: "test",
                                                occurredAt: t0.addingTimeInterval(offset))
        }
        // No history at all — a fresh install, or a database predating the table.
        let empty = try await store.processRunningSince(at: t0)
        XCTAssertNil(empty, "no history proves nothing — the conservative direction")

        try await write(.launch, 0)
        try await write(.sleep, 100)          // sleep/wake never break coverage: the process
        try await write(.wake, 200)           // survives sleep with its file offsets
        let running = try await store.processRunningSince(at: t0.addingTimeInterval(300))
        XCTAssertEqual(running, t0)

        // A clean quit: nothing is running after it, whatever came before.
        try await write(.quit, 400)
        let afterQuit = try await store.processRunningSince(at: t0.addingTimeInterval(500))
        XCTAssertNil(afterQuit)

        // A relaunch starts a new process — and a fresh one seeds its JSONL offsets to EOF, so
        // its launch time is exactly the bound the caller's span check needs.
        try await write(.launch, 600)
        let relaunched = try await store.processRunningSince(at: t0.addingTimeInterval(700))
        XCTAssertEqual(relaunched, t0.addingTimeInterval(600))

        // The read is anchored at the instant asked about, never at "now": a launch after it
        // belongs to a later process and must not vouch for the earlier span.
        let earlier = try await store.processRunningSince(at: t0.addingTimeInterval(550))
        XCTAssertNil(earlier)
    }

    /// A crash leaves no `quit` row. It is still caught, without a marker of its own: the
    /// relaunch that follows is the newest launch, and its timestamp fails the caller's
    /// "launched at or before the window start" check.
    func testCrashIsCaughtByTheRelaunchRow() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeLifecycleEvent(.launch, appVersion: "test", occurredAt: t0)
        try await store.writeLifecycleEvent(.launch, appVersion: "test",
                                            occurredAt: t0.addingTimeInterval(3_600))
        let since = try await store.processRunningSince(at: t0.addingTimeInterval(7_200))
        XCTAssertEqual(since, t0.addingTimeInterval(3_600),
                       "the surviving process is the relaunched one, not the crashed one")
    }
}
