import XCTest
import GRDB
@testable import KvotarCore

/// One weekly from the fleet's stored history, hour by hour — the data is generated into
/// `WeeklyLadderReplayFixtures.swift` by `scripts/long_limit_replay.py --ladder-fixture`.
struct WeeklyLadderReplayWeek {
    /// The ladder's four rungs: event 10's two steps, then events 9 and 3.
    enum Rung: Equatable { case half, quarter, nearlySpent, spent }

    let name: String
    let tool: Tool
    let limit: BlockEpisode.Limit
    let resetsAt: Int
    let periodSeconds: Int
    /// The hour the replay script fires each rung, ascending.
    let expected: [(Rung, Int)]
    /// `(hour_start, used %)`, ascending.
    let hours: [(Int, Double)]
}

private final class LadderPresenter: NotificationPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _decisions: [NotificationDecision] = []
    func present(_ decision: NotificationDecision) async {
        lock.withLock { _decisions.append(decision) }
    }
    var decisions: [NotificationDecision] { lock.withLock { _decisions } }
    var kinds: [NotificationEventType] { decisions.map(\.eventType) }
    var steps: [String?] { decisions.filter { $0.eventType == .limitAheadOfPace }.map(\.copyVariant) }
}

/// STEP_232 — REV-106: every weekly warns on the way down, 50 → 25 → 10 → 0 % left — and
/// since STEP_238 the third mark is **15** on a seven-day primary, where that tab turns red.
///
/// The ladder is decided behind `WeeklyLadder.isEnabled` — off in STEP_232, **on since
/// STEP_233**. Every behavioural test here builds its engine with the switch stated rather
/// than inherited, and the last section runs the same inputs with it off and asserts that
/// nothing at all changes: that is what the revert would restore.
final class WeeklyLadderTests: XCTestCase {

