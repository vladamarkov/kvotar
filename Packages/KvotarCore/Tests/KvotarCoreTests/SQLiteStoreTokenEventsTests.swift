import XCTest
import GRDB
@testable import KvotarCore

final class SQLiteStoreTokenEventsTests: XCTestCase {

    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory()
            .appending("kvotar-tokenevents-test-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    private func makeEvent(
        tool: Tool = .claude,
        sessionId: String = "s1",
        dedupKey: String = "req-1",
        project: String? = "/home/u/proj",
        model: String? = "claude-sonnet-4-6",
        surfaceBucket: String = "Claude Code",
        startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        recordedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        input: Int = 100, output: Int = 50, cacheCreation: Int = 20, cacheRead: Int = 10,
        legacyDedupKey: String? = nil,
        originator: String? = nil
    ) -> TokenEvent {
        TokenEvent(
            tool: tool,
            sessionId: sessionId,
            project: project,
            model: model,
            surfaceBucket: surfaceBucket,
            slug: "my-session",
            startedAt: startedAt,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            recordedAt: recordedAt,
            dedupKey: dedupKey,
            legacyDedupKey: legacyDedupKey,
            originator: originator
        )
    }

    func testWritePersistsSessionAndUsageInOneBatch() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeTokenEvents([makeEvent()])

