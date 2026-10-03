import XCTest
import GRDB
@testable import KvotarCore

/// The §17.2 ordered aggregate-before-purge pass (STEP_50 — REV-42 + REV-43).
/// `runRetentionCleanup()` reads the wall clock, so fixtures are laid out relative to real
/// `now`: doomed snapshots sit in a fully-elapsed UTC hour older than the 2h cutoff.
final class SQLiteStoreRetentionTests: XCTestCase {

    private var dbPath: String!
    private var now: Int!
    /// An hour bucket old enough that everything in it is past the 2h snapshot cutoff.
    private var hourStart: Int!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory()
            .appending("kvotar-retention-\(UUID().uuidString).db")
        now = Int(Date().timeIntervalSince1970)
        hourStart = ((now - 10800) / 3600) * 3600
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    // MARK: - Fixture helpers

    private func insertSnapshot(
        _ store: SQLiteStore, tool: String = "claude", polledAt: Int,
        primaryPct: Double?, secondaryPct: Double? = nil, rateLimitReached: Int? = nil
    ) async throws {
        // Locals only in the closure — capturing test-class properties is a Sendable violation.
        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO poll_snapshots
                        (tool, polled_at, primary_used_pct, secondary_used_pct,
                         rate_limit_reached)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [tool, polledAt, primaryPct, secondaryPct, rateLimitReached])
            }
        }
    }

    private struct RollupFacts {
        var snapshotCount: Int
        var primaryMin: Double?
        var primaryMax: Double?
        var primaryLast: Double?
        var rateLimitReachedMax: Int?
        var planType: String?
        var lastPolledAt: Int
    }

    private func rollupFacts(_ store: SQLiteStore, tool: String = "claude")
        async throws -> RollupFacts?
    {
        let hourStart: Int = hourStart
        return try await store.withPool { pool in
            try pool.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT * FROM history_rollups WHERE tool = ? AND hour_start = ?
                    """, arguments: [tool, hourStart]) else { return nil }
                return RollupFacts(
                    snapshotCount: row["snapshot_count"],
                    primaryMin: row["primary_used_pct_min"],
                    primaryMax: row["primary_used_pct_max"],
                    primaryLast: row["primary_used_pct_last"],
                    rateLimitReachedMax: row["rate_limit_reached_max"],
                    planType: row["plan_type"],
                    lastPolledAt: row["last_polled_at"])
            }
        }
    }

    private func count(_ store: SQLiteStore, _ sql: String, _ args: StatementArguments = [])
        async throws -> Int
    {
        try await store.withPool { pool in
            try pool.read { db in
                try Int.fetchOne(db, sql: sql, arguments: args) ?? 0
            }
        }
    }

    // MARK: - history_rollups: aggregate-before-purge

    /// One hour bucket fed by two successive cleanup passes merges into a single row with
    /// correct min/max/count/last (§17.1 merge semantics) — the 2h-retention / 30-min-cadence
    /// case where a bucket is purged across up to three runs.
    func testRollupMergesAcrossCleanupRuns() async throws {
        let store = try SQLiteStore(path: dbPath)
        let now: Int = now
        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO accounts (tool, email, plan_type, updated_at)
                    VALUES ('claude', NULL, 'max', ?)
                    """, arguments: [now])
            }
        }

        // Pass 1: two doomed rows in the bucket + a fresh exempt row keeping MAX(id) recent.
        try await insertSnapshot(store, polledAt: hourStart, primaryPct: 10,
                                 secondaryPct: 1, rateLimitReached: 0)
        try await insertSnapshot(store, polledAt: hourStart + 60, primaryPct: 20,
                                 secondaryPct: 2, rateLimitReached: 1)
        try await insertSnapshot(store, polledAt: now, primaryPct: 99)
        try await store.runRetentionCleanup()

        var fetched = try await rollupFacts(store)
        var facts = try XCTUnwrap(fetched)
        XCTAssertEqual(facts.snapshotCount, 2)
        XCTAssertEqual(facts.primaryMin, 10.0)
        XCTAssertEqual(facts.primaryMax, 20.0)
        XCTAssertEqual(facts.primaryLast, 20.0)
        XCTAssertEqual(facts.rateLimitReachedMax, 1)
        XCTAssertEqual(facts.planType, "max")
        XCTAssertEqual(facts.lastPolledAt, hourStart + 60)

        // Pass 2: a third row of the same hour surfaces (was the exempt row's junior — now a
        // newer exempt row exists), lands in the same bucket via merge.
        try await insertSnapshot(store, polledAt: hourStart + 120, primaryPct: 5,
                                 secondaryPct: 3, rateLimitReached: 0)
        try await insertSnapshot(store, polledAt: now + 1, primaryPct: 98)
        try await store.runRetentionCleanup()

        fetched = try await rollupFacts(store)
        facts = try XCTUnwrap(fetched)
        XCTAssertEqual(facts.snapshotCount, 3, "merge must add, not replace")
        XCTAssertEqual(facts.primaryMin, 5.0, "min must consider both runs")
        XCTAssertEqual(facts.primaryMax, 20.0, "max must survive the second run")
        XCTAssertEqual(facts.primaryLast, 5.0, "newer batch must take the _last columns")
        XCTAssertEqual(facts.rateLimitReachedMax, 1, "an hour with any hit keeps max = 1")
        XCTAssertEqual(facts.lastPolledAt, hourStart + 120)

        // Exactly one bucket row; the doomed snapshots are gone, the exempt rows remain.
        let buckets = try await count(store, "SELECT COUNT(*) FROM history_rollups")
        XCTAssertEqual(buckets, 1)
        let snapshots = try await count(store, "SELECT COUNT(*) FROM poll_snapshots")
        XCTAssertEqual(snapshots, 2)
    }

    /// The retention-exempt latest row per tool is not rolled up while exempt; once superseded
    /// and purged it lands in its own (old) bucket — the long-sleep case (§17.1).
    func testExemptRowRollsUpOnlyOnceSuperseded() async throws {
        let store = try SQLiteStore(path: dbPath)

        // A single old row: past the cutoff but MAX(id) for the tool → exempt.
        try await insertSnapshot(store, polledAt: hourStart, primaryPct: 42)
        try await store.runRetentionCleanup()

        let earlyRollup = try await rollupFacts(store)
        XCTAssertNil(earlyRollup,
                     "the exempt row must not be rolled up while it is the last known state")
        let earlySnapshots = try await count(store, "SELECT COUNT(*) FROM poll_snapshots")
        XCTAssertEqual(earlySnapshots, 1)

        // A fresh poll supersedes it → next pass purges and rolls it into its own bucket.
        try await insertSnapshot(store, polledAt: now, primaryPct: 7)
        try await store.runRetentionCleanup()

        let fetched = try await rollupFacts(store)
        let facts = try XCTUnwrap(fetched)
        XCTAssertEqual(facts.snapshotCount, 1)
        XCTAssertEqual(facts.primaryLast, 42.0)
        let snapshots = try await count(store, "SELECT COUNT(*) FROM poll_snapshots")
        XCTAssertEqual(snapshots, 1, "only the new exempt row remains")
    }

    // MARK: - session_summaries: idle-session receipts

    private func insertSession(
        _ store: SQLiteStore, id: String, lastSeenAt: Int,
        events: [(key: String, input: Int, output: Int)]
    ) async throws {
        try await store.withPool { pool in
            try pool.write { db in
                // ON CONFLICT UPDATE, not INSERT OR REPLACE — REPLACE deletes the session row
                // and the FK cascade would wipe its earlier events.
                try db.execute(sql: """
                    INSERT INTO local_sessions
                        (session_id, tool, project, model, last_seen_at)
                    VALUES (?, 'claude', '/tmp/proj', 'claude-sonnet-4-6', ?)
                    ON CONFLICT(session_id, tool) DO UPDATE SET last_seen_at = excluded.last_seen_at
                    """, arguments: [id, lastSeenAt])
                for e in events {
                    try db.execute(sql: """
                        INSERT INTO local_usage_events
                            (session_id, tool, dedup_key, recorded_at, input_tokens, output_tokens)
                        VALUES (?, 'claude', ?, ?, ?, ?)
                        """, arguments: [id, e.key, lastSeenAt, e.input, e.output])
                }
            }
        }
    }

    private func summaryFacts(_ store: SQLiteStore, id: String)
        async throws -> (eventCount: Int, input: Int, output: Int)?
    {
        try await store.withPool { pool in
            try pool.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT * FROM session_summaries WHERE session_id = ? AND tool = 'claude'
                    """, arguments: [id]) else { return nil }
                return (eventCount: row["event_count"],
                        input: row["input_tokens"],
                        output: row["output_tokens"])
            }
        }
    }

    /// A session summarized once idle >24h is re-summarized after it resumes — sums correct,
    /// still one row (the upsert is self-correcting, §17.1).
    func testResumedSessionIsReSummarizedWithoutDuplicates() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await insertSession(store, id: "s1", lastSeenAt: now - 100_000,
                                events: [("e1", 100, 10), ("e2", 200, 20)])
        try await store.runRetentionCleanup()

        var facts = try await summaryFacts(store, id: "s1")
        XCTAssertEqual(facts?.eventCount, 2)
        XCTAssertEqual(facts?.input, 300)
        XCTAssertEqual(facts?.output, 30)

        // Session resumes (new event, still idle >24h at the next pass) → re-upsert.
        try await insertSession(store, id: "s1", lastSeenAt: now - 90_000,
                                events: [("e3", 50, 5)])
        try await store.runRetentionCleanup()

        facts = try await summaryFacts(store, id: "s1")
        XCTAssertEqual(facts?.eventCount, 3, "re-summarize must include the resumed event")
        XCTAssertEqual(facts?.input, 350)
        let summaryCount = try await count(store, "SELECT COUNT(*) FROM session_summaries")
        XCTAssertEqual(summaryCount, 1, "re-upsert must not duplicate the receipt")
    }

    /// A recently-active session (idle < 24h) is not summarized yet.
    func testActiveSessionNotSummarized() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await insertSession(store, id: "fresh", lastSeenAt: now - 3600,
                                events: [("e1", 1, 1)])
        try await store.runRetentionCleanup()
        let summaries = try await count(store, "SELECT COUNT(*) FROM session_summaries")
        XCTAssertEqual(summaries, 0)
    }

    // MARK: - Raw corpus permanence (v5.18 — REV-43)

    /// A session far past the retired 30-day cutoff survives the pass, events intact.
    func testRawCorpusSurvivesCleanup() async throws {
        let store = try SQLiteStore(path: dbPath)
        let fortyDaysAgo = now - 40 * 86400
        try await insertSession(store, id: "ancient", lastSeenAt: fortyDaysAgo,
                                events: [("e1", 10, 1), ("e2", 20, 2)])
        try await store.runRetentionCleanup()

        let sessions = try await count(store,
            "SELECT COUNT(*) FROM local_sessions WHERE session_id = 'ancient'")
        XCTAssertEqual(sessions, 1, "the raw corpus is permanent — no 30d delete")
        let events = try await count(store,
            "SELECT COUNT(*) FROM local_usage_events WHERE session_id = 'ancient'")
        XCTAssertEqual(events, 2, "events must survive with their session")
        // And it still gets its summary receipt.
        let summaries = try await count(store,
            "SELECT COUNT(*) FROM session_summaries WHERE session_id = 'ancient'")
        XCTAssertEqual(summaries, 1)
    }

    // MARK: - Time-based deletes at 90 days

    func testNinetyDayDeletesSpareRecentRows() async throws {
        let store = try SQLiteStore(path: dbPath)
        let old = now - 91 * 86400
        let recent = now - 89 * 86400
        try await store.withPool { pool in
            try pool.write { db in
                for ts in [old, recent] {
                    try db.execute(sql: """
                        INSERT INTO poll_health_events
                            (tool, endpoint, timestamp, retry_after_seconds,
                             consecutive_count, base_interval_at_time)
                        VALUES ('claude', 'oauth_usage', ?, 0, 1, 60)
                        """, arguments: [ts])
                    try db.execute(sql: """
                        INSERT INTO state_transitions
                            (tool, timestamp, from_state, to_state, triggered_by)
                        VALUES ('claude', ?, 'healthy', 'elevated', 'poll')
                        """, arguments: [ts])
                    try db.execute(sql: """
                        INSERT INTO notification_events
                            (tool, event_type, fired_at, window_start)
                        VALUES ('claude', 'at_risk', ?, ?)
                        """, arguments: [ts, ts])
                }
            }
        }
        try await store.runRetentionCleanup()

        for table in ["poll_health_events", "state_transitions"] {
            let remaining = try await count(store,
                "SELECT COUNT(*) FROM \(table)")
            XCTAssertEqual(remaining, 1, "\(table): 90d cutoff must spare the recent row")
        }
        let notifRemaining = try await count(store,
            "SELECT COUNT(*) FROM notification_events")
        XCTAssertEqual(notifRemaining, 1,
                       "notification_events: 90d delete on fired_at replaces window-scoped deletion")
        let survivor = try await count(store,
            "SELECT COUNT(*) FROM notification_events WHERE fired_at = ?", [recent])
        XCTAssertEqual(survivor, 1)
    }

    // MARK: STEP_114 read

    func testHistoryRollupsReadReturnsRowsInRangeOldestFirst() async throws {
        let store = try SQLiteStore(path: dbPath)
        let base = (now - 10 * 3600) - (now - 10 * 3600) % 3600   // ten hours ago, hour-aligned: purged by the 2h cutoff
        try await insertSnapshot(store, polledAt: base + 100, primaryPct: 10, secondaryPct: 3)
        try await insertSnapshot(store, polledAt: base + 3700, primaryPct: 20, secondaryPct: 4)
        try await insertSnapshot(store, polledAt: base + 7300, primaryPct: 25, secondaryPct: 4)
        try await insertSnapshot(store, tool: "codex", polledAt: base + 100, primaryPct: 2)
        try await store.runRetentionCleanup()

        let rows = try await store.historyRollups(
            tool: .claude, since: Date(timeIntervalSince1970: TimeInterval(base)),
            until: Date(timeIntervalSince1970: TimeInterval(base + 7200)))
        XCTAssertEqual(rows.map(\.hourStart), [base, base + 3600], "third hour is past `until`")
        XCTAssertEqual(rows.map(\.primaryUsedPctLast), [10, 20])
        XCTAssertEqual(rows.map(\.secondaryUsedPctMax), [3, 4])
        XCTAssertEqual(rows[0].tool, "claude")
    }
}