    private var dbPath: String!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let week = 7.0 * 86_400

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory().appending("kvotar-ladder-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    // MARK: Builders

    private func makeEngine(_ store: SQLiteStore, ladder: Bool = true)
        -> (NotificationEngine, LadderPresenter) {
        let presenter = LadderPresenter()
        return (NotificationEngine(store: store, presenter: presenter,
                                   weeklyLadderEnabled: ladder), presenter)
    }

    /// A Claude-shaped account: a calm five-hour window over a weekly with no reported width.
    private func secondaryWeekly(tool: Tool = .claude, used: Double, elapsedFraction: Double,
                                 resetsAt: Date? = nil, now: Date? = nil,
                                 primaryUsed: Double = 20) -> QuotaSnapshot {
        let now = now ?? base
        return QuotaSnapshot(
            tool: tool, primaryUsedPct: primaryUsed,
            primaryResetsAt: now.addingTimeInterval(3600), primaryWindowSeconds: 18_000,
            secondaryUsedPct: used,
            secondaryResetsAt: resetsAt ?? now.addingTimeInterval(week * (1 - elapsedFraction)),
            rateLimitReached: false, extraUsage: .disabled)
    }

    /// The owner's shape: Codex Pro, one seven-day window and nothing else.
    private func primaryWeekly(used: Double, elapsedFraction: Double, resetsAt: Date? = nil,
                               now: Date? = nil) -> QuotaSnapshot {
        let now = now ?? base
        return QuotaSnapshot(
            tool: .codex, primaryUsedPct: used,
            primaryResetsAt: resetsAt ?? now.addingTimeInterval(week * (1 - elapsedFraction)),
            primaryWindowSeconds: QuotaSnapshot.weeklyPrimarySeconds,
            secondaryUsedPct: nil, secondaryResetsAt: nil,
            rateLimitReached: used >= 100, extraUsage: .disabled, planType: "pro")
    }

    /// What `PollCoordinator` builds from a fresh poll — the only thing that carries a weekly.
    private func signal(_ snapshot: QuotaSnapshot, state: AppState = .healthy,
                        now: Date? = nil) -> NotificationSignal {
        let now = now ?? base
        return NotificationSignal(
            tool: snapshot.tool, state: state, utilizationPct: snapshot.primaryUsedPct,
            runwayMinutes: nil, resetsAt: snapshot.primaryResetsAt,
            primaryWindowSeconds: snapshot.primaryWindowSeconds,
            isLowAllowanceShape: snapshot.isLowAllowanceShape,
            blockEpisode: snapshot.blockEpisode,
            longLimit: snapshot.longLimit(now: now),
            weekly: snapshot.weeklyForNotifications(now: now), now: now)
    }

    private func change(_ snapshot: QuotaSnapshot, from: AppState, to: AppState,
                        runway: Double? = nil, now: Date? = nil) -> StateChange {
        StateChange(tool: snapshot.tool, previous: from, new: to,
                    utilizationPct: snapshot.primaryUsedPct, runwayMinutes: runway,
                    resetsAt: snapshot.primaryResetsAt,
                    primaryWindowSeconds: snapshot.primaryWindowSeconds,
                    isLowAllowanceShape: snapshot.isLowAllowanceShape,
                    blockEpisode: snapshot.blockEpisode,
                    longLimit: snapshot.longLimit(now: now ?? base))
    }

    /// One fresh poll with no state change.
    private func poll(_ engine: NotificationEngine, _ snapshot: QuotaSnapshot,
                      state: AppState = .healthy, now: Date? = nil) async {
        await engine.evaluateCycle(change: nil, signal: signal(snapshot, state: state, now: now),
                                   now: now ?? base)
    }

    private func ladderKey(_ store: SQLiteStore, _ tool: Tool,
                           _ limit: BlockEpisode.Limit) async throws -> String? {
        try await store.readSetting(key: WeeklyLadder.settingsKey(tool: tool, limit: limit))
    }

    // MARK: Which window is the weekly (REV-106 §2.3)

    func testTheSecondaryIsTheWeeklyExactlyAsTheLongLimitAssessesIt() {
        let snapshot = secondaryWeekly(used: 60, elapsedFraction: 0.4)
        XCTAssertEqual(snapshot.weeklyForNotifications(now: base),
                       snapshot.longLimit(.secondary, now: base))
        XCTAssertEqual(snapshot.weeklyForNotifications(now: base)?.tier, .aheadOfPace)
    }

    func testASevenDayPrimaryIsTheWeekly() throws {
        let weekly = try XCTUnwrap(primaryWeekly(used: 50, elapsedFraction: 0.42)
            .weeklyForNotifications(now: base))
        XCTAssertEqual(weekly.limit, .primary)
        XCTAssertEqual(weekly.tier, .aheadOfPace)
        XCTAssertEqual(weekly.elapsedPct, 42, accuracy: 0.001)
        XCTAssertEqual(weekly.periodSeconds, 7 * 86_400)
    }

    /// The assessment is for §16 only: the strip, ranks 5b and 10, the reminder and every row
    /// read these three, and none of them may start seeing the primary.
    func testTheLongLimitReadersStillExcludeThePrimary() {
        let snapshot = primaryWeekly(used: 95, elapsedFraction: 0.42)
        XCTAssertEqual(snapshot.longLimitAssessments(now: base), [])
        XCTAssertEqual(snapshot.longLimitsRanked(now: base), [])
        XCTAssertNil(snapshot.longLimit(now: base))
    }

    func testOutOfScopeStaysOut() {
        // A monthly limit and no weekly at all.
        let monthly = QuotaSnapshot(
            tool: .claude, primaryUsedPct: nil, primaryResetsAt: nil,
            secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: false,
            monthlyLimit: MonthlyLimit(limitAmount: 100, usedAmount: 80, remainingPercent: 20,
                                       resetsAt: base.addingTimeInterval(20 * 86_400)))
        XCTAssertNil(monthly.weeklyForNotifications(now: base))

        // The 30-day low-allowance primary (REV-59): only Over quota fires there.
        let thirtyDay = QuotaSnapshot(
            tool: .codex, primaryUsedPct: 80,
            primaryResetsAt: base.addingTimeInterval(20 * 86_400),
            primaryWindowSeconds: 30 * 86_400,
            secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: false,
            extraUsage: .disabled, planType: "go")
        XCTAssertNil(thirtyDay.weeklyForNotifications(now: base))
        // …and a seven-day window on a low-allowance plan name is out by the same gate.
        let sevenDayGo = QuotaSnapshot(
            tool: .codex, primaryUsedPct: 80,
            primaryResetsAt: base.addingTimeInterval(4 * 86_400),
            primaryWindowSeconds: 7 * 86_400,
            secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: false,
            extraUsage: .disabled, planType: "go")
        XCTAssertNil(sevenDayGo.weeklyForNotifications(now: base))

        // An unanchored weekly: no reset, so no pace and no instance.
        let unanchored = QuotaSnapshot(
            tool: .codex, primaryUsedPct: 0, primaryResetsAt: nil,
            primaryWindowSeconds: 7 * 86_400,
            secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: false,
            extraUsage: .disabled, planType: "pro")
        XCTAssertNil(unanchored.weeklyForNotifications(now: base))

        // A per-model weekly allowance stops a model, not the account.
        let modelOnly = QuotaSnapshot(
            tool: .claude, primaryUsedPct: 20, primaryResetsAt: base.addingTimeInterval(3600),
            primaryWindowSeconds: 18_000, secondaryUsedPct: nil, secondaryResetsAt: nil,
            rateLimitReached: false,
            additionalRateLimits: [AdditionalRateLimit(
                id: nil, name: "Fable", usedPercent: 80,
                resetsAt: base.addingTimeInterval(4 * 86_400))])
        XCTAssertNil(modelOnly.weeklyForNotifications(now: base))

        // A five-hour primary with no secondary is not a weekly either.
        let fiveHourOnly = QuotaSnapshot(
            tool: .codex, primaryUsedPct: 80, primaryResetsAt: base.addingTimeInterval(3600),
            primaryWindowSeconds: 18_000, secondaryUsedPct: nil, secondaryResetsAt: nil,
            rateLimitReached: false)
        XCTAssertNil(fiveHourOnly.weeklyForNotifications(now: base))
    }

    // MARK: The step (REV-106 §2.1)

    func testTheStepIsHalfBelowTheSecondMarkAndQuarterFromIt() throws {
        func step(used: Double, elapsed: Double) -> WeeklyLadder.Step? {
            secondaryWeekly(used: used, elapsedFraction: elapsed)
                .weeklyForNotifications(now: base).flatMap(WeeklyLadder.step(for:))
        }
        XCTAssertEqual(step(used: 50, elapsed: 0.42), .half)
        XCTAssertEqual(step(used: 74.9, elapsed: 0.42), .half)
        XCTAssertEqual(step(used: 75, elapsed: 0.42), .quarter)
        XCTAssertEqual(step(used: 89.9, elapsed: 0.42), .quarter)
        XCTAssertNil(step(used: 90, elapsed: 0.42), "the red line is event 9's, not a step")
        XCTAssertNil(step(used: 49, elapsed: 0.2), "under the floor")
        XCTAssertEqual(StateEngine.weeklySecondNoticePct, 75)
    }

    /// STEP_238: a seven-day primary is nearly spent, for notifications, where its tab turns
    /// red — Bad timing's 85 — and the secondary weekly keeps 90.
    func testASevenDayPrimaryIsNearlySpentAtTheLineItsTabTurnsRedAt() throws {
        XCTAssertEqual(StateEngine.weeklyPrimaryNearlySpentPct, 85)
        XCTAssertEqual(StateEngine.weeklyPrimaryNearlySpentPct, StateEngine.badTimingUtil)
        XCTAssertEqual(StateEngine.longLimitNearlySpentPct, 90)

        func primary(_ used: Double, elapsed: Double = 0.42) -> LongLimitAssessment? {
            primaryWeekly(used: used, elapsedFraction: elapsed).weeklyForNotifications(now: base)
        }
        XCTAssertEqual(primary(84.9)?.tier, .aheadOfPace)
        XCTAssertEqual(primary(84.9).flatMap(WeeklyLadder.step(for:)), .quarter)
        XCTAssertEqual(primary(85)?.tier, .nearlySpent)
        XCTAssertNil(primary(85).flatMap(WeeklyLadder.step(for:)), "the red line is event 9's")
        XCTAssertEqual(primary(85, elapsed: 0.95)?.tier, .nearlySpent, "a position, whatever the pace")
        XCTAssertEqual(primary(99)?.tier, .nearlySpent)
        XCTAssertEqual(primary(100)?.tier, .spent)

        // The secondary weekly and its display readers did not move.
        let secondary = secondaryWeekly(used: 87, elapsedFraction: 0.42)
        XCTAssertEqual(secondary.weeklyForNotifications(now: base)?.tier, .aheadOfPace)
        XCTAssertEqual(secondary.longLimit(now: base)?.tier, .aheadOfPace)
    }

    /// The tester's 15 Sep week between 80 % and the red line: back on pace, so nothing.
    func testOnPaceAtSeventyFiveSendsNothing() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        await poll(engine, secondaryWeekly(used: 75, elapsedFraction: 0.70))
        await poll(engine, secondaryWeekly(used: 80, elapsedFraction: 0.75))
        XCTAssertEqual(presenter.kinds, [])
        let stored = try await ladderKey(store, .claude, .secondary)
        XCTAssertNil(stored)
    }

