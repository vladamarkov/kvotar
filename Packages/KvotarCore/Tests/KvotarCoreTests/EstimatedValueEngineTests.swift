import XCTest
@testable import KvotarCore

final class EstimatedValueEngineTests: XCTestCase {

    // MARK: - Formula (task line 7)

    func testKnownTokenCountsTimesKnownRatesEqualsExpectedValue() {
        let table = PricingTable(
            version: "1.0.0", updated: "2026-06-08",
            models: [
                "claude-sonnet-4-6": ModelPricing(
                    inputPerMtok: 3.00, outputPerMtok: 15.00,
                    cacheCreationPerMtok: 3.75, cacheReadPerMtok: 0.30),
            ],
            fallback: [:]
        )
        let totals = SQLiteStore.ModelTokenTotals(
            model: "claude-sonnet-4-6",
            inputTokens: 1_000_000, outputTokens: 1_000_000,
            cacheCreationTokens: 1_000_000, cacheReadTokens: 1_000_000)

        let value = EstimatedValueEngine.value(for: totals, provider: "claude", table: table)

        XCTAssertEqual(value, 3.00 + 15.00 + 3.75 + 0.30, accuracy: 0.0001)
    }

    // MARK: - Model lookup fallback (task line 8)

    func testUnknownModelFallsBackToProviderRate() {
        let table = PricingTable(
            version: "1.0.0", updated: "2026-06-08",
            models: [:],
            fallback: ["codex": ModelPricing(inputPerMtok: 2.00, outputPerMtok: 8.00)]
        )
        let totals = SQLiteStore.ModelTokenTotals(
            model: "gpt-6-preview", inputTokens: 1_000_000, outputTokens: 1_000_000,
            cacheCreationTokens: 0, cacheReadTokens: 0)

        let value = EstimatedValueEngine.value(for: totals, provider: "codex", table: table)

        XCTAssertEqual(value, 2.00 + 8.00, accuracy: 0.0001)
    }

    func testNilModelUsesProviderFallbackWithoutExactMatchAttempt() {
        let table = PricingTable(
            version: "1.0.0", updated: "2026-06-08",
            models: [:],
            fallback: ["claude": ModelPricing(inputPerMtok: 3.00, outputPerMtok: 15.00)]
        )
        let totals = SQLiteStore.ModelTokenTotals(
            model: nil, inputTokens: 1_000_000, outputTokens: 0,
            cacheCreationTokens: 0, cacheReadTokens: 0)

        let value = EstimatedValueEngine.value(for: totals, provider: "claude", table: table)

        XCTAssertEqual(value, 3.00, accuracy: 0.0001)
    }

    func testMissingModelAndMissingFallbackNeverThrowsReturnsZero() {
        let table = PricingTable(version: "1.0.0", updated: "2026-06-08", models: [:], fallback: [:])
        let totals = SQLiteStore.ModelTokenTotals(
            model: "unknown", inputTokens: 1_000_000, outputTokens: 0,
            cacheCreationTokens: 0, cacheReadTokens: 0)

        let value = EstimatedValueEngine.value(for: totals, provider: "claude", table: table)

        XCTAssertEqual(value, 0, accuracy: 0.0001)
    }

    // MARK: - Null field handling (task line 9)

    /// Rewritten in STEP_91. The original asserted `2.00 + 8.00` for a Codex row with **null** cache
    /// rates and a full million tokens in each cache column — a shape the shipped table can no
    /// longer produce (§12.1 gives every Codex row a cached rate) and a model of the data that is
    /// wrong besides: the cache column holds a *subset of* input, not extra tokens. What survives is
    /// the real question — a null rate must contribute zero, never crash and never fabricate.
    func testNullCacheRateOnCodexContributesZeroForTheCachedSlice() {
        let table = PricingTable(
            version: "1.0.0", updated: "2026-06-08",
            models: [
                "gpt-5.5": ModelPricing(
                    inputPerMtok: 5.00, outputPerMtok: 30.00,
                    cacheCreationPerMtok: nil, cacheReadPerMtok: nil),
            ],
            fallback: [:]
        )
        // 1M input, of which 600k is the re-sent cached prefix; 1M output.
        let totals = SQLiteStore.ModelTokenTotals(
            model: "gpt-5.5", inputTokens: 1_000_000, outputTokens: 1_000_000,
            cacheCreationTokens: 600_000, cacheReadTokens: 0)

        let value = EstimatedValueEngine.value(for: totals, provider: "codex", table: table)

        // 400k uncached at $5 + 600k cached at nothing + 1M output at $30.
        XCTAssertEqual(value, 0.4 * 5.00 + 30.00, accuracy: 0.0001,
                       "a null cached rate must price the cached slice at zero, not at the input rate")
    }

