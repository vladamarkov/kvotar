import XCTest
import GRDB
@testable import KvotarCore

/// Pins the `quota_series` substrate (v10 — REV-53, STEP_76): the gated write inside
/// `writePoll`, the resets_at-proximity window read, and the newest-point anchor.
final class SQLiteStoreQuotaSeriesTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private var resetsAt: Date { base.addingTimeInterval(18_000) }

    private var dbPath: String!
    private var store: SQLiteStore!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory().appending("kvotar-qseries-\(UUID().uuidString).db")
        store = try SQLiteStore(path: dbPath)
    }

    override func tearDown() {
        store = nil
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + s) }
    }

    private func snapshot(pct: Double?, resetsAt: Date?) -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: pct, primaryResetsAt: resetsAt,
                      secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: nil)
    }

    func testWritePollInsertsSeriesRowForWindowPolls() async throws {
        try await store.writePoll(snapshot: snapshot(pct: 12, resetsAt: resetsAt), now: base)
        let rows = try await store.quotaSeries(tool: .claude, resetsAtNear: resetsAt)
        XCTAssertEqual(rows, [QuotaSeriesPoint(polledAt: base, usedPct: 12, resetsAt: resetsAt)])
    }

    func testWritePollSkipsSeriesRowOnNullWindow() async throws {
        // A pct without a resets_at (and vice versa) can't be attributed to a window.
        try await store.writePoll(snapshot: snapshot(pct: 12, resetsAt: nil), now: base)
        try await store.writePoll(snapshot: snapshot(pct: nil, resetsAt: resetsAt),
                                  now: base.addingTimeInterval(60))
        let latest = try await store.latestQuotaSeriesPoint(tool: .claude)
        XCTAssertNil(latest, "null-window polls must not land in quota_series")
    }

    func testSameSecondPollReplacesNotThrows() async throws {
        // Tripwire + scheduled poll can share a second; the PK conflict must not abort the
        // poll transaction (INSERT OR REPLACE).
        try await store.writePoll(snapshot: snapshot(pct: 12, resetsAt: resetsAt), now: base)
        try await store.writePoll(snapshot: snapshot(pct: 13, resetsAt: resetsAt), now: base)
        let rows = try await store.quotaSeries(tool: .claude, resetsAtNear: resetsAt)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].usedPct, 13, "the later write wins the second")
    }

    func testQuotaSeriesSelectsByResetsAtProximity() async throws {
        // Same tool, three rows: this window (±jitter) and the next window 5h later.
        try await store.writePoll(snapshot: snapshot(pct: 10, resetsAt: resetsAt), now: base)
        try await store.writePoll(
            snapshot: snapshot(pct: 15, resetsAt: resetsAt.addingTimeInterval(1)),   // wobble
            now: base.addingTimeInterval(240))
        try await store.writePoll(
            snapshot: snapshot(pct: 2, resetsAt: resetsAt.addingTimeInterval(18_000)),
            now: base.addingTimeInterval(480))
        let rows = try await store.quotaSeries(tool: .claude, resetsAtNear: resetsAt)
        XCTAssertEqual(rows.map(\.usedPct), [10, 15],
                       "±1s wobble is the same window; +5h is not — and rows come oldest first")
    }

    func testLatestQuotaSeriesPointReturnsNewest() async throws {
        try await store.writePoll(snapshot: snapshot(pct: 10, resetsAt: resetsAt), now: base)
        try await store.writePoll(snapshot: snapshot(pct: 15, resetsAt: resetsAt),
                                  now: base.addingTimeInterval(240))
        let latest = try await store.latestQuotaSeriesPoint(tool: .claude)
        XCTAssertEqual(latest, QuotaSeriesPoint(polledAt: base.addingTimeInterval(240),
                                                usedPct: 15, resetsAt: resetsAt))
    }

    // MARK: previousWindowOutcome (REV-68/D-75 — STEP_112 window-boundary form)

    /// Two windows on record and the current one populated: `[N]` is the *previous* window's
    /// high-water reading, not its last one, and a window that never crossed 100 has no limit time.
    func testPreviousWindowOutcomeHighWaterOfTheWindowBeforeCurrent() async throws {
        let prev = resetsAt
        let current = resetsAt.addingTimeInterval(18_000)
        // Previous window: 40 → 94 → 88 (a late poll after a partial recovery is not the peak).
        try await store.writePoll(snapshot: snapshot(pct: 40, resetsAt: prev), now: base)
        try await store.writePoll(snapshot: snapshot(pct: 94, resetsAt: prev),
                                  now: base.addingTimeInterval(600))
        try await store.writePoll(snapshot: snapshot(pct: 88, resetsAt: prev.addingTimeInterval(1)),
                                  now: base.addingTimeInterval(1_200))
        // Current window has polled once already — must be excluded by `before`.
        try await store.writePoll(snapshot: snapshot(pct: 3, resetsAt: current),
                                  now: base.addingTimeInterval(19_000))
        let outcome = try await store.previousWindowOutcome(
            tool: .claude, before: current, now: base.addingTimeInterval(19_100))
        let o = try XCTUnwrap(outcome)
        XCTAssertEqual(o.highWaterPct, 94, "the peak, not the newest reading")
        XCTAssertNil(o.hitLimitAt)
        // The anchor is the newest poll's stamp (the +1 s wobble row) — what the header last showed.
        XCTAssertEqual(o.resetsAt, prev.addingTimeInterval(1))
    }

    /// `hitLimitAt` is the first poll at or past 100 — the `— hit the limit at [t₁]` clock.
    func testPreviousWindowOutcomeFirstPollAtTheLimit() async throws {
        let prev = resetsAt
        try await store.writePoll(snapshot: snapshot(pct: 97, resetsAt: prev), now: base)
        try await store.writePoll(snapshot: snapshot(pct: 100, resetsAt: prev),
                                  now: base.addingTimeInterval(300))
        try await store.writePoll(snapshot: snapshot(pct: 100, resetsAt: prev),
                                  now: base.addingTimeInterval(600))
        let outcome = try await store.previousWindowOutcome(
            tool: .claude, before: prev.addingTimeInterval(18_000), now: base.addingTimeInterval(19_000))
        XCTAssertEqual(outcome?.hitLimitAt, base.addingTimeInterval(300))
        XCTAssertEqual(outcome?.highWaterPct, 100)
    }

    /// Fresh-null form (`before: nil`): the previous window is the newest one that has *ended*, the
    /// same guard `lastActiveWindow` applies — a still-open window is never the "last" one.
    func testPreviousWindowOutcomeNilBeforeUsesEndedWindowsOnly() async throws {
        try await store.writePoll(snapshot: snapshot(pct: 61, resetsAt: resetsAt), now: base)
        let stillOpen = try await store.previousWindowOutcome(
            tool: .claude, before: nil, now: resetsAt.addingTimeInterval(-60))
        XCTAssertNil(stillOpen, "the window has not ended yet")
        let ended = try await store.previousWindowOutcome(
            tool: .claude, before: nil, now: resetsAt.addingTimeInterval(60))
        XCTAssertEqual(ended, WindowOutcome(resetsAt: resetsAt, highWaterPct: 61, hitLimitAt: nil))
    }

    /// No earlier window on record → nil (plain `New window since [t]` form). Also per tool.
    func testPreviousWindowOutcomeNilWhenNoEarlierWindow() async throws {
        let none = try await store.previousWindowOutcome(tool: .claude, before: resetsAt, now: base)
        XCTAssertNil(none)
        try await store.writePoll(snapshot: snapshot(pct: 20, resetsAt: resetsAt), now: base)
        let onlyCurrent = try await store.previousWindowOutcome(
            tool: .claude, before: resetsAt, now: base.addingTimeInterval(60))
        XCTAssertNil(onlyCurrent, "the only window on record is the current one")
        let otherTool = try await store.previousWindowOutcome(
            tool: .codex, before: nil, now: resetsAt.addingTimeInterval(60))
        XCTAssertNil(otherTool, "rows are per tool")
    }

    func testTokenEventTimestampsHalfOpenRange() async throws {
        for offset in [0.0, 100, 200] {
            try await store.writeTokenEvents([TokenEvent(
                tool: .claude, sessionId: "s", surfaceBucket: "cli",
                inputTokens: 1, outputTokens: 1, cacheCreationTokens: 0, cacheReadTokens: 0,
                recordedAt: base.addingTimeInterval(offset), dedupKey: "k\(offset)")])
        }
        let stamps = try await store.tokenEventTimestamps(
            tool: .claude, since: base, until: base.addingTimeInterval(200))
        XCTAssertEqual(stamps, [base, base.addingTimeInterval(100)],
                       "[since, until): inclusive lower, exclusive upper")
    }

    // MARK: - Window width and the bounded history read (v23 — REV-93 §4, STEP_181)

    /// The width the provider reported is the one thing a *finished* window needs to be named,
    /// and `poll_snapshots` — where it was already written — is purged at two hours.
    private func widthSnapshot(tool: Tool = .claude, pct: Double, resetsAt: Date,
                               width: Int?) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, primaryUsedPct: pct, primaryResetsAt: resetsAt,
                      primaryWindowSeconds: width, secondaryUsedPct: nil,
                      secondaryResetsAt: nil, rateLimitReached: nil)
    }

    func testWritePollPersistsTheProviderReportedWindowWidth() async throws {
        try await store.writePoll(
            snapshot: widthSnapshot(pct: 12, resetsAt: resetsAt, width: 18_000), now: base)
        let rows = try await store.quotaSeries(tool: .claude, resetsAtNear: resetsAt)
        XCTAssertEqual(rows.map(\.windowSeconds), [18_000])
    }

    /// Codex reports no duration on some payloads, and that is honest data. Nothing invents one.
    func testMissingWidthIsStoredAsNullNotGuessed() async throws {
        try await store.writePoll(
            snapshot: widthSnapshot(tool: .codex, pct: 5, resetsAt: resetsAt, width: nil),
            now: base)
        let rows = try await store.quotaSeries(tool: .codex, resetsAtNear: resetsAt)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].windowSeconds)
    }

    func testQuotaSeriesRangeIsBoundedHalfOpenAndPerTool() async throws {
        for offset in [0.0, 100, 200] {
            try await store.writePoll(
                snapshot: widthSnapshot(pct: 10 + offset / 100, resetsAt: resetsAt, width: 18_000),
                now: base.addingTimeInterval(offset))
        }
        try await store.writePoll(
            snapshot: widthSnapshot(tool: .codex, pct: 90, resetsAt: resetsAt, width: 604_800),
            now: base.addingTimeInterval(100))

        let claude = try await store.quotaSeriesRange(
            tool: .claude, since: base, until: base.addingTimeInterval(200))
        XCTAssertEqual(claude.map(\.polledAt), [base, base.addingTimeInterval(100)],
                       "[since, until): inclusive lower, exclusive upper")
        let codex = try await store.quotaSeriesRange(
            tool: .codex, since: base, until: base.addingTimeInterval(200))
        XCTAssertEqual(codex.map(\.windowSeconds), [604_800], "rows are per tool")
    }

    /// A database written by a pre-`v23` build keeps every row it had, and those rows stay
    /// width-unknown. No backfill: the width was never recorded, and inventing it is the
    /// fabrication REV-93 §4 forbids.
    func testMigrationPreservesRowsAndLeavesLegacyWidthNull() throws {
        let path = NSTemporaryDirectory().appending("kvotar-qs-v23-\(UUID().uuidString).db")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }

        var migrator = DatabaseMigrator()
        SQLiteStore.registerMigrations(&migrator)
        let pool = try DatabasePool(path: path)
        try migrator.migrate(pool, upTo: "v22_quota_series_local_activity")

        // A row the way the old build wrote it: five columns, no width.
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO quota_series
                    (tool, polled_at, primary_used_pct, primary_resets_at, last_local_activity_at)
                VALUES ('claude', ?, 41.0, ?, NULL)
                """, arguments: [Int(base.timeIntervalSince1970),
                                 Int(resetsAt.timeIntervalSince1970)])
        }

        try migrator.migrate(pool)

        let (count, pct, width) = try pool.read { db -> (Int, Double?, Int?) in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n, MAX(primary_used_pct) AS pct,
                       MAX(primary_window_seconds) AS width FROM quota_series
                """)
            return (row?["n"] as Int? ?? 0, row?["pct"] as Double?, row?["width"] as Int?)
        }
        XCTAssertEqual(count, 1, "the legacy row survives the migration")
        XCTAssertEqual(pct, 41.0)
        XCTAssertNil(width, "and never acquires a width it never had")

        let version = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'schema_version'")
        }
        XCTAssertEqual(version, "25")
    }

    /// The `v24` twin of the test above: a database written by a pre-`v24` build keeps every row
    /// it had, and those rows never acquire a weekly window they were not written with
    /// (STEP_188 — REV-95 §3.1; no backfill, the STEP_181 rule).
    func testV24MigrationPreservesRowsAndLeavesTheSecondaryNull() throws {
        let path = NSTemporaryDirectory().appending("kvotar-qs-v24-\(UUID().uuidString).db")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }

        var migrator = DatabaseMigrator()
        SQLiteStore.registerMigrations(&migrator)
        let pool = try DatabasePool(path: path)
        try migrator.migrate(pool, upTo: "v23_quota_series_window_seconds")

        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO quota_series
                    (tool, polled_at, primary_used_pct, primary_resets_at,
                     last_local_activity_at, primary_window_seconds)
                VALUES ('claude', ?, 41.0, ?, NULL, 18000)
                """, arguments: [Int(base.timeIntervalSince1970),
                                 Int(resetsAt.timeIntervalSince1970)])
        }

        try migrator.migrate(pool)

        let row = try pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n, MAX(primary_used_pct) AS pct,
                       MAX(secondary_used_pct) AS spct, MAX(secondary_resets_at) AS sreset,
                       MAX(secondary_window_seconds) AS swidth FROM quota_series
                """)
        }
        XCTAssertEqual(row?["n"] as Int? ?? 0, 1, "the legacy row survives the migration")
        XCTAssertEqual(row?["pct"] as Double?, 41.0)
        XCTAssertNil(row?["spct"] as Double?)
        XCTAssertNil(row?["sreset"] as Int?)
        XCTAssertNil(row?["swidth"] as Int?)

        // The seven `forecast_log` columns land in the same migration and are equally empty.
        let log = try pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n FROM pragma_table_info('forecast_log')
                WHERE name IN ('shadow_version', 'blend_rate_pct_per_min', 'rise_probability',
                               'rise_p10_pct', 'rise_p90_pct', 'displayed_state',
                               'warning_first_shown_at')
                """)
        }
        XCTAssertEqual(log?["n"] as Int? ?? 0, 7)

        let version = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'schema_version'")
        }
        XCTAssertEqual(version, "25")
    }

    // MARK: The weekly window rides the same row (STEP_188 — REV-95 §3.1)

    private func windowedSnapshot(pct: Double?, resetsAt: Date?,
                                  secondaryPct: Double?, secondaryResetsAt: Date?,
                                  secondaryWidth: Int?) -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: pct, primaryResetsAt: resetsAt,
                      secondaryUsedPct: secondaryPct, secondaryResetsAt: secondaryResetsAt,
                      secondaryWindowSeconds: secondaryWidth, rateLimitReached: nil)
    }

    private func secondaryColumns() throws -> (Double?, Int?, Int?) {
        try DatabasePool(path: dbPath).read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT secondary_used_pct, secondary_resets_at, secondary_window_seconds
                  FROM quota_series ORDER BY polled_at DESC LIMIT 1
                """)
            return (row?["secondary_used_pct"] as Double?,
                    row?["secondary_resets_at"] as Int?,
                    row?["secondary_window_seconds"] as Int?)
        }
    }

    func testWritePollRecordsTheSecondaryWindow() async throws {
        let weeklyReset = base.addingTimeInterval(604_800)
        try await store.writePoll(
            snapshot: windowedSnapshot(pct: 12, resetsAt: resetsAt, secondaryPct: 31,
                                       secondaryResetsAt: weeklyReset, secondaryWidth: 604_800),
            now: base)
        let (pct, reset, width) = try secondaryColumns()
        XCTAssertEqual(pct, 31)
        // Decoding as Int must succeed — a REAL-stored Double would break this (PATTERNS.md).
        XCTAssertEqual(reset, Int(weeklyReset.timeIntervalSince1970))
        XCTAssertEqual(width, 604_800)
    }

    func testWritePollLeavesTheSecondaryColumnsNullWhenThereIsNoWeeklyWindow() async throws {
        try await store.writePoll(snapshot: snapshot(pct: 12, resetsAt: resetsAt), now: base)
        let (pct, reset, width) = try secondaryColumns()
        XCTAssertNil(pct)
        XCTAssertNil(reset)
        XCTAssertNil(width)
    }

    func testAWeeklyWindowWithoutAStatedWidthStoresNoWidth() async throws {
        // Claude's shape: a weekly percentage and reset, and no width on the wire.
        try await store.writePoll(
            snapshot: windowedSnapshot(pct: 12, resetsAt: resetsAt, secondaryPct: 31,
                                       secondaryResetsAt: base.addingTimeInterval(604_800),
                                       secondaryWidth: nil),
            now: base)
        let (pct, _, width) = try secondaryColumns()
        XCTAssertEqual(pct, 31)
        XCTAssertNil(width, "a width nobody stated is never invented")
    }

    func testAWeeklyWindowAloneStillWritesNoRow() async throws {
        // The row-selection gate is unchanged: the primary window decides whether a poll lands
        // here at all, so a weekly reading with no primary anchor is not a series row.
        try await store.writePoll(
            snapshot: windowedSnapshot(pct: nil, resetsAt: nil, secondaryPct: 31,
                                       secondaryResetsAt: base.addingTimeInterval(604_800),
                                       secondaryWidth: 604_800),
            now: base)
        let latest = try await store.latestQuotaSeriesPoint(tool: .claude)
        XCTAssertNil(latest)
    }

    // MARK: The weekly history read (STEP_227)

    func testSecondaryRangeReadsOnlyRowsWithAWeeklyHalfOpen() async throws {
        let weeklyReset = base.addingTimeInterval(604_800)
        try await store.writePoll(snapshot: snapshot(pct: 5, resetsAt: resetsAt), now: base)
        try await store.writePoll(
            snapshot: windowedSnapshot(pct: 6, resetsAt: resetsAt, secondaryPct: 31,
                                       secondaryResetsAt: weeklyReset, secondaryWidth: nil),
            now: base.addingTimeInterval(120))
        try await store.writePoll(
            snapshot: windowedSnapshot(pct: 7, resetsAt: resetsAt, secondaryPct: 33,
                                       secondaryResetsAt: weeklyReset, secondaryWidth: 604_800),
            now: base.addingTimeInterval(240))

        let rows = try await store.quotaSeriesSecondaryRange(
            tool: .claude, since: base, until: base.addingTimeInterval(240))
        XCTAssertEqual(rows.map(\.usedPct), [31], "no-weekly rows skipped, `until` excluded")
        XCTAssertEqual(rows.first?.resetsAt, weeklyReset)
        XCTAssertNil(rows.first?.windowSeconds, "an unstated width stays unstated")

        let codex = try await store.quotaSeriesSecondaryRange(
            tool: .codex, since: base, until: base.addingTimeInterval(600))
        XCTAssertEqual(codex, [])
    }
}
