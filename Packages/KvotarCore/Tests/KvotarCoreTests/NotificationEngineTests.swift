import XCTest
import GRDB
@testable import KvotarCore

/// Records delivered decisions for assertion. A lock-guarded class (rather than an actor) so
/// accessors are synchronous and usable inside `XCTAssertEqual` autoclosures.
private final class MockPresenter: NotificationPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _decisions: [NotificationDecision] = []
    func present(_ decision: NotificationDecision) async {
        lock.withLock { _decisions.append(decision) }
    }
    var decisions: [NotificationDecision] { lock.withLock { _decisions } }
    func count(_ type: NotificationEventType) -> Int { decisions.filter { $0.eventType == type }.count }
    func variants(_ type: NotificationEventType) -> [String?] {
        decisions.filter { $0.eventType == type }.map { $0.copyVariant }
    }
    var total: Int { decisions.count }
    private var _resets: [Tool] = []
    func windowDidReset(_ tool: Tool) async { lock.withLock { _resets.append(tool) } }
    var resets: [Tool] { lock.withLock { _resets } }
}

final class NotificationEngineTests: XCTestCase {

    private var dbPath: String!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    /// A stable in-window reset time (3h out) → its window start is `base + 3h − 5h`.
    private var resetsAt: Date { base.addingTimeInterval(3 * 3600) }

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory().appending("kvotar-notif-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    // MARK: Builders

    /// STEP_144: the Window reset group defaults to **off**; these tests predate the switch and
    /// exercise the engine's reset path, so the fixture turns it on. The default itself is
    /// pinned in `NotificationGroupTests`.
    private func makeStore() async throws -> SQLiteStore {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeSetting(key: NotificationGroup.windowReset.settingsKey, value: "true")
        return store
    }

    private func makeEngine(_ store: SQLiteStore) -> (NotificationEngine, MockPresenter) {
        let presenter = MockPresenter()
        return (NotificationEngine(store: store, presenter: presenter), presenter)
    }

    private func change(
        tool: Tool = .claude, from: AppState, to: AppState,
        util: Double? = 90, runway: Double? = nil, extraEnabled: Bool? = nil,
        usedCredits: Decimal? = nil, monthlyLimit: Int? = nil, cached: Bool = false,
        reset: Date? = nil, episode: BlockEpisode? = nil,
        longLimit: LongLimitAssessment? = nil
    ) -> StateChange {
        StateChange(tool: tool, previous: from, new: to, utilizationPct: util,
                    runwayMinutes: runway, resetsAt: reset ?? resetsAt,
                    extraUsageEnabled: extraEnabled,
                    extraUsageUsedCredits: usedCredits,
                    extraUsageMonthlyLimit: monthlyLimit,
                    extraUsageIsCached: cached,
                    blockEpisode: episode, longLimit: longLimit)
    }

    /// A nearly-spent weekly, `days` from its reset.
    private func nearlySpentWeekly(days: Double = 3, used: Double = 92)
        -> LongLimitAssessment {
        LongLimitAssessment(limit: .secondary, tier: .nearlySpent, usedPct: used,
                            elapsedPct: 50, resetsAt: base.addingTimeInterval(days * 86_400),
                            periodSeconds: 7 * 86_400)
    }

    private func signal(
        tool: Tool = .claude, state: AppState = .atRisk, util: Double? = 90,
        runway: Double? = nil, reset: Date? = nil, shortDelta: Double? = nil,
        last2Delta: Double? = nil, localTokens: Int? = nil, lastActivity: Date? = nil,
        surfaces: Int = 0,
        model: String? = nil, project: String? = nil, surfaceNames: [String] = [],
        episode: BlockEpisode? = nil,
        longLimit: LongLimitAssessment? = nil,
        now: Date? = nil
    ) -> NotificationSignal {
        NotificationSignal(
            tool: tool, state: state, utilizationPct: util, runwayMinutes: runway,
            resetsAt: reset ?? resetsAt, blockEpisode: episode, longLimit: longLimit,
            utilDeltaShortWindow: shortDelta, fastBurnDelta: shortDelta,
            utilDeltaLast2Polls: last2Delta, localTokensLast2Min: localTokens,
            lastLocalActivityAt: lastActivity,
            activeSurfaceBucketCount: surfaces, model: model, project: project,
            surfaces: surfaceNames, now: now ?? base)
    }

    /// The idle shape: no active session → `resets_at: null`, utilization degraded to nil
    /// (ClaudeAccountAdapter §8.0.2). The builder above can't produce a nil reset (it defaults),
    /// so null-window polls get their own helper.
    private func nullWindowSignal(tool: Tool = .claude, now: Date) -> NotificationSignal {
        NotificationSignal(tool: tool, state: .healthy, utilizationPct: nil,
                           runwayMinutes: nil, resetsAt: nil, now: now)
    }

    private var expectedWindowStart: Int {
        NotificationEngine.windowStart(resetsAt: resetsAt, windowSeconds: nil, now: base)
    }

    /// One `evaluateCycle` call — the STEP_28 entry point. `now` defaults to the signal's clock
    /// (Path 2 time control) or `base` for change-only cycles.
    private func cycle(
        _ engine: NotificationEngine, change: StateChange? = nil,
        signal: NotificationSignal? = nil, now: Date? = nil
    ) async {
        await engine.evaluateCycle(change: change, signal: signal,
                                   now: now ?? signal?.now ?? base)
    }

    // MARK: Arbitration priority + stable identifier (STEP_28)

    func testArbitrationPriorityMatchesSection16() {
        // Baseline §16 — exact rank table, including the two intentional ties.
        XCTAssertEqual(NotificationEventType.overQuota.arbitrationPriority, 1)
        XCTAssertEqual(NotificationEventType.spendControl.arbitrationPriority, 1)
        // §4.1a (STEP_146): window changed sits below over quota and above at risk.
        XCTAssertEqual(NotificationEventType.windowChanged.arbitrationPriority, 2)
        XCTAssertEqual(NotificationEventType.atRisk.arbitrationPriority, 3)
        // REV-96 §3.2 (STEP_193): event 9 sits between At risk and Bad timing, shifting
        // everything below it down one.
        XCTAssertEqual(NotificationEventType.limitNearlySpent.arbitrationPriority, 4)
        XCTAssertEqual(NotificationEventType.badTiming.arbitrationPriority, 5)
        // REV-106 §2.7 (STEP_232): event 10 sits between Bad timing and Fast burn, shifting
        // everything below it down one again.
        XCTAssertEqual(NotificationEventType.limitAheadOfPace.arbitrationPriority, 6)
        XCTAssertEqual(NotificationEventType.fastBurnSpike.arbitrationPriority, 7)
        XCTAssertEqual(NotificationEventType.offMachineBurn.arbitrationPriority, 8)
        XCTAssertEqual(NotificationEventType.multiSurface.arbitrationPriority, 9)
        XCTAssertEqual(NotificationEventType.windowResetPre.arbitrationPriority, 10)
        XCTAssertEqual(NotificationEventType.windowResetPost.arbitrationPriority, 10)
    }

    func testStableRequestIDFormat() {
        let ws = expectedWindowStart
        let decision = NotificationDecision(
            tool: .claude, eventType: .atRisk, windowStart: ws, copyVariant: nil)
        XCTAssertEqual(decision.stableRequestID, "claude-at_risk-\(ws)")
    }

    // MARK: Path 1 — transition-based

    func testOverQuotaFiresOnceAndWritesRow() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)