    // MARK: - Codex input split (STEP_91)

    /// **The single most important test in STEP_91.** The stored Codex corpus keeps the cached count
    /// in `cache_read_tokens` before 2026-07-13 and in `cache_creation_tokens` from that date
    /// (Baseline §8.4). Two rows describing identical usage under the two conventions must be
    /// indistinguishable in dollars — reading one column priced 88% of the corpus at the full
    /// uncached rate.
    func testCodexCachedSliceIsReadFromEitherCacheColumn() {
        let table = Self.codexTable
        let creationEra = SQLiteStore.ModelTokenTotals(
            model: "gpt-5.5", inputTokens: 1_000_000, outputTokens: 100_000,
            cacheCreationTokens: 900_000, cacheReadTokens: 0)
        let readEra = SQLiteStore.ModelTokenTotals(
            model: "gpt-5.5", inputTokens: 1_000_000, outputTokens: 100_000,
            cacheCreationTokens: 0, cacheReadTokens: 900_000)

        let a = EstimatedValueEngine.value(for: creationEra, provider: "codex", table: table)
        let b = EstimatedValueEngine.value(for: readEra, provider: "codex", table: table)

        XCTAssertEqual(a, b, accuracy: 0.000_001,
                       "the two storage conventions must produce identical dollars")
        XCTAssertEqual(creationEra.codexCachedInputTokens, readEra.codexCachedInputTokens)
        // 100k uncached at $5 + 900k cached at $0.50 + 100k output at $30.
        XCTAssertEqual(a, 0.1 * 5.00 + 0.9 * 0.50 + 0.1 * 30.00, accuracy: 0.000_001)
    }

    /// Cached tokens are cheaper than uncached ones, and the two rates are not the same number —
    /// if they were equal the split would be arithmetic with no effect.
    func testCachedCodexTokensArePricedStrictlyBelowUncachedInput() {
        let table = Self.codexTable
        let allUncached = SQLiteStore.ModelTokenTotals(
            model: "gpt-5.5", inputTokens: 1_000_000, outputTokens: 0,
            cacheCreationTokens: 0, cacheReadTokens: 0)
        let allCached = SQLiteStore.ModelTokenTotals(
            model: "gpt-5.5", inputTokens: 1_000_000, outputTokens: 0,
            cacheCreationTokens: 1_000_000, cacheReadTokens: 0)

        let uncachedCost = EstimatedValueEngine.value(for: allUncached, provider: "codex", table: table)
        let cachedCost = EstimatedValueEngine.value(for: allCached, provider: "codex", table: table)

        XCTAssertLessThan(cachedCost, uncachedCost)
        XCTAssertNotEqual(cachedCost, uncachedCost, accuracy: 0.000_001)
    }

    /// The subset invariant held in 4,905/4,905 observed events, but a future payload is not bound
    /// by it, and a negative uncached count would silently credit the user.
    func testCodexUncachedRemainderIsClampedAtZero() {
        let table = Self.codexTable
        let impossible = SQLiteStore.ModelTokenTotals(
            model: "gpt-5.5", inputTokens: 100_000, outputTokens: 0,
            cacheCreationTokens: 900_000, cacheReadTokens: 0)

        let value = EstimatedValueEngine.value(for: impossible, provider: "codex", table: table)

        // 0 uncached (clamped) + 900k cached at $0.50; never a negative input term.
        XCTAssertEqual(value, 0.9 * 0.50, accuracy: 0.000_001)
        XCTAssertGreaterThan(value, 0)
    }

