import XCTest
import GRDB
@testable import KvotarCore

final class SQLiteStoreForecastLogTests: XCTestCase {

    private var dbPath: String!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory().appending("kvotar-forecastlog-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    func testWriteForecastLogRoundTrips() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeForecastLog(ForecastLogEntry(
            tool: .claude, computedAt: t0,
            primaryUsedPct: 78, secondaryUsedPct: 31,
            burnRatePctPerMin: 0.5,
            etaTo100: t0.addingTimeInterval(44 * 60),
            primaryResetsAt: t0.addingTimeInterval(90 * 60),
            forecastTier: .partial, trigger: .stateChange,
            appVersion: "0.9.3 (142)",
            displayedState: .atRisk,
            warningFirstShownAt: t0.addingTimeInterval(-5 * 60)))

        try await store.withPool { pool in
            try pool.read { db in
                // Asserting the raw strings also proves the reserved-keyword `"trigger"`
                // quoting in the INSERT prepares and binds correctly.
                let row = try Row.fetchOne(db, sql: "SELECT * FROM forecast_log")
                XCTAssertEqual(row?["tool"], "claude")
                XCTAssertEqual(row?["computed_at"], 1_800_000_000)
                XCTAssertEqual(row?["primary_used_pct"], 78.0)
                XCTAssertEqual(row?["secondary_used_pct"], 31.0)
                XCTAssertEqual(row?["burn_rate_pct_per_min"], 0.5)
                XCTAssertEqual(row?["eta_to_100"], 1_800_000_000 + 44 * 60)
                XCTAssertEqual(row?["primary_resets_at"], 1_800_000_000 + 90 * 60)
                XCTAssertEqual(row?["forecast_tier"], "partial")
                XCTAssertEqual(row?["trigger"], "state_change")
                XCTAssertEqual(row?["app_version"], "0.9.3 (142)")
                XCTAssertEqual(row?["displayed_state"], "at_risk")
                XCTAssertEqual(row?["warning_first_shown_at"], 1_800_000_000 - 5 * 60)
            }
        }
    }

    func testQuantizedBurnLandsUnrounded() async throws {
        let store = try SQLiteStore(path: dbPath)
        // A real quantized-quotient shape (9% over 14 min) — must land bit-exact.
        let burn = 9.0 / 14.0
        try await store.writeForecastLog(ForecastLogEntry(
            tool: .codex, computedAt: t0,
            primaryUsedPct: 44, secondaryUsedPct: nil,
            burnRatePctPerMin: burn,
            etaTo100: nil, primaryResetsAt: nil,
            forecastTier: .full, trigger: .sample,
            appVersion: "0.9.3 (142)",
            displayedState: .healthy, warningFirstShownAt: nil))

        try await store.withPool { pool in
            try pool.read { db in
                let stored = try Double.fetchOne(
                    db, sql: "SELECT burn_rate_pct_per_min FROM forecast_log")
                XCTAssertEqual(stored, burn)
                let version = try String.fetchOne(
                    db, sql: "SELECT app_version FROM forecast_log")
                XCTAssertEqual(version, "0.9.3 (142)")
            }
        }
    }

    /// A row whose evaluation produced no shadow leaves all five §11.5 columns NULL — **together**.
    /// That is itself a gradable record ("the app had no second opinion here"), where a partially
    /// filled row would not be, and nothing is ever carried over from a previous evaluation
    /// (REV-95 §3.2 / REV-54 §7 — STEP_190).
    func testANilShadowWritesFiveNulls() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeForecastLog(ForecastLogEntry(
            tool: .claude, computedAt: t0,
            primaryUsedPct: 61, secondaryUsedPct: 22,
            burnRatePctPerMin: 0.4,
            etaTo100: t0.addingTimeInterval(60 * 60),
            primaryResetsAt: t0.addingTimeInterval(120 * 60),
            forecastTier: .full, trigger: .sample,
            appVersion: "0.9.3 (142)",
            displayedState: .healthy, warningFirstShownAt: nil))

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(db, sql: """
                    SELECT shadow_version, blend_rate_pct_per_min, rise_probability,
                           rise_p10_pct, rise_p90_pct FROM forecast_log
                    """)
                XCTAssertNotNil(row, "the columns exist")
                XCTAssertNil(row?["shadow_version"] as String?)
                XCTAssertNil(row?["blend_rate_pct_per_min"] as Double?)
                XCTAssertNil(row?["rise_probability"] as Double?)
                XCTAssertNil(row?["rise_p10_pct"] as Double?)
                XCTAssertNil(row?["rise_p90_pct"] as Double?)
            }
        }
    }

    /// And a row that has one writes all five, stamped with the generation that produced them
    /// (STEP_190).
    func testAShadowWritesAllFiveColumns() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeForecastLog(ForecastLogEntry(
            tool: .claude, computedAt: t0,
            primaryUsedPct: 61, secondaryUsedPct: 22,
            burnRatePctPerMin: 0.4,
            etaTo100: t0.addingTimeInterval(60 * 60),
            primaryResetsAt: t0.addingTimeInterval(120 * 60),
            forecastTier: .full, trigger: .sample,
            appVersion: "0.9.3 (142)",
            displayedState: .healthy, warningFirstShownAt: nil,
            shadow: ShadowForecast(version: "s1", blendRate: 0.37, riseProbability: 0.88,
                                   riseP10: 0, riseP90: 12)))

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(db, sql: """
                    SELECT shadow_version, blend_rate_pct_per_min, rise_probability,
                           rise_p10_pct, rise_p90_pct FROM forecast_log
                    """)
                XCTAssertEqual(row?["shadow_version"] as String?, "s1")
                XCTAssertEqual(row?["blend_rate_pct_per_min"] as Double?, 0.37)
                XCTAssertEqual(row?["rise_probability"] as Double?, 0.88)
                XCTAssertEqual(row?["rise_p10_pct"] as Double?, 0)
                XCTAssertEqual(row?["rise_p90_pct"] as Double?, 12)
            }
        }
    }

    // MARK: - Window exposure (the table's first runtime reader — STEP_190)

    func testWindowExposureFoldsRowsPerAnchorAndKeepsTheEarliestWarning() async throws {
        let store = try SQLiteStore(path: dbPath)
        let anchor = t0.addingTimeInterval(3600)
        let warned = t0.addingTimeInterval(1800)
        for (offset, warning) in [(0.0, nil), (300.0, warned), (600.0, t0.addingTimeInterval(2400))]
            as [(Double, Date?)] {
            try await store.writeForecastLog(ForecastLogEntry(
                tool: .claude, computedAt: t0.addingTimeInterval(offset),
                primaryUsedPct: 50, secondaryUsedPct: nil, burnRatePctPerMin: 0.2,
                etaTo100: nil, primaryResetsAt: anchor,
                forecastTier: .full, trigger: .sample, appVersion: "0.9.3 (142)",
                displayedState: .healthy, warningFirstShownAt: warning))
        }

        let rows = try await store.forecastLogWindowExposure(
            tool: .claude, since: t0.addingTimeInterval(-60),
            until: t0.addingTimeInterval(3600))
        XCTAssertEqual(rows.count, 1, "one row per window, not per poll")
        XCTAssertEqual(rows.first?.anchor, anchor)
        XCTAssertTrue(rows.first?.recorded ?? false)
        XCTAssertEqual(rows.first?.warningFirstShownAt, warned,
                       "SQLite's MIN ignores NULLs, so the earliest recorded stamp wins")
    }

    /// The ruling-1 marker. `displayed_state` and `warning_first_shown_at` both arrived in `v24`,
    /// so a row without the first cannot be trusted to have been able to record the second.
    func testWindowExposureReportsAPreV24RowAsUnrecorded() async throws {
        let store = try SQLiteStore(path: dbPath)
        let anchor = t0.addingTimeInterval(3600)
        let computedAtUnix = Int(t0.timeIntervalSince1970)
        let anchorUnix = Int(anchor.timeIntervalSince1970)
        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO forecast_log
                        (tool, computed_at, forecast_tier, "trigger", app_version,
                         primary_resets_at)
                    VALUES ('claude', ?, 'full', 'sample', '0.3.0 (11)', ?)
                    """, arguments: [computedAtUnix, anchorUnix])
            }
        }
        let rows = try await store.forecastLogWindowExposure(
            tool: .claude, since: t0.addingTimeInterval(-60), until: t0.addingTimeInterval(3600))
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows.first?.recorded ?? true)
        XCTAssertNil(rows.first?.warningFirstShownAt)
    }

    func testWindowExposureSkipsRowsWithNoWindowAnchor() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeForecastLog(ForecastLogEntry(
            tool: .claude, computedAt: t0,
            primaryUsedPct: nil, secondaryUsedPct: nil, burnRatePctPerMin: nil,
            etaTo100: nil, primaryResetsAt: nil,
            forecastTier: .coldStart, trigger: .sample, appVersion: "0.9.3 (142)",
            displayedState: .idleFallback, warningFirstShownAt: nil))
        let rows = try await store.forecastLogWindowExposure(
            tool: .claude, since: t0.addingTimeInterval(-60), until: t0.addingTimeInterval(3600))
        XCTAssertTrue(rows.isEmpty, "there is nothing to key an exposure to")
    }

    func testTimestampsStoredAsIntAndNullsPersist() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeForecastLog(ForecastLogEntry(
            tool: .claude, computedAt: t0,
            primaryUsedPct: nil, secondaryUsedPct: nil,
            burnRatePctPerMin: nil,
            etaTo100: nil, primaryResetsAt: nil,
            forecastTier: .coldStart, trigger: .sample,
            appVersion: "0.9.3 (142)",
            displayedState: .idleFallback, warningFirstShownAt: nil))

        try await store.withPool { pool in
            try pool.read { db in
                // Decoding as Int must succeed — a REAL-stored Double would break this.
                let ts = try Int.fetchOne(db, sql: "SELECT computed_at FROM forecast_log")
                XCTAssertEqual(ts, 1_800_000_000)
                let row = try Row.fetchOne(db, sql: "SELECT * FROM forecast_log")
                XCTAssertNil(row?["eta_to_100"] as Int?, "null eta persists as NULL")
                XCTAssertNil(row?["burn_rate_pct_per_min"] as Double?, "null burn persists as NULL")
                XCTAssertNil(row?["primary_used_pct"] as Double?, "null utilization persists as NULL")
                XCTAssertEqual(row?["forecast_tier"], "cold_start")
                XCTAssertNil(row?["warning_first_shown_at"] as Int?,
                             "no warning shown in this window persists as NULL, not 0")
                XCTAssertEqual(row?["displayed_state"], "idle_fallback")
            }
        }
    }
}
