import XCTest
@testable import KvotarCore

final class AttributionEngineTests: XCTestCase {

    /// Test double: emits a controlled sequence of `TokenEvent` batches on demand.
    private final class FakeLocalAdapter: LocalAdapter, @unchecked Sendable {
        let tokenEvents: AsyncStream<[TokenEvent]>
        let deltaSignals: AsyncStream<LocalDeltaSignal>
        let localWrites: AsyncStream<Date>
        private let continuation: AsyncStream<[TokenEvent]>.Continuation
        private let writeContinuation: AsyncStream<Date>.Continuation
        init() {
            (tokenEvents, continuation) = AsyncStream.makeStream(of: [TokenEvent].self)
            (deltaSignals, _) = AsyncStream.makeStream(of: LocalDeltaSignal.self)
            (localWrites, writeContinuation) = AsyncStream.makeStream(of: Date.self)
        }
        func startWatching() async {}
        func stopWatching() async {}
        func emit(_ events: [TokenEvent]) { continuation.yield(events) }
        /// A flush that appended completed lines carrying no token accounting (STEP_170).
        func emitWrite(at: Date) { writeContinuation.yield(at) }
    }

    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory().appending("kvotar-attribution-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
        dbPath = nil
        super.tearDown()
    }

    private func pricingBundle() throws -> Bundle {
        let table = PricingTable(
            version: "1.0.0", updated: "2026-06-08",
            models: ["claude-sonnet-4-6": ModelPricing(
                inputPerMtok: 3.00, outputPerMtok: 15.00,
                cacheCreationPerMtok: 3.75, cacheReadPerMtok: 0.30)],
            fallback: ["codex": ModelPricing(inputPerMtok: 2.00, outputPerMtok: 8.00)]
        )
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attribution-pricing-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(table).write(to: dir.appendingPathComponent("pricing.json"))
        return try XCTUnwrap(Bundle(url: dir))
    }

    /// The same helper with STEP_96's cache-write tiers priced — 1.25× input for a 5-minute
    /// write, 2× for a 1-hour one.
    private func tieredPricingBundle() throws -> Bundle {
        let table = PricingTable(
            version: "1.2.0", updated: "2026-08-12",
            models: ["claude-sonnet-4-6": ModelPricing(
                inputPerMtok: 3.00, outputPerMtok: 15.00,
                cacheWrite5mPerMtok: 3.75, cacheWrite1hPerMtok: 6.00,
                cacheReadPerMtok: 0.30)],
            fallback: ["codex": ModelPricing(inputPerMtok: 2.00, outputPerMtok: 8.00)]
        )
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attribution-pricing-tiered-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(table).write(to: dir.appendingPathComponent("pricing.json"))
        return try XCTUnwrap(Bundle(url: dir))
    }

    /// STEP_96's whole safety claim, end to end: knowing that a cache write was the expensive
    /// 1-hour kind must move the **money** and nothing else. Same events, same totals; the only
    /// difference is whether the tier split was recorded.
    func testCacheWriteTierRaisesValueWithoutMovingAnyCount() async throws {
        func run(oneHour: Int?, bundle: Bundle) async throws -> LocalAttribution {
            let path = NSTemporaryDirectory() + "tier-\(UUID().uuidString).sqlite"
            defer { try? FileManager.default.removeItem(atPath: path) }
            let store = try SQLiteStore(path: path)
            let claude = FakeLocalAdapter()
            let engine = AttributionEngine(store: store, claude: claude,
                                           codex: FakeLocalAdapter(), bundle: bundle)
            await engine.start()
            let at = Date()
            claude.emit([
                TokenEvent(tool: .claude, sessionId: "s1", project: "/home/u/proj",
                           model: "claude-sonnet-4-6", surfaceBucket: "Claude Code", startedAt: at,
                           inputTokens: 100, outputTokens: 50,
                           cacheCreationTokens: 1_000_000, cacheCreation1hTokens: oneHour,
                           cacheReadTokens: 10, recordedAt: at, dedupKey: "a"),
            ])
            let result = await waitForAttribution(engine, tool: .claude)
            let attr = try XCTUnwrap(result)
            await engine.stop()
            return attr
        }

        // Before: the split was never recorded, so the whole write prices at the 5-minute rate —
        // what every row written before migration v17 still does.
        let flat = try await run(oneHour: nil, bundle: try tieredPricingBundle())
        // After: the same million tokens, now known to have been written at the 1-hour tier.
        let tiered = try await run(oneHour: 1_000_000, bundle: try tieredPricingBundle())

        // The money rises by exactly the extra 0.75× of input the 1-hour tier costs.
        XCTAssertGreaterThan(tiered.estValue.thirtyDay, flat.estValue.thirtyDay)
        XCTAssertEqual(tiered.estValue.thirtyDay - flat.estValue.thirtyDay,
                       1_000_000 * (6.00 - 3.75) / 1_000_000, accuracy: 0.000_001)

        // Nothing a user counts moves: the cache-hit ratio keeps `cache_creation` whole in its
        // denominator, and the token rate is untouched. This is what makes the subset column safe.
        XCTAssertEqual(try XCTUnwrap(tiered.cacheHitRatio),
                       try XCTUnwrap(flat.cacheHitRatio), accuracy: 0.000_000_1)
        XCTAssertEqual(try XCTUnwrap(tiered.tokensPerMinute),
                       try XCTUnwrap(flat.tokensPerMinute), accuracy: 0.000_1)
        XCTAssertEqual(tiered.subagentCount, flat.subagentCount)
    }

