import XCTest
import GRDB
@testable import KvotarCore

/// STEP_26 — `quota_limit_events` write side (§9.4, closes REV-5) and its round-trip with the
/// STEP_25 reader that feeds `resolveCeiling`.
final class SQLiteStoreQuotaLimitEventsTests: XCTestCase {

    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory()
            .appending("kvotar-quotalimit-test-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    func testWriteThenReadRoundTrip() async throws {
        let store = try SQLiteStore(path: dbPath)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.writeQuotaLimitEvent(
            tool: .claude, timestamp: at, utilizationPct: 97.5, windowType: .fiveHour,
            sourceFile: "session-a.jsonl", planType: "max")

        let utils = try await store.readQuotaLimitUtilizations(
            tool: .claude, windowType: .fiveHour, planType: "max")
        XCTAssertEqual(utils, [97.5])
    }

    func testReadFiltersByPlanType() async throws {
        // §9.4 rule 4: a plan change resets the personal ceiling via the plan_type filter.
        let store = try SQLiteStore(path: dbPath)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.writeQuotaLimitEvent(
            tool: .claude, timestamp: at, utilizationPct: 96, windowType: .fiveHour,
            sourceFile: "session-a.jsonl", planType: "pro")

        let utils = try await store.readQuotaLimitUtilizations(
            tool: .claude, windowType: .fiveHour, planType: "max")
        XCTAssertEqual(utils, [], "observations from a previous plan must not surface")
    }

    func testDuplicateObservationIgnored() async throws {
        // UNIQUE (tool, source_file, timestamp) + INSERT OR IGNORE — re-observing the same JSONL
        // event (e.g. after a re-promotion re-read) must not double-count.
        let store = try SQLiteStore(path: dbPath)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<2 {
            try await store.writeQuotaLimitEvent(
                tool: .codex, timestamp: at, utilizationPct: 99, windowType: .fiveHour,
                sourceFile: "rollout-b.jsonl", planType: "plus")
        }

        let utils = try await store.readQuotaLimitUtilizations(
            tool: .codex, windowType: .fiveHour, planType: "plus")
        XCTAssertEqual(utils, [99])
    }

    // MARK: - Plausibility floor (STEP_80, REV-54 §6)

