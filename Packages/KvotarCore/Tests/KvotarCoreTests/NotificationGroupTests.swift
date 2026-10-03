import XCTest
import GRDB
@testable import KvotarCore

private final class GroupPresenter: NotificationPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _decisions: [NotificationDecision] = []
    func present(_ decision: NotificationDecision) async {
        lock.withLock { _decisions.append(decision) }
    }
    var kinds: [NotificationEventType] { lock.withLock { _decisions.map(\.eventType) } }
    func count(_ type: NotificationEventType) -> Int { kinds.filter { $0 == type }.count }
}

/// STEP_144 / REV-79 (UI Spec D-100, Baseline §16 amendment) — four user-facing on/off groups
/// over the nine events. A disabled group is dropped in `evaluateCycle` before arbitration and
/// before `fire`: no decision reaches the presenter and no `notification_events` row is written.
/// Absent keys read as on / on / on / **off**.
final class NotificationGroupTests: XCTestCase {

    private var dbPath: String!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private var resetsAt: Date { base.addingTimeInterval(3 * 3600) }

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory().appending("kvotar-notif-group-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    // MARK: Builders

    private func makeStore(_ settings: [NotificationGroup: String] = [:]) async throws -> SQLiteStore {
        let store = try SQLiteStore(path: dbPath)
        for (group, value) in settings {
            try await store.writeSetting(key: group.settingsKey, value: value)
        }
        return store
    }

    private func makeEngine(_ store: SQLiteStore) -> (NotificationEngine, GroupPresenter) {
        let presenter = GroupPresenter()
        return (NotificationEngine(store: store, presenter: presenter), presenter)
    }

    private func change(tool: Tool = .claude, from: AppState, to: AppState,
                        extraEnabled: Bool? = nil) -> StateChange {
        StateChange(tool: tool, previous: from, new: to, utilizationPct: 90,
                    runwayMinutes: nil, resetsAt: resetsAt, extraUsageEnabled: extraEnabled,
                    extraUsageUsedCredits: nil, extraUsageMonthlyLimit: nil,
                    extraUsageIsCached: false)
    }

    private func signal(state: AppState = .atRisk, shortDelta: Double? = nil,
                        reset: Date? = nil, now: Date? = nil) -> NotificationSignal {
        NotificationSignal(tool: .claude, state: state, utilizationPct: 90, runwayMinutes: nil,
                           resetsAt: reset ?? resetsAt, utilDeltaShortWindow: shortDelta, fastBurnDelta: shortDelta,
                           utilDeltaLast2Polls: nil, localTokensLast2Min: nil,
                           lastLocalActivityAt: nil, activeSurfaceBucketCount: 0,
                           model: nil, project: nil, surfaces: [], now: now ?? base)
    }

    private var windowStart: Int {
        NotificationEngine.windowStart(resetsAt: resetsAt, windowSeconds: nil, now: base)
    }

    private func rows(_ store: SQLiteStore, _ type: NotificationEventType) async throws -> Int {
        try await store.countNotificationEvents(tool: .claude, eventType: type, windowStart: windowStart)
    }

    // MARK: Mapping

    /// Every event has one switch — except window changed, which has none and is always on
    /// (STEP_146).
    func testEveryEventBelongsToExactlyOneGroupExceptWindowChanged() {
        let listed = NotificationGroup.allCases.flatMap(\.events)
        let switched = NotificationEventType.allCases.filter { $0 != .windowChanged }
        XCTAssertEqual(listed.count, switched.count)
        XCTAssertEqual(Set(listed), Set(switched))
        for group in NotificationGroup.allCases {
            for event in group.events { XCTAssertEqual(event.group, group) }
        }
        XCTAssertNil(NotificationEventType.windowChanged.group)
    }

    func testKeysAndDefaults() {
        XCTAssertEqual(NotificationGroup.atRisk.settingsKey, "notification_at_risk_enabled")
        XCTAssertEqual(NotificationGroup.fastBurn.settingsKey, "notification_fast_burn_enabled")
        XCTAssertEqual(NotificationGroup.overQuota.settingsKey, "notification_over_quota_enabled")
        XCTAssertEqual(NotificationGroup.windowReset.settingsKey, "notification_window_reset_enabled")
        XCTAssertTrue(NotificationGroup.isEnabled(nil, for: .atRisk))
        XCTAssertTrue(NotificationGroup.isEnabled(nil, for: .fastBurn))
        XCTAssertTrue(NotificationGroup.isEnabled(nil, for: .overQuota))
        XCTAssertFalse(NotificationGroup.isEnabled(nil, for: .windowReset))
        XCTAssertFalse(NotificationGroup.isEnabled("false", for: .atRisk))
        XCTAssertTrue(NotificationGroup.isEnabled("true", for: .windowReset))
    }

    // MARK: Disabled ⇒ no decision, no row

    func testAtRiskDisabledDropsAtRiskAndBadTiming() async throws {
        let store = try await makeStore([.atRisk: "false"])
        let (engine, presenter) = makeEngine(store)
        await engine.evaluateCycle(change: change(from: .healthy, to: .atRisk), signal: nil, now: base)
        await engine.evaluateCycle(change: change(from: .atRisk, to: .badTiming), signal: nil, now: base)
        XCTAssertEqual(presenter.kinds, [])
        let atRisk = try await rows(store, .atRisk)
        let badTiming = try await rows(store, .badTiming)
        XCTAssertEqual(atRisk + badTiming, 0)
    }

    func testFastBurnDisabledDropsSpike() async throws {
        let store = try await makeStore([.fastBurn: "false"])
        let (engine, presenter) = makeEngine(store)
        await engine.evaluateCycle(change: nil, signal: signal(state: .healthy, shortDelta: 25), now: base)
        XCTAssertEqual(presenter.kinds, [])
        let count = try await rows(store, .fastBurnSpike)
        XCTAssertEqual(count, 0)
    }

    func testOverQuotaDisabledDropsOverQuota() async throws {
        let store = try await makeStore([.overQuota: "false"])
        let (engine, presenter) = makeEngine(store)
        await engine.evaluateCycle(change: change(from: .healthy, to: .overQuota, extraEnabled: true),
                                   signal: nil, now: base)
        XCTAssertEqual(presenter.kinds, [])
        let count = try await rows(store, .overQuota)
        XCTAssertEqual(count, 0)
    }

    func testWindowResetAbsentIsOffAndTrueIsOn() async throws {
        for (value, expected) in [(nil, 0), ("true", 1)] as [(String?, Int)] {
            dbPath = NSTemporaryDirectory().appending("kvotar-notif-group-\(UUID().uuidString).db")
            let store = try await makeStore(value.map { [.windowReset: $0] } ?? [:])
            let (engine, presenter) = makeEngine(store)
            await engine.evaluateCycle(change: nil, signal: signal(state: .atRisk, now: base), now: base)
            let nearReset = resetsAt.addingTimeInterval(-20 * 60)
            await engine.evaluateCycle(change: nil, signal: signal(state: .atRisk, now: nearReset), now: nearReset)
            XCTAssertEqual(presenter.count(.windowResetPre), expected, "value \(value ?? "absent")")
            let count = try await rows(store, .windowResetPre)
            XCTAssertEqual(count, expected, "value \(value ?? "absent")")
        }
    }

    // MARK: Absent ⇒ on for the three default-on groups

    func testAbsentKeysLeaveDefaultOnGroupsFiring() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await engine.evaluateCycle(change: change(from: .healthy, to: .overQuota, extraEnabled: true),
                                   signal: nil, now: base)
        XCTAssertEqual(presenter.count(.overQuota), 1)
    }

