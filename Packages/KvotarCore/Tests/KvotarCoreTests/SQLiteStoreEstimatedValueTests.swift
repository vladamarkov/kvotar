import XCTest
@testable import KvotarCore

final class SQLiteStoreEstimatedValueTests: XCTestCase {

    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory()
            .appending("kvotar-estimatedvalue-test-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    private func makeEvent(
        sessionId: String, dedupKey: String, model: String?,
        recordedAt: Date, input: Int = 100, output: Int = 50,
        cacheCreation: Int = 20, cacheCreation1h: Int? = nil, cacheRead: Int = 10
    ) -> TokenEvent {
        TokenEvent(
            tool: .claude, sessionId: sessionId, model: model,
            surfaceBucket: "Claude Code", startedAt: recordedAt,
            inputTokens: input, outputTokens: output,
            cacheCreationTokens: cacheCreation, cacheCreation1hTokens: cacheCreation1h,
            cacheReadTokens: cacheRead,
            recordedAt: recordedAt, dedupKey: dedupKey
        )
    }

    // MARK: - Cache-write tier split (STEP_96)

    /// The 1-hour slice round-trips as a **subset** of the total, and a row that never recorded a
    /// split (everything written before migration v17, deliberately not backfilled) sums in as 0 —
    /// which puts it in the 5-minute remainder, i.e. exactly the price it had before this step.
    func testCacheWriteTierRoundTripsAndUnknownSplitsFallToFiveMinute() async throws {
        let store = try SQLiteStore(path: dbPath)
        let now = Date()
        try await store.writeTokenEvents([
            // Post-v17 row: 24,576 written, 20,480 of it at the 1-hour tier.
            makeEvent(sessionId: "s1", dedupKey: "a", model: "claude-opus-5", recordedAt: now,
                      cacheCreation: 24_576, cacheCreation1h: 20_480),
            // Pre-v17-shaped row: total only, split unknown.
            makeEvent(sessionId: "s2", dedupKey: "b", model: "claude-opus-5", recordedAt: now,
                      cacheCreation: 10_000, cacheCreation1h: nil),
        ])

        let totals = try await store.tokenTotalsByModel(tool: .claude, since: now.addingTimeInterval(-60))
        let row = try XCTUnwrap(totals.first { $0.model == "claude-opus-5" })

        // The total is the sum of both rows and is unchanged by the split existing.
        XCTAssertEqual(row.cacheCreationTokens, 34_576)
        // Only the row that recorded a split contributes to the 1-hour sum.
        XCTAssertEqual(row.cacheCreation1hTokens, 20_480)
        // So the 5-minute remainder is that row's 4,096 plus the whole unknown-split row.
        XCTAssertEqual(row.cacheCreationTokens - row.cacheCreation1hTokens, 14_096)
        // Never a sibling: the 1-hour slice must not appear in a displayed count.
        XCTAssertLessThanOrEqual(row.cacheCreation1hTokens, row.cacheCreationTokens)
    }

    func testGroupsTotalsByModel() async throws {
        let store = try SQLiteStore(path: dbPath)
        let now = Date()
        try await store.writeTokenEvents([
            makeEvent(sessionId: "s1", dedupKey: "a", model: "claude-sonnet-4-6",
                      recordedAt: now, input: 100, output: 50, cacheCreation: 20, cacheRead: 10),
            makeEvent(sessionId: "s2", dedupKey: "b", model: "claude-sonnet-4-6",
                      recordedAt: now, input: 200, output: 60, cacheCreation: 0, cacheRead: 0),
            makeEvent(sessionId: "s3", dedupKey: "c", model: "claude-opus-4-8",
                      recordedAt: now, input: 10, output: 5, cacheCreation: 0, cacheRead: 0),
        ])

        let totals = try await store.tokenTotalsByModel(tool: .claude, since: now.addingTimeInterval(-60))

        let byModel = Dictionary(uniqueKeysWithValues: totals.map { ($0.model, $0) })
        XCTAssertEqual(byModel["claude-sonnet-4-6"]?.inputTokens, 300)
        XCTAssertEqual(byModel["claude-sonnet-4-6"]?.outputTokens, 110)
        XCTAssertEqual(byModel["claude-sonnet-4-6"]?.cacheCreationTokens, 20)
        XCTAssertEqual(byModel["claude-sonnet-4-6"]?.cacheReadTokens, 10)
        XCTAssertEqual(byModel["claude-opus-4-8"]?.inputTokens, 10)
    }