    private func claudeEvent(session: String, dedup: String, surface: String = "Claude Code",
                             input: Int = 100, cacheRead: Int = 10,
                             at recordedAt: Date = Date()) -> TokenEvent {
        TokenEvent(tool: .claude, sessionId: session, project: "/home/u/proj",
                   model: "claude-sonnet-4-6", surfaceBucket: surface, startedAt: recordedAt,
                   inputTokens: input, outputTokens: 50, cacheCreationTokens: 20,
                   cacheReadTokens: cacheRead, recordedAt: recordedAt, dedupKey: dedup)
    }

    /// `tokens` is the event's **whole** `input_tokens`, of which `cached` is the re-sent prefix —
    /// Codex reports cached as a *subset of* input, never in addition to it (Baseline §8.4), so a
    /// fixture with `cached > tokens` describes a payload that has never been observed and cannot
    /// occur. `readEra` puts the cached count in `cache_read_tokens` instead of
    /// `cache_creation_tokens`, reproducing rows written before the 2026-07-13 convention change.
    private func codexEvent(session: String, dedup: String, surface: String, tokens: Int,
                            cached: Int = 0, output: Int = 0,
                            readEra: Bool = false) -> TokenEvent {
        TokenEvent(tool: .codex, sessionId: session, project: "/repo", model: "gpt-5.5",
                   surfaceBucket: surface, startedAt: Date(), inputTokens: tokens,
                   outputTokens: output,
                   cacheCreationTokens: readEra ? 0 : cached,
                   cacheReadTokens: readEra ? cached : 0, recordedAt: Date(),
                   dedupKey: dedup, originator: "codex_cli_rs")
    }

    /// Poll until the engine reports attribution for `tool` (ingestion is async).
    private func waitForAttribution(_ engine: AttributionEngine, tool: Tool,
                                    timeout: TimeInterval = 3) async -> LocalAttribution? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Require project (the session row) so we don't observe a mid-ingest read where
            // surface totals are visible but the session upsert hasn't landed yet.
            if let a = await engine.attribution(for: tool), a.project != nil {
                return a
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return await engine.attribution(for: tool)
    }

    func testClaudeAttributionFromStream() async throws {
        let store = try SQLiteStore(path: dbPath)
        let claude = FakeLocalAdapter()
        let codex = FakeLocalAdapter()
        let engine = AttributionEngine(store: store, claude: claude, codex: codex,
                                       bundle: try pricingBundle())
        await engine.start()

        claude.emit([
            claudeEvent(session: "s1", dedup: "a"),
            claudeEvent(session: "s1", dedup: "b", surface: "Subagent · reviewer"),
        ])

        let result = await waitForAttribution(engine, tool: .claude)
        let attr = try XCTUnwrap(result)
        XCTAssertEqual(attr.project, "/home/u/proj")
        XCTAssertEqual(attr.model, "claude-sonnet-4-6")
        XCTAssertEqual(attr.subagentCount, 1)
        // cache-hit = cacheRead / (input + cacheRead + cacheCreation) = 20 / (200 + 20 + 40)
        // over both events — cacheCreation (misses written to cache) is in the denominator (REV-21).
        XCTAssertEqual(try XCTUnwrap(attr.cacheHitRatio), 20.0 / 260.0, accuracy: 0.0001)
        XCTAssertGreaterThan(attr.estValue.thirtyDay, 0)
        XCTAssertEqual(try XCTUnwrap(attr.tokensPerMinute), Double(2 * 150) / 2, accuracy: 0.001)

        await engine.stop()
    }

