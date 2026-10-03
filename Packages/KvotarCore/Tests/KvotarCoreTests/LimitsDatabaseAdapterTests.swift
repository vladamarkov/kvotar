import XCTest
@testable import KvotarCore

final class LimitsDatabaseAdapterTests: XCTestCase {

    // MARK: - Bundled seed

    func testLoadsBundledSeed() async throws {
        let adapter = LimitsDatabaseAdapter()
        await adapter.loadOnLaunch()

        // Remote is stubbed (nil), so the bundled seed must be the source.
        let source = await adapter.source
        XCTAssertEqual(source, .bundled)
    }

    func testCeilingReturnsCommunityTierForKnownPlan() async throws {
        let adapter = LimitsDatabaseAdapter()
        await adapter.loadOnLaunch()

        let ceiling = await adapter.ceiling(tool: .claude, planType: "max", window: .fiveHour)
        XCTAssertEqual(ceiling.tier, .community)
        XCTAssertEqual(ceiling.utilizationPct, 100)
    }

    func testCeilingFallsBackToHardcodedPriorForUnknownPlan() async throws {
        let adapter = LimitsDatabaseAdapter()
        await adapter.loadOnLaunch()

        let ceiling = await adapter.ceiling(tool: .codex, planType: "enterprise", window: .weekly)
        XCTAssertEqual(ceiling.tier, .hardcodedPrior)
        XCTAssertEqual(ceiling.utilizationPct, 100)
    }

    // MARK: - Fallback when bundle has no seed

    func testFallsBackToHardcodedPriorWhenBundleMissingSeed() async throws {
        // An empty bundle (temp dir) has no limits.json → bundled load fails → hardcoded prior.
        let emptyDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-bundle-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }
        let emptyBundle = try XCTUnwrap(Bundle(url: emptyDir))

        let adapter = LimitsDatabaseAdapter(bundle: emptyBundle)
        await adapter.loadOnLaunch()

        let source = await adapter.source
        XCTAssertEqual(source, .hardcodedPrior)
        let ceiling = await adapter.ceiling(tool: .claude, planType: "max", window: .fiveHour)
        XCTAssertEqual(ceiling.tier, .hardcodedPrior)
    }

    // MARK: - Idempotent load

    func testLoadIsIdempotent() async throws {
        let adapter = LimitsDatabaseAdapter()
        await adapter.loadOnLaunch()
        let first = await adapter.source
        await adapter.loadOnLaunch()
        let second = await adapter.source
        XCTAssertEqual(second, first)
    }

    // MARK: - Personal ceiling resolver (§9.4)

    func testResolveCeilingUsesCommunityBelowThreeObservations() {
        let resolved = LimitsDatabaseAdapter.resolveCeiling(
            personalObservations: [82, 79],
            communityCeiling: 100
        )
        XCTAssertEqual(resolved, 100)
    }

    func testResolveCeilingUsesLowestPersonalAtThreeOrMore() {
        let resolved = LimitsDatabaseAdapter.resolveCeiling(
            personalObservations: [85, 78, 91],
            communityCeiling: 100
        )
        XCTAssertEqual(resolved, 78)
    }

    func testResolveCeilingEmptyObservations() {
        let resolved = LimitsDatabaseAdapter.resolveCeiling(
            personalObservations: [],
            communityCeiling: 95
        )
        XCTAssertEqual(resolved, 95)
    }

    // MARK: - Post-cleanup behaviour (STEP_80)

    func testResolveCeilingAfterSubFloorCleanupUsesSurvivingMinimum() {
        // This machine's table goes 8 → 6 rows: still ≥ 3, so the personal ceiling stands and is
        // now the honest one (97) instead of the poisoned 5.
        let resolved = LimitsDatabaseAdapter.resolveCeiling(
            personalObservations: [100, 100, 97, 97, 99, 100],
            communityCeiling: 100
        )
        XCTAssertEqual(resolved, 97)
    }

    func testResolveCeilingFallsBackToCommunityWhenCleanupDropsBelowThree() {
        // A tester's table could go 3 → 1. The ≥ 3 gate must still hold — dropping below the
        // threshold falls back to the community prior rather than trusting a single observation.
        let resolved = LimitsDatabaseAdapter.resolveCeiling(
            personalObservations: [98],
            communityCeiling: 100
        )
        XCTAssertEqual(resolved, 100)
    }

    func testCeilingObservationFloorIsFifty() {
        // P1-21's starting value — pinned so a tuning change is a deliberate edit, not a drift.
        XCTAssertEqual(LimitsDatabaseAdapter.quotaCeilingObservationFloorPct, 50.0)
    }
}