    // MARK: Drop happens before arbitration

    func testDisabledHigherPriorityDoesNotSilenceEnabledLower() async throws {
        let store = try await makeStore([.overQuota: "false"])
        let (engine, presenter) = makeEngine(store)
        // Over quota (rank 1) transition + a fast-burn spike (rank 4) in the same cycle.
        await engine.evaluateCycle(change: change(from: .healthy, to: .overQuota, extraEnabled: true),
                                   signal: signal(state: .overQuota, shortDelta: 25), now: base)
        XCTAssertEqual(presenter.kinds, [.fastBurnSpike])
        let overQuota = try await rows(store, .overQuota)
        let spike = try await rows(store, .fastBurnSpike)
        XCTAssertEqual(overQuota, 0)
        XCTAssertEqual(spike, 1)
    }

    // MARK: Re-enabling starts clean

    func testReEnabledGroupHasFullCap() async throws {
        let store = try await makeStore([.overQuota: "false"])
        let (engine, presenter) = makeEngine(store)
        await engine.evaluateCycle(change: change(from: .healthy, to: .overQuota, extraEnabled: true),
                                   signal: nil, now: base)
        XCTAssertEqual(presenter.count(.overQuota), 0)
        try await store.writeSetting(key: NotificationGroup.overQuota.settingsKey, value: "true")
        await engine.evaluateCycle(change: change(from: .healthy, to: .overQuota, extraEnabled: true),
                                   signal: nil, now: base)
        XCTAssertEqual(presenter.count(.overQuota), 1)
    }
}