    /// REV-20/STEP_32: a catch-up burst of honestly-backdated events (the parser now stamps the
    /// line's own timestamp) must not inflate the 2-min rate — old events fall outside the window.
    func testBackdatedCatchUpBurstDoesNotInflateRate() async throws {
        let store = try SQLiteStore(path: dbPath)
        let claude = FakeLocalAdapter()
        let codex = FakeLocalAdapter()
        let engine = AttributionEngine(store: store, claude: claude, codex: codex,
                                       bundle: try pricingBundle())
        await engine.start()

        let tenMinAgo = Date().addingTimeInterval(-600)
        claude.emit([
            claudeEvent(session: "s1", dedup: "old-1", at: tenMinAgo),
            claudeEvent(session: "s1", dedup: "old-2", at: tenMinAgo.addingTimeInterval(30)),
        ])

        let result = await waitForAttribution(engine, tool: .claude)
        let attr = try XCTUnwrap(result)
        XCTAssertNil(attr.tokensPerMinute,
                     "backfilled events outside the 2-min window must read as no live rate")

        await engine.stop()
    }

    func testCodexSurfaceSharesAndCacheHit() async throws {
        let store = try SQLiteStore(path: dbPath)
        let claude = FakeLocalAdapter()
        let codex = FakeLocalAdapter()
        let engine = AttributionEngine(store: store, claude: claude, codex: codex,
                                       bundle: try pricingBundle())
        await engine.start()

        // Fixture rebuilt in STEP_91. It previously read input 80 / cached 240 — cached three times
        // larger than the input it is a subset of, a payload the provider cannot emit. Now: a
        // Desktop thread whose 800-token prompt is 600 tokens of re-sent transcript, and a CLI
        // one-shot whose 200-token prompt is 100 cached.
        codex.emit([
            codexEvent(session: "d1", dedup: "d", surface: "Desktop",
                       tokens: 800, cached: 600, output: 200),
            codexEvent(session: "c1", dedup: "c", surface: "CLI",
                       tokens: 200, cached: 100, output: 50),
        ])

        let result = await waitForAttribution(engine, tool: .codex)
        let attr = try XCTUnwrap(result)
        // Codex cache hit = cached ÷ input (STEP_91): cached is *inside* input, so input is already
        // the whole prompt. 700 cached against 1,000 input.
        XCTAssertEqual(try XCTUnwrap(attr.cacheHitRatio), 700.0 / 1000.0, accuracy: 0.0001)
        // Surface shares count `input + output` on Codex (STEP_91) — adding the cache columns would
        // count the cached slice twice, and it tilts the bar toward whichever surface cached most.
        // Desktop 1,000 vs CLI 250.
        let shares = Dictionary(uniqueKeysWithValues: attr.surfaceShares.map { ($0.label, $0.fraction) })
        XCTAssertEqual(try XCTUnwrap(shares["Desktop"]), 0.8, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(shares["CLI"]), 0.2, accuracy: 0.0001)

        await engine.stop()
    }

    /// The convention-union rule at engine level (STEP_91): an old-era row that stores the cached
    /// count in `cache_read_tokens` must produce the same cache-hit ratio as a new-era row that
    /// stores it in `cache_creation_tokens`. Reading one column alone rendered `Cache hit 0%` for
    /// any window containing rows from the other era — 88% of this machine's stored Codex corpus.
    func testCodexCacheHitIsIdenticalAcrossBothStorageConventions() async throws {
        let store = try SQLiteStore(path: dbPath)
        let claude = FakeLocalAdapter()
        let codex = FakeLocalAdapter()
        let engine = AttributionEngine(store: store, claude: claude, codex: codex,
                                       bundle: try pricingBundle())
        await engine.start()

        // Same usage, both conventions, one window: 500 cached of 1,000 input in each era.
        codex.emit([
            codexEvent(session: "new", dedup: "n", surface: "CLI",
                       tokens: 1_000, cached: 500, output: 100),
            codexEvent(session: "old", dedup: "o", surface: "CLI",
                       tokens: 1_000, cached: 500, output: 100, readEra: true),
        ])

        let result = await waitForAttribution(engine, tool: .codex)
        let attr = try XCTUnwrap(result)
        XCTAssertEqual(try XCTUnwrap(attr.cacheHitRatio), 1000.0 / 2000.0, accuracy: 0.0001,
                       "an era's cached tokens must count wherever that era stored them")

        await engine.stop()
    }

