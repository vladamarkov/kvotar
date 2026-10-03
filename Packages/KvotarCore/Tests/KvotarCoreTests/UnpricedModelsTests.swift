import XCTest
@testable import KvotarCore

/// §17.1 `unpriced_models` + the recording seam (REV-62 §5.3, STEP_92): every `(provider, model)`
/// pair `resolvePricing` priced at the provider fallback becomes one durable merged row, except
/// the known non-models, which must never be recorded — the table's job is to tell a maintainer
/// which pricing row to add, and `<synthetic>` is not a model to price.
final class UnpricedModelsTests: XCTestCase {

    private var dbPath: String!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory().appending("kvotar-unpriced-\(UUID().uuidString).db")
        UnpricedModelCollector.shared.reset()
        PricingWarningLog.shared.reset()
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        UnpricedModelCollector.shared.reset()
        PricingWarningLog.shared.reset()
        super.tearDown()
    }

    /// A fixture table that knows one Claude model and both fallbacks — the misses below are
    /// deliberate fixtures, not live edits (STEP_92 DoD).
    private let fixtureTable = PricingTable(
        version: "test", updated: "2026-08-12",
        models: [
            "claude-known": ModelPricing(provider: "claude", inputPerMtok: 3, outputPerMtok: 15),
            "claude-crossed": ModelPricing(provider: "claude", inputPerMtok: 3, outputPerMtok: 15),
        ],
        fallback: [
            "claude": ModelPricing(inputPerMtok: 3, outputPerMtok: 15),
            "codex": ModelPricing(inputPerMtok: 2.5, outputPerMtok: 15),
        ])

    // MARK: - Store: merge-upsert semantics

    func testFirstObservationWritesExactlyOneRow() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.upsertUnpricedModels([
            UnpricedModelObservation(provider: "claude", model: "claude-imaginary-6",
                                     firstSeenAt: 100, lastSeenAt: 100, observationCount: 1)
        ])
        let rows = try await store.unpricedModels()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].provider, "claude")
        XCTAssertEqual(rows[0].model, "claude-imaginary-6")
        XCTAssertEqual(rows[0].firstSeenAt, 100)
        XCTAssertEqual(rows[0].lastSeenAt, 100)
        XCTAssertEqual(rows[0].observationCount, 1)
    }

    func testSecondObservationMergesRatherThanInserts() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.upsertUnpricedModels([
            UnpricedModelObservation(provider: "claude", model: "claude-imaginary-6",
                                     firstSeenAt: 100, lastSeenAt: 110, observationCount: 3)
        ])
        try await store.upsertUnpricedModels([
            UnpricedModelObservation(provider: "claude", model: "claude-imaginary-6",
                                     firstSeenAt: 200, lastSeenAt: 260, observationCount: 2)
        ])
        let rows = try await store.unpricedModels()
        XCTAssertEqual(rows.count, 1, "a second observation must merge, not insert")
        XCTAssertEqual(rows[0].firstSeenAt, 100, "first-seen must keep the earlier instant")
        XCTAssertEqual(rows[0].lastSeenAt, 260, "last-seen must advance")
        XCTAssertEqual(rows[0].observationCount, 5, "counts must accumulate")
    }

    func testSameModelUnderTwoProvidersIsTwoRows() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.upsertUnpricedModels([
            UnpricedModelObservation(provider: "claude", model: "shared-string",
                                     firstSeenAt: 100, lastSeenAt: 100, observationCount: 1),
            UnpricedModelObservation(provider: "codex", model: "shared-string",
                                     firstSeenAt: 100, lastSeenAt: 100, observationCount: 1),
        ])
        let rows = try await store.unpricedModels()
        XCTAssertEqual(rows.count, 2, "the pair is (provider, model), not model alone")
    }

    // MARK: - Collector: what resolvePricing records

    func testFallbackMissIsCollected() {
        let pricing = EstimatedValueEngine.resolvePricing(
            model: "claude-imaginary-6", provider: "claude", table: fixtureTable)
        XCTAssertNotNil(pricing, "the miss still prices at the fallback")
        let drained = UnpricedModelCollector.shared.drain()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].provider, "claude")
        XCTAssertEqual(drained[0].model, "claude-imaginary-6")
        XCTAssertEqual(drained[0].observationCount, 1)
    }

    func testExactMatchIsNotCollected() {
        _ = EstimatedValueEngine.resolvePricing(
            model: "claude-known", provider: "claude", table: fixtureTable)
        XCTAssertTrue(UnpricedModelCollector.shared.drain().isEmpty,
                      "a priced model must leave no trace")
    }

    func testKnownNonModelsAreObservedButNeverRecorded() {
        for nonModel in ["<synthetic>", "codex-auto-review"] {
            _ = EstimatedValueEngine.resolvePricing(
                model: nonModel, provider: nonModel == "<synthetic>" ? "claude" : "codex",
                table: fixtureTable)
        }
        XCTAssertTrue(UnpricedModelCollector.shared.drain().isEmpty,
                      "non-models must never reach the table — it would be born lying (REV-62 §5.4)")
    }

    func testNilModelRecordsNothing() {
        _ = EstimatedValueEngine.resolvePricing(model: nil, provider: "codex", table: fixtureTable)
        XCTAssertTrue(UnpricedModelCollector.shared.drain().isEmpty,
                      "a nil model has no string to record; its fix is STEP_93's attribution")
    }

    /// A Claude-rowed model string requested for Codex has no usable row for that pair — the
    /// mismatch falls through to the fallback and must be recorded like any other miss, under
    /// the raw model string (no "(provider mismatch)" suffix — that hack is the warning log's).
    func testProviderMismatchIsCollectedUnderRawString() {
        _ = EstimatedValueEngine.resolvePricing(
            model: "claude-crossed", provider: "codex", table: fixtureTable)
        let drained = UnpricedModelCollector.shared.drain()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].provider, "codex")
        XCTAssertEqual(drained[0].model, "claude-crossed")
    }

    func testRepeatObservationsMergeInTheCollector() {
        let base = Date(timeIntervalSince1970: 1_000)
        UnpricedModelCollector.shared.record(provider: "codex", model: "gpt-imaginary", at: base)
        UnpricedModelCollector.shared.record(provider: "codex", model: "gpt-imaginary",
                                             at: base.addingTimeInterval(60))
        let drained = UnpricedModelCollector.shared.drain()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].firstSeenAt, 1_000)
        XCTAssertEqual(drained[0].lastSeenAt, 1_060)
        XCTAssertEqual(drained[0].observationCount, 2)
        XCTAssertTrue(UnpricedModelCollector.shared.drain().isEmpty, "drain must clear the buffer")
    }

    // MARK: - End to end: collector batch → merged durable row

    func testDrainedBatchLandsAsMergedRow() async throws {
        let store = try SQLiteStore(path: dbPath)
        _ = EstimatedValueEngine.resolvePricing(
            model: "claude-imaginary-6", provider: "claude", table: fixtureTable)
        _ = EstimatedValueEngine.resolvePricing(
            model: "claude-imaginary-6", provider: "claude", table: fixtureTable)
        try await store.upsertUnpricedModels(UnpricedModelCollector.shared.drain())
        let rows = try await store.unpricedModels()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].observationCount, 2)
    }
}