        await cycle(engine, change: change(from: .healthy, to: .overQuota, extraEnabled: true))

        XCTAssertEqual(presenter.count(.overQuota), 1)
        XCTAssertEqual(presenter.variants(.overQuota), ["case_1"])
        let count = try await store.countNotificationEvents(
            tool: .claude, eventType: .overQuota, windowStart: expectedWindowStart)
        XCTAssertEqual(count, 1)
    }

    /// Rank 10 is display-only (REV-96 §2.3, inheriting Weekly-elevated's ruling) — a transition
    /// into it must produce no candidate and fire nothing.
    func testLimitAheadOfPaceTransitionFiresNothing() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)

        await cycle(engine, change: change(from: .healthy, to: .limitAheadOfPace, util: 22))

        XCTAssertEqual(presenter.total, 0, "Ahead of pace is display-only — no notification kind")
    }

    // MARK: Event 9 — Limit nearly spent (REV-96 §3.2 — live since STEP_194)

    /// Once per limit instance, not once per five-hour window: a weekly warning keyed to the
    /// window bucket would re-arm every few hours, which is the defect STEP_193 removed next door.
    func testNearlySpentFiresOncePerLimitInstance() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let weekly = nearlySpentWeekly()

        await cycle(engine, change: change(from: .healthy, to: .limitNearlySpent, util: 40,
                                           longLimit: weekly))
        XCTAssertEqual(presenter.decisions.map(\.eventType), [.limitNearlySpent])
        XCTAssertEqual(presenter.decisions.first?.longLimit, weekly)

        // The five-hour window rolls, the state calms and comes back: still the same week.
        await cycle(engine, change: change(from: .limitNearlySpent, to: .healthy, util: 10,
                                           longLimit: weekly))
        await cycle(engine, change: change(from: .healthy, to: .limitNearlySpent, util: 40,
                                           longLimit: weekly))
        XCTAssertEqual(presenter.total, 1, "one warning per week, however the state moves")
    }

    /// A relaunch inside the same week fires nothing — the key is in `settings`, not in memory.
    func testNearlySpentIsSilentAfterARelaunchInTheSameInstance() async throws {
        let store = try await makeStore()
        let weekly = nearlySpentWeekly()
        let (first, firstPresenter) = makeEngine(store)
        await cycle(first, change: change(from: .healthy, to: .limitNearlySpent, util: 40,
                                          longLimit: weekly))
        XCTAssertEqual(firstPresenter.total, 1)

        let (second, secondPresenter) = makeEngine(store)
        await cycle(second, change: change(from: .healthy, to: .limitNearlySpent, util: 40,
                                           longLimit: weekly))
        XCTAssertEqual(secondPresenter.total, 0)
    }

    /// The next week is a different instance and warns again.
    func testNearlySpentFiresAgainOnTheNextInstance() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, change: change(from: .healthy, to: .limitNearlySpent, util: 40,
                                           longLimit: nearlySpentWeekly(days: 3)))
        await cycle(engine, change: change(from: .healthy, to: .limitNearlySpent, util: 40,
                                           longLimit: nearlySpentWeekly(days: 10)))
        XCTAssertEqual(presenter.total, 2)
    }

    /// A one-second wobble in the provider's `resets_at` is the same week, not a second warning —
    /// the failure STEP_193 found on the tester's block, generalised to this key.
    func testNearlySpentDoesNotRefireOnResetJitter() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, change: change(from: .healthy, to: .limitNearlySpent, util: 40,
                                           longLimit: nearlySpentWeekly(days: 3)))
        let wobbled = LongLimitAssessment(
            limit: .secondary, tier: .nearlySpent, usedPct: 93, elapsedPct: 51,
            resetsAt: base.addingTimeInterval(3 * 86_400 + 1), periodSeconds: 7 * 86_400)
        await cycle(engine, change: change(from: .healthy, to: .limitNearlySpent, util: 40,
                                           longLimit: wobbled))
        XCTAssertEqual(presenter.total, 1)
    }

    /// The weekly and the monthly are separate instances with separate keys.
    func testNearlySpentKeysAreIndependentPerLimit() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let monthly = LongLimitAssessment(limit: .monthly, tier: .nearlySpent, usedPct: 92,
                                          elapsedPct: 67,
                                          resetsAt: base.addingTimeInterval(10 * 86_400),
                                          periodSeconds: 30 * 86_400,
                                          usedAmount: 6454, limitAmount: 7000,
                                          unit: .money(currency: "EUR", exponent: 2))
        await cycle(engine, change: change(from: .healthy, to: .limitNearlySpent, util: 40,
                                           longLimit: nearlySpentWeekly()))
        await cycle(engine, change: change(from: .healthy, to: .limitNearlySpent, util: 40,
                                           longLimit: monthly))
        XCTAssertEqual(presenter.total, 2)
    }

    /// **It cannot fire while a five-hour red state is live** — by ranking, not by a second gate:
    /// `StateEngine` classifies At risk above rank 5b, so no transition into 5b exists to fire on.
    /// When the five-hour calms and the weekly is still past the line, the transition happens then.
    func testNearlySpentWaitsForTheFiveHourWarningToPass() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let weekly = nearlySpentWeekly()
        // At risk owns the moment; §16 arbitration keeps the higher-priority banner.
        await cycle(engine, change: change(from: .healthy, to: .atRisk, util: 90, runway: 12,
                                           longLimit: weekly))
        XCTAssertEqual(presenter.decisions.map(\.eventType), [.atRisk])
        // The five-hour resets; the weekly has not.
        await cycle(engine, change: change(from: .atRisk, to: .limitNearlySpent, util: 5,
                                           longLimit: weekly))
        XCTAssertEqual(presenter.decisions.map(\.eventType), [.atRisk, .limitNearlySpent])
    }

    /// A transition into rank 5b with no assessment fires nothing rather than something unkeyed.
    func testNearlySpentWithoutAnAssessmentFiresNothing() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, change: change(from: .healthy, to: .limitNearlySpent, util: 40))
        XCTAssertEqual(presenter.total, 0)
    }

    /// Silencing block banners must not silence the warning that avoids the block: event 9 rides
    /// the **At risk** switch (owner ruling 2026-09-14).
    func testNearlySpentFollowsTheAtRiskSwitch() async throws {
        let store = try await makeStore()
        try await store.writeSetting(key: NotificationGroup.overQuota.settingsKey, value: "false")
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, change: change(from: .healthy, to: .limitNearlySpent, util: 40,
                                           longLimit: nearlySpentWeekly()))
        XCTAssertEqual(presenter.total, 1, "the Over quota switch does not reach it")

        try await store.writeSetting(key: NotificationGroup.atRisk.settingsKey, value: "false")
        let (muted, mutedPresenter) = makeEngine(store)
        await cycle(muted, change: change(from: .healthy, to: .limitNearlySpent, util: 40,
                                          longLimit: nearlySpentWeekly(days: 10)))
        XCTAssertEqual(mutedPresenter.total, 0, "the At risk switch does")
    }

    /// R33-6 (STEP_39): a cold launch into a blocked window notifies — the StateEngine emits the
    /// first evaluation as a transition from `.idleFallback` — and a second relaunch into the
    /// same window is suppressed by the existing per-window cap, because `notification_events`
    /// is persisted and keyed by `window_start`. Two engines over one store = two launches.
    func testColdLaunchHardBlockFiresOncePerWindowAcrossRelaunches() async throws {
        let store = try await makeStore()
        let (first, firstPresenter) = makeEngine(store)
        await cycle(first, change: change(from: .idleFallback, to: .overQuota))
        XCTAssertEqual(firstPresenter.count(.overQuota), 1,
                       "a cold launch directly into a blocked window must not be silent")

        let (second, secondPresenter) = makeEngine(store)
        await cycle(second, change: change(from: .idleFallback, to: .overQuota))
        XCTAssertEqual(secondPresenter.count(.overQuota), 0,
                       "same window, second relaunch → deduped by the per-window cap")
    }

    /// D-124 (STEP_212): a first evaluation into rank 5b notifies once, and a second launch
    /// inside the same week is suppressed by the limit-instance key (`instance_already_fired`).
    func testColdLaunchNearlySpentFiresOncePerInstanceAcrossRelaunches() async throws {
        let store = try await makeStore()
        let weekly = nearlySpentWeekly()
        let (first, firstPresenter) = makeEngine(store)
        await cycle(first, change: change(from: .idleFallback, to: .limitNearlySpent, util: 40,
                                          longLimit: weekly))
        XCTAssertEqual(firstPresenter.count(.limitNearlySpent), 1,
                       "a launch straight into red must not be silent")

        let (second, secondPresenter) = makeEngine(store)
        await cycle(second, change: change(from: .idleFallback, to: .limitNearlySpent, util: 40,
                                           longLimit: weekly))
        XCTAssertEqual(secondPresenter.count(.limitNearlySpent), 0,
                       "same week, second launch → deduped by the limit-instance key")
    }

    func testOverQuotaCappedAtOnePerWindow() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // Two genuine transitions back into over-quota in the same window → still one notification.
        await cycle(engine, change: change(from: .healthy, to: .overQuota))
        await cycle(engine, change: change(from: .atRisk, to: .overQuota))
        XCTAssertEqual(presenter.count(.overQuota), 1)
    }

    func testOverQuotaCodexHasNoVariant() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, change: change(tool: .codex, from: .healthy, to: .overQuota))
        XCTAssertEqual(presenter.variants(.overQuota), [nil])
    }

    // MARK: REV-96 (STEP_193) — one banner per block episode

    /// The tester's 4–7 Sep block, in miniature. The weekly is spent and the five-hour window
    /// rolls underneath it: two genuine transitions back into Over quota, two different
    /// `window_start` keys — which is exactly what produced eleven banners — and one episode.
    func testOneBannerPerEpisodeAcrossAFiveHourRollover() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let weekly = BlockEpisode(tool: .codex, limit: .secondary,
                                  limitResetsAt: base.addingTimeInterval(3 * 24 * 3600))
        await cycle(engine, change: change(tool: .codex, from: .healthy, to: .overQuota,
                                           reset: base.addingTimeInterval(3600), episode: weekly))
        // Five hours later the primary window has rolled; same weekly, same episode.
        await cycle(engine, change: change(tool: .codex, from: .idleFallback, to: .overQuota,
                                           reset: base.addingTimeInterval(6 * 3600),
                                           episode: weekly),
                    now: base.addingTimeInterval(5 * 3600))
        XCTAssertEqual(presenter.count(.overQuota), 1,
                       "one block, one banner — the rollover underneath it is not a new block")
    }

    /// REV-102 / STEP_218 — the Team tester's Sunday: one weekly episode while the org-paid
    /// credits run from charging to the cap. One over-quota banner, and no Spend-control event,
    /// because the cap is no longer a block candidate on a seat with windows.
    func testTeamWeeklyBlockIsOneBannerAndNoSpendControl() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let weekly = BlockEpisode(tool: .claude, limit: .secondary,
                                  limitResetsAt: base.addingTimeInterval(36 * 3600))
        await cycle(engine, change: change(from: .healthy, to: .overQuota, util: 0,
                                           extraEnabled: true, usedCredits: 16.8,
                                           monthlyLimit: 7000, episode: weekly))
        // Six hours on the cap is reached; the state never left Over quota, and a re-entry
        // after a stale gap carries the same episode.
        await cycle(engine, change: change(from: .idleFallback, to: .overQuota, util: 0,
                                           extraEnabled: true,
                                           usedCredits: Decimal(string: "70.25"),
                                           monthlyLimit: 7000, episode: weekly),
                    now: base.addingTimeInterval(6 * 3600))
        XCTAssertEqual(presenter.count(.overQuota), 1)
        XCTAssertEqual(presenter.count(.spendControl), 0)
    }

    /// The episode key is persisted, so a relaunch inside the block is silent even though the
    /// five-hour window it is keyed under has moved on. Two engines over one store = two launches.
    func testRelaunchInsideAnEpisodeFiresNothing() async throws {
        let store = try await makeStore()
        let episode = BlockEpisode(tool: .codex, limit: .secondary,
                                   limitResetsAt: base.addingTimeInterval(2 * 24 * 3600))
        let (first, firstPresenter) = makeEngine(store)
        await cycle(first, change: change(tool: .codex, from: .healthy, to: .overQuota,
                                          episode: episode))
        XCTAssertEqual(firstPresenter.count(.overQuota), 1)

        let (second, secondPresenter) = makeEngine(store)
        await cycle(second, change: change(tool: .codex, from: .idleFallback, to: .overQuota,
                                           reset: base.addingTimeInterval(8 * 3600),
                                           episode: episode))
        XCTAssertEqual(secondPresenter.count(.overQuota), 0,
                       "the stored episode key outlives the process")
    }

    /// A new block after the first one ended is a new episode and notifies — the dedup must not
    /// swallow the genuinely separate primary block the tester hit after their weekly reset.
    func testTheNextBlockIsItsOwnEpisode() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let weekly = BlockEpisode(tool: .codex, limit: .secondary,
                                  limitResetsAt: base.addingTimeInterval(2 * 24 * 3600))
        await cycle(engine, change: change(tool: .codex, from: .healthy, to: .overQuota,
                                           episode: weekly))
        // Recovery: a poll that sees no blocking limit ends the episode.
        await cycle(engine, change: change(tool: .codex, from: .overQuota, to: .healthy),
                    signal: signal(tool: .codex, state: .healthy, util: 12,
                                   now: base.addingTimeInterval(3 * 24 * 3600)),
                    now: base.addingTimeInterval(3 * 24 * 3600))
        let primary = BlockEpisode(tool: .codex, limit: .primary,
                                   limitResetsAt: base.addingTimeInterval(3 * 24 * 3600 + 7200))
        await cycle(engine, change: change(tool: .codex, from: .healthy, to: .overQuota,
                                           reset: base.addingTimeInterval(3 * 24 * 3600 + 7200),
                                           episode: primary),
                    now: base.addingTimeInterval(3 * 24 * 3600 + 60))
        XCTAssertEqual(presenter.count(.overQuota), 2, "a different block is a different episode")
    }

    /// Recovery clears the stored key. Without the clear the same limit reaching 100 % again
    /// after a reset would be read as the episode that already fired.
    func testRecoveryClearsTheStoredEpisodeKey() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let episode = BlockEpisode(tool: .codex, limit: .secondary,
                                   limitResetsAt: base.addingTimeInterval(2 * 24 * 3600))
        await cycle(engine, change: change(tool: .codex, from: .healthy, to: .overQuota,
                                           episode: episode))
        let key = try await store.readSetting(key: BlockEpisode.settingsKey(for: .codex))
        XCTAssertEqual(key, episode.key)

        await cycle(engine, change: change(tool: .codex, from: .overQuota, to: .healthy),
                    signal: signal(tool: .codex, state: .healthy, util: 12))
        let cleared = try await store.readSetting(key: BlockEpisode.settingsKey(for: .codex))
        XCTAssertNil(cleared)
        XCTAssertEqual(presenter.count(.overQuota), 1)
    }

    /// A JSONL delta or a staleness evaluation carries no account reading, so it must not end an
    /// episode by silence — only a poll signal can.
    func testACycleWithoutASignalDoesNotEndAnEpisode() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let episode = BlockEpisode(tool: .codex, limit: .secondary,
                                   limitResetsAt: base.addingTimeInterval(2 * 24 * 3600))
        await cycle(engine, change: change(tool: .codex, from: .healthy, to: .overQuota,
                                           episode: episode))
        await cycle(engine, change: nil, signal: nil)
        await cycle(engine, change: change(tool: .codex, from: .idleFallback, to: .overQuota,
                                           episode: episode))
        XCTAssertEqual(presenter.count(.overQuota), 1)
    }

    /// Spend control keys on its episode the same way, and its body's reset is the monthly's.
    func testSpendControlIsOneBannerPerEpisode() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let monthly = BlockEpisode(tool: .codex, limit: .monthly,
                                   limitResetsAt: base.addingTimeInterval(9 * 24 * 3600))
        await cycle(engine, change: change(tool: .codex, from: .healthy, to: .spendControl,
                                           episode: monthly))
        await cycle(engine, change: change(tool: .codex, from: .idleFallback, to: .spendControl,
                                           reset: base.addingTimeInterval(6 * 3600),
                                           episode: monthly),
                    now: base.addingTimeInterval(5 * 3600))
        XCTAssertEqual(presenter.count(.spendControl), 1)
    }

    /// The provider wobbles `resets_at` by a second or two between polls (the tester's weekly
    /// reported 06:55:26 and 06:55:27 inside one block). A string comparison would read that as a
    /// new episode and fire again, so the match carries the one Core jitter tolerance.
    func testAWobbledResetIsTheSameEpisode() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let reset = base.addingTimeInterval(2 * 24 * 3600)
        let first = BlockEpisode(tool: .codex, limit: .secondary, limitResetsAt: reset)
        let wobbled = BlockEpisode(tool: .codex, limit: .secondary,
                                   limitResetsAt: reset.addingTimeInterval(1))
        await cycle(engine, change: change(tool: .codex, from: .healthy, to: .overQuota,
                                           episode: first))
        await cycle(engine, change: change(tool: .codex, from: .idleFallback, to: .overQuota,
                                           episode: wobbled))
        XCTAssertEqual(presenter.count(.overQuota), 1)
    }

    /// But a reset that genuinely moved — a new week — is a new episode.
    func testAResetBeyondTheToleranceIsANewEpisode() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let reset = base.addingTimeInterval(2 * 24 * 3600)
        await cycle(engine, change: change(tool: .codex, from: .healthy, to: .overQuota,
                                           episode: BlockEpisode(tool: .codex, limit: .secondary,
                                                                 limitResetsAt: reset)))
        await cycle(engine, change: change(tool: .codex, from: .idleFallback, to: .overQuota,
                                           episode: BlockEpisode(
                                            tool: .codex, limit: .secondary,
                                            limitResetsAt: reset.addingTimeInterval(7 * 24 * 3600))))
        XCTAssertEqual(presenter.count(.overQuota), 2)
    }

    /// With no anchor there is no episode, and the per-window cap is what gates the banner —
    /// unchanged from what ships, so this path is never worse than before.
    func testBlockWithNoEpisodeKeepsThePerWindowCap() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, change: change(from: .healthy, to: .overQuota))
        await cycle(engine, change: change(from: .atRisk, to: .overQuota))
        XCTAssertEqual(presenter.count(.overQuota), 1)
        let key = try await store.readSetting(key: BlockEpisode.settingsKey(for: .claude))
        XCTAssertNil(key, "nothing to key on, nothing stored")
    }

    // MARK: STEP_27 — §7.1 three-case over-quota variants + payload carriage

    func testOverQuotaCase2WhenCachedCreditsPresent() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // Credits used earlier this window ($3.20), toggle now off — the §7.1 cached value rides
        // the StateChange → case_2, amounts carried for the presenter's dollar body.
        await cycle(engine, change: change(from: .healthy, to: .overQuota, util: 106,
                                           extraEnabled: false, usedCredits: 3.20,
                                           monthlyLimit: 2000, cached: true))
        XCTAssertEqual(presenter.variants(.overQuota), ["case_2"])
        let decision = try XCTUnwrap(presenter.decisions.first)
        XCTAssertEqual(decision.extraUsageUsedCredits, 3.20)
        XCTAssertEqual(decision.extraUsageMonthlyLimit, 2000)
    }

    func testOverQuotaCase3WhenNoCredits() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, change: change(from: .healthy, to: .overQuota, util: 106,
                                           extraEnabled: false))
        XCTAssertEqual(presenter.variants(.overQuota), ["case_3"])
    }

    // Step 21: the ceiling case — a healthy→over-quota transition at exactly 100% with no
    // credits fires the Path-1 over-quota notification with the case_3 ("Quota spent") variant,
    // just like a measured >100%. The variant keys off extra_usage, not the exact utilization.
    func testOverQuotaCase3AtExactly100() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, change: change(from: .healthy, to: .overQuota, util: 100,
                                           extraEnabled: false))
        XCTAssertEqual(presenter.count(.overQuota), 1)
        XCTAssertEqual(presenter.variants(.overQuota), ["case_3"])
    }

    func testTransitionCandidateCarriesSignalContext() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // Poll cycles hand the transition its same-cycle signal — project/model flow onto the
        // decision so the §4.2 "project name in body" rule has its input (STEP_27).
        let s = signal(state: .overQuota, util: 106, model: "claude-sonnet-4-6",
                       project: "/Users/u/kvotar")
        await cycle(engine, change: change(from: .healthy, to: .overQuota, util: 106),
                    signal: s)
        let decision = try XCTUnwrap(presenter.decisions.first { $0.eventType == .overQuota })
        XCTAssertEqual(decision.project, "/Users/u/kvotar")
        XCTAssertEqual(decision.model, "claude-sonnet-4-6")
    }

    func testMultiSurfaceCarriesSurfaceNames() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let s = signal(tool: .codex, state: .multiSurface, shortDelta: 12, surfaces: 2,
                       model: "gpt-5.5", surfaceNames: ["Desktop", "CLI"])
        await cycle(engine, signal: s)
        let decision = try XCTUnwrap(presenter.decisions.first { $0.eventType == .multiSurface })
        XCTAssertEqual(decision.surfaces, ["Desktop", "CLI"])
    }

    func testBadTimingFires() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, change: change(from: .healthy, to: .badTiming))
        XCTAssertEqual(presenter.count(.badTiming), 1)
    }

    func testSpendControlFires() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, change: change(tool: .codex, from: .healthy, to: .spendControl))
        XCTAssertEqual(presenter.count(.spendControl), 1)
    }

    func testAtRiskFirstFireThenCappedAtTwo() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // Three transitions into at-risk; window cap is 2.
        await cycle(engine, change: change(from: .healthy, to: .atRisk))
        await cycle(engine, change: change(from: .elevated, to: .atRisk))
        await cycle(engine, change: change(from: .elevated, to: .atRisk))
        XCTAssertEqual(presenter.count(.atRisk), 2)
    }

    // MARK: Path 2 — at-risk re-arm (Baseline §13.2, UI Spec §4)

    func testAtRiskRearmRequiresDismissAndLowRunway() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)

        await cycle(engine, change: change(from: .healthy, to: .atRisk))   // first fire
        // Runway < 10 but not yet dismissed → no re-arm.
        await cycle(engine, signal: signal(state: .atRisk, runway: 5))
        XCTAssertEqual(presenter.count(.atRisk), 1)

        await engine.markDismissed(tool: .claude, eventType: .atRisk, now: base)
        // Dismissed + runway < 10 → re-arm fires once.
        await cycle(engine, signal: signal(state: .atRisk, runway: 5))
        XCTAssertEqual(presenter.count(.atRisk), 2)
        XCTAssertTrue(presenter.variants(.atRisk).contains("rearm"))

        // Does not fire a second time.
        await cycle(engine, signal: signal(state: .atRisk, runway: 5))
        XCTAssertEqual(presenter.count(.atRisk), 2)
    }

    func testAtRiskRearmSuppressedWhenRunwayAbove10() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, change: change(from: .healthy, to: .atRisk))
        await engine.markDismissed(tool: .claude, eventType: .atRisk, now: base)
        await cycle(engine, signal: signal(state: .atRisk, runway: 20))
        XCTAssertEqual(presenter.count(.atRisk), 1)
    }

    // MARK: Path 2 — fast burn cooldown

    func testFastBurnObeysCooldown() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)

        await cycle(engine, signal: signal(state: .fastBurnSpike, shortDelta: 25, now: base))
        XCTAssertEqual(presenter.count(.fastBurnSpike), 1)

        // 5 min later — inside the 10-min cooldown → suppressed.
        await cycle(engine, signal: signal(state: .fastBurnSpike, shortDelta: 25,
                                       now: base.addingTimeInterval(300)))
        XCTAssertEqual(presenter.count(.fastBurnSpike), 1)

        // 10 min + 1s later — cooldown elapsed → fires again.
        await cycle(engine, signal: signal(state: .fastBurnSpike, shortDelta: 25,
                                       now: base.addingTimeInterval(601)))
        XCTAssertEqual(presenter.count(.fastBurnSpike), 2)
    }

    func testFastBurnBelowThresholdDoesNotFire() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, signal: signal(state: .elevated, shortDelta: 5))
        XCTAssertEqual(presenter.count(.fastBurnSpike), 0)
    }

    func testFastBurnCarriesModelForSpikeCopy() async throws {
        // STEP_26 — the detailed fast-burn copy: the active model from local attribution rides
        // the signal into the decision (previously always nil from the poll driver).
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, signal: signal(state: .fastBurnSpike, shortDelta: 25,
                                       model: "claude-sonnet-4-6", now: base))
        let decision = try XCTUnwrap(presenter.decisions.first { $0.eventType == .fastBurnSpike })
        XCTAssertEqual(decision.model, "claude-sonnet-4-6")
    }

    // MARK: Path 2 — off-machine sustained + cooldown

    func testOffMachineRequiresTwoSustainedPolls() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // Local activity observed but stale (>8 min before every poll) → confirmed idle (REV-23).
        let stale = base.addingTimeInterval(-600)
        // Poll 1 — rising + confirmed idle, but not yet sustained.
        await cycle(engine, signal: signal(state: .offMachineBurn, last2Delta: 3, lastActivity: stale,
                                       now: base))
        XCTAssertEqual(presenter.count(.offMachineBurn), 0)
        // Poll 2 — sustained → fires.
        await cycle(engine, signal: signal(state: .offMachineBurn, last2Delta: 3, lastActivity: stale,
                                       now: base.addingTimeInterval(60)))
        XCTAssertEqual(presenter.count(.offMachineBurn), 1)
        // Poll 3 — inside 20-min cooldown → suppressed.
        await cycle(engine, signal: signal(state: .offMachineBurn, last2Delta: 3, lastActivity: stale,
                                       now: base.addingTimeInterval(120)))
        XCTAssertEqual(presenter.count(.offMachineBurn), 1)
    }

    func testOffMachineDormantWhenLocalUnknown() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // nil last-activity = never observed = cannot confirm idle → never off-machine (REV-23).
        await cycle(engine, signal: signal(state: .elevated, last2Delta: 3, lastActivity: nil))
        await cycle(engine, signal: signal(state: .elevated, last2Delta: 3, lastActivity: nil,
                                       now: base.addingTimeInterval(60)))
        XCTAssertEqual(presenter.count(.offMachineBurn), 0)
    }

    func testOffMachineDormantWhileLocalActive() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // Recent local activity (a long turn writes no usage line yet the session is live): not idle.
        await cycle(engine, signal: signal(state: .offMachineBurn, last2Delta: 3,
                                       lastActivity: base.addingTimeInterval(-30), now: base))
        await cycle(engine, signal: signal(state: .offMachineBurn, last2Delta: 3,
                                       lastActivity: base.addingTimeInterval(30),
                                       now: base.addingTimeInterval(60)))
        XCTAssertEqual(presenter.count(.offMachineBurn), 0,
                       "recent local activity suppresses the off-machine notification (REV-23)")
    }

    // MARK: Path 2 — the 2026-09-03 episode replayed (STEP_170 pin, STEP_173)

    /// The alpha tester's Codex morning, poll for poll: `(offset, last2Delta, writeMark, tokenMark)`
    /// where the marks are the newest local write / newest token row known at that poll, as window
    /// offsets. Lifted from their 09-07 bundle — the same rows `OffMachineEstimatorTests`
    /// replays, reduced to the polls where the meter actually moved.
    ///
    /// Codex wrote no `token_count` until offset 8964, so the token clock is the one that called a
    /// working machine idle. `off_machine_burn` fired for real at offsets 7278, 8706 and 9963.
    private static let sept3Polls: [(offset: TimeInterval, delta: Double,
                                     write: TimeInterval?, token: TimeInterval?)] = [
        (7212, 2, 7188, nil), (7278, 3, 7277, nil), (7337, 1, 7323, nil), (7401, 2, 7389, nil),
        (7458, 2, 7458, nil), (7524, 4, 7524, nil), (7588, 6, 7560, nil), (7652, 3, 7652, nil),
        (7715, 3, 7704, nil), (7776, 3, 7770, nil), (8463, 1, 8418, nil), (8646, 2, 8640, nil),
        (8706, 2, 8669, nil), (8770, 1, 8669, nil), (8828, 2, 8827, nil), (8951, 1, 8880, nil),
        (9010, 4, 9006, 8964), (9069, 3, 9056, 9056), (9124, 2, 9123, 9056),
        (9183, 4, 9178, 9142), (9241, 3, 9226, 9226), (9292, 3, 9285, 9226),
        (9357, 4, 9340, 9308), (9474, 3, 9473, 9308), (9537, 2, 9528, 9308),
        (9603, 3, 9591, 9308), (9661, 2, 9643, 9308), (9717, 1, 9715, 9308),
        (9780, 3, 9777, 9308), (9900, 2, 9888, 9308), (9963, 2, 9949, 9308),
        (10022, 4, 10018, 10018), (10070, 3, 10068, 10018), (10134, 4, 10121, 10018),
        (10197, 2, 10178, 10018),
    ]

    /// Replays the episode on the clock the app read **before** STEP_170 — the last *token* row.
    /// Codex's write lag leaves that clock hours stale mid-session, so the machine reads confirmed
    /// idle and the alert fires at a user who is working. This is the defect, kept so the pin
    /// below cannot pass vacuously.
    func testSept3EpisodeFiresOffMachineOnTheTokenClock() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        for poll in Self.sept3Polls {
            await cycle(engine, signal: signal(tool: .codex, state: .offMachineBurn,
                                               last2Delta: poll.delta,
                                               lastActivity: poll.token.map(base.addingTimeInterval),
                                               now: base.addingTimeInterval(poll.offset)))
        }
        XCTAssertGreaterThan(presenter.count(.offMachineBurn), 0,
                             "the token clock is what fired three alerts at a working machine")
    }

    /// The pin. On the STEP_170 clock — the newest of {local write, token row} — every one of those
    /// polls has a file write seconds old, so the machine is never confirmed idle and the alert
    /// stays dormant across the whole episode.
    func testSept3EpisodeNeverFiresOffMachineOnTheLivenessClock() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        for poll in Self.sept3Polls {
            // The fused liveness value `AttributionEngine` now hands the coordinator.
            let liveness = [poll.write, poll.token].compactMap { $0 }.max()
            await cycle(engine, signal: signal(tool: .codex, state: .offMachineBurn,
                                               last2Delta: poll.delta,
                                               lastActivity: liveness.map(base.addingTimeInterval),
                                               now: base.addingTimeInterval(poll.offset)))
        }
        XCTAssertEqual(presenter.count(.offMachineBurn), 0,
                       "a growing session file is a live machine — no Elsewhere alert (STEP_170)")
    }

    // MARK: Path 2 — multi-surface (Codex only)

    func testMultiSurfaceFiresForCodex() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, signal: signal(tool: .codex, state: .multiSurface, shortDelta: 12,
                                       surfaces: 2))
        XCTAssertEqual(presenter.count(.multiSurface), 1)
    }

    func testMultiSurfaceIgnoredForClaude() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, signal: signal(tool: .claude, state: .elevated, shortDelta: 12, surfaces: 2))
        XCTAssertEqual(presenter.count(.multiSurface), 0)
    }

    // MARK: Path 2 — window reset pre/post

    func testWindowResetPreFiresWhenWarningAndCloseToReset() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // Poll 1 — in warning far from reset (arms the warning history).
        await cycle(engine, signal: signal(state: .atRisk, now: base))
        // Poll 2 — 20 min before reset, same window → pre fires.
        let nearReset = resetsAt.addingTimeInterval(-20 * 60)
        await cycle(engine, signal: signal(state: .atRisk, now: nearReset))
        XCTAssertEqual(presenter.count(.windowResetPre), 1)
    }

    func testWindowResetPostFiresAndRetainsPriorWindow() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let r1 = resetsAt
        let ws1 = NotificationEngine.windowStart(resetsAt: r1, windowSeconds: nil, now: base)

        // Fire an at-risk in window 1, then roll over to a fresh window 2.
        await cycle(engine, change: change(from: .healthy, to: .atRisk, reset: r1))
        await cycle(engine, signal: signal(state: .atRisk, reset: r1, now: base))

        let atReset = r1                                   // now == old reset instant
        let r2 = r1.addingTimeInterval(5 * 3600)           // new full window, > 4h30m out
        await cycle(engine, signal: signal(state: .healthy, reset: r2, now: atReset))

        XCTAssertEqual(presenter.count(.windowResetPost), 1)
        // Window 1's rows survive the rollover (learning substrate; §13.2 v5.17 — REV-42).
        let retained = try await store.countNotificationEvents(
            tool: .claude, eventType: .atRisk, windowStart: ws1)
        XCTAssertEqual(retained, 1)
    }

    /// A sub-second `resets_at` wobble (whole-second key flips back and forth) must not be mistaken
    /// for a window rollover — the post-reset notification must stay silent until the reset instant
    /// genuinely advances. Guards the regression that fired the "quota reset" banner every poll.
    func testWindowResetPostIgnoresSubSecondJitter() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // Reset far out (> 4h30m) so the post-reset guard would otherwise pass on a false rollover.
        let farReset = base.addingTimeInterval(5 * 3600)
        let jittered = farReset.addingTimeInterval(1)   // +1s → whole-second key differs by 1

        await cycle(engine, signal: signal(state: .healthy, reset: farReset, now: base))
        for i in 1...5 {                                // alternate the two adjacent second values
            let reset = i.isMultiple(of: 2) ? farReset : jittered
            await cycle(engine, signal: signal(state: .healthy, reset: reset,
                                           now: base.addingTimeInterval(Double(i) * 60)))
        }
        XCTAssertEqual(presenter.count(.windowResetPost), 0, "jitter must not fire post-reset")

        // A genuine +5h reset still rolls over and fires exactly once.
        let realReset = farReset.addingTimeInterval(5 * 3600)
        await cycle(engine, signal: signal(state: .healthy, reset: realReset, now: farReset))
        XCTAssertEqual(presenter.count(.windowResetPost), 1)
    }

    /// **Characterization, not a regression pin — this documents a defence the engine does not have.**
    ///
    /// The test above proves a *stationary* `resets_at` jittering ±1s stays silent. A **sliding**
    /// anchor is the opposite shape and defeats every guard at once (REV-57 §3): the advance is the
    /// poll gap itself, so `advance > minResetAdvanceForRollover` holds whenever the cadence exceeds
    /// 60s; a far-future reset satisfies `postResetGuardMin` trivially; and `windowStart` is derived
    /// from `resets_at`, so it slides too and the 1-per-window cap counts zero every time.
    ///
    /// The engine cannot fix this from here — 60s is correct for the wobble it was written for, and
    /// any threshold expressed in seconds loses to an anchor that tracks wall-clock. That is why the
    /// fix is upstream, in `CodexAccountAdapter`: the shape must never reach this engine. Asserting
    /// the misfire keeps the reasoning honest — if someone later "fixes" it here, this test says
    /// what they actually changed. The end-to-end proof that the adapter prevents it lives in
    /// `CodexAccountAdapterTests.testUnanchoredPollSequenceFiresNoResetNotifications`.
    func testSlidingResetAnchorDefeatsEveryGuard() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let thirtyDays: TimeInterval = 2_592_000
        let cadence: TimeInterval = 65          // 60s ± 5s jitter (§9) — just over the 60s guard

        // Four polls of the raw provider shape: reset always one full window-width from *now*.
        for i in 0..<4 {
            let pollAt = base.addingTimeInterval(Double(i) * cadence)
            await cycle(engine, signal: signal(state: .healthy, util: 0,
                                               reset: pollAt.addingTimeInterval(thirtyDays),
                                               now: pollAt))
        }

        // One per poll after the first (the first has no previous anchor to compare against).
        XCTAssertEqual(presenter.count(.windowResetPost), 3,
                       "a sliding anchor reads as a rollover on every poll — the storm, reproduced")
    }

    /// Continuity gate (docs/NOTIFICATIONS.md §5 Option A, live mis-fire 2026-07-13): a window
    /// observed open, then idle (null-window polls), then a fresh window when the user starts
    /// working. The stale `lastResetsAt` anchor makes the key change + reset advance both hold,
    /// but the previous poll saw no open window — a fresh start, not a reset. Must stay silent.
    func testWindowResetPostSuppressedOnFreshStartAfterIdle() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let r1 = resetsAt

        // Window 1 open, then the user goes idle — the endpoint degrades to the null-window shape.
        await cycle(engine, signal: signal(state: .healthy, util: 20, reset: r1, now: base))
        await cycle(engine, signal: nullWindowSignal(now: r1.addingTimeInterval(3600)))
        await cycle(engine, signal: nullWindowSignal(now: r1.addingTimeInterval(2 * 3600)))

        // The user starts working — a fresh 5-hour window opens.
        let workStart = r1.addingTimeInterval(3 * 3600)
        let r2 = workStart.addingTimeInterval(5 * 3600)
        await cycle(engine, signal: signal(state: .healthy, util: 0, reset: r2,
                                           now: workStart.addingTimeInterval(5 * 60)))
        XCTAssertEqual(presenter.count(.windowResetPost), 0,
                       "fresh start after idle must not read as a window reset")

        // A genuine rollover of the new window still fires — the gate is per-poll, not sticky.
        let r3 = r2.addingTimeInterval(5 * 3600)
        await cycle(engine, signal: signal(state: .healthy, util: 0, reset: r3, now: r2))
        XCTAssertEqual(presenter.count(.windowResetPost), 1)
    }

    /// App launched during idle: the first poll is null-window, so the first open window has
    /// neither a `lastResetsAt` anchor nor previous-poll continuity — no post-reset.
    func testWindowResetPostSuppressedWhenLaunchedDuringIdle() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, signal: nullWindowSignal(now: base))
        let r = base.addingTimeInterval(5 * 3600 + 600)
        await cycle(engine, signal: signal(state: .healthy, util: 0, reset: r,
                                           now: base.addingTimeInterval(600)))
        XCTAssertEqual(presenter.count(.windowResetPost), 0)
    }

    // MARK: Window reset event (§13.2 v5.17 — rows retained, in-memory state reset)

    func testHandleWindowResetRetainsPriorWindowRows() async throws {
        let store = try await makeStore()
        let (engine, _) = makeEngine(store)
        let currentWS = expectedWindowStart
        let oldWS = currentWS - NotificationEngine.fallbackWindowLength

        try await store.writeNotificationEvent(tool: .claude, eventType: .atRisk,
                                               firedAt: 1, windowStart: oldWS, copyVariant: nil)
        // Establish the current window in the engine, then reset.
        await cycle(engine, signal: signal(state: .healthy))
        await engine.handleWindowReset(.claude)

        // The prior window's history survives the reset (learning substrate; REV-42)…
        let old = try await store.countNotificationEvents(
            tool: .claude, eventType: .atRisk, windowStart: oldWS)
        XCTAssertEqual(old, 1, "windowReset must no longer delete notification_events rows")
        // …and stays invisible to the current window's enforcement.
        let current = try await store.countNotificationEvents(
            tool: .claude, eventType: .atRisk, windowStart: currentWS)
        XCTAssertEqual(current, 0)
    }

    // MARK: Launch into an existing warning state does not notify (UI Spec §4.2)

    func testLaunchIntoWarningDoesNotNotify() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let stateEngine = StateEngine()

        // First-ever evaluation lands directly in at-risk → StateEngine reports no transition,
        // so the cycle has no Path 1 candidate and nothing fires (UI Spec §4.2).
        let inputs = StateInputs(
            tool: .claude,
            snapshot: QuotaSnapshot(tool: .claude, primaryUsedPct: 90, primaryResetsAt: resetsAt,
                                    secondaryUsedPct: 10, secondaryResetsAt: nil,
                                    rateLimitReached: false, extraUsage: .disabled),
            health: .healthy,
            forecast: Forecast(tool: .claude, tier: .fullRunway, runwayMinutes: 5,
                               burnRatePerMin: 1, isEstimate: false, pollCount: 10),
            trigger: .poll, now: base)
        let evaluation = await stateEngine.evaluate(inputs)
        XCTAssertNil(evaluation.change, "first evaluation must not report a transition")

        await cycle(engine, change: evaluation.change)
        XCTAssertEqual(presenter.total, 0)
    }

    // MARK: STEP_28 — single delivery per cycle (Baseline §16, UI Spec §4.2 / D-11)

    func testSingleDeliveryPerCycleHighestPriorityWins() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // One cycle: over-quota transition (rank 1) + fast-burn-eligible signal (rank 4).
        await cycle(engine,
                    change: change(from: .atRisk, to: .overQuota, extraEnabled: true),
                    signal: signal(state: .overQuota, shortDelta: 25))

        XCTAssertEqual(presenter.total, 1, "at most one notification per evaluation cycle")
        XCTAssertEqual(presenter.count(.overQuota), 1)
        // The suppressed fast-burn candidate must not be persisted.
        let fastBurnRows = try await store.countNotificationEvents(
            tool: .claude, eventType: .fastBurnSpike, windowStart: expectedWindowStart)
        XCTAssertEqual(fastBurnRows, 0)
    }

    func testSuppressedCandidateStillEligibleNextCycle() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // Cycle 1: over-quota wins; fast-burn suppressed without consuming cap or cooldown.
        await cycle(engine,
                    change: change(from: .atRisk, to: .overQuota),
                    signal: signal(state: .overQuota, shortDelta: 25))
        XCTAssertEqual(presenter.count(.fastBurnSpike), 0)
        // Cycle 2, one poll later: fast-burn is the only candidate → fires immediately, no
        // cooldown carried over from the suppressed attempt.
        await cycle(engine, signal: signal(state: .overQuota, shortDelta: 25,
                                           now: base.addingTimeInterval(60)))
        XCTAssertEqual(presenter.count(.fastBurnSpike), 1)
    }

    func testFastBurnBeatsOffMachineAndMultiSurface() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // Poll 1 arms the off-machine sustained counter without any spike delta; poll 2 then has
        // fast-burn (4), off-machine (5), and multi-surface (6) all eligible in one cycle.
        // Stale local activity (>8 min) = confirmed idle, so off-machine is genuinely eligible (REV-23).
        let stale = base.addingTimeInterval(-600)
        await cycle(engine, signal: signal(tool: .codex, state: .elevated,
                                           last2Delta: 3, lastActivity: stale, now: base))
        XCTAssertEqual(presenter.total, 0)
        await cycle(engine, signal: signal(tool: .codex, state: .fastBurnSpike, shortDelta: 25,
                                           last2Delta: 3, lastActivity: stale, surfaces: 2,
                                           now: base.addingTimeInterval(60)))

        XCTAssertEqual(presenter.count(.fastBurnSpike), 1)
        XCTAssertEqual(presenter.count(.offMachineBurn), 0)
        XCTAssertEqual(presenter.count(.multiSurface), 0)
        XCTAssertEqual(presenter.total, 1)
    }

    func testTransitionWinsTieOverSignalCandidateOfEqualPriority() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // Arm the re-arm path: first at-risk fire, then dismissed.
        await cycle(engine, change: change(from: .healthy, to: .atRisk))
        await engine.markDismissed(tool: .claude, eventType: .atRisk, now: base)
        // One cycle offering both an at-risk transition (Path 1) and an eligible at-risk
        // re-arm (Path 2) — same rank 2; the transition (collected first) must win.
        await cycle(engine,
                    change: change(from: .elevated, to: .atRisk),
                    signal: signal(state: .atRisk, runway: 5))
        XCTAssertEqual(presenter.count(.atRisk), 2)
        XCTAssertEqual(presenter.variants(.atRisk), [nil, nil],
                       "tie must resolve to the transition candidate, not the re-arm variant")
    }

    func testFastBurnCappedAtTwoPerWindow() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // Three eligible spikes in one window, each past the 10-min cooldown → cap of 2 holds.
        await cycle(engine, signal: signal(state: .fastBurnSpike, shortDelta: 25, now: base))
        await cycle(engine, signal: signal(state: .fastBurnSpike, shortDelta: 25,
                                           now: base.addingTimeInterval(601)))
        await cycle(engine, signal: signal(state: .fastBurnSpike, shortDelta: 25,
                                           now: base.addingTimeInterval(1300)))
        XCTAssertEqual(presenter.count(.fastBurnSpike), 2)
    }

    func testMultiSurfaceCappedAtTwoPerWindow() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // Three eligible multi-surface cycles in one window, each past the 10-min cooldown →
        // cap of 2 holds (UI Spec §4 event 6 "Max per episode: 2").
        for offset in [0.0, 601, 1300] {
            await cycle(engine, signal: signal(tool: .codex, state: .multiSurface,
                                               shortDelta: 12, surfaces: 2,
                                               now: base.addingTimeInterval(offset)))
        }
        XCTAssertEqual(presenter.count(.multiSurface), 2)
    }

    func testRefireProducesSameStableRequestID() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        // Two fast-burn fires across the cooldown in the same window → identical stable IDs,
        // so macOS replaces the banner in place instead of stacking.
        await cycle(engine, signal: signal(state: .fastBurnSpike, shortDelta: 25, now: base))
        await cycle(engine, signal: signal(state: .fastBurnSpike, shortDelta: 25,
                                           now: base.addingTimeInterval(601)))
        let ids = presenter.decisions.filter { $0.eventType == .fastBurnSpike }
            .map { $0.stableRequestID }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 1, "same window → same stable ID")

        // A fire in the next window carries a different ID.
        let nextReset = resetsAt.addingTimeInterval(5 * 3600)
        await cycle(engine, signal: signal(state: .healthy, reset: nextReset, now: resetsAt))
        await cycle(engine, signal: signal(state: .fastBurnSpike, reset: nextReset,
                                           shortDelta: 25,
                                           now: resetsAt.addingTimeInterval(60)))
        let nextID = try XCTUnwrap(presenter.decisions.last {
            $0.eventType == .fastBurnSpike }?.stableRequestID)
        XCTAssertNotEqual(nextID, ids[0], "next window → different stable ID")
    }

    func testPostResetSuppressedWhenHigherPriorityWinsRolloverCycle() async throws {
        // STEP_28 accepted trade-off: if a higher-priority candidate is eligible in the exact
        // rollover cycle, the post-reset notification loses arbitration and — because rollover
        // is detected exactly once — never fires for that window.
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        await cycle(engine, signal: signal(state: .healthy, reset: resetsAt, now: base))
        // Rollover cycle also carries a fast-burn-eligible delta (cross-reset artifact).
        let nextReset = resetsAt.addingTimeInterval(5 * 3600)
        await cycle(engine, signal: signal(state: .healthy, reset: nextReset,
                                           shortDelta: 25, now: resetsAt))
        XCTAssertEqual(presenter.count(.fastBurnSpike), 1)
        XCTAssertEqual(presenter.count(.windowResetPost), 0,
                       "post-reset loses the rollover cycle and stays lost for the window")
        // Next poll: rollover flag gone; post-reset must not appear late.
        await cycle(engine, signal: signal(state: .healthy, reset: nextReset,
                                           now: resetsAt.addingTimeInterval(60)))
        XCTAssertEqual(presenter.count(.windowResetPost), 0)
    }

    // MARK: Window changed (UI Spec §4.1a — STEP_146)

    /// A poll that recorded a window fact fires one `window_changed`, carrying the fact, with no
    /// cap or cooldown to consult — and a restructuring (width change + window added in one poll)
    /// arrives as one fact, not two banners.
    func testWindowFactOnThePollSignalFiresWindowChangedOnce() async throws {
        let store = try await makeStore()
        let (engine, presenter) = makeEngine(store)
        let restructured = WindowFact(kind: .restructured, before: [604_800],
                                      after: [18_000, 604_800])
        let s = NotificationSignal(
            tool: .codex, state: .healthy, utilizationPct: 0, runwayMinutes: nil,
            resetsAt: resetsAt, primaryWindowSeconds: 18_000, windowFacts: [restructured],
            now: base)
        await cycle(engine, signal: s)
        XCTAssertEqual(presenter.count(.windowChanged), 1)
        XCTAssertEqual(presenter.decisions.last?.windowFact, restructured)
        XCTAssertEqual(presenter.decisions.last?.copyVariant, "restructured")
        // The next ordinary poll carries no fact and fires nothing.
        await cycle(engine, signal: signal(tool: .codex, state: .healthy, util: 1,
                                           now: base.addingTimeInterval(60)))
        XCTAssertEqual(presenter.count(.windowChanged), 1)
    }

    /// Over quota still wins the cycle (§16 rank 1); at risk loses to it (rank 3 vs 2). And no
    /// switch silences it: every group is off here and it still fires.
    func testWindowChangedRanksBelowOverQuotaAndAboveAtRiskAndHasNoSwitch() async throws {
        let store = try await makeStore()
        for group in NotificationGroup.allCases {
            try await store.writeSetting(key: group.settingsKey, value: "false")
        }
        let (engine, presenter) = makeEngine(store)
        let fact = WindowFact(kind: .removed, before: [18_000])
        let s = NotificationSignal(
            tool: .claude, state: .atRisk, utilizationPct: 90, runwayMinutes: 20,
            resetsAt: resetsAt, windowFacts: [fact], now: base)
        await cycle(engine, change: change(from: .healthy, to: .atRisk), signal: s)
        XCTAssertEqual(presenter.count(.windowChanged), 1)
        XCTAssertEqual(presenter.count(.atRisk), 0, "window changed outranks at risk")
    }

    // D-128 (STEP_226): a window reset tells the presenter, once, for that tool only.
    func testWindowResetTellsThePresenter() async throws {
        let presenter = MockPresenter()
        let engine = NotificationEngine(store: nil, presenter: presenter)
        await engine.handleWindowReset(.codex)
        XCTAssertEqual(presenter.resets, [.codex])
        XCTAssertEqual(presenter.total, 0)
    }
}