    func testExcludesRowsOlderThanWindowStart() async throws {
        let store = try SQLiteStore(path: dbPath)
        let now = Date()
        try await store.writeTokenEvents([
            makeEvent(sessionId: "s1", dedupKey: "old", model: "claude-sonnet-4-6",
                      recordedAt: now.addingTimeInterval(-1_000), input: 999),
            makeEvent(sessionId: "s1", dedupKey: "new", model: "claude-sonnet-4-6",
                      recordedAt: now, input: 1),
        ])

        let totals = try await store.tokenTotalsByModel(tool: .claude, since: now.addingTimeInterval(-60))

        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals.first?.inputTokens, 1, "the row before windowStart must be excluded")
    }

    func testOtherToolIsExcluded() async throws {
        let store = try SQLiteStore(path: dbPath)
        let now = Date()
        try await store.writeTokenEvents([
            TokenEvent(tool: .codex, sessionId: "cs1", model: "gpt-5.5", surfaceBucket: "CLI",
                       startedAt: now, inputTokens: 500, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0,
                       recordedAt: now, dedupKey: "codex-1"),
        ])

        let totals = try await store.tokenTotalsByModel(tool: .claude, since: now.addingTimeInterval(-60))

        XCTAssertTrue(totals.isEmpty)
    }

    func testEmptyWindowReturnsEmptyArray() async throws {
        let store = try SQLiteStore(path: dbPath)
        let totals = try await store.tokenTotalsByModel(tool: .claude, since: Date())
        XCTAssertTrue(totals.isEmpty)
    }

    // MARK: Until bound (REV-18 — off-machine span alignment)

    func testUntilBoundExcludesRowsAtOrAfterEnd() async throws {
        let store = try SQLiteStore(path: dbPath)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(120)
        try await store.writeTokenEvents([
            makeEvent(sessionId: "s1", dedupKey: "in", model: "claude-sonnet-4-6",
                      recordedAt: start.addingTimeInterval(60), input: 1),
            makeEvent(sessionId: "s1", dedupKey: "at-end", model: "claude-sonnet-4-6",
                      recordedAt: end, input: 100),
            makeEvent(sessionId: "s1", dedupKey: "after", model: "claude-sonnet-4-6",
                      recordedAt: end.addingTimeInterval(60), input: 999),
        ])

        let totals = try await store.tokenTotalsByModel(tool: .claude, since: start, until: end)

        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals.first?.inputTokens, 1, "the bound is half-open: [since, until)")
    }

    func testNilUntilKeepsUnboundedBehaviour() async throws {
        let store = try SQLiteStore(path: dbPath)
        let now = Date()
        try await store.writeTokenEvents([
            makeEvent(sessionId: "s1", dedupKey: "a", model: "claude-sonnet-4-6",
                      recordedAt: now, input: 7),
        ])

        let totals = try await store.tokenTotalsByModel(tool: .claude,
                                                        since: now.addingTimeInterval(-60))

        XCTAssertEqual(totals.first?.inputTokens, 7)
    }

    // MARK: sessionCount (REV-44 §2.5a "Sessions" row)

    func testSessionCountDistinctActiveInWindowFoldsSubagents() async throws {
        let store = try SQLiteStore(path: dbPath)
        let now = Date()
        try await store.writeTokenEvents([
            // Two distinct sessions active in the window.
            makeEvent(sessionId: "s1", dedupKey: "a", model: "claude-sonnet-4-6", recordedAt: now),
            makeEvent(sessionId: "s2", dedupKey: "b", model: "claude-opus-4-8", recordedAt: now),
            // A subagent line carries its parent's sessionId → same session, not a new one.
            makeEvent(sessionId: "s1", dedupKey: "a-sub", model: "claude-sonnet-4-6", recordedAt: now),
            // A session whose last activity is before the window → excluded (active-in-window, not
            // started-in-window).
            makeEvent(sessionId: "s3", dedupKey: "old", model: "claude-sonnet-4-6",
                      recordedAt: now.addingTimeInterval(-1_000)),
        ])

        let count = try await store.sessionCount(tool: .claude, since: now.addingTimeInterval(-60))
        XCTAssertEqual(count, 2, "distinct sessions active in the window; subagent folds into parent")
    }

    func testSessionCountExcludesOtherToolAndEmpty() async throws {
        let store = try SQLiteStore(path: dbPath)
        let now = Date()
        try await store.writeTokenEvents([
            TokenEvent(tool: .codex, sessionId: "cs1", model: "gpt-5.5", surfaceBucket: "CLI",
                       startedAt: now, inputTokens: 1, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0, recordedAt: now, dedupKey: "cx"),
        ])
        let count = try await store.sessionCount(tool: .claude, since: now.addingTimeInterval(-60))
        XCTAssertEqual(count, 0)
    }

    // MARK: - Per-event model attribution (STEP_93, REV-62 §4.3)

    /// The step's core defect, as a fixture: a session that switches model midway. Shape drawn
    /// from a real multi-model session (fable-5 turns with sonnet subagent turns interleaved;
    /// 31 of 145 live sessions look like this). Under session-scoped attribution every token
    /// below would be priced at whichever model spoke last; per-event, each slice keeps its own.
    func testMultiModelSessionPricesEachSliceAtItsOwnModel() async throws {
        let store = try SQLiteStore(path: dbPath)
        let now = Date()
        try await store.writeTokenEvents([
            makeEvent(sessionId: "s1", dedupKey: "t1", model: "claude-fable-5",
                      recordedAt: now, input: 1_000, output: 400, cacheCreation: 50, cacheRead: 200),
            makeEvent(sessionId: "s1", dedupKey: "t2", model: "claude-sonnet-4-6",
                      recordedAt: now, input: 300, output: 100, cacheCreation: 0, cacheRead: 0),
            // Sonnet speaks last → session model ends up sonnet; fable's tokens must not follow it.
            makeEvent(sessionId: "s1", dedupKey: "t3", model: "claude-sonnet-4-6",
                      recordedAt: now, input: 200, output: 50, cacheCreation: 0, cacheRead: 0),
        ])
        let totals = try await store.tokenTotalsByModel(tool: .claude,
                                                        since: now.addingTimeInterval(-60))
        let byModel = Dictionary(uniqueKeysWithValues: totals.map { ($0.model, $0) })
        XCTAssertEqual(byModel["claude-fable-5"]?.inputTokens, 1_000)
        XCTAssertEqual(byModel["claude-fable-5"]?.cacheReadTokens, 200)
        XCTAssertEqual(byModel["claude-sonnet-4-6"]?.inputTokens, 500)
        XCTAssertEqual(byModel["claude-sonnet-4-6"]?.outputTokens, 150)
    }

    /// Pre-v15 rows have NULL attribution columns and must keep pricing exactly as before —
    /// grouped under the session model — until the enrichment sweep fills them.
    func testNullModelRowFallsBackToSessionModel() async throws {
        let store = try SQLiteStore(path: dbPath)
        let now = Date()
        let at = Int(now.timeIntervalSince1970)
        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO local_sessions (session_id, tool, model, last_seen_at)
                    VALUES ('s1', 'claude', 'claude-opus-4-8', ?)
                    """, arguments: [at])
                try db.execute(sql: """
                    INSERT INTO local_usage_events
                        (session_id, tool, dedup_key, recorded_at, input_tokens, output_tokens,
                         cache_creation_tokens, cache_read_tokens)
                    VALUES ('s1', 'claude', 'pre-v15', ?, 100, 50, 0, 0)
                    """, arguments: [at])
            }
        }
        let totals = try await store.tokenTotalsByModel(tool: .claude,
                                                        since: now.addingTimeInterval(-60))
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals.first?.model, "claude-opus-4-8")
        XCTAssertEqual(totals.first?.inputTokens, 100)
    }

    /// The 24×-understatement fix: a session mixing main-agent and subagent events splits by the
    /// event's own bucket, not the session's last-writer-wins one.
    func testSurfaceSplitGroupsByEventBucket() async throws {
        let store = try SQLiteStore(path: dbPath)
        let now = Date()
        try await store.writeTokenEvents([
            makeEvent(sessionId: "s1", dedupKey: "m1", model: "claude-fable-5", recordedAt: now,
                      input: 1_000, output: 500, cacheCreation: 0, cacheRead: 0),
            TokenEvent(tool: .claude, sessionId: "s1", model: "claude-sonnet-4-6",
                       surfaceBucket: "Subagent · Explore", startedAt: now,
                       inputTokens: 300, outputTokens: 100,
                       cacheCreationTokens: 0, cacheReadTokens: 0,
                       recordedAt: now, dedupKey: "sub1"),
        ])
        let totals = try await store.tokenTotalsBySurface(tool: .claude,
                                                          since: now.addingTimeInterval(-60))
        let byBucket = Dictionary(uniqueKeysWithValues: totals.map { ($0.surfaceBucket, $0.totalTokens) })
        XCTAssertEqual(byBucket["Claude Code"], 1_500)
        XCTAssertEqual(byBucket["Subagent · Explore"], 400,
                       "subagent tokens stay in the subagent bucket regardless of write order")
    }

    /// STEP_192: the per-surface split carries each bucket's newest event time, read in the same
    /// query as the totals — what `SurfaceWorkSplit.activeSurfaces` decides "burning now" from.
    func testSurfaceSplitCarriesNewestEventPerBucket() async throws {
        let store = try SQLiteStore(path: dbPath)
        let now = Date(timeIntervalSince1970: 1_757_800_000)
        try await store.writeTokenEvents([
            makeEvent(sessionId: "s1", dedupKey: "m1", model: "claude-fable-5",
                      recordedAt: now.addingTimeInterval(-3600),
                      input: 1_000, output: 500, cacheCreation: 0, cacheRead: 0),
            makeEvent(sessionId: "s1", dedupKey: "m2", model: "claude-fable-5",
                      recordedAt: now.addingTimeInterval(-60),
                      input: 100, output: 50, cacheCreation: 0, cacheRead: 0),
            TokenEvent(tool: .claude, sessionId: "s1", model: "claude-sonnet-4-6",
                       surfaceBucket: "Subagent · Explore", startedAt: now,
                       inputTokens: 300, outputTokens: 100,
                       cacheCreationTokens: 0, cacheReadTokens: 0,
                       recordedAt: now.addingTimeInterval(-1800), dedupKey: "sub1"),
        ])
        let totals = try await store.tokenTotalsBySurface(tool: .claude,
                                                          since: now.addingTimeInterval(-7200))
        let byBucket = Dictionary(uniqueKeysWithValues: totals.map { ($0.surfaceBucket, $0.lastEventAt) })
        XCTAssertEqual(byBucket["Claude Code"], now.addingTimeInterval(-60),
                       "the newest of the bucket's events, not the oldest or the session's")
        XCTAssertEqual(byBucket["Subagent · Explore"], now.addingTimeInterval(-1800))
    }
}
