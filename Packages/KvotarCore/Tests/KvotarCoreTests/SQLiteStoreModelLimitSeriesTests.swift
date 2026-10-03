import XCTest
import GRDB
@testable import KvotarCore

/// Pins the `model_limit_series` write inside `writePoll` (v25 — STEP_209): one row per poll per
/// model allowance per reported window, keyed on the provider id where there is one and the name
/// otherwise, and never gated on the main five-hour window.
final class SQLiteStoreModelLimitSeriesTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private var dbPath: String!
    private var store: SQLiteStore!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory().appending("kvotar-mlseries-\(UUID().uuidString).db")
        store = try SQLiteStore(path: dbPath)
    }

    override func tearDown() {
        store = nil
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) }
    }

    private struct Stored: Equatable {
        let tool: String
        let polledAt: Int
        let key: String
        let id: String?
        let name: String?
        let slot: String
        let usedPct: Double?
        let resetsAt: Int?
        let windowSeconds: Int?
    }

    private func storedRows() async throws -> [Stored] {
        try await store.withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT * FROM model_limit_series
                    ORDER BY polled_at, tool, limit_key, window_slot
                    """).map { row in
                    Stored(tool: row["tool"], polledAt: row["polled_at"], key: row["limit_key"],
                           id: row["limit_id"], name: row["limit_name"], slot: row["window_slot"],
                           usedPct: row["used_pct"], resetsAt: row["resets_at"],
                           windowSeconds: row["window_seconds"])
                }
            }
        }
    }

    private func snapshot(tool: Tool, primaryPct: Double? = 10,
                          limits: [AdditionalRateLimit]) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, primaryUsedPct: primaryPct,
                      primaryResetsAt: primaryPct.map { _ in base.addingTimeInterval(18_000) },
                      secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: nil,
                      additionalRateLimits: limits)
    }

    /// Claude's scoped weekly, as the adapter builds it: no id, a name, one window.
    private var fable: AdditionalRateLimit {
        AdditionalRateLimit(id: nil, name: "Fable", usedPercent: 53,
                            resetsAt: base.addingTimeInterval(200_000),
                            primaryWindowSeconds: 604_800)
    }

    func testClaudeScopedWeeklyIsKeyedOnItsName() async throws {
        try await store.writePoll(snapshot: snapshot(tool: .claude, limits: [fable]), now: base)
        let rows = try await storedRows()
        XCTAssertEqual(rows, [Stored(
            tool: "claude", polledAt: 1_700_000_000, key: "Fable", id: nil, name: "Fable",
            slot: "primary", usedPct: 53, resetsAt: 1_700_200_000, windowSeconds: 604_800)])
    }

    func testCodexAllowanceWritesBothWindowsKeyedOnItsId() async throws {
        let spark = AdditionalRateLimit(
            id: "codex_bengalfox", name: "GPT-5.3-Codex-Spark", usedPercent: 4,
            resetsAt: base.addingTimeInterval(9_000), primaryWindowSeconds: 18_000,
            secondary: .init(usedPercent: 12, resetsAt: base.addingTimeInterval(300_000),
                             windowSeconds: 604_800))
        try await store.writePoll(snapshot: snapshot(tool: .codex, limits: [spark]), now: base)
        let rows = try await storedRows()
        XCTAssertEqual(rows.map(\.slot), ["primary", "secondary"])
        XCTAssertEqual(Set(rows.map(\.key)), ["codex_bengalfox"])
        XCTAssertEqual(rows.map(\.name), ["GPT-5.3-Codex-Spark", "GPT-5.3-Codex-Spark"])
        XCTAssertEqual(rows.map(\.usedPct), [4, 12])
        XCTAssertEqual(rows.map(\.resetsAt), [1_700_009_000, 1_700_300_000])
        XCTAssertEqual(rows.map(\.windowSeconds), [18_000, 604_800])
    }

    func testAnEmptyWindowWritesNoRow() async throws {
        // A Codex allowance whose primary came back null, with a live weekly.
        let weeklyOnly = AdditionalRateLimit(
            id: "codex_bengalfox", name: "GPT-5.3-Codex-Spark",
            secondary: .init(usedPercent: 0, resetsAt: base.addingTimeInterval(300_000)))
        try await store.writePoll(snapshot: snapshot(tool: .codex, limits: [weeklyOnly]), now: base)
        let rows = try await storedRows()
        XCTAssertEqual(rows.map(\.slot), ["secondary"])
    }

    func testNoAllowancesWritesNothing() async throws {
        try await store.writePoll(snapshot: snapshot(tool: .claude, limits: []), now: base)
        let rows = try await storedRows()
        XCTAssertEqual(rows, [])
    }

    func testNotGatedOnTheMainFiveHourWindow() async throws {
        // Overnight Claude: no five-hour anchor, so no `quota_series` row — the allowance still lands.
        try await store.writePoll(snapshot: snapshot(tool: .claude, primaryPct: nil, limits: [fable]),
                                  now: base)
        let series = try await store.latestQuotaSeriesPoint(tool: .claude)
        XCTAssertNil(series)
        let rows = try await storedRows()
        XCTAssertEqual(rows.map(\.key), ["Fable"])
    }

    func testEveryPollAppendsAndASharedSecondReplaces() async throws {
        try await store.writePoll(snapshot: snapshot(tool: .claude, limits: [fable]), now: base)
        let later = AdditionalRateLimit(id: nil, name: "Fable", usedPercent: 54,
                                        resetsAt: fable.resetsAt, primaryWindowSeconds: 604_800)
        try await store.writePoll(snapshot: snapshot(tool: .claude, limits: [later]),
                                  now: base.addingTimeInterval(120))
        // Tripwire + scheduled poll in the same second: the later write wins, nothing throws.
        let same = AdditionalRateLimit(id: nil, name: "Fable", usedPercent: 55,
                                       resetsAt: fable.resetsAt, primaryWindowSeconds: 604_800)
        try await store.writePoll(snapshot: snapshot(tool: .claude, limits: [same]),
                                  now: base.addingTimeInterval(120))
        let rows = try await storedRows()
        XCTAssertEqual(rows.map(\.usedPct), [53, 55])
    }

    /// A database written by a `v24` build keeps its rows and gains an empty table.
    func testV25MigrationIsAdditive() throws {
        let path = NSTemporaryDirectory().appending("kvotar-mls-v25-\(UUID().uuidString).db")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }

        var migrator = DatabaseMigrator()
        SQLiteStore.registerMigrations(&migrator)
        let pool = try DatabasePool(path: path)
        try migrator.migrate(pool, upTo: "v24_forecast_shadow_substrate")
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO quota_series (tool, polled_at, primary_used_pct, primary_resets_at)
                VALUES ('claude', 1700000000, 41.0, 1700018000)
                """)
        }

        try migrator.migrate(pool)

        try pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM quota_series"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM model_limit_series"), 0)
            XCTAssertEqual(try String.fetchOne(
                db, sql: "SELECT value FROM settings WHERE key = 'schema_version'"), "25")
        }
    }

    // MARK: The first reader (STEP_227)

    func testRangeReadRoundTripsEveryField() async throws {
        let spark = AdditionalRateLimit(
            id: "codex_bengalfox", name: "GPT-5.3-Codex-Spark", usedPercent: 4,
            resetsAt: base.addingTimeInterval(9_000), primaryWindowSeconds: 18_000,
            secondary: .init(usedPercent: 12, resetsAt: base.addingTimeInterval(300_000),
                             windowSeconds: 604_800))
        try await store.writePoll(snapshot: snapshot(tool: .codex, limits: [spark]), now: base)
        try await store.writePoll(snapshot: snapshot(tool: .claude, limits: [fable]), now: base)

        let rows = try await store.modelLimitSeriesRange(
            tool: .codex, since: base, until: base.addingTimeInterval(1))
        XCTAssertEqual(rows, [
            .init(polledAt: base, limitKey: "codex_bengalfox", limitName: "GPT-5.3-Codex-Spark",
                  windowSlot: "primary", usedPct: 4, resetsAt: base.addingTimeInterval(9_000),
                  windowSeconds: 18_000),
            .init(polledAt: base, limitKey: "codex_bengalfox", limitName: "GPT-5.3-Codex-Spark",
                  windowSlot: "secondary", usedPct: 12, resetsAt: base.addingTimeInterval(300_000),
                  windowSeconds: 604_800),
        ])
        let none = try await store.modelLimitSeriesRange(
            tool: .codex, since: base.addingTimeInterval(1), until: base.addingTimeInterval(60))
        XCTAssertEqual(none, [], "half-open: a row at `since` is in, after it nothing")
    }
}