    /// The two rate signals `recentTokens` feeds — `tokensPerMinute` (the §2.5a local rate) and
    /// `localTokensLast2Min` (the off-machine idle floor, state-engine rule 7) — count
    /// `input + output` and **never** the cache columns. This was always the code's behaviour and
    /// was never stated; STEP_91 makes it explicit, because the parser fix moves both numbers on
    /// Codex (reasoning no longer inflates `output`, so the rate falls by roughly a third) and a
    /// reader seeing that drop needs to know which quantity is supposed to have changed.
    func testCodexRateSignalsCountInputPlusOutputOnly() async throws {
        let store = try SQLiteStore(path: dbPath)
        let claude = FakeLocalAdapter()
        let codex = FakeLocalAdapter()
        let engine = AttributionEngine(store: store, claude: claude, codex: codex,
                                       bundle: try pricingBundle())
        await engine.start()

        // 1,000 input (600 of it cached) + 200 output in the last two minutes.
        codex.emit([codexEvent(session: "r1", dedup: "r", surface: "CLI",
                               tokens: 1_000, cached: 600, output: 200)])

        let result = await waitForAttribution(engine, tool: .codex)
        let attr = try XCTUnwrap(result)
        let idleFloor = await engine.localTokensLast2Min(for: .codex)
        XCTAssertEqual(idleFloor, 1_200,
                       "the idle floor counts input + output, not the cached slice again")
        // rateWindow is 2 minutes, so the per-minute figure is half the window's tokens.
        XCTAssertEqual(try XCTUnwrap(attr.tokensPerMinute), 600, accuracy: 0.001)

        await engine.stop()
    }

    func testCodexCacheHitNilWhenNoCachedTokens() async throws {
        let store = try SQLiteStore(path: dbPath)
        let claude = FakeLocalAdapter()
        let codex = FakeLocalAdapter()
        let engine = AttributionEngine(store: store, claude: claude, codex: codex,
                                       bundle: try pricingBundle())
        await engine.start()

        codex.emit([codexEvent(session: "z1", dedup: "z", surface: "CLI", tokens: 0, cached: 0)])

        let result = await waitForAttribution(engine, tool: .codex)
        let attr = try XCTUnwrap(result)
        XCTAssertNil(attr.cacheHitRatio, "zero denominator must stay nil, never fabricate 0%")

        await engine.stop()
    }

    // MARK: STEP_26 — window alignment, batch ingest, recency

    func testWindowStartAlignsAttributionWindow() async throws {
        let store = try SQLiteStore(path: dbPath)
        let claude = FakeLocalAdapter()
        let codex = FakeLocalAdapter()
        let engine = AttributionEngine(store: store, claude: claude, codex: codex,
                                       bundle: try pricingBundle())
        await engine.start()

        claude.emit([claudeEvent(session: "s1", dedup: "a")])
        _ = await waitForAttribution(engine, tool: .claude)

        // Window starting before the event includes it; a window starting after excludes it —
        // the §3.3 real-quota-window alignment (vs the old sliding now−5h).
        let before = await engine.attribution(for: .claude,
                                              windowStart: Date().addingTimeInterval(-60))
        XCTAssertFalse(try XCTUnwrap(before).surfaceShares.isEmpty)
        let after = await engine.attribution(for: .claude,
                                             windowStart: Date().addingTimeInterval(60))
        XCTAssertEqual(after?.surfaceShares ?? [], [], "event before window start must not count")

        await engine.stop()
    }

