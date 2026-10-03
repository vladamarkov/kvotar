import XCTest
import GRDB
@testable import KvotarCore

/// STEP_52 substrate writers — `discontinuity_events` and `popover_opens` round-trips per the
/// §17.1 column contract, including preserved NULLs and Int timestamps.
final class SQLiteStoreDiscontinuityTests: XCTestCase {

    private var dbPath: String!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory().appending("kvotar-substrate-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    func testWriteDiscontinuityEventsRoundTrips() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeDiscontinuityEvents(tool: .codex, observedAt: t0, events: [
            DiscontinuityObservation(eventType: .limitChanged, windowType: "monthly",
                                     oldValue: "4000", newValue: "6000"),
            DiscontinuityObservation(eventType: .windowReset, windowType: "five_hour",
                                     oldValue: "1799999000", newValue: nil,
                                     utilizationPct: 91.5),
        ])

        try await store.withPool { pool in
            try pool.read { db in
                let rows = try Row.fetchAll(
                    db, sql: "SELECT * FROM discontinuity_events ORDER BY id")
                XCTAssertEqual(rows.count, 2)
                XCTAssertEqual(rows[0]["tool"], "codex")
                XCTAssertEqual(rows[0]["event_type"], "limit_changed")
                XCTAssertEqual(rows[0]["observed_at"], 1_800_000_000)
                XCTAssertEqual(rows[0]["window_type"], "monthly")
                XCTAssertEqual(rows[0]["old_value"], "4000")
                XCTAssertEqual(rows[0]["new_value"], "6000")
                XCTAssertNil(rows[0]["utilization_pct"] as Double?)
                XCTAssertEqual(rows[1]["event_type"], "window_reset")
                XCTAssertNil(rows[1]["new_value"] as String?)
                XCTAssertEqual(rows[1]["utilization_pct"], 91.5)
            }
        }
    }

    func testWriteEmptyEventsWritesNothing() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeDiscontinuityEvents(tool: .claude, observedAt: t0, events: [])
        try await store.withPool { pool in
            try pool.read { db in
                let count = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM discontinuity_events")
                XCTAssertEqual(count, 0)
            }
        }
    }

    func testWritePopoverOpenRoundTripsIncludingNulls() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writePopoverOpen(openedAt: t0, tab: "claude",
                                         claudeState: "at_risk", claudeUsedPct: 82,
                                         codexState: nil, codexUsedPct: nil)

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT * FROM popover_opens")
                XCTAssertEqual(row?["opened_at"], 1_800_000_000)
                XCTAssertEqual(row?["tab"], "claude")
                XCTAssertEqual(row?["claude_state"], "at_risk")
                XCTAssertEqual(row?["claude_primary_used_pct"], 82.0)
                XCTAssertNil(row?["codex_state"] as String?,
                             "unknown/loading lands as NULL, never an invented state string")
                XCTAssertNil(row?["codex_primary_used_pct"] as Double?)
            }
        }
    }

    // MARK: STEP_114 read

    func testDiscontinuityEventsReadFiltersByTypeToolAndRangeOldestFirst() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeDiscontinuityEvents(tool: .claude, observedAt: t0.addingTimeInterval(200), events: [
            DiscontinuityObservation(eventType: .earlyReset, windowType: "weekly",
                                     oldValue: "1800100000", newValue: "1800000200",
                                     utilizationPct: 61)])
        try await store.writeDiscontinuityEvents(tool: .claude, observedAt: t0.addingTimeInterval(100), events: [
            DiscontinuityObservation(eventType: .windowRemoved, windowType: "five_hour",
                                     oldValue: "18000", newValue: nil, utilizationPct: 40),
            DiscontinuityObservation(eventType: .windowReset, windowType: "five_hour",
                                     oldValue: "1", newValue: nil, utilizationPct: 12)])
        try await store.writeDiscontinuityEvents(tool: .codex, observedAt: t0.addingTimeInterval(150), events: [
            DiscontinuityObservation(eventType: .windowRemoved, windowType: "weekly",
                                     oldValue: "604800", newValue: nil, utilizationPct: 3)])
        try await store.writeDiscontinuityEvents(tool: .claude, observedAt: t0.addingTimeInterval(5000), events: [
            DiscontinuityObservation(eventType: .windowAdded, windowType: "weekly",
                                     oldValue: nil, newValue: "604800")])

        let rows = try await store.discontinuityEvents(
            tool: .claude, since: t0, until: t0.addingTimeInterval(1000),
            types: ["window_removed", "early_reset", "window_added"])
        XCTAssertEqual(rows.map(\.eventType), ["window_removed", "early_reset"],
                       "window_reset excluded by type, codex by tool, the late row by range")
        XCTAssertEqual(rows[0].at, t0.addingTimeInterval(100))
        XCTAssertEqual(rows[0].windowType, "five_hour")
        XCTAssertEqual(rows[0].oldValue, "18000")
        XCTAssertNil(rows[0].newValue)
        XCTAssertEqual(rows[0].utilizationPct, 40)
        XCTAssertEqual(rows[1].utilizationPct, 61)
        let none = try await store.discontinuityEvents(tool: .claude, since: t0, until: t0.addingTimeInterval(1000), types: [])
        XCTAssertTrue(none.isEmpty)
    }
}