    /// Claude's four columns are disjoint quantities and its math is untouched by STEP_91 — pinned
    /// here so the Codex fork cannot quietly be "tidied" into the Claude branch (REV-50's warning).
    /// The table here predates STEP_96's tier fields, so this also pins the compatibility read:
    /// `cache_creation_per_mtok` keeps working as the 5-minute rate.
    func testClaudeStillPricesAllFourColumnsSeparately() {
        let table = PricingTable(
            version: "1.0.0", updated: "2026-06-08",
            models: [
                "claude-opus-5": ModelPricing(
                    provider: "claude",
                    inputPerMtok: 5.00, outputPerMtok: 25.00,
                    cacheCreationPerMtok: 6.25, cacheReadPerMtok: 0.50),
            ],
            fallback: [:]
        )
        let totals = SQLiteStore.ModelTokenTotals(
            model: "claude-opus-5", inputTokens: 1_000_000, outputTokens: 1_000_000,
            cacheCreationTokens: 1_000_000, cacheReadTokens: 1_000_000)

        let value = EstimatedValueEngine.value(for: totals, provider: "claude", table: table)

        XCTAssertEqual(value, 5.00 + 25.00 + 6.25 + 0.50, accuracy: 0.0001,
                       "Claude must keep the four-column sum — no input split, no union")
    }

    // MARK: - Cache-write tiers (STEP_96)

    /// Anthropic charges 1.25× input for a 5-minute cache write and 2× for a 1-hour one. A single
    /// rate priced 84.3% of this corpus's writes at the cheaper tier (REV-62 §4.4, ≈$332).
    private static let opus5Tiered = PricingTable(
        version: "1.2.0", updated: "2026-08-12",
        models: [
            "claude-opus-5": ModelPricing(
                provider: "claude",
                inputPerMtok: 5.00, outputPerMtok: 25.00,
                cacheWrite5mPerMtok: 6.25, cacheWrite1hPerMtok: 10.00,
                cacheReadPerMtok: 0.50),
        ],
        fallback: [:]
    )

    private func writeOnlyTotals(total: Int, oneHour: Int?) -> SQLiteStore.ModelTokenTotals {
        SQLiteStore.ModelTokenTotals(
            model: "claude-opus-5", inputTokens: 0, outputTokens: 0,
            cacheCreationTokens: total, cacheCreation1hTokens: oneHour ?? 0, cacheReadTokens: 0)
    }

    func testAOneHourCacheWritePricesAtTwiceInput() {
        let value = EstimatedValueEngine.value(
            for: writeOnlyTotals(total: 1_000_000, oneHour: 1_000_000),
            provider: "claude", table: Self.opus5Tiered)
        XCTAssertEqual(value, 10.00, accuracy: 0.000_001, "1-hour write is 2× the $5 input rate")
    }

    func testAFiveMinuteCacheWritePricesAtOnePointTwoFiveTimesInput() {
        let value = EstimatedValueEngine.value(
            for: writeOnlyTotals(total: 1_000_000, oneHour: 0),
            provider: "claude", table: Self.opus5Tiered)
        XCTAssertEqual(value, 6.25, accuracy: 0.000_001, "5-minute write is 1.25× the $5 input rate")
    }

    /// The real measured split for `claude-opus-5` on the dogfood corpus: 4,801,565 tokens written
    /// at the 5-minute tier against 22,244,362 at the 1-hour tier (82.2% 1-hour).
    func testMixedTiersPriceEachSliceAtItsOwnRate() {
        let fiveMinute = 4_801_565, oneHour = 22_244_362
        let value = EstimatedValueEngine.value(
            for: writeOnlyTotals(total: fiveMinute + oneHour, oneHour: oneHour),
            provider: "claude", table: Self.opus5Tiered)

        let expected = (Double(fiveMinute) * 6.25 + Double(oneHour) * 10.00) / 1_000_000
        XCTAssertEqual(value, expected, accuracy: 0.000_001)

        // What the same tokens cost before this step, when every write took the 5-minute rate.
        let flat = Double(fiveMinute + oneHour) * 6.25 / 1_000_000
        XCTAssertGreaterThan(value, flat, "the corrected value must rise, not fall")
        XCTAssertEqual(value - flat, Double(oneHour) * 3.75 / 1_000_000, accuracy: 0.000_001,
                       "the whole difference is the 1-hour slice's extra 0.75× of input")
    }