    func testBatchIngestPersistsWholeFlushAndTracksRecency() async throws {
        let store = try SQLiteStore(path: dbPath)
        let claude = FakeLocalAdapter()
        let codex = FakeLocalAdapter()
        let engine = AttributionEngine(store: store, claude: claude, codex: codex,
                                       bundle: try pricingBundle())
        await engine.start()

        // One flush = one batch = one transaction (STEP_26); all events must land.
        claude.emit([
            claudeEvent(session: "s1", dedup: "a"),
            claudeEvent(session: "s1", dedup: "b"),
            claudeEvent(session: "s2", dedup: "c"),
        ])
        let result = await waitForAttribution(engine, tool: .claude)
        let attr = try XCTUnwrap(result)
        XCTAssertEqual(try XCTUnwrap(attr.tokensPerMinute), Double(3 * 150) / 2, accuracy: 0.001,
                       "all three batched events must be ingested")

        // Recency (§15.1 tie-break input) reflects the newest event in the batch.
        let claudeActivity = await engine.lastActivityAt(for: .claude)
        let activity = try XCTUnwrap(claudeActivity)
        XCTAssertEqual(activity.timeIntervalSinceNow, 0, accuracy: 5)
        XCTAssertEqual(attr.lastActivityAt, activity)
        let codexActivity = await engine.lastActivityAt(for: .codex)
        XCTAssertNil(codexActivity, "no Codex activity observed")

        await engine.stop()
    }

    // MARK: REV-30 — liveness gap survives a restart

    /// A fresh engine (nothing ingested in-memory this launch, mirroring a restart mid-session)
    /// must seed the burn-card liveness timestamp from the persisted most-recent event, so the
    /// first render reads active instead of a false "Claude Code idle" until the first poll.
    func testLivenessSeededFromStoreSurvivesRestart() async throws {
        let store = try SQLiteStore(path: dbPath)
        let recent = Date().addingTimeInterval(-60)
        try await store.writeTokenEvents([claudeEvent(session: "s1", dedup: "a", at: recent)])

        let engine = AttributionEngine(store: store, claude: FakeLocalAdapter(),
                                       codex: FakeLocalAdapter(), bundle: try pricingBundle())
        await engine.start()   // fakes emit nothing → lastEventAt stays nil this launch

        let result = await engine.attribution(for: .claude)
        let attr = try XCTUnwrap(result)
        XCTAssertEqual(try XCTUnwrap(attr.lastActivityAt).timeIntervalSince1970,
                       recent.timeIntervalSince1970, accuracy: 1,
                       "burn-card liveness must be seeded from the persisted event")
        XCTAssertTrue(attr.isActive(now: Date()), "recent stored activity reads live after restart")
        // The since-launch detection / §15.1 tie-break signal must NOT be seeded by the store.
        let inMemory = await engine.lastActivityAt(for: .claude)
        XCTAssertNil(inMemory, "store seed must not leak into the since-launch detection signal")

        await engine.stop()
    }

    /// The store seed still honours the gap: a persisted event older than `idleGap` stays idle.
    func testLivenessStoreSeedIdleWhenStoredEventOlderThanGap() async throws {
        let store = try SQLiteStore(path: dbPath)
        let old = Date().addingTimeInterval(-LocalAttribution.idleGap - 120)
        try await store.writeTokenEvents([claudeEvent(session: "s1", dedup: "a", at: old)])

        let engine = AttributionEngine(store: store, claude: FakeLocalAdapter(),
                                       codex: FakeLocalAdapter(), bundle: try pricingBundle())
        await engine.start()

        let result = await engine.attribution(for: .claude)
        let attr = try XCTUnwrap(result)
        XCTAssertFalse(attr.isActive(now: Date()),
                       "a stored event older than idleGap must not read as a live session")

        await engine.stop()
    }

    // MARK: STEP_170 — a growing rollout file is local activity