        try await store.withPool { pool in
            try pool.read { db in
                let session = try Row.fetchOne(
                    db, sql: "SELECT * FROM local_sessions WHERE session_id = ?", arguments: ["s1"])
                XCTAssertEqual(session?["project"], "/home/u/proj")
                XCTAssertEqual(session?["model"], "claude-sonnet-4-6")
                XCTAssertEqual(session?["surface_bucket"], "Claude Code")

                let usage = try Row.fetchOne(
                    db, sql: "SELECT * FROM local_usage_events WHERE session_id = ?",
                    arguments: ["s1"])
                XCTAssertEqual(usage?["input_tokens"], 100)
                XCTAssertEqual(usage?["output_tokens"], 50)
                XCTAssertEqual(usage?["cache_creation_tokens"], 20)
                XCTAssertEqual(usage?["cache_read_tokens"], 10)
            }
        }
    }

    func testEmptyBatchIsNoOp() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeTokenEvents([])
        try await store.withPool { pool in
            try pool.read { db in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM local_usage_events")
                XCTAssertEqual(count, 0)
            }
        }
    }

    func testDuplicateDedupKeyIsIgnored() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeTokenEvents([makeEvent(dedupKey: "dup", input: 10)])
        // Replay with the same PK but different token values — must be ignored, not overwrite.
        try await store.writeTokenEvents([makeEvent(dedupKey: "dup", input: 999)])

        try await store.withPool { pool in
            try pool.read { db in
                let count = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM local_usage_events WHERE dedup_key = ?",
                    arguments: ["dup"])
                XCTAssertEqual(count, 1)
                let input = try Int.fetchOne(
                    db, sql: "SELECT input_tokens FROM local_usage_events WHERE dedup_key = ?",
                    arguments: ["dup"])
                XCTAssertEqual(input, 10, "INSERT OR IGNORE keeps the first row")
            }
        }
    }

    func testSessionUpsertAdvancesLastSeenAndKeepsEarliestStarted() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeTokenEvents([makeEvent(
            dedupKey: "a",
            startedAt: Date(timeIntervalSince1970: 1_000),
            recordedAt: Date(timeIntervalSince1970: 1_000))])
        try await store.writeTokenEvents([makeEvent(
            dedupKey: "b",
            startedAt: Date(timeIntervalSince1970: 2_000),
            recordedAt: Date(timeIntervalSince1970: 2_000))])

        try await store.withPool { pool in
            try pool.read { db in
                let sessionCount = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM local_sessions")
                XCTAssertEqual(sessionCount, 1, "session is upserted, not duplicated")

                let started = try Int.fetchOne(
                    db, sql: "SELECT started_at FROM local_sessions WHERE session_id = ?",
                    arguments: ["s1"])
                XCTAssertEqual(started, 1_000, "keeps earliest started_at")

                let lastSeen = try Int.fetchOne(
                    db, sql: "SELECT last_seen_at FROM local_sessions WHERE session_id = ?",
                    arguments: ["s1"])
                XCTAssertEqual(lastSeen, 2_000, "advances last_seen_at")

                let usageCount = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM local_usage_events WHERE session_id = ?",
                    arguments: ["s1"])
                XCTAssertEqual(usageCount, 2)
            }
        }
    }

    func testSessionProjectIsTheFolderOfItsEarliestRequest() async throws {
        // Requests arrive newest first — the live watcher reads a file from its end at launch,
        // the backfill reads the beginning later — so the folder the session ended in lands
        // first. The project must still be the folder of the earliest request.
        let store = try SQLiteStore(path: dbPath)
        try await store.writeTokenEvents([makeEvent(
            dedupKey: "late", project: "/home/u/kvotar/dist", model: "claude-sonnet-4-6",
            startedAt: Date(timeIntervalSince1970: 3_000),
            recordedAt: Date(timeIntervalSince1970: 3_000))])
        _ = try await store.backfillTokenEvents([makeEvent(
            dedupKey: "early", project: "/home/u/kvotar", model: "claude-opus-4-8",
            startedAt: Date(timeIntervalSince1970: 1_000),
            recordedAt: Date(timeIntervalSince1970: 1_000))])
        // A later request with no folder changes nothing.
        try await store.writeTokenEvents([makeEvent(
            dedupKey: "later", project: nil, model: nil,
            startedAt: Date(timeIntervalSince1970: 4_000),
            recordedAt: Date(timeIntervalSince1970: 4_000))])

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(
                    db, sql: "SELECT project, model, started_at FROM local_sessions WHERE session_id = ?",
                    arguments: ["s1"])
                XCTAssertEqual(row?["project"] as String?, "/home/u/kvotar",
                               "the earliest request's folder, whatever order it arrived in")
                XCTAssertEqual(row?["model"] as String?, "claude-opus-4-8",
                               "model still takes the newest non-null value written")
                XCTAssertEqual(row?["started_at"] as Int?, 1_000)
            }
        }
    }

    func testOriginatorPersistsForCodexEvent() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeTokenEvents([makeEvent(
            tool: .codex, sessionId: "codex-s1", dedupKey: "codex-1",
            project: nil, model: nil, surfaceBucket: "CLI",
            originator: "codex_cli_rs")])

        try await store.withPool { pool in
            try pool.read { db in
                let session = try Row.fetchOne(
                    db, sql: "SELECT * FROM local_sessions WHERE session_id = ? AND tool = ?",
                    arguments: ["codex-s1", "codex"])
                XCTAssertEqual(session?["originator"], "codex_cli_rs")
                XCTAssertEqual(session?["surface_bucket"], "CLI")
            }
        }
    }

    func testDeletingSessionCascadesToUsageEvents() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeTokenEvents([makeEvent(dedupKey: "a"), makeEvent(dedupKey: "b")])

        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(
                    sql: "DELETE FROM local_sessions WHERE session_id = ?", arguments: ["s1"])
            }
            try pool.read { db in
                let usageCount = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM local_usage_events WHERE session_id = ?",
                    arguments: ["s1"])
                XCTAssertEqual(usageCount, 0, "composite FK ON DELETE CASCADE removes usage rows")
            }
        }
    }

    // MARK: - Backfill writes (STEP_95)

    /// The load-bearing difference from `writeTokenEvents`: the Codex session-id convention
    /// changed ~2026-07-13 (bare ULID → rollout basename) while the dedup key stayed stable, so
    /// the backfill guard must skip a known `(tool, dedup_key)` under **any** session id — the
    /// composite PK alone would re-insert every pre-boundary corpus event as a duplicate.
    func testBackfillSkipsKnownDedupKeyAcrossSessionIdConventions() async throws {
        let store = try SQLiteStore(path: dbPath)
        // Live-era row under the old convention (bare ULID session id).
        try await store.writeTokenEvents([makeEvent(
            tool: .codex, sessionId: "01900000-0000-7000-8000-000000000001",
            dedupKey: "rollout-2026-05-17_2026-05-17T15:43:10.608Z_28800",
            surfaceBucket: "CLI")])

        // Backfill re-reads the same corpus line, now keyed by the new convention.
        let counts = try await store.backfillTokenEvents([makeEvent(
            tool: .codex, sessionId: "rollout-2026-05-17",
            dedupKey: "rollout-2026-05-17_2026-05-17T15:43:10.608Z_28800",
            surfaceBucket: "CLI")])

        XCTAssertEqual(counts.inserted, 0)
        XCTAssertEqual(counts.insertedTokens, 0)
        try await store.withPool { pool in
            try pool.read { db in
                let usage = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM local_usage_events WHERE tool = 'codex'")
                XCTAssertEqual(usage, 1, "the corpus event must not be double-stored")
                // Skipped events also skip the session upsert — no clutter row under the new id.
                let sessions = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM local_sessions WHERE tool = 'codex'")
                XCTAssertEqual(sessions, 1)
            }
        }
    }

    func testBackfillInsertsNewEventsAndReportsClaudeFourColumnTokens() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeTokenEvents([makeEvent(dedupKey: "known")])

        let counts = try await store.backfillTokenEvents([
            makeEvent(dedupKey: "known"),                                       // dup → skipped
            makeEvent(sessionId: "s2", dedupKey: "fresh",
                      input: 100, output: 50, cacheCreation: 20, cacheRead: 10),
        ])

        XCTAssertEqual(counts.inserted, 1)
        // Claude displayed count sums all four disjoint columns (Baseline §4).
        XCTAssertEqual(counts.insertedTokens, 180)
        try await store.withPool { pool in
            try pool.read { db in
                let session = try Row.fetchOne(
                    db, sql: "SELECT * FROM local_sessions WHERE session_id = ?", arguments: ["s2"])
                XCTAssertNotNil(session, "an inserted event upserts its session row")
            }
        }
    }

    func testBackfillReportsCodexInputPlusOutputTokens() async throws {
        let store = try SQLiteStore(path: dbPath)
        let counts = try await store.backfillTokenEvents([makeEvent(
            tool: .codex, sessionId: "rollout-x", dedupKey: "rollout-x_t_150",
            surfaceBucket: "CLI",
            input: 100, output: 50, cacheCreation: 30, cacheRead: 0)])

        XCTAssertEqual(counts.inserted, 1)
        // Codex cached (held in cache_creation) is a subset of input — displayed count is
        // input + output, never the four-column sum (Baseline §4 fork, STEP_91).
        XCTAssertEqual(counts.insertedTokens, 150)
    }

    func testBackfillRerunInsertsNothing() async throws {
        let store = try SQLiteStore(path: dbPath)
        let batch = [makeEvent(dedupKey: "a"), makeEvent(sessionId: "s2", dedupKey: "b")]
        let first = try await store.backfillTokenEvents(batch)
        XCTAssertEqual(first.inserted, 2)

        let second = try await store.backfillTokenEvents(batch)
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.insertedTokens, 0)
    }

    // MARK: - Per-event attribution + zero-usage guard (STEP_93, REV-62 §4.3)

    /// Reads one usage event's stored (model, surface_bucket) pair directly.
    private func storedAttribution(
        _ store: SQLiteStore, dedupKey: String
    ) async throws -> (model: String?, surface: String?) {
        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(db, sql: """
                    SELECT model, surface_bucket FROM local_usage_events WHERE dedup_key = ?
                    """, arguments: [dedupKey])
                return (row?["model"], row?["surface_bucket"])
            }
        }
    }

    func testEventRowCarriesItsOwnModelAndSurface() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeTokenEvents([
            makeEvent(dedupKey: "main", model: "claude-fable-5", surfaceBucket: "Claude Code"),
            makeEvent(dedupKey: "side", model: "claude-sonnet-4-6",
                      surfaceBucket: "Subagent · Explore"),
        ])
        let main = try await storedAttribution(store, dedupKey: "main")
        XCTAssertEqual(main.model, "claude-fable-5")
        XCTAssertEqual(main.surface, "Claude Code")
        let side = try await storedAttribution(store, dedupKey: "side")
        XCTAssertEqual(side.model, "claude-sonnet-4-6")
        XCTAssertEqual(side.surface, "Subagent · Explore")
    }

    /// The `<synthetic>` fix (task 3): a zero-usage line is Claude Code's placeholder for a turn
    /// that died before the API. It must neither rename the session it lands last in nor appear
    /// as a per-event model — one such line relabelled 196 genuine turns (REV-62 §4.3).
    func testZeroUsageEventNeverAssertsAModel() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeTokenEvents([
            makeEvent(dedupKey: "real", model: "claude-fable-5",
                      recordedAt: Date(timeIntervalSince1970: 1_800_000_000)),
            makeEvent(dedupKey: "placeholder", model: "<synthetic>",
                      recordedAt: Date(timeIntervalSince1970: 1_800_000_100),
                      input: 0, output: 0, cacheCreation: 0, cacheRead: 0),
        ])
        let sessionModel = try await store.withPool { pool in
            try pool.read { db in
                try String.fetchOne(
                    db, sql: "SELECT model FROM local_sessions WHERE session_id = 's1'")
            }
        }
        XCTAssertEqual(sessionModel, "claude-fable-5",
                       "the zero-token placeholder landing last must not rename the session")
        let stored = try await storedAttribution(store, dedupKey: "placeholder")
        XCTAssertNil(stored.model, "a zero-usage event asserts no model of its own")
    }

    func testEnrichmentFillsOnlyNullColumnsAndNeverTokenCounts() async throws {
        let store = try SQLiteStore(path: dbPath)
        // Simulate pre-v15 rows: attribution columns NULL, written under the session model.
        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO local_sessions (session_id, tool, model, surface_bucket, last_seen_at)
                    VALUES ('s1', 'claude', 'claude-sonnet-4-6', 'Claude Code', 1800000000)
                    """)
                try db.execute(sql: """
                    INSERT INTO local_usage_events
                        (session_id, tool, dedup_key, recorded_at, input_tokens, output_tokens,
                         cache_creation_tokens, cache_read_tokens)
                    VALUES ('s1', 'claude', 'old-1', 1800000000, 100, 50, 20, 10),
                           ('s1', 'claude', 'old-2', 1800000060, 200, 80, 0, 0)
                    """)
                // A row the live path already attributed — enrichment must not overwrite it.
                try db.execute(sql: """
                    INSERT INTO local_usage_events
                        (session_id, tool, dedup_key, recorded_at, input_tokens, output_tokens,
                         cache_creation_tokens, cache_read_tokens, model, surface_bucket)
                    VALUES ('s1', 'claude', 'live-1', 1800000120, 10, 5, 0, 0,
                            'claude-fable-5', 'Claude Code')
                    """)
            }
        }

        let updated = try await store.enrichTokenEventAttribution([
            makeEvent(dedupKey: "old-1", model: "claude-fable-5",
                      surfaceBucket: "Subagent · Explore"),
            makeEvent(dedupKey: "old-2", model: "claude-opus-4-8", surfaceBucket: "Claude Code"),
            // The re-parse claims a different model for the live row — it must be ignored.
            makeEvent(dedupKey: "live-1", model: "claude-opus-4-8", surfaceBucket: "CLI"),
        ])
        XCTAssertEqual(updated, 2)

        let old1 = try await storedAttribution(store, dedupKey: "old-1")
        XCTAssertEqual(old1.model, "claude-fable-5")
        XCTAssertEqual(old1.surface, "Subagent · Explore")
        let live = try await storedAttribution(store, dedupKey: "live-1")
        XCTAssertEqual(live.model, "claude-fable-5", "already-attributed rows are untouched")
        XCTAssertEqual(live.surface, "Claude Code")
        let tokens = try await store.withPool { pool in
            try pool.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT input_tokens, output_tokens FROM local_usage_events
                    WHERE dedup_key = 'old-1'
                    """).map { (($0["input_tokens"] as Int?) ?? -1, ($0["output_tokens"] as Int?) ?? -1) }
            }
        }
        XCTAssertEqual(tokens?.0, 100, "enrichment never touches a token quantity (REV-43)")
        XCTAssertEqual(tokens?.1, 50)
    }

    // MARK: - STEP_100 surface-attribution repair (the one path that overwrites a bucket)

    /// The repair rewrites a *wrong* bucket, which is the whole reason it exists — the enrichment
    /// above `COALESCE`s and so is a no-op on these rows. It must move both the event column and
    /// the session column (the §2.5b bar coalesces one onto the other), match across the Codex
    /// session-id convention change, leave a row that already agrees alone, and touch no token.
    func testSurfaceRepairOverwritesWrongBucketsAndLeavesTokensAlone() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.withPool { pool in
            try pool.write { db in
                // One real file is one `session_meta` and therefore one bucket, so the two
                // mislabelled rows share a session; the already-correct row is its own.
                try db.execute(sql: """
                    INSERT INTO local_sessions (session_id, tool, surface_bucket, last_seen_at)
                    VALUES ('old-convention-ulid', 'codex', 'IDE extension', 1800000000),
                           ('rollout-cli', 'codex', 'CLI', 1800000000)
                    """)
                try db.execute(sql: """
                    INSERT INTO local_usage_events
                        (session_id, tool, dedup_key, recorded_at, input_tokens, output_tokens,
                         cache_creation_tokens, cache_read_tokens, surface_bucket)
                    VALUES ('old-convention-ulid', 'codex', 'rollout-x_t_100', 1800000000,
                            100, 50, 0, 0, 'IDE extension'),
                           ('old-convention-ulid', 'codex', 'rollout-x_t_200', 1800000060,
                            10, 5, 0, 0, 'IDE extension'),
                           ('rollout-cli', 'codex', 'rollout-cli_t_300', 1800000120,
                            10, 5, 0, 0, 'CLI')
                    """)
            }
        }

        // The re-parse names the session by the NEW convention (rollout basename) while the
        // stored rows use the old ULID — the dedup key alone has to find both columns.
        let updated = try await store.repairSurfaceAttribution([
            // The desktop app reporting the VS Code shell's name for itself — the mislabel.
            makeEvent(tool: .codex, sessionId: "rollout-x", dedupKey: "rollout-x_t_100",
                      model: "gpt-5.5", surfaceBucket: "Desktop"),
            makeEvent(tool: .codex, sessionId: "rollout-x", dedupKey: "rollout-x_t_200",
                      model: "gpt-5.5", surfaceBucket: "Desktop"),
            // Already correct — must not count as a repair.
            makeEvent(tool: .codex, sessionId: "rollout-cli", dedupKey: "rollout-cli_t_300",
                      model: "gpt-5.5", surfaceBucket: "CLI"),
        ])
        XCTAssertEqual(updated, 2, "only the rows that disagreed were rewritten")

        let desktop = try await storedAttribution(store, dedupKey: "rollout-x_t_100")
        XCTAssertEqual(desktop.surface, "Desktop")
        let second = try await storedAttribution(store, dedupKey: "rollout-x_t_200")
        XCTAssertEqual(second.surface, "Desktop")

        let session = try await store.withPool { pool in
            try pool.read { db in
                try String.fetchOne(db, sql: """
                    SELECT surface_bucket FROM local_sessions WHERE session_id = 'old-convention-ulid'
                    """)
            }
        }
        XCTAssertEqual(session, "Desktop",
                       "the pre-v15 fallback column is reconciled from the session's own events, "
                       + "not matched by session id (the Codex convention changed under it)")

        let cli = try await store.withPool { pool in
            try pool.read { db in
                try String.fetchOne(db, sql: """
                    SELECT surface_bucket FROM local_sessions WHERE session_id = 'rollout-cli'
                    """)
            }
        }
        XCTAssertEqual(cli, "CLI", "a session that already agreed is left as it was")

        let tokens = try await store.withPool { pool in
            try pool.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT input_tokens, output_tokens FROM local_usage_events
                    WHERE dedup_key = 'rollout-x_t_100'
                    """).map { (($0["input_tokens"] as Int?) ?? -1, ($0["output_tokens"] as Int?) ?? -1) }
            }
        }
        XCTAssertEqual(tokens?.0, 100, "the repair never touches a token quantity (REV-43)")
        XCTAssertEqual(tokens?.1, 50)
    }

    /// A pre-`v15` session — its events carry no bucket of their own — keeps the session-level
    /// value, because there the session column *is* the answer the bar coalesces onto.
    func testSurfaceRepairLeavesPreV15SessionsAlone() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO local_sessions (session_id, tool, surface_bucket, last_seen_at)
                    VALUES ('old', 'codex', 'CLI', 1800000000),
                           ('new', 'codex', 'IDE extension', 1800000000)
                    """)
                try db.execute(sql: """
                    INSERT INTO local_usage_events
                        (session_id, tool, dedup_key, recorded_at, input_tokens, output_tokens,
                         cache_creation_tokens, cache_read_tokens, surface_bucket)
                    VALUES ('old', 'codex', 'old-1', 1800000000, 1, 1, 0, 0, NULL),
                           ('new', 'codex', 'new-1', 1800000000, 1, 1, 0, 0, 'IDE extension')
                    """)
            }
        }
        _ = try await store.repairSurfaceAttribution([
            makeEvent(tool: .codex, sessionId: "new", dedupKey: "new-1",
                      model: "gpt-5.5", surfaceBucket: "Desktop"),
        ])
        let buckets = try await store.withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT session_id, surface_bucket FROM local_sessions ORDER BY session_id
                    """).map { ($0["session_id"] as String, $0["surface_bucket"] as String?) }
            }
        }
        XCTAssertEqual(buckets.first(where: { $0.0 == "old" })?.1, "CLI",
                       "no event carries a bucket here — the session value must survive")
        XCTAssertEqual(buckets.first(where: { $0.0 == "new" })?.1, "Desktop")
    }

    /// Idempotence is what makes the completion stamp safe to lose: a crash before the stamp is
    /// written costs a free re-run, never a double edit.
    func testSurfaceRepairIsIdempotent() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO local_sessions (session_id, tool, surface_bucket, last_seen_at)
                    VALUES ('s1', 'codex', 'IDE extension', 1800000000)
                    """)
                try db.execute(sql: """
                    INSERT INTO local_usage_events
                        (session_id, tool, dedup_key, recorded_at, input_tokens, output_tokens,
                         cache_creation_tokens, cache_read_tokens, surface_bucket)
                    VALUES ('s1', 'codex', 'k1', 1800000000, 1, 1, 0, 0, 'IDE extension')
                    """)
            }
        }
        let event = makeEvent(tool: .codex, sessionId: "s1", dedupKey: "k1",
                              model: "gpt-5.5", surfaceBucket: "Desktop")
        let first = try await store.repairSurfaceAttribution([event])
        XCTAssertEqual(first, 1)
        let second = try await store.repairSurfaceAttribution([event])
        XCTAssertEqual(second, 0, "a second pass finds nothing to change")
    }

    func testEnrichmentSkipsZeroUsageModelAndMatchesAcrossSessionIds() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO local_sessions (session_id, tool, last_seen_at)
                    VALUES ('old-convention-ulid', 'codex', 1800000000)
                    """)
                try db.execute(sql: """
                    INSERT INTO local_usage_events
                        (session_id, tool, dedup_key, recorded_at, input_tokens, output_tokens,
                         cache_creation_tokens, cache_read_tokens)
                    VALUES ('old-convention-ulid', 'codex', 'rollout-x_t_100', 1800000000,
                            100, 50, 0, 0),
                           ('old-convention-ulid', 'codex', 'rollout-x_t_0', 1800000060,
                            0, 0, 0, 0)
                    """)
            }
        }
        // Re-parsed events arrive under the NEW session-id convention (rollout basename) — the
        // dedup key alone must find the old-convention rows (STEP_95's cross-convention lesson).
        let updated = try await store.enrichTokenEventAttribution([
            makeEvent(tool: .codex, sessionId: "rollout-x", dedupKey: "rollout-x_t_100",
                      model: "gpt-5.5", surfaceBucket: "IDE extension"),
            makeEvent(tool: .codex, sessionId: "rollout-x", dedupKey: "rollout-x_t_0",
                      model: "gpt-5.5", surfaceBucket: "IDE extension",
                      input: 0, output: 0, cacheCreation: 0, cacheRead: 0),
        ])
        XCTAssertEqual(updated, 2, "both rows matched across the session-id convention change")
        let real = try await storedAttribution(store, dedupKey: "rollout-x_t_100")
        XCTAssertEqual(real.model, "gpt-5.5")
        let zero = try await storedAttribution(store, dedupKey: "rollout-x_t_0")
        XCTAssertNil(zero.model, "a zero-usage event enriches no model")
        XCTAssertEqual(zero.surface, "IDE extension", "surface still fills — it prices nothing")
    }

    func testRepairPlaceholderSessionModelsIsNarrow() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.withPool { pool in
            try pool.write { db in
                // The REV-62 §4.3 shape: genuine turns plus one zero-token placeholder that
                // landed last and renamed the session.
                try db.execute(sql: """
                    INSERT INTO local_sessions (session_id, tool, model, last_seen_at)
                    VALUES ('renamed', 'claude', '<synthetic>', 1800000200),
                           ('healthy', 'claude', 'claude-opus-4-8', 1800000200)
                    """)
                try db.execute(sql: """
                    INSERT INTO local_usage_events
                        (session_id, tool, dedup_key, recorded_at, input_tokens, output_tokens,
                         cache_creation_tokens, cache_read_tokens, model)
                    VALUES ('renamed', 'claude', 'r1', 1800000000, 100, 50, 0, 0, 'claude-fable-5'),
                           ('renamed', 'claude', 'r2', 1800000100, 200, 80, 0, 0, 'claude-fable-5'),
                           ('renamed', 'claude', 'r3', 1800000200, 0, 0, 0, 0, NULL),
                           ('healthy', 'claude', 'h1', 1800000000, 10, 5, 0, 0, 'claude-opus-4-8')
                    """)
            }
        }
        let repaired = try await store.repairPlaceholderSessionModels()
        XCTAssertEqual(repaired, 1)
        let models = try await store.withPool { pool in
            try pool.read { db in
                try Row.fetchAll(db, sql: "SELECT session_id, model FROM local_sessions ORDER BY 1")
                    .map { ($0["session_id"] as String? ?? "", $0["model"] as String?) }
            }
        }
        XCTAssertEqual(models.first(where: { $0.0 == "renamed" })?.1, "claude-fable-5",
                       "the session takes its last real model back")
        XCTAssertEqual(models.first(where: { $0.0 == "healthy" })?.1, "claude-opus-4-8",
                       "non-placeholder sessions are untouched")
    }


    // MARK: STEP_94 — cross-session duplicate guard on the live path

    /// Mechanism (c): a resumed/forked Claude session rewrites copied lines under the new
    /// session id. The key is the billed message's identity, so the copy must be skipped —
    /// including its session upsert, exactly as the backfill behaves.
    func testLiveWriteSkipsSameKeyUnderAnotherSession() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeTokenEvents([makeEvent(sessionId: "s-orig", dedupKey: "m1_r1")])
        try await store.writeTokenEvents([makeEvent(sessionId: "s-fork", dedupKey: "m1_r1")])

        try await store.withPool { pool in
            try pool.read { db in
                let rows = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM local_usage_events WHERE tool = 'claude' AND dedup_key = 'm1_r1'
                    """)
                XCTAssertEqual(rows, 1, "one billed message, one row, whichever file wrote it")
                let forkSession = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM local_sessions WHERE session_id = 's-fork'
                    """)
                XCTAssertEqual(forkSession, 0,
                               "a skipped copy must not create the fork's session row")
            }
        }
    }

    /// Rows written before STEP_94 changed the Claude key format keep their bare-`requestId`
    /// keys forever (the corpus is permanent; sweeps only reach recently-touched files). A
    /// re-read of such a file parses to the new key format — the guard must still match the
    /// old row via `legacyDedupKey` or every historical file re-read would double its events.
    func testLiveWriteSkipsWhenLegacyKeyRowExists() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeTokenEvents([makeEvent(sessionId: "s1", dedupKey: "r1")])
        try await store.writeTokenEvents(
            [makeEvent(sessionId: "s1", dedupKey: "m1_r1", legacyDedupKey: "r1")])

        try await store.withPool { pool in
            try pool.read { db in
                let rows = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM local_usage_events WHERE tool = 'claude'
                    """)
                XCTAssertEqual(rows, 1, "the new-format re-parse must match its old-format row")
            }
        }
    }

    // MARK: STEP_94 — historical re-emission cleanup

    /// The one-shot corpus-driven delete: rows whose file, cleanly re-parsed, no longer yields
    /// their key are re-emissions — bounded by the near-now exemption and the per-session
    /// mass-deletion guard.
    func testReconcileCodexReEmissionsDeletesOnlyStaleUnkeptRows() async throws {
        let store = try SQLiteStore(path: dbPath)
        let old = Date(timeIntervalSince1970: 1_780_000_000)
        let sweepCutoff = old.addingTimeInterval(3600)
        func codexEvent(_ session: String, _ key: String, at: Date) -> TokenEvent {
            makeEvent(tool: .codex, sessionId: session, dedupKey: key,
                      model: nil, surfaceBucket: "CLI", startedAt: at, recordedAt: at)
        }
        try await store.writeTokenEvents([
            // rollout-a: 6 rows, one of them a re-emission (not in the kept set).
            codexEvent("rollout-a", "rollout-a_t1_10", at: old),
            codexEvent("rollout-a", "rollout-a_t2_10", at: old),   // re-emission
            codexEvent("rollout-a", "rollout-a_t3_20", at: old),
            codexEvent("rollout-a", "rollout-a_t4_30", at: old),
            codexEvent("rollout-a", "rollout-a_t5_40", at: old),
            // a near-now row missing from the kept set — the live/sweep race, must survive.
            codexEvent("rollout-a", "rollout-a_t6_50", at: sweepCutoff.addingTimeInterval(60)),
            // pre-convention row under a bare-UUID session, key prefixed by rollout-b's basename.
            codexEvent("uuid-b", "rollout-b_t1_10", at: old),
            codexEvent("uuid-b", "rollout-b_t2_10", at: old),      // re-emission, old convention
            codexEvent("uuid-b", "rollout-b_t3_20", at: old),
            codexEvent("uuid-b", "rollout-b_t4_30", at: old),
            codexEvent("uuid-b", "rollout-b_t5_40", at: old),
            codexEvent("uuid-b", "rollout-b_t6_50", at: old),
        ])

        let deleted = try await store.reconcileCodexReEmissions(
            keptKeys: [
                "rollout-a": ["rollout-a_t1_10", "rollout-a_t3_20", "rollout-a_t4_30",
                              "rollout-a_t5_40"],
                "rollout-b": ["rollout-b_t1_10", "rollout-b_t3_20", "rollout-b_t4_30",
                              "rollout-b_t5_40", "rollout-b_t6_50"],
            ],
            olderThan: sweepCutoff)
        XCTAssertEqual(deleted, 2)

        try await store.withPool { pool in
            try pool.read { db in
                let keys = try String.fetchAll(db, sql: """
                    SELECT dedup_key FROM local_usage_events WHERE tool = 'codex' ORDER BY dedup_key
                    """)
                XCTAssertFalse(keys.contains("rollout-a_t2_10"), "the re-emission is gone")
                XCTAssertFalse(keys.contains("rollout-b_t2_10"),
                               "the bare-UUID-session row is matched by its key's basename prefix")
                XCTAssertTrue(keys.contains("rollout-a_t6_50"),
                              "a row newer than the cutoff survives even when unkept")
                XCTAssertEqual(keys.count, 10)
            }
        }
    }

    /// A truncated kept-set (mid-file read error) must never mass-delete a session — the guard
    /// skips it entirely.
    func testReconcileCodexReEmissionsSkipsSessionOnMassDeletion() async throws {
        let store = try SQLiteStore(path: dbPath)
        let old = Date(timeIntervalSince1970: 1_780_000_000)
        let events = (1...10).map { i in
            makeEvent(tool: .codex, sessionId: "rollout-c", dedupKey: "rollout-c_t\(i)_\(i)",
                      model: nil, surfaceBucket: "CLI",
                      startedAt: old, recordedAt: old)
        }
        try await store.writeTokenEvents(events)

        // Kept set covers only one row — as if the file read died after the first chunk.
        let deleted = try await store.reconcileCodexReEmissions(
            keptKeys: ["rollout-c": ["rollout-c_t1_1"]],
            olderThan: old.addingTimeInterval(3600))
        XCTAssertEqual(deleted, 0, "9 of 10 candidates exceeds the bound — session skipped whole")
    }

    // MARK: STEP_103 — forked-thread history cleanup

    /// The one-shot forked-history sweep: only sessions in `keptKeys` (fork-marked files) are
    /// touched, a 100% deletion is *allowed* (the 2026-07-03 phantom — deliberately no STEP_94
    /// mass-deletion guard), the near-now exemption carries over, and a `local_sessions` row is
    /// deleted only when the sweep empties it. The phantom is seeded under the pre-2026-07-13
    /// bare-UUID session convention — like the real one — so this also pins that the emptied
    /// session row is matched from the deleted rows' own stored ids, not re-derived basenames.
    func testReconcileForkedThreadHistoryDeletesInheritedRowsAndEmptiedSessions() async throws {
        let store = try SQLiteStore(path: dbPath)
        let old = Date(timeIntervalSince1970: 1_780_000_000)
        let sweepCutoff = old.addingTimeInterval(3600)
        func codexEvent(_ session: String, _ key: String, at: Date = old) -> TokenEvent {
            makeEvent(tool: .codex, sessionId: session, dedupKey: key,
                      model: nil, surfaceBucket: "Desktop", startedAt: at, recordedAt: at)
        }
        try await store.writeTokenEvents([
            // rollout-fork: 2 inherited + 1 genuine + 1 near-now unkept (live/sweep race).
            codexEvent("rollout-fork", "rollout-fork_t1_10"),
            codexEvent("rollout-fork", "rollout-fork_t2_20"),
            codexEvent("rollout-fork", "rollout-fork_t3_30"),
            codexEvent("rollout-fork", "rollout-fork_t4_40",
                       at: sweepCutoff.addingTimeInterval(60)),
            // rollout-phantom: 100% inherited, stored under the bare-UUID convention.
            codexEvent("uuid-phantom", "rollout-phantom_t1_10"),
            codexEvent("uuid-phantom", "rollout-phantom_t2_20"),
            // rollout-plain: no fork marker ⇒ not in keptKeys ⇒ untouchable, kept or not.
            codexEvent("rollout-plain", "rollout-plain_t1_10"),
        ])

        let keptKeys: [String: Set<String>] = [
            "rollout-fork": ["rollout-fork_t3_30"],
            // The 100% case: a clean parse of the phantom yields zero events.
            "rollout-phantom": [],
        ]
        let result = try await store.reconcileForkedThreadHistory(
            keptKeys: keptKeys, olderThan: sweepCutoff)
        XCTAssertEqual(result.events, 4, "2 inherited from the fork + the whole phantom")
        XCTAssertEqual(result.sessions, 1, "only the emptied phantom session row goes")

        try await store.withPool { pool in
            try pool.read { db in
                let keys = try String.fetchAll(db, sql: """
                    SELECT dedup_key FROM local_usage_events WHERE tool = 'codex'
                    ORDER BY dedup_key
                    """)
                XCTAssertEqual(keys, ["rollout-fork_t3_30", "rollout-fork_t4_40",
                                      "rollout-plain_t1_10"])
                let sessions = try String.fetchAll(db, sql: """
                    SELECT session_id FROM local_sessions WHERE tool = 'codex'
                    ORDER BY session_id
                    """)
                XCTAssertEqual(sessions, ["rollout-fork", "rollout-plain"],
                               "the fork session keeps its genuine rows; the phantom row is gone")
            }
        }

        // Idempotence: the same sweep again deletes nothing further.
        let again = try await store.reconcileForkedThreadHistory(
            keptKeys: keptKeys, olderThan: sweepCutoff)
        XCTAssertEqual(again.events, 0)
        XCTAssertEqual(again.sessions, 0)
    }

    // MARK: STEP_94 — migration v16 duplicate cleanup

    /// Seeds a database at v15 with the two duplicate shapes the audit found (REV-62 §4.1 b/c),
    /// then lets v16 run: the Codex bare-UUID twin survives (its output is the raw, un-folded
    /// recording), the Claude earliest-recorded row survives, emptied duplicate session rows go,
    /// and untouched sessions — including legitimately empty ones — stay.
    func testV16DeletesCrossSessionDuplicatesAndEmptiedSessions() throws {
        var migrator = DatabaseMigrator()
        SQLiteStore.registerMigrations(&migrator)
        let pool = try DatabasePool(path: dbPath)
        try migrator.migrate(pool, upTo: "v15_event_attribution")

        try pool.write { db in
            for (sid, tool) in [("uuid-1", "codex"), ("rollout-x", "codex"),
                                ("rollout-y", "codex"), ("s-orig", "claude"),
                                ("s-fork", "claude"), ("empty-pre", "claude")] {
                try db.execute(sql: """
                    INSERT INTO local_sessions (session_id, tool, last_seen_at) VALUES (?, ?, 100)
                    """, arguments: [sid, tool])
            }
            // Codex convention pair: same key, bare-UUID twin holds raw output (5), rollout twin
            // holds the era's reasoning-folded output (8).
            try db.execute(sql: """
                INSERT INTO local_usage_events
                    (session_id, tool, dedup_key, recorded_at, input_tokens, output_tokens)
                VALUES ('uuid-1', 'codex', 'rollout-x_t1_100', 100, 10, 5),
                       ('rollout-x', 'codex', 'rollout-x_t1_100', 100, 10, 8),
                       ('rollout-y', 'codex', 'rollout-y_t2_200', 200, 3, 3)
                """)
            // Claude fork pair: identical recorded_at (the line's timestamp was copied), so the
            // first-ingested row is the original session's.
            try db.execute(sql: """
                INSERT INTO local_usage_events
                    (session_id, tool, dedup_key, recorded_at, input_tokens)
                VALUES ('s-orig', 'claude', 'r1', 100, 7),
                       ('s-fork', 'claude', 'r1', 100, 7)
                """)
        }

        try migrator.migrate(pool)

        try pool.read { db in
            let codexRows = try Row.fetchAll(db, sql: """
                SELECT session_id FROM local_usage_events WHERE tool = 'codex' ORDER BY session_id
                """).map { $0["session_id"] as String }
            XCTAssertEqual(codexRows, ["rollout-y", "uuid-1"],
                           "the rollout twin of the pair is gone; the unrelated row stays")
            let claudeRows = try Row.fetchAll(db, sql: """
                SELECT session_id FROM local_usage_events WHERE tool = 'claude'
                """).map { $0["session_id"] as String }
            XCTAssertEqual(claudeRows, ["s-orig"], "the earliest-recorded copy survives")

            let sessions = try Row.fetchAll(db, sql: """
                SELECT session_id FROM local_sessions ORDER BY session_id
                """).map { $0["session_id"] as String }
            XCTAssertEqual(sessions, ["empty-pre", "rollout-y", "s-orig", "uuid-1"],
                           "emptied duplicate sessions go; pre-existing empty ones are untouched")

            let index = try String.fetchOne(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'index' AND name = 'idx_local_usage_events_tool_dedup'
                """)
            XCTAssertNotNil(index, "the guard's (tool, dedup_key) index exists")
        }
    }

    // MARK: STEP_117 — migration v19 fabricated-fixture cleanup

    /// Seeds a database at v18 with the seven fixture sessions the old `~/.codex`-wide watcher
    /// ingested from a Codex worktree checkout of this repo (REV-71 §3.4), plus a real neighbour,
    /// then lets v19 run: the seven go from all three tables they reached, and nothing else moves.
    func testV19DeletesFabricatedFixtureSessions() throws {
        let fabricated = ["codex-desktop-session", "codex-cli-session", "codex-ide-session",
                          "codex-guardian-session", "codex-duplicate-session",
                          "codex-top-level-session", "codex-sqlite-session"]

        var migrator = DatabaseMigrator()
        SQLiteStore.registerMigrations(&migrator)
        let pool = try DatabasePool(path: dbPath)
        try migrator.migrate(pool, upTo: "v18_poll_window_seconds")

        try pool.write { db in
            for sid in fabricated + ["rollout-real-codex", "codex-desktop-session-lookalike"] {
                try db.execute(sql: """
                    INSERT INTO local_sessions (session_id, tool, last_seen_at) VALUES (?, 'codex', 100)
                    """, arguments: [sid])
                try db.execute(sql: """
                    INSERT INTO local_usage_events
                        (session_id, tool, dedup_key, recorded_at, input_tokens)
                    VALUES (?, 'codex', 'k', 100, 10)
                    """, arguments: [sid])
                try db.execute(sql: """
                    INSERT INTO session_summaries
                        (session_id, tool, last_seen_at, event_count, input_tokens, output_tokens,
                         cache_creation_tokens, cache_read_tokens, summarized_at)
                    VALUES (?, 'codex', 100, 1, 10, 0, 0, 0, 100)
                    """, arguments: [sid])
            }
            // A Claude session sharing one of the fabricated ids: the bound is (id, tool), so it
            // must survive — nothing outside the Codex corpus is in scope.
            try db.execute(sql: """
                INSERT INTO local_sessions (session_id, tool, last_seen_at)
                VALUES ('codex-cli-session', 'claude', 100)
                """)
        }

        try migrator.migrate(pool)

        try pool.read { db in
            for table in ["local_usage_events", "local_sessions", "session_summaries"] {
                let remaining = try String.fetchAll(db, sql: """
                    SELECT session_id FROM \(table) WHERE tool = 'codex' ORDER BY session_id
                    """)
                XCTAssertEqual(remaining, ["codex-desktop-session-lookalike", "rollout-real-codex"],
                               "\(table): the seven fixtures go, neighbours stay")
            }
            let claude = try String.fetchAll(db, sql: """
                SELECT session_id FROM local_sessions WHERE tool = 'claude'
                """)
            XCTAssertEqual(claude, ["codex-cli-session"],
                           "the delete is bounded by tool as well as id")

            let version = try String.fetchOne(
                db, sql: "SELECT value FROM settings WHERE key = 'schema_version'")
            XCTAssertEqual(version, "25")
        }
    }
}
