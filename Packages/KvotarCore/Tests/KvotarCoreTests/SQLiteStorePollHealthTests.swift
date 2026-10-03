import XCTest
import GRDB
@testable import KvotarCore

final class SQLiteStorePollHealthTests: XCTestCase {

    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory()
            .appending("kvotar-pollhealth-test-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    // MARK: poll_health_events writer (§9.5)

    func testWritePollHealthEventPersistsAllColumns() async throws {
        let store = try SQLiteStore(path: dbPath)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.writePollHealthEvent(
            tool: .claude, endpoint: .oauthUsage,
            retryAfterSeconds: 30, consecutiveCount: 2, baseIntervalAtTime: 120, at: at)

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM poll_health_events WHERE tool = ?",
                    arguments: ["claude"])
                XCTAssertEqual(row?["endpoint"], "oauth_usage")
                XCTAssertEqual(row?["timestamp"], 1_800_000_000)
                XCTAssertEqual(row?["retry_after_seconds"], 30)
                XCTAssertEqual(row?["consecutive_count"], 2)
                XCTAssertEqual(row?["base_interval_at_time"], 120)
                // Forensic columns stay null when no details/context are supplied (§9.5 — R31-4).
                XCTAssertNil(row?["response_body"] as String?)
                XCTAssertNil(row?["category"] as String?)
                XCTAssertNil(row?["null_window_source"] as String?)
            }
        }
    }

    /// Normalized forensic context persists, but raw response headers and bodies never do.
    func testWritePollHealthEventPersistsForensicColumns() async throws {
        let store = try SQLiteStore(path: dbPath)
        let details = RateLimit429Details(
            statusCode: 429,
            headers: ["Retry-After": "0", "X-Foo": "bar"],
            body: "{\"error\":\"rate_limited\"}",
            category: "transient")
        let resetsAt = Date(timeIntervalSince1970: 1_800_003_600)
        try await store.writePollHealthEvent(
            tool: .claude, endpoint: .oauthUsage,
            retryAfterSeconds: 0, consecutiveCount: 1, baseIntervalAtTime: 60,
            details: details,
            lastPrimaryUsedPct: 42.5, lastSecondaryUsedPct: 8.0,
            lastPrimaryResetsAt: resetsAt, lastExtraUsageEnabled: true,
            nullWindowSource: .provider,
            at: Date(timeIntervalSince1970: 1_800_000_000))

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM poll_health_events WHERE tool = ?", arguments: ["claude"])
                XCTAssertNil(row?["response_headers_json"] as String?)
                XCTAssertNil(row?["response_body"] as String?)
                XCTAssertEqual(row?["category"], "transient")
                XCTAssertEqual(row?["last_primary_used_pct"], 42.5)
                XCTAssertEqual(row?["last_secondary_used_pct"], 8.0)
                XCTAssertEqual(row?["last_primary_resets_at"], 1_800_003_600)
                XCTAssertEqual(row?["last_extra_usage_enabled"], 1)
                XCTAssertEqual(row?["null_window_source"], "provider")
            }
        }
    }

    func testEndpointRawValuesMatchSchemaStrings() {
        XCTAssertEqual(PollHealthEndpoint.oauthUsage.rawValue, "oauth_usage")
        XCTAssertEqual(PollHealthEndpoint.rpc.rawValue, "rpc")
        XCTAssertEqual(PollHealthEndpoint.whamUsage.rawValue, "wham_usage")
    }

    // MARK: credential_expired writer + v8 nullable retry_after (§9.1/§9.5 — REV-41, STEP_48)

    /// A pre-poll gate row: `retry_after_seconds` NULL (the v8 migration relaxed the NOT NULL),
    /// category `credential_expired`, response fields null, last-good context copied on.
    func testWriteCredentialExpiredGateRowHasNullRetryAfter() async throws {
        let store = try SQLiteStore(path: dbPath)
        let resetsAt = Date(timeIntervalSince1970: 1_800_003_600)
        try await store.writeCredentialExpiredEvent(
            tool: .claude, endpoint: .oauthUsage,
            consecutiveCount: 0, baseIntervalAtTime: 60,
            details: nil,
            lastPrimaryUsedPct: 42.5, lastSecondaryUsedPct: 8.0,
            lastPrimaryResetsAt: resetsAt, lastExtraUsageEnabled: true,
            nullWindowSource: .provider,
            at: Date(timeIntervalSince1970: 1_800_000_000))

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM poll_health_events WHERE tool = ?", arguments: ["claude"])
                XCTAssertNil(row?["retry_after_seconds"] as Int?,
                             "a gate row sends no request → retry_after is NULL (§9.5, v8)")
                XCTAssertEqual(row?["category"], "credential_expired")
                XCTAssertNil(row?["response_headers_json"] as String?, "no request → no headers")
                XCTAssertNil(row?["response_body"] as String?)
                XCTAssertEqual(row?["consecutive_count"], 0, "the ladder count is unchanged")
                XCTAssertEqual(row?["base_interval_at_time"], 60)
                XCTAssertEqual(row?["last_primary_used_pct"], 42.5, "last-good context is copied on")
                XCTAssertEqual(row?["null_window_source"], "provider")
            }
        }
    }

    /// A reclassified-429 row keeps its category but not the response headers/body.
    func testWriteCredentialExpiredReclassifiedRowDropsResponseContent() async throws {
        let store = try SQLiteStore(path: dbPath)
        let details = RateLimit429Details(
            statusCode: 429,
            headers: ["Retry-After": "3600"],
            body: "{\"type\":\"rate_limit_error\"}",
            category: "credential_expired")
        try await store.writeCredentialExpiredEvent(
            tool: .claude, endpoint: .oauthUsage,
            consecutiveCount: 0, baseIntervalAtTime: 60, details: details,
            at: Date(timeIntervalSince1970: 1_800_000_000))

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM poll_health_events WHERE tool = ?", arguments: ["claude"])
                XCTAssertNil(row?["retry_after_seconds"] as Int?,
                             "the disguised countdown is not recorded as a rate signal")
                XCTAssertNil(row?["response_headers_json"] as String?)
                XCTAssertNil(row?["response_body"] as String?)
                XCTAssertEqual(row?["category"], "credential_expired")
            }
        }
    }

    /// After the v8 migration the recreated `poll_health_events` still accepts a NOT-NULL
    /// `retry_after_seconds` rate row alongside a NULL credential-expired row — the schema holds
    /// both shapes and the lineage reaches v8.
    func testV8SchemaHoldsBothRowShapes() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writePollHealthEvent(
            tool: .claude, endpoint: .oauthUsage,
            retryAfterSeconds: 90, consecutiveCount: 2, baseIntervalAtTime: 120,
            at: Date(timeIntervalSince1970: 1_800_000_000))
        try await store.writeCredentialExpiredEvent(
            tool: .claude, endpoint: .oauthUsage,
            consecutiveCount: 0, baseIntervalAtTime: 60,
            at: Date(timeIntervalSince1970: 1_800_000_100))

        try await store.withPool { pool in
            try pool.read { db in
                let rows = try Row.fetchAll(
                    db, sql: "SELECT retry_after_seconds FROM poll_health_events ORDER BY timestamp")
                XCTAssertEqual(rows.count, 2)
                XCTAssertEqual(rows[0]["retry_after_seconds"], 90)
                XCTAssertNil(rows[1]["retry_after_seconds"] as Int?)
                let version = try String.fetchOne(
                    db, sql: "SELECT value FROM settings WHERE key = 'schema_version'")
                XCTAssertEqual(version, "25",
                               "migration lineage reaches the model limit series")
            }
        }
    }

    // MARK: quota_limit_events reader (§9.4)

    func testReadQuotaLimitUtilizationsFiltersByToolWindowAndPlan() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.withPool { pool in
            try pool.write { db in
                for (i, row) in [
                    ("claude", "five_hour", "max", 91.0),
                    ("claude", "five_hour", "max", 88.5),
                    ("claude", "five_hour", "pro", 70.0),   // other plan — excluded
                    ("claude", "weekly", "max", 95.0),      // other window — excluded
                    ("codex", "five_hour", "max", 60.0),    // other tool — excluded
                ].enumerated() {
                    try db.execute(sql: """
                        INSERT INTO quota_limit_events
                            (tool, timestamp, utilization_pct, window_type, source_file, plan_type)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [row.0, 1_800_000_000 + i, row.3, row.1, "f\(i).jsonl", row.2])
                }
            }
        }

        let observed = try await store.readQuotaLimitUtilizations(
            tool: .claude, windowType: .fiveHour, planType: "max")
        XCTAssertEqual(observed.sorted(), [88.5, 91.0],
                       "plan-change reset works by filtering, not deletion (§9.4)")
    }

    func testReadQuotaLimitUtilizationsEmptyWhenNoObservations() async throws {
        let store = try SQLiteStore(path: dbPath)
        let observed = try await store.readQuotaLimitUtilizations(
            tool: .claude, windowType: .fiveHour, planType: "max")
        XCTAssertTrue(observed.isEmpty)
    }

    // MARK: endpoint_rejected writer (§9.5 — STEP_75)

    func testWriteEndpointRejectionEventPersistsTheSpecifiedColumns() async throws {
        let store = try SQLiteStore(path: dbPath)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.writeEndpointRejectionEvent(
            tool: .claude, endpoint: .claudePrepaid, phase: .opened,
            consecutiveCount: 3, responseBody: nil, at: at)

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT * FROM poll_health_events")
                XCTAssertEqual(row?["endpoint"], "claude_prepaid")
                XCTAssertEqual(row?["category"], "endpoint_rejected")
                XCTAssertEqual(row?["timestamp"], 1_800_000_000)
                XCTAssertEqual(row?["consecutive_count"], 3)
                XCTAssertEqual(row?["base_interval_at_time"], 0,
                               "this class never touches the §9.3 ladder")
                XCTAssertNil(row?["retry_after_seconds"] as Int?,
                             "the server issued no backoff instruction (nullable since v8)")
                XCTAssertNil(row?["response_headers_json"] as String?)
                XCTAssertNil(row?["response_body"] as String?)
            }
        }
    }

    /// Two rows, not 57: the pair carries the episode's duration and its true occurrence count.
    func testEpisodePairIsDistinguishableAndCarriesItsDuration() async throws {
        let store = try SQLiteStore(path: dbPath)
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.writeEndpointRejectionEvent(
            tool: .claude, endpoint: .claudePrepaid, phase: .opened,
            consecutiveCount: 3, at: opened)
        try await store.writeEndpointRejectionEvent(
            tool: .claude, endpoint: .claudePrepaid, phase: .cleared,
            consecutiveCount: 57, at: opened.addingTimeInterval(90_000))

        try await store.withPool { pool in
            try pool.read { db in
                let rows = try Row.fetchAll(
                    db, sql: """
                        SELECT * FROM poll_health_events
                        WHERE category LIKE 'endpoint_rejected%' ORDER BY timestamp
                        """)
                XCTAssertEqual(rows.count, 2, "an episode is two rows regardless of its length")
                XCTAssertEqual(rows.first?["category"], "endpoint_rejected")
                XCTAssertEqual(rows.last?["category"], "endpoint_rejected_cleared")
                XCTAssertEqual(rows.last?["consecutive_count"], 57)
                let openedAt: Int = try XCTUnwrap(rows.first?["timestamp"])
                let clearedAt: Int = try XCTUnwrap(rows.last?["timestamp"])
                XCTAssertEqual(clearedAt - openedAt, 90_000,
                               "25 hours, readable from the pair alone")
            }
        }
    }

    func testEndpointRejectionBodyIsNeverPersisted() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeEndpointRejectionEvent(
            tool: .claude, endpoint: .claudePrepaid, phase: .opened, consecutiveCount: 3,
            responseBody: "only available for Pro and Max plans")

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT * FROM poll_health_events")
                XCTAssertNil(row?["response_body"] as String?)
            }
        }
    }
}