    /// The tester's 2026-09-03 case, in miniature. The last *token* line is well past `idleGap`,
    /// but the rollout file is still gaining lines — Codex writes a turn's `token_count` twenty to
    /// thirty minutes after the work starts. Token-only liveness calls that idle and the Elsewhere
    /// notification fires at a machine that is working.
    func testFileGrowthKeepsTheToolLiveWithoutTokenLines() async throws {
        let store = try SQLiteStore(path: dbPath)
        let stale = Date().addingTimeInterval(-LocalAttribution.idleGap - 600)
        try await store.writeTokenEvents([TokenEvent(
            tool: .codex, sessionId: "s1", project: "/repo", model: "gpt-5.5",
            surfaceBucket: "IDE extension", startedAt: stale, inputTokens: 100, outputTokens: 20,
            cacheCreationTokens: 0, cacheReadTokens: 0, recordedAt: stale, dedupKey: "a",
            originator: "codex_vscode")])

        let codex = FakeLocalAdapter()
        let engine = AttributionEngine(store: store, claude: FakeLocalAdapter(),
                                       codex: codex, bundle: try pricingBundle())
        await engine.start()

        let beforeResult = await engine.attribution(for: .codex)
        let before = try XCTUnwrap(beforeResult)
        XCTAssertFalse(before.isActive(now: Date()),
                       "precondition: with only a stale token line the tool reads idle")

        codex.emitWrite(at: Date())

        var attr: LocalAttribution?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            attr = await engine.attribution(for: .codex)
            if attr?.isActive(now: Date()) == true { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        let after = try XCTUnwrap(attr)
        XCTAssertTrue(after.isActive(now: Date()),
                      "a watched file gaining lines is evidence a local surface is alive")
        XCTAssertFalse(LocalAttribution.isConfirmedIdle(lastActivityAt: after.lastActivityAt,
                                                        now: Date()),
                       "the Elsewhere notification's idle test must not fire while a file grows")

        // Liveness only: a write is never evidence of an amount.
        XCTAssertEqual(after.modelTotals.reduce(0) { $0 + $1.inputTokens },
                       before.modelTotals.reduce(0) { $0 + $1.inputTokens },
                       "a token-less append must add no tokens")
        XCTAssertEqual(after.estValue.thirtyDay, before.estValue.thirtyDay,
                       "a token-less append must move no est. token value")
        let inMemory = await engine.lastActivityAt(for: .codex)
        XCTAssertNil(inMemory,
                     "file growth must not leak into the since-launch detection / tie-break signal")

        await engine.stop()
    }

    func testCurrentSessionExcludesStaleSessions() async throws {
        let store = try SQLiteStore(path: dbPath)
        // A session last seen 6 hours ago must not count as the current session (5-hour window).
        let old = Date().addingTimeInterval(-6 * 3_600)
        try await store.writeTokenEvents([TokenEvent(
            tool: .claude, sessionId: "old", project: "/old", model: "m", surfaceBucket: "Claude Code",
            startedAt: old, inputTokens: 1, outputTokens: 1, cacheCreationTokens: 0, cacheReadTokens: 0,
            recordedAt: old, dedupKey: "old")])

        let recent = try await store.currentSession(tool: .claude, since: Date().addingTimeInterval(-18_000))
        XCTAssertNil(recent)
    }

    // MARK: Span-aligned local value (REV-18 — off-machine estimator input)

    func testLocalValuePerMinValuesOnlyTheSpan() async throws {
        let store = try SQLiteStore(path: dbPath)
        let engine = AttributionEngine(store: store, claude: FakeLocalAdapter(),
                                       codex: FakeLocalAdapter(), bundle: try pricingBundle())
        await engine.start()   // loads the pricing table

        let start = Date().addingTimeInterval(-600)
        let end = start.addingTimeInterval(120)
        try await store.writeTokenEvents([
            // 1M input at 3.00 $/Mtok inside the span → $3.00 over 2 minutes → 1.50 $/min.
            TokenEvent(tool: .claude, sessionId: "s1", project: "/p", model: "claude-sonnet-4-6",
                       surfaceBucket: "Claude Code", startedAt: start,
                       inputTokens: 1_000_000, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0,
                       recordedAt: start.addingTimeInterval(60), dedupKey: "in-span"),
            // After the span — must not leak into the valuation.
            TokenEvent(tool: .claude, sessionId: "s1", project: "/p", model: "claude-sonnet-4-6",
                       surfaceBucket: "Claude Code", startedAt: start,
                       inputTokens: 5_000_000, outputTokens: 0,
                       cacheCreationTokens: 0, cacheReadTokens: 0,
                       recordedAt: end.addingTimeInterval(60), dedupKey: "after-span"),
        ])

        let rate = await engine.localValuePerMin(for: .claude, from: start, until: end)

        XCTAssertEqual(try XCTUnwrap(rate), 1.50, accuracy: 0.0001)
    }

    func testLocalValuePerMinNilOnEmptySpan() async throws {
        let store = try SQLiteStore(path: dbPath)
        let engine = AttributionEngine(store: store, claude: FakeLocalAdapter(),
                                       codex: FakeLocalAdapter(), bundle: try pricingBundle())
        let at = Date()
        let rate = await engine.localValuePerMin(for: .claude, from: at, until: at)
        XCTAssertNil(rate, "zero-length span has no rate")
    }
}