    /// Rows written before migration v17 record no split and are deliberately not backfilled
    /// (user ruling 2026-08-12). They must price at the 5-minute rate — byte-identical to what
    /// they cost before the tier existed, so the boundary is a known fact, not a silent shift.
    func testUnknownSplitPricesExactlyAsBefore() {
        let value = EstimatedValueEngine.value(
            for: writeOnlyTotals(total: 1_000_000, oneHour: nil),
            provider: "claude", table: Self.opus5Tiered)
        XCTAssertEqual(value, 6.25, accuracy: 0.000_001)
    }

    /// A bundled table predating the split carries only `cache_creation_per_mtok` — which *was*
    /// the 5-minute rate. Without the compatibility read, every Claude cache write on such a table
    /// would silently price at $0. (The `dist/` copies pinned at version 1.0.2 are real.)
    func testALegacyTableWithoutTierFieldsStillPricesCacheWrites() {
        let legacy = PricingTable(
            version: "1.1.0", updated: "2026-08-12",
            models: [
                "claude-opus-5": ModelPricing(
                    provider: "claude",
                    inputPerMtok: 5.00, outputPerMtok: 25.00,
                    cacheCreationPerMtok: 6.25, cacheReadPerMtok: 0.50),
            ],
            fallback: [:]
        )
        let value = EstimatedValueEngine.value(
            for: writeOnlyTotals(total: 1_000_000, oneHour: 1_000_000),
            provider: "claude", table: legacy)
        XCTAssertEqual(value, 6.25, accuracy: 0.000_001,
                       "no tier fields ⇒ both tiers price at the 5-minute rate, never at zero")
    }

    /// A 1-hour slice larger than the total would make the 5-minute remainder negative and credit
    /// the user. Clamped, matching STEP_91's clamp on the Codex uncached remainder.
    func testOneHourSliceAboveTheTotalIsClamped() {
        let value = EstimatedValueEngine.value(
            for: writeOnlyTotals(total: 1_000_000, oneHour: 4_000_000),
            provider: "claude", table: Self.opus5Tiered)
        XCTAssertEqual(value, 10.00, accuracy: 0.000_001,
                       "priced as if the whole total were 1-hour — never more, never negative")
    }

    /// Codex has no cache-write charge at all (REV-62 §5.1) and its `cacheCreationTokens` holds
    /// cached *input*, not a write. The tier split must not leak across the fork.
    func testCodexIsUntouchedByTheTierSplit() {
        let totals = SQLiteStore.ModelTokenTotals(
            model: "gpt-5.5", inputTokens: 1_000_000, outputTokens: 0,
            cacheCreationTokens: 900_000, cacheCreation1hTokens: 0, cacheReadTokens: 0)
        let value = EstimatedValueEngine.value(for: totals, provider: "codex", table: Self.codexTable)
        XCTAssertEqual(value, (0.1 * 5.00) + (0.9 * 0.50), accuracy: 0.000_001)
    }

    // MARK: - Provider guard (STEP_91)

    /// `pricing.json` has carried a `provider` field on every row since the first version and
    /// nothing read it, so a Claude model string arriving on a Codex session silently took Claude
    /// rates. A mismatch is now treated as no match at all.
    func testResolvePricingRefusesARowFromAnotherProvider() {
        PricingWarningLog.shared.reset()
        let table = PricingTable(
            version: "1.0.0", updated: "2026-06-08",
            models: [
                "claude-opus-5": ModelPricing(
                    provider: "claude",
                    inputPerMtok: 5.00, outputPerMtok: 25.00,
                    cacheCreationPerMtok: 6.25, cacheReadPerMtok: 0.50),
            ],
            fallback: ["codex": ModelPricing(inputPerMtok: 2.50, outputPerMtok: 15.00,
                                             cacheCreationPerMtok: 0.25, cacheReadPerMtok: 0.25)]
        )

        let resolved = EstimatedValueEngine.resolvePricing(
            model: "claude-opus-5", provider: "codex", table: table)

        XCTAssertEqual(resolved?.inputPerMtok, 2.50, "must fall through to the Codex fallback")
        XCTAssertNil(resolved?.provider, "the fallback row, not the Claude row")
    }

