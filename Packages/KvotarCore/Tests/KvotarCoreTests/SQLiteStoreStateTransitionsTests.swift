import XCTest
import GRDB
@testable import KvotarCore

final class SQLiteStoreStateTransitionsTests: XCTestCase {

    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory().appending("kvotar-transitions-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    func testWriteStateTransitionRoundTrips() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeStateTransition(
            tool: .claude, from: .healthy, to: .elevated,
            triggeredBy: .poll, utilizationPct: 68)

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT * FROM state_transitions")
                XCTAssertEqual(row?["tool"], "claude")
                XCTAssertEqual(row?["from_state"], "healthy")
                XCTAssertEqual(row?["to_state"], "elevated")
                XCTAssertEqual(row?["triggered_by"], "poll")
                XCTAssertEqual(row?["utilization_pct"], 68.0)
            }
        }
    }

    func testTimestampStoredAsInt() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeStateTransition(
            tool: .codex, from: .healthy, to: .nullWindow,
            triggeredBy: .jsonlDelta, utilizationPct: nil)

        try await store.withPool { pool in
            try pool.read { db in
                // Decoding as Int must succeed — a REAL-stored Double would break this.
                let ts = try Int.fetchOne(db, sql: "SELECT timestamp FROM state_transitions")
                XCTAssertNotNil(ts)
                let util = try Row.fetchOne(db, sql: "SELECT utilization_pct FROM state_transitions")
                XCTAssertNil(util?["utilization_pct"] as Double?, "null utilization persists as NULL")
            }
        }
    }

    // MARK: - Bounded critical-observation read (STEP_158 — REV-84)

    /// Raw INSERT with a chosen timestamp — the public writer stamps `Date()` internally, and
    /// these tests need deterministic bounds (the `SQLiteStoreRetentionTests` idiom).
    private func insert(_ store: SQLiteStore, tool: String = "claude", ts: Int,
                        to state: String, util: Double? = nil) async throws {
        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO state_transitions
                        (tool, timestamp, from_state, to_state, triggered_by, utilization_pct)
                    VALUES (?, ?, 'healthy', ?, 'poll', ?)
                    """, arguments: [tool, ts, state, util])
            }
        }
    }

    func testCriticalStateEntriesBoundsOrderAndToolFilter() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await insert(store, ts: 2_000, to: "over_quota")
        try await insert(store, ts: 1_000, to: "at_risk")          // == since: included
        try await insert(store, ts: 500, to: "bad_timing")         // before since: excluded
        try await insert(store, ts: 3_000, to: "spend_control")    // == until: excluded
        try await insert(store, tool: "codex", ts: 1_500, to: "at_risk")

        let entries = try await store.criticalStateEntries(
            tool: .claude,
            since: Date(timeIntervalSince1970: 1_000),
            until: Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(entries.map(\.toState), ["at_risk", "over_quota"],
                       "since inclusive, until exclusive, oldest first")
        XCTAssertEqual(entries.map { Int($0.at.timeIntervalSince1970) }, [1_000, 2_000])
    }

    func testCriticalStateEntriesExcludeNonCriticalAndUnknownStates() async throws {
        let store = try SQLiteStore(path: dbPath)
        for state in ["healthy", "elevated", "weekly_elevated", "fast_burn_spike",
                      "off_machine_burn", "multi_surface", "null_window", "idle_fallback",
                      "some_future_state"] {
            try await insert(store, ts: 1_100, to: state)
        }
        try await insert(store, ts: 1_200, to: "bad_timing")

        let entries = try await store.criticalStateEntries(
            tool: .claude,
            since: Date(timeIntervalSince1970: 0),
            until: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(entries.map(\.toState), ["bad_timing"],
                       "only the four critical destinations match; an unfamiliar stored state is skipped, not an error")
    }

    func testCriticalStateEntriesCarryNullableUtilization() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await insert(store, ts: 1_000, to: "at_risk", util: 87.5)
        try await insert(store, ts: 2_000, to: "over_quota", util: nil)

        let entries = try await store.criticalStateEntries(
            tool: .claude,
            since: Date(timeIntervalSince1970: 0),
            until: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].utilizationPct, 87.5)
        XCTAssertNil(entries[1].utilizationPct, "null utilization stays nil, never a fabricated 0")
    }
}