    // MARK: Priority, group, key shape

    func testEventTenSitsBelowBadTimingAndAboveFastBurnInTheAtRiskGroup() {
        XCTAssertGreaterThan(NotificationEventType.limitAheadOfPace.arbitrationPriority,
                             NotificationEventType.badTiming.arbitrationPriority)
        XCTAssertLessThan(NotificationEventType.limitAheadOfPace.arbitrationPriority,
                          NotificationEventType.fastBurnSpike.arbitrationPriority)
        XCTAssertEqual(NotificationEventType.limitAheadOfPace.group, .atRisk)
        XCTAssertTrue(NotificationGroup.atRisk.events.contains(.limitAheadOfPace))
        XCTAssertEqual(NotificationEventType.limitAheadOfPace.rawValue, "limit_ahead_of_pace")
    }

    func testTheKeyIsTheInstanceAndTheLowestStep() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        let snapshot = secondaryWeekly(used: 55, elapsedFraction: 0.40)
        await poll(engine, snapshot)

        XCTAssertEqual(presenter.steps, ["half"])
        XCTAssertEqual(presenter.decisions.first?.longLimit,
                       snapshot.weeklyForNotifications(now: base))
        let reset = Int(snapshot.secondaryResetsAt!.timeIntervalSince1970)
        let stored = try await ladderKey(store, .claude, .secondary)
        XCTAssertEqual(stored, "\(reset)|half")
    }

    func testEventTenFollowsTheAtRiskSwitch() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeSetting(key: NotificationGroup.atRisk.settingsKey, value: "false")
        let (engine, presenter) = makeEngine(store)
        await poll(engine, secondaryWeekly(used: 55, elapsedFraction: 0.40))
        XCTAssertEqual(presenter.kinds, [])
        let stored = try await ladderKey(store, .claude, .secondary)
        XCTAssertNil(stored, "a dropped group consumes nothing — re-enabling starts clean")
    }

    // MARK: Never overtaken (REV-106 §2.2)

    func testADeeperStepFollowsAndAShallowerOneNeverDoes() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        let reset = base.addingTimeInterval(week * 0.6)
        await poll(engine, secondaryWeekly(used: 55, elapsedFraction: 0.40, resetsAt: reset))
        await poll(engine, secondaryWeekly(used: 78, elapsedFraction: 0.40, resetsAt: reset))
        XCTAssertEqual(presenter.steps, ["half", "quarter"])
        // The reading falls back under the second mark, still off pace: nothing to catch up.
        await poll(engine, secondaryWeekly(used: 60, elapsedFraction: 0.40, resetsAt: reset))
        XCTAssertEqual(presenter.steps, ["half", "quarter"])
    }

    /// A first reading at 23 % left sends the quarter step alone.
    func testAFirstReadingPastTheSecondMarkSendsOnlyThatStep() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        let reset = base.addingTimeInterval(week * 0.6)
        await poll(engine, secondaryWeekly(used: 77, elapsedFraction: 0.40, resetsAt: reset))
        await poll(engine, secondaryWeekly(used: 60, elapsedFraction: 0.40, resetsAt: reset))
        XCTAssertEqual(presenter.steps, ["quarter"])
    }

    /// First reading at 92 %: nearly spent alone — and neither early step can follow it, on
    /// the persisted key (a relaunch) as well as in the process that saw it.
    func testAFirstReadingAtNinetyTwoSendsNearlySpentAlone() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        let reset = base.addingTimeInterval(week * 0.5)
        let red = secondaryWeekly(used: 92, elapsedFraction: 0.5, resetsAt: reset)
        await engine.evaluateCycle(
            change: change(red, from: .idleFallback, to: .limitNearlySpent),
            signal: signal(red, state: .limitNearlySpent), now: base)
        XCTAssertEqual(presenter.kinds, [.limitNearlySpent])

        // The provider lowers the reading inside the same week, still off pace.
        let lowered = secondaryWeekly(used: 80, elapsedFraction: 0.5, resetsAt: reset)
        await poll(engine, lowered)
        let (relaunched, relaunchedPresenter) = makeEngine(store)
        await poll(relaunched, lowered)
        XCTAssertEqual(presenter.kinds, [.limitNearlySpent])
        XCTAssertEqual(relaunchedPresenter.kinds, [])
    }

    /// The red line reached but not announced (the group was off) still closes the early steps
    /// for the process that saw it.
    func testTheRedLineReachedUnannouncedStillClosesTheEarlySteps() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writeSetting(key: NotificationGroup.atRisk.settingsKey, value: "false")
        let (engine, presenter) = makeEngine(store)
        let reset = base.addingTimeInterval(week * 0.5)
        await poll(engine, secondaryWeekly(used: 92, elapsedFraction: 0.5, resetsAt: reset),
                   state: .limitNearlySpent)
        try await store.writeSetting(key: NotificationGroup.atRisk.settingsKey, value: "true")
        await poll(engine, secondaryWeekly(used: 80, elapsedFraction: 0.5, resetsAt: reset))
        XCTAssertEqual(presenter.kinds, [])
    }

    // MARK: No repeat (REV-106 §2.2)

    func testARelaunchInsideASentStepSendsNothing() async throws {
        let store = try SQLiteStore(path: dbPath)
        let snapshot = secondaryWeekly(used: 55, elapsedFraction: 0.40)
        let (first, firstPresenter) = makeEngine(store)
        await poll(first, snapshot)
        XCTAssertEqual(firstPresenter.steps, ["half"])

        let (second, secondPresenter) = makeEngine(store)
        await poll(second, snapshot)
        XCTAssertEqual(secondPresenter.kinds, [])
    }

    func testAOneSecondResetWobbleIsTheSameWeek() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        let reset = base.addingTimeInterval(week * 0.6)
        await poll(engine, secondaryWeekly(used: 55, elapsedFraction: 0.40, resetsAt: reset))
        await poll(engine, secondaryWeekly(used: 56, elapsedFraction: 0.40,
                                           resetsAt: reset.addingTimeInterval(1)))
        XCTAssertEqual(presenter.steps, ["half"])
    }

    func testPaceRecoveringAndSlippingAgainSendsNothingNew() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        let reset = base.addingTimeInterval(week * 0.6)
        await poll(engine, secondaryWeekly(used: 55, elapsedFraction: 0.40, resetsAt: reset))
        // A day and a half on: 56 % used at 61 % of the week is on pace.
        let later = base.addingTimeInterval(week * 0.21)
        await poll(engine, secondaryWeekly(used: 56, elapsedFraction: 0, resetsAt: reset,
                                           now: later), now: later)
        // …and off pace again before the second mark.
        let slipped = base.addingTimeInterval(week * 0.22)
        await poll(engine, secondaryWeekly(used: 72, elapsedFraction: 0, resetsAt: reset,
                                           now: slipped), now: slipped)
        XCTAssertEqual(presenter.steps, ["half"])
    }

    /// A five-hour reset under the weekly changes `window_start` and nothing about the week.
    func testAFiveHourResetUnderTheWeeklySendsNothingNew() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        let reset = base.addingTimeInterval(week * 0.6)
        await poll(engine, secondaryWeekly(used: 55, elapsedFraction: 0.40, resetsAt: reset))
        let afterRollover = base.addingTimeInterval(5 * 3600)
        await poll(engine, secondaryWeekly(used: 56, elapsedFraction: 0, resetsAt: reset,
                                           now: afterRollover, primaryUsed: 2),
                   now: afterRollover)
        XCTAssertEqual(presenter.steps, ["half"])
    }

    /// A restored reading, a staleness evaluation and a JSONL delta all arrive with no signal —
    /// and only a signal carries a weekly.
    func testACycleWithoutAPollSignalNeverSendsAStep() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        let snapshot = secondaryWeekly(used: 55, elapsedFraction: 0.40)
        await engine.evaluateCycle(
            change: change(snapshot, from: .healthy, to: .limitAheadOfPace),
            signal: nil, now: base)
        await engine.evaluateCycle(change: nil, signal: nil, now: base)
        XCTAssertEqual(presenter.kinds, [])
        let stored = try await ladderKey(store, .claude, .secondary)
        XCTAssertNil(stored)
    }

    // MARK: Re-arm (REV-106 §2.2)

    func testANewInstanceStartsTheLadderAgain() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        let reset = base.addingTimeInterval(week * 0.6)
        await poll(engine, secondaryWeekly(used: 78, elapsedFraction: 0.40, resetsAt: reset))

        // The week resets; the old row is retired on the first poll past its reset.
        let nextWeek = reset.addingTimeInterval(3600)
        await poll(engine, secondaryWeekly(used: 1, elapsedFraction: 0, resetsAt:
                                            reset.addingTimeInterval(week), now: nextWeek),
                   now: nextWeek)
        let retired = try await ladderKey(store, .claude, .secondary)
        XCTAssertNil(retired, "a row about a week that has reset is retired")

        let midWeek = reset.addingTimeInterval(week * 0.4)
        await poll(engine, secondaryWeekly(used: 55, elapsedFraction: 0, resetsAt:
                                            reset.addingTimeInterval(week), now: midWeek),
                   now: midWeek)
        XCTAssertEqual(presenter.steps, ["quarter", "half"])
    }

    /// The provider ends the week early: a different anchor appears before the old one's reset
    /// (17 of the 23 Codex weeklies in the corpus ended this way).
    func testAnEarlyResetRearmsTheLadder() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        let reset = base.addingTimeInterval(week * 0.6)
        await poll(engine, secondaryWeekly(tool: .codex, used: 78, elapsedFraction: 0.40,
                                           resetsAt: reset))
        // Two days later, three days before the old reset, a new week is half spent already.
        let later = base.addingTimeInterval(2 * 86_400)
        let newReset = later.addingTimeInterval(week * 0.7)
        await poll(engine, secondaryWeekly(tool: .codex, used: 52, elapsedFraction: 0,
                                           resetsAt: newReset, now: later), now: later)
        XCTAssertEqual(presenter.steps, ["quarter", "half"])
        let stored = try await ladderKey(store, .codex, .secondary)
        XCTAssertEqual(stored, "\(Int(newReset.timeIntervalSince1970))|half")
    }

    // MARK: Arbitration (REV-106 §2.2, §2.7)

    /// A step that loses to a higher-priority event writes nothing and goes on the next poll.
    func testAStepThatLosesArbitrationIsSentOnTheNextPollAndNotBefore() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        let snapshot = secondaryWeekly(used: 55, elapsedFraction: 0.40, primaryUsed: 92)
        await engine.evaluateCycle(
            change: change(snapshot, from: .healthy, to: .atRisk, runway: 12),
            signal: signal(snapshot, state: .atRisk), now: base)
        XCTAssertEqual(presenter.kinds, [.atRisk])
        let afterLoss = try await ladderKey(store, .claude, .secondary)
        XCTAssertNil(afterLoss, "the loser wrote nothing")

        // The five-hour window is still At risk — the ladder reads the assessment, not the rank.
        let next = base.addingTimeInterval(120)
        await poll(engine, secondaryWeekly(used: 55, elapsedFraction: 0.40,
                                           resetsAt: snapshot.secondaryResetsAt, now: next,
                                           primaryUsed: 92),
                   state: .atRisk, now: next)
        XCTAssertEqual(presenter.kinds, [.atRisk, .limitAheadOfPace])
    }

    /// At risk is untouched on a seven-day primary: state, notification, priority.
    func testAtRiskStillFiresOnASevenDayPrimary() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        let snapshot = primaryWeekly(used: 80, elapsedFraction: 0.5)
        await engine.evaluateCycle(
            change: change(snapshot, from: .healthy, to: .atRisk, runway: 12),
            signal: signal(snapshot, state: .atRisk), now: base)
        XCTAssertEqual(presenter.kinds, [.atRisk])
    }

    // MARK: A seven-day primary (REV-106 §2.4)

    /// Event 2 is never sent on a seven-day primary. Since STEP_238 the poll that turns the
    /// tab red sends event 9 instead — one notice, with the red state, not five points later.
    func testBadTimingIsNotSentOnASevenDayPrimary() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        // On pace, so no step competes: 86 % used at 80 % of the week.
        let snapshot = primaryWeekly(used: 86, elapsedFraction: 0.80)
        // The transition arriving with no poll signal (a JSONL delta) carries no weekly.
        await engine.evaluateCycle(
            change: change(snapshot, from: .healthy, to: .badTiming), signal: nil, now: base)
        XCTAssertEqual(presenter.kinds, [])
        await engine.evaluateCycle(
            change: change(snapshot, from: .healthy, to: .badTiming),
            signal: signal(snapshot, state: .badTiming), now: base)
        XCTAssertEqual(presenter.kinds, [.limitNearlySpent])
        XCTAssertEqual(presenter.decisions.first?.longLimit?.limit, .primary)
    }

    func testBadTimingStillFiresOnAFiveHourPrimary() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        let snapshot = secondaryWeekly(used: 30, elapsedFraction: 0.5, primaryUsed: 88)
        await engine.evaluateCycle(
            change: change(snapshot, from: .healthy, to: .badTiming),
            signal: signal(snapshot, state: .badTiming), now: base)
        XCTAssertEqual(presenter.kinds, [.badTiming])
    }

    /// Event 9 on a seven-day primary: decided on the signal path, once per instance, under
    /// the `nearly_spent.*` family with the primary as the limit.
    func testNearlySpentOnASevenDayPrimaryFiresOncePerInstance() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store)
        let reset = base.addingTimeInterval(week * 0.2)
        // Under the line nothing is sent (on pace at 80 % of the week, so no early step either).
        await poll(engine, primaryWeekly(used: 84, elapsedFraction: 0, resetsAt: reset))
        XCTAssertEqual(presenter.kinds, [])
        // At it — 15 % left (STEP_238) — the notice goes once, and 90 % adds nothing.
        let snapshot = primaryWeekly(used: 85, elapsedFraction: 0, resetsAt: reset)
        await poll(engine, snapshot, state: .badTiming)
        await poll(engine, snapshot, state: .badTiming)
        await poll(engine, primaryWeekly(used: 92, elapsedFraction: 0, resetsAt: reset),
                   state: .badTiming)
        XCTAssertEqual(presenter.kinds, [.limitNearlySpent])
        XCTAssertEqual(presenter.decisions.first?.longLimit?.limit, .primary)
        let stored = try await store.readSetting(
            key: LongLimitAssessment.nearlySpentSettingsKey(tool: .codex, limit: .primary))
        XCTAssertEqual(stored, String(Int(reset.timeIntervalSince1970)))

        let (relaunched, relaunchedPresenter) = makeEngine(store)
        await poll(relaunched, snapshot, state: .badTiming)
        XCTAssertEqual(relaunchedPresenter.kinds, [])

        // The next week is its own instance.
        let nextWeek = reset.addingTimeInterval(week * 0.8)
        await poll(engine, primaryWeekly(used: 93, elapsedFraction: 0,
                                         resetsAt: reset.addingTimeInterval(week), now: nextWeek),
                   state: .badTiming, now: nextWeek)
        XCTAssertEqual(presenter.kinds, [.limitNearlySpent, .limitNearlySpent])
    }

    // MARK: The replayed weeks (REV-106 §4.3, §4.5)

    /// A week's reading at one of its recorded hours, in the account shape it came from. On a
    /// secondary weekly the five-hour window underneath is calm and rolls every five hours.
    private func snapshot(_ w: WeeklyLadderReplayWeek, hour: Int, used: Double) -> QuotaSnapshot {
        let reset = Date(timeIntervalSince1970: TimeInterval(w.resetsAt))
        if w.limit == .primary {
            return primaryWeekly(used: used, elapsedFraction: 0, resetsAt: reset)
        }
        return QuotaSnapshot(
            tool: w.tool, primaryUsedPct: 10,
            primaryResetsAt: Date(timeIntervalSince1970: TimeInterval((hour / 18_000 + 1) * 18_000)),
            primaryWindowSeconds: 18_000,
            secondaryUsedPct: used, secondaryResetsAt: reset,
            secondaryWindowSeconds: w.tool == .codex ? w.periodSeconds : nil,
            rateLimitReached: used >= 100, extraUsage: .disabled)
    }

    /// The state `StateEngine` would hold on that reading — enough of §13 to produce the
    /// transitions events 2, 3 and 9 ride on. The ladder itself needs none of it.
    private func state(_ snapshot: QuotaSnapshot, at now: Date) -> AppState {
        if snapshot.blockEpisode != nil { return .overQuota }
        if snapshot.primaryWindowSeconds == QuotaSnapshot.weeklyPrimarySeconds {
            return (snapshot.primaryUsedPct ?? 0) >= 85 ? .badTiming : .healthy
        }
        switch snapshot.longLimit(now: now)?.tier {
        case .nearlySpent?: return .limitNearlySpent
        case .aheadOfPace?: return .limitAheadOfPace
        default: return .healthy
        }
    }

    /// Every recorded hour of a week through the engine as one fresh poll each, returning what
    /// was delivered and the hour it was delivered in.
    private func replay(_ w: WeeklyLadderReplayWeek, _ engine: NotificationEngine,
                        _ presenter: LadderPresenter) async -> [(NotificationDecision, Int)] {
        var delivered: [(NotificationDecision, Int)] = []
        var previous = AppState.healthy
        for (hour, used) in w.hours {
            let now = Date(timeIntervalSince1970: TimeInterval(hour))
            let snapshot = snapshot(w, hour: hour, used: used)
            let current = state(snapshot, at: now)
            let seen = presenter.decisions.count
            await engine.evaluateCycle(
                change: current == previous ? nil
                    : change(snapshot, from: previous, to: current, now: now),
                signal: signal(snapshot, state: current, now: now), now: now)
            previous = current
            delivered += presenter.decisions.dropFirst(seen).map { ($0, hour) }
        }
        return delivered
    }

    private func rung(_ d: NotificationDecision) -> WeeklyLadderReplayWeek.Rung? {
        switch (d.eventType, d.copyVariant) {
        case (.limitAheadOfPace, "half"): return .half
        case (.limitAheadOfPace, "quarter"): return .quarter
        case (.limitNearlySpent, _): return .nearlySpent
        case (.overQuota, _): return .spent
        default: return nil
        }
    }

    /// Every named week: each rung once, at the hour the replay script names — which makes
    /// this a check of the script's transcription against the shipped rule, both ways.
    func testEveryReplayedWeekFiresEachRungOnceAtTheReplaysHour() async throws {
        for w in WeeklyLadderReplayWeek.all {
            let path = dbPath + "-" + w.name
            defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
            let (engine, presenter) = makeEngine(try SQLiteStore(path: path))
            let delivered = await replay(w, engine, presenter)

            XCTAssertEqual(delivered.count, w.expected.count,
                           "\(w.name): \(delivered.map { "\($0.0.eventType.rawValue)@\($0.1)" })")
            for (got, want) in zip(delivered, w.expected) {
                XCTAssertEqual(rung(got.0), want.0, w.name)
                XCTAssertEqual(got.1, want.1, "\(w.name) \(want.0)")
            }
        }
    }

    /// REV-106 §4.3's table, as numbers: hours from each early step to the first 100 % reading
    /// on the three weeks that ran out. Today's first notice came 6, 24 and 8 hours before it.
    func testTheThreeExhaustedWeeksLeadTheStopByDays() {
        func lead(_ w: WeeklyLadderReplayWeek, _ r: WeeklyLadderReplayWeek.Rung) -> Int? {
            guard let stop = w.expected.first(where: { $0.0 == .spent })?.1,
                  let at = w.expected.first(where: { $0.0 == r })?.1 else { return nil }
            return (stop - at) / 3600
        }
        let weeks: [WeeklyLadderReplayWeek] = [.testerClaude15Sep, .testerClaude22Sep, .testerCodex7Sep]
        XCTAssertEqual(weeks.map { lead($0, .half) }, [108, 64, 49])
        XCTAssertEqual(weeks.map { lead($0, .quarter) }, [84, 45, 25])
        XCTAssertEqual(weeks.map { lead($0, .nearlySpent) }, [6, 24, 8])
        for w in weeks {
            XCTAssertEqual(w.expected.map(\.0), [.half, .quarter, .nearlySpent, .spent], w.name)
        }
    }

    /// 20 Aug: 4 → 77 % inside the week's first four hours. Step 1's hour fell inside the
    /// grace, so the quarter step is sent without it. The week went on to 87 % — past the
    /// line its tab turns red at and short of 90 — so since STEP_238 nearly spent follows,
    /// 25 hours later, on a week the provider then ended early.
    func testTheTwentiethOfAugustJumpSendsTheQuarterStepThenNearlySpent() async throws {
        let w = WeeklyLadderReplayWeek.ownerCodex20Aug
        let peak = w.hours.map(\.1).max() ?? 0
        XCTAssertGreaterThanOrEqual(peak, 85)
        XCTAssertLessThan(peak, 90)
        let (engine, presenter) = makeEngine(try SQLiteStore(path: dbPath))
        let delivered = await replay(w, engine, presenter)
        XCTAssertEqual(delivered.map { $0.0.eventType }, [.limitAheadOfPace, .limitNearlySpent])
        XCTAssertEqual(presenter.steps, ["quarter"])
        XCTAssertEqual((delivered[1].1 - delivered[0].1) / 3600, 25)
    }

    /// The owner's open week, the notice whose absence started REV-106: half at 50 % used with
    /// 42 % of the week gone. Then the week is carried on by hand, as it went on 1–2 Oct: to
    /// 75 %, the quarter step; to 85 %, where the tab turns red and nearly spent speaks with it
    /// (STEP_238 — it used to wait for 90); and to 90 %, which adds nothing.
    func testTheOwnersOpenWeek() async throws {
        let w = WeeklyLadderReplayWeek.ownerCodexOpenWeek
        let (engine, presenter) = makeEngine(try SQLiteStore(path: dbPath))
        let delivered = await replay(w, engine, presenter)
        XCTAssertEqual(presenter.steps, ["half"])
        let half = try XCTUnwrap(delivered.first)
        XCTAssertEqual(half.1, 1_790_787_600, "17:00 UTC on 30 Sep — 19:00 CEST")
        XCTAssertEqual(half.0.longLimit?.usedPct, 50)
        XCTAssertEqual(half.0.longLimit?.elapsedPct ?? 0, 41.8, accuracy: 0.05)

        let reset = Date(timeIntervalSince1970: TimeInterval(w.resetsAt))
        let later = reset.addingTimeInterval(-week * 0.42)
        await poll(engine, primaryWeekly(used: 75, elapsedFraction: 0, resetsAt: reset),
                   now: later)
        XCTAssertEqual(presenter.steps, ["half", "quarter"])

        let atEightyFive = primaryWeekly(used: 85, elapsedFraction: 0, resetsAt: reset)
        let redAt = reset.addingTimeInterval(-week * 0.35)
        await engine.evaluateCycle(
            change: change(atEightyFive, from: .healthy, to: .badTiming, now: redAt),
            signal: signal(atEightyFive, state: .badTiming, now: redAt), now: redAt)
        XCTAssertEqual(presenter.kinds, [.limitAheadOfPace, .limitAheadOfPace, .limitNearlySpent])

        let atNinety = primaryWeekly(used: 90, elapsedFraction: 0, resetsAt: reset)
        let laterStill = redAt.addingTimeInterval(3600)
        await poll(engine, atNinety, state: .badTiming, now: laterStill)
        await poll(engine, atNinety, state: .badTiming, now: laterStill.addingTimeInterval(120))
        XCTAssertEqual(presenter.kinds, [.limitAheadOfPace, .limitAheadOfPace, .limitNearlySpent])
        XCTAssertEqual(presenter.steps, ["half", "quarter"])
    }

    // MARK: The switch (off in STEP_232, on since STEP_233)

    func testTheShippedSwitchIsOn() {
        XCTAssertTrue(WeeklyLadder.isEnabled)
    }

    /// Every replayed week with the switch off: no event 10, no key, and events 2, 3 and 9
    /// exactly as before — Bad timing on the seven-day primary, nearly spent and the block on
    /// the secondaries, at the same hours.
    func testWithTheSwitchOffNothingChanges() async throws {
        for w in WeeklyLadderReplayWeek.all {
            let path = dbPath + "-off-" + w.name
            defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
            let store = try SQLiteStore(path: path)
            let presenter = LadderPresenter()
            let engine = NotificationEngine(store: store, presenter: presenter,
                                            weeklyLadderEnabled: false)
            let delivered = await replay(w, engine, presenter)

            XCTAssertFalse(presenter.kinds.contains(.limitAheadOfPace), w.name)
            for limit in BlockEpisode.Limit.allCases {
                let stored = try await ladderKey(store, w.tool, limit)
                XCTAssertNil(stored, w.name)
            }
            if w.limit == .primary {
                let reachedBadTiming = w.hours.contains { $0.1 >= 85 }
                XCTAssertEqual(presenter.kinds, reachedBadTiming ? [.badTiming] : [], w.name)
                let nearlySpent = try await store.readSetting(
                    key: LongLimitAssessment.nearlySpentSettingsKey(tool: w.tool, limit: .primary))
                XCTAssertNil(nearlySpent, w.name)
            } else {
                let shipped = w.expected.filter { $0.0 == .nearlySpent || $0.0 == .spent }
                XCTAssertEqual(delivered.compactMap { rung($0.0) }, shipped.map(\.0), w.name)
                XCTAssertEqual(delivered.map(\.1), shipped.map(\.1), w.name)
            }
        }
    }

    /// The hand-built cases with the switch off: nothing fires and nothing is written.
    func testWithTheSwitchOffTheLadderWritesAndSendsNothing() async throws {
        let store = try SQLiteStore(path: dbPath)
        let (engine, presenter) = makeEngine(store, ladder: false)
        let reset = base.addingTimeInterval(week * 0.6)
        await poll(engine, secondaryWeekly(used: 55, elapsedFraction: 0.40, resetsAt: reset))
        await poll(engine, secondaryWeekly(used: 78, elapsedFraction: 0.40, resetsAt: reset))
        await poll(engine, primaryWeekly(used: 60, elapsedFraction: 0.40))
        await poll(engine, primaryWeekly(used: 92, elapsedFraction: 0.40), state: .badTiming)
        XCTAssertEqual(presenter.kinds, [])
        for tool in [Tool.claude, .codex] {
            for limit in BlockEpisode.Limit.allCases {
                let ladder = try await ladderKey(store, tool, limit)
                XCTAssertNil(ladder)
                let nearlySpent = try await store.readSetting(
                    key: LongLimitAssessment.nearlySpentSettingsKey(tool: tool, limit: limit))
                XCTAssertNil(nearlySpent)
            }
        }
        // Bad timing on a seven-day primary is still sent, as shipped.
        let snapshot = primaryWeekly(used: 86, elapsedFraction: 0.80)
        await engine.evaluateCycle(
            change: change(snapshot, from: .healthy, to: .badTiming),
            signal: signal(snapshot, state: .badTiming), now: base)
        XCTAssertEqual(presenter.kinds, [.badTiming])
    }
}
