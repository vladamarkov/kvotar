import XCTest
import GRDB
@testable import KvotarCore

final class SQLiteStoreNotificationsTests: XCTestCase {

    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory().appending("kvotar-notifstore-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    func testWriteRoundTripsWithIntTimestamps() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeNotificationEvent(
            tool: .claude, eventType: .overQuota, firedAt: 1_800_000_000,
            windowStart: 1_799_982_000, copyVariant: "case_1")

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT * FROM notification_events")
                XCTAssertEqual(row?["tool"], "claude")
                XCTAssertEqual(row?["event_type"], "over_quota")
                XCTAssertEqual(row?["copy_variant"], "case_1")
                XCTAssertNil(row?["dismissed_at"] as Int?)
                // Decoding as Int must succeed — a REAL-stored Double would break this.
                let fired = try Int.fetchOne(db, sql: "SELECT fired_at FROM notification_events")
                XCTAssertEqual(fired, 1_800_000_000)
            }
        }
    }

    func testCountAndLastReflectWrites() async throws {
        let store = try SQLiteStore(path: dbPath)
        let ws = 1_799_982_000
        try await store.writeNotificationEvent(tool: .codex, eventType: .atRisk,
                                               firedAt: 100, windowStart: ws, copyVariant: nil)
        try await store.writeNotificationEvent(tool: .codex, eventType: .atRisk,
                                               firedAt: 200, windowStart: ws, copyVariant: "rearm")

        let count = try await store.countNotificationEvents(
            tool: .codex, eventType: .atRisk, windowStart: ws)
        XCTAssertEqual(count, 2)

        let last = try await store.lastNotificationEvent(
            tool: .codex, eventType: .atRisk, windowStart: ws)
        XCTAssertEqual(last?.firedAt, 200)
        XCTAssertNil(last?.dismissedAt)

        // Different window is isolated.
        let other = try await store.countNotificationEvents(
            tool: .codex, eventType: .atRisk, windowStart: ws + 18000)
        XCTAssertEqual(other, 0)
    }

    func testMarkDismissedUpdatesMostRecent() async throws {
        let store = try SQLiteStore(path: dbPath)
        let ws = 42
        try await store.writeNotificationEvent(tool: .claude, eventType: .atRisk,
                                               firedAt: 100, windowStart: ws, copyVariant: nil)
        try await store.writeNotificationEvent(tool: .claude, eventType: .atRisk,
                                               firedAt: 200, windowStart: ws, copyVariant: nil)
        try await store.markNotificationDismissed(tool: .claude, eventType: .atRisk,
                                                  windowStart: ws, dismissedAt: 250)

        let last = try await store.lastNotificationEvent(
            tool: .claude, eventType: .atRisk, windowStart: ws)
        XCTAssertEqual(last?.dismissedAt, 250)
    }

    // Window resets no longer delete rows (§13.2 v5.17 — REV-42): prior-window rows are
    // retained as learning substrate, and enforcement stays correct purely because every
    // query scopes window_start = current.
    func testEnforcementUnaffectedByRetainedPriorWindowRows() async throws {
        let store = try SQLiteStore(path: dbPath)
        // Two prior windows' worth of history, including a dismissed fire.
        try await store.writeNotificationEvent(tool: .claude, eventType: .badTiming,
                                               firedAt: 1, windowStart: 100, copyVariant: nil)
        try await store.writeNotificationEvent(tool: .claude, eventType: .atRisk,
                                               firedAt: 2, windowStart: 100, copyVariant: nil)
        try await store.markNotificationDismissed(tool: .claude, eventType: .atRisk,
                                                  windowStart: 100, dismissedAt: 3)
        try await store.writeNotificationEvent(tool: .claude, eventType: .badTiming,
                                               firedAt: 4, windowStart: 200, copyVariant: nil)

        // Current window (300) sees none of it: max-per-window count starts at zero and
        // there is no "last fire" to drive cooldown/re-arm — R33-6 restart dedup included,
        // which keys on the same per-window count.
        let count = try await store.countNotificationEvents(
            tool: .claude, eventType: .badTiming, windowStart: 300)
        XCTAssertEqual(count, 0, "prior-window rows must be invisible to the current window")
        let last = try await store.lastNotificationEvent(
            tool: .claude, eventType: .atRisk, windowStart: 300)
        XCTAssertNil(last, "cooldown/re-arm must see no prior-window fire")

        // The prior windows' history is still there, dismissal intact.
        let retained = try await store.countNotificationEvents(
            tool: .claude, eventType: .badTiming, windowStart: 100)
        XCTAssertEqual(retained, 1, "prior-window rows must be retained, not deleted")
        let dismissed = try await store.lastNotificationEvent(
            tool: .claude, eventType: .atRisk, windowStart: 100)
        XCTAssertEqual(dismissed?.dismissedAt, 3)
    }
}