    func testResolvePricingAcceptsAMatchingProvider() {
        PricingWarningLog.shared.reset()
        let table = PricingTable(
            version: "1.0.0", updated: "2026-06-08",
            models: [
                "gpt-5.5": ModelPricing(provider: "codex",
                                        inputPerMtok: 5.00, outputPerMtok: 30.00,
                                        cacheCreationPerMtok: 0.50, cacheReadPerMtok: 0.50),
            ],
            fallback: [:]
        )

        let resolved = EstimatedValueEngine.resolvePricing(
            model: "gpt-5.5", provider: "codex", table: table)

        XCTAssertEqual(resolved?.inputPerMtok, 5.00)
    }

    /// A row with no `provider` (the shape older hand-written tables and every fallback row use) is
    /// not a mismatch — the guard must not reject rows that simply never declared one.
    func testResolvePricingAcceptsARowWithNoProviderDeclared() {
        PricingWarningLog.shared.reset()
        let table = PricingTable(
            version: "1.0.0", updated: "2026-06-08",
            models: ["gpt-5.5": ModelPricing(inputPerMtok: 5.00, outputPerMtok: 30.00)],
            fallback: [:]
        )

        XCTAssertEqual(
            EstimatedValueEngine.resolvePricing(model: "gpt-5.5", provider: "codex", table: table)?
                .inputPerMtok,
            5.00)
    }

    // MARK: - Warning dedup (STEP_91)

    /// One warning per `(provider, model)` per process. The undeduplicated form consumed 33% of log
    /// lines and 36% of log bytes in one hour of runtime (REV-62 §4.7).
    func testUnpricedModelWarnsOncePerProviderAndModel() {
        PricingWarningLog.shared.reset()
        XCTAssertTrue(PricingWarningLog.shared.shouldWarn(provider: "claude", model: "claude-opus-5"))
        XCTAssertFalse(PricingWarningLog.shared.shouldWarn(provider: "claude", model: "claude-opus-5"))
        XCTAssertFalse(PricingWarningLog.shared.shouldWarn(provider: "claude", model: "claude-opus-5"))
        // A different model, and the same model on a different provider, each still get their line.
        XCTAssertTrue(PricingWarningLog.shared.shouldWarn(provider: "claude", model: "claude-haiku-4-5"))
        XCTAssertTrue(PricingWarningLog.shared.shouldWarn(provider: "codex", model: "claude-opus-5"))
        PricingWarningLog.shared.reset()
        XCTAssertTrue(PricingWarningLog.shared.shouldWarn(provider: "claude", model: "claude-opus-5"))
    }

    /// Verified rates as shipped (§12.1). Not a re-derivation of the rate card — a pin on the two
    /// numbers this step exists to correct, so a future edit that reverts either fails loudly.
    private static let codexTable = PricingTable(
        version: "1.1.0", updated: "2026-08-12",
        models: [
            "gpt-5.5": ModelPricing(provider: "codex",
                                    inputPerMtok: 5.00, outputPerMtok: 30.00,
                                    cacheCreationPerMtok: 0.50, cacheReadPerMtok: 0.50),
        ],
        fallback: [:]
    )

    // MARK: - Bundle loading

    func testMissingPricingResourceLogsWarningAndDoesNotCrash() async throws {
        let emptyDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-pricing-bundle-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }
        let emptyBundle = try XCTUnwrap(Bundle(url: emptyDir))

        let dbPath = tempDBPath()
        defer { removeDB(at: dbPath) }
        let store = try SQLiteStore(path: dbPath)
        let engine = EstimatedValueEngine(store: store, bundle: emptyBundle)
        await engine.loadPricingTable()