    func testFloorDiscardsImplausibleObservations() async throws {
        // 5 and 7 are the live sub-floor readings that pinned this account's ceiling at 5.0%;
        // 49.9 pins the boundary itself. None may reach a permanent table.
        let store = try SQLiteStore(path: dbPath)
        for (i, pct) in [5.0, 7.0, 49.9].enumerated() {
            let written = try await store.writeQuotaLimitEvent(
                tool: .claude, timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)),
                utilizationPct: pct, windowType: .fiveHour,
                sourceFile: "session-\(i).jsonl", planType: "max")
            XCTAssertFalse(written, "\(pct)% cannot be a five-hour exhaustion")
        }

        let utils = try await store.readQuotaLimitUtilizations(
            tool: .claude, windowType: .fiveHour, planType: "max")
        XCTAssertEqual(utils, [], "sub-floor observations must not be recorded")
    }

    func testFloorAcceptsPlausibleObservations() async throws {
        // 50 is the floor itself (inclusive); 97/100 are the real cluster.
        let store = try SQLiteStore(path: dbPath)
        for (i, pct) in [50.0, 97.0, 100.0].enumerated() {
            let written = try await store.writeQuotaLimitEvent(
                tool: .claude, timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)),
                utilizationPct: pct, windowType: .fiveHour,
                sourceFile: "session-\(i).jsonl", planType: "max")
            XCTAssertTrue(written, "\(pct)% is a plausible ceiling observation")
        }

        let utils = try await store.readQuotaLimitUtilizations(
            tool: .claude, windowType: .fiveHour, planType: "max")
        XCTAssertEqual(utils.sorted(), [50.0, 97.0, 100.0])
    }

    // Deliberately non-`async`: GRDB resolves `pool.read`/`write` to their async overloads inside
    // an async test, and this case wants the plain synchronous ones (as the app's store does).
    func testV11MigrationDeletesSubFloorRows() throws {
        // The one-time cleanup: rows written before the floor existed are removed by
        // `v11_quota_ceiling_floor`, and the surviving minimum is what `resolveCeiling` sees.
        // Migrate up to v10 first so the pre-floor rows can be inserted the way the app wrote them.
        var migrator = DatabaseMigrator()
        SQLiteStore.registerMigrations(&migrator)
        let pool = try DatabasePool(path: dbPath)
        try migrator.migrate(pool, upTo: "v10_quota_series")

        // This account's live table at the time of the fix.
        let observed = [100.0, 100.0, 5.0, 7.0, 97.0, 97.0, 99.0, 100.0]
        try pool.write { db in
            for (i, pct) in observed.enumerated() {
                try db.execute(sql: """
                    INSERT INTO quota_limit_events
                        (tool, timestamp, utilization_pct, window_type, source_file, plan_type)
                    VALUES ('claude', ?, ?, 'five_hour', ?, 'max')
                    """, arguments: [1_800_000_000 + i, pct, "session-\(i).jsonl"])
            }
        }
        let before = try pool.read { db in
            try Double.fetchAll(db, sql: "SELECT utilization_pct FROM quota_limit_events")
        }
        XCTAssertEqual(LimitsDatabaseAdapter.resolveCeiling(
            personalObservations: before, communityCeiling: 100), 5.0,
            "precondition: the poisoned ceiling this step exists to fix")

        try migrator.migrate(pool)

        let after = try pool.read { db in
            try Double.fetchAll(db, sql: "SELECT utilization_pct FROM quota_limit_events")
                .sorted()
        }
        XCTAssertEqual(after, [97.0, 97.0, 99.0, 100.0, 100.0, 100.0],
                       "only the two sub-floor rows are deleted")
        XCTAssertEqual(LimitsDatabaseAdapter.resolveCeiling(
            personalObservations: after, communityCeiling: 100), 97.0)
    }

    /// REV-39 / STEP_45: the persisted poll base is retired, so the rows a prior build wrote must
    /// go — a left-behind `poll_base_interval.<tool>` would be a claim about how the app polls
    /// that no code can any longer make true. The `settings_changes` audit trail is kept: it is
    /// the evidence REV-39 §5.1 was written from (the base sawtoothing with nobody touching it).
    /// Deliberately non-`async`, for the same reason as the v11 case above.
    func testV13MigrationDeletesPersistedPollBaseButKeepsTheAudit() throws {
        var migrator = DatabaseMigrator()
        SQLiteStore.registerMigrations(&migrator)
        let pool = try DatabasePool(path: dbPath)
        try migrator.migrate(pool, upTo: "v12_unanchored_window_cleanup")

        try pool.write { db in
            for (key, value) in [("poll_base_interval.claude", "240"),
                                 ("poll_base_interval.codex", "120"),
                                 ("debug_mode_enabled", "1")] {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, ?)
                    """, arguments: [key, value, 1_800_000_000])
            }
            try db.execute(sql: """
                INSERT INTO settings_changes (changed_at, key, old_value, new_value)
                VALUES (?, 'poll_base_interval.claude', '120', '240')
                """, arguments: [1_800_000_000])
        }

        try migrator.migrate(pool)

        try pool.read { db in
            let remaining = try String.fetchAll(
                db, sql: "SELECT key FROM settings WHERE key LIKE 'poll_base_interval.%'")
            XCTAssertEqual(remaining, [], "both tools' persisted bases are gone")
            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT value FROM settings WHERE key = 'debug_mode_enabled'"), "1",
                "unrelated settings are untouched")
            XCTAssertEqual(try Int.fetchOne(
                db, sql: """
                    SELECT COUNT(*) FROM settings_changes WHERE key = 'poll_base_interval.claude'
                    """), 1, "the audit trail survives the setting it audited")
        }
    }

    func testTimestampStoredAsInteger() async throws {
        // PATTERNS.md §SQLite: timestamp columns are INTEGER; a Double would store as REAL.
        let store = try SQLiteStore(path: dbPath)
        try await store.writeQuotaLimitEvent(
            tool: .claude, timestamp: Date(timeIntervalSince1970: 1_800_000_000.7),
            utilizationPct: 95, windowType: .weekly,
            sourceFile: "session-c.jsonl", planType: "max")

        try await store.withPool { pool in
            try pool.read { db in
                let type = try String.fetchOne(
                    db, sql: "SELECT typeof(timestamp) FROM quota_limit_events")
                XCTAssertEqual(type, "integer")
            }
        }
    }
}