        // With no pricing table cached, estimatedValue must still resolve to zero, not throw.
        let result = try await engine.estimatedValue(for: .claude)
        XCTAssertEqual(result.weekly, 0)
        XCTAssertEqual(result.thirtyDay, 0)
    }

    // MARK: - End-to-end: real SQLiteStore + fixture pricing.json bundle

    func testEstimatedValueAggregatesPerWindowFromRealStoreAndBundle() async throws {
        let table = PricingTable(
            version: "1.0.0", updated: "2026-06-08",
            models: ["claude-sonnet-4-6": ModelPricing(
                inputPerMtok: 3.00, outputPerMtok: 15.00,
                cacheCreationPerMtok: 3.75, cacheReadPerMtok: 0.30)],
            fallback: [:]
        )
        let bundleDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pricing-fixture-bundle-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try JSONEncoder().encode(table).write(to: bundleDir.appendingPathComponent("pricing.json"))
        let fixtureBundle = try XCTUnwrap(Bundle(url: bundleDir))

        let dbPath = tempDBPath()
        defer { removeDB(at: dbPath) }
        let store = try SQLiteStore(path: dbPath)

        let now = Date()
        // One full-rate event (1M of every token type = $22.05) at each of three ages, plus one
        // event older than every window so it must never be counted.
        try await store.writeTokenEvents([
            fullRateEvent(sessionId: "within-5h", dedupKey: "a", recordedAt: now.addingTimeInterval(-3_600)),
            fullRateEvent(sessionId: "within-weekly", dedupKey: "b", recordedAt: now.addingTimeInterval(-2 * 86_400)),
            fullRateEvent(sessionId: "within-30day", dedupKey: "c", recordedAt: now.addingTimeInterval(-10 * 86_400)),
            fullRateEvent(sessionId: "too-old", dedupKey: "d", recordedAt: now.addingTimeInterval(-40 * 86_400)),
        ])

        let engine = EstimatedValueEngine(store: store, bundle: fixtureBundle)
        await engine.loadPricingTable()
        let result = try await engine.estimatedValue(for: .claude)

        let perEvent = 3.00 + 15.00 + 3.75 + 0.30
        XCTAssertEqual(result.weekly, perEvent * 2, accuracy: 0.0001)
        XCTAssertEqual(result.thirtyDay, perEvent * 3, accuracy: 0.0001)

        // The window-scoped figure §2.5b's `This window` row renders takes an explicit span —
        // there is no rolling five-hour member to reach for (REV-60 — STEP_90).
        let thisWindow = try await engine.value(for: .claude,
                                                from: now.addingTimeInterval(-18_000), until: now)
        XCTAssertEqual(thisWindow, perEvent, accuracy: 0.0001)
    }

    func testTodayWindowCountsOnlyEventsSinceLocalMidnight() async throws {
        // STEP_27: `WindowValue.today` (Codex credits card, UI Spec §2.4) = local midnight → now.
        let table = PricingTable(
            version: "1.0.0", updated: "2026-06-08",
            models: ["claude-sonnet-4-6": ModelPricing(
                inputPerMtok: 3.00, outputPerMtok: 15.00,
                cacheCreationPerMtok: 3.75, cacheReadPerMtok: 0.30)],
            fallback: [:]
        )
        let bundleDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pricing-fixture-bundle-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try JSONEncoder().encode(table).write(to: bundleDir.appendingPathComponent("pricing.json"))
        let fixtureBundle = try XCTUnwrap(Bundle(url: bundleDir))

        let dbPath = tempDBPath()
        defer { removeDB(at: dbPath) }
        let store = try SQLiteStore(path: dbPath)

        let startOfDay = Calendar.current.startOfDay(for: Date())
        try await store.writeTokenEvents([
            fullRateEvent(sessionId: "today", dedupKey: "t", recordedAt: Date()),
            fullRateEvent(sessionId: "yesterday", dedupKey: "y",
                          recordedAt: startOfDay.addingTimeInterval(-1)),
        ])

        let engine = EstimatedValueEngine(store: store, bundle: fixtureBundle)
        await engine.loadPricingTable()
        let result = try await engine.estimatedValue(for: .claude)

        let perEvent = 3.00 + 15.00 + 3.75 + 0.30
        XCTAssertEqual(result.today, perEvent, accuracy: 0.0001,
                       "the pre-midnight event must not count toward today")
    }

    private func fullRateEvent(sessionId: String, dedupKey: String, recordedAt: Date) -> TokenEvent {
        TokenEvent(
            tool: .claude, sessionId: sessionId, model: "claude-sonnet-4-6",
            surfaceBucket: "Claude Code", startedAt: recordedAt,
            inputTokens: 1_000_000, outputTokens: 1_000_000,
            cacheCreationTokens: 1_000_000, cacheReadTokens: 1_000_000,
            recordedAt: recordedAt, dedupKey: dedupKey
        )
    }

    private func tempDBPath() -> String {
        NSTemporaryDirectory().appending("kvotar-value-engine-test-\(UUID().uuidString).db")
    }

    private func removeDB(at path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }
}
