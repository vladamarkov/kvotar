import XCTest
import GRDB
@testable import KvotarCore

private final class ShapePresenter: NotificationPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _decisions: [NotificationDecision] = []
    func present(_ decision: NotificationDecision) async {
        lock.withLock { _decisions.append(decision) }
    }
    var decisions: [NotificationDecision] { lock.withLock { _decisions } }
    var kinds: [NotificationEventType] { decisions.map(\.eventType) }
    func count(_ type: NotificationEventType) -> Int { kinds.filter { $0 == type }.count }
}

/// STEP_88 / REV-59 §5 (UI Spec D-60 / §4.1) — on the low-allowance Codex shape exactly one
/// notification kind survives: **Over quota**. At risk, Bad timing, Fast burn and Off-machine are
/// forecast- or rate-derived and have no inputs left; Multi-surface is rate-gated; Window reset is
/// suppressed by user ruling — on a 30-day window it fires once a month and carries nothing the
/// user can act on.
///
/// Also pins the constant that has always been wrong: `NotificationEngine.windowLength` was
/// hardcoded to five hours, and `windowStart` derives every per-window cap, cooldown key and
/// `stableRequestID` from it (REV-57 §3 guards 3/4, one layer down).
final class NotificationEngineLowAllowanceTests: XCTestCase {

    private var dbPath: String!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private static let thirtyDays = 30 * 86_400
    private static let fiveHours = 5 * 3_600

    /// Anchored three days into a 30-day window, so the reset is 27 days out — the live `go` shape.
    private var resetsAt: Date { base.addingTimeInterval(TimeInterval(Self.thirtyDays - 3 * 86_400)) }

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory().appending("kvotar-notif-shape-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    private func makeEngine() async throws -> (NotificationEngine, ShapePresenter) {
        let store = try SQLiteStore(path: dbPath)
        // STEP_144: Window reset defaults off; the shape tests below exercise its engine path.
        try await store.writeSetting(key: NotificationGroup.windowReset.settingsKey, value: "true")
        let presenter = ShapePresenter()
        return (NotificationEngine(store: store, presenter: presenter), presenter)
    }

    private func signal(
        state: AppState, util: Double?, reset: Date?, now: Date,
        windowSeconds: Int? = thirtyDays, lowAllowance: Bool = true,
        shortDelta: Double? = nil, last2Delta: Double? = nil,
        lastActivity: Date? = nil, surfaces: Int = 0
    ) -> NotificationSignal {
        NotificationSignal(
            tool: .codex, state: state, utilizationPct: util, runwayMinutes: nil,
            resetsAt: reset, primaryWindowSeconds: windowSeconds,
            isLowAllowanceShape: lowAllowance,
            utilDeltaShortWindow: shortDelta, fastBurnDelta: shortDelta, utilDeltaLast2Polls: last2Delta,
            lastLocalActivityAt: lastActivity, activeSurfaceBucketCount: surfaces,
            surfaces: surfaces > 1 ? ["IDE extension", "CLI"] : [], now: now)
    }

    private func blockChange(reset: Date?) -> StateChange {
        StateChange(tool: .codex, previous: .elevated, new: .overQuota, utilizationPct: 100,
                    resetsAt: reset, primaryWindowSeconds: Self.thirtyDays,
                    isLowAllowanceShape: true)
    }

    // MARK: The one surviving kind

    /// The blocked shape, arriving: fires once, and only this.
    func testBlockedPayloadFiresOverQuotaAndNothingElse() async throws {
        let (engine, presenter) = try await makeEngine()
        await engine.evaluateCycle(
            change: blockChange(reset: resetsAt),
            signal: signal(state: .overQuota, util: 100, reset: resetsAt, now: base),
            now: base)
        XCTAssertEqual(presenter.kinds, [.overQuota])
    }

    /// **The pre-fix failure.** The blocked window is not anchored — the provider sent no reset,
    /// which is the shape spike R2 has never let us capture cleanly. The cap then falls back to a
    /// clock bucket, and that bucket was five hours wide: the same unchanged block re-notified
    /// every five hours, 144 times over a 30-day window. Bucketing on the reported width makes the
    /// once-per-window cap mean what it says.
    func testUnanchoredBlockDoesNotReNotifyEveryFiveHours() async throws {
        let (engine, presenter) = try await makeEngine()
        await engine.evaluateCycle(change: blockChange(reset: nil),
                                   signal: signal(state: .overQuota, util: 100, reset: nil, now: base),
                                   now: base)
        let sixHoursLater = base.addingTimeInterval(6 * 3_600)
        await engine.evaluateCycle(
            change: blockChange(reset: nil),
            signal: signal(state: .overQuota, util: 100, reset: nil, now: sixHoursLater),
            now: sixHoursLater)
        XCTAssertEqual(presenter.count(.overQuota), 1,
                       "one block, one banner — the window did not roll over, only a five-hour bucket did")
    }

    /// The window key is the window's own start, not the start of some five-hour slice of it.
    /// Persisted to `notification_events.window_start` and carried in `stableRequestID`, so a
    /// wrong value is both a wrong cap and a corrupted substrate row.
    func testWindowStartUsesTheReportedWidth() {
        let ws = NotificationEngine.windowStart(resetsAt: resetsAt,
                                                windowSeconds: Self.thirtyDays, now: base)
        XCTAssertEqual(ws, Int(resetsAt.timeIntervalSince1970) - Self.thirtyDays)
    }

    /// Claude reports no width at all, and its windows genuinely are five hours — the constant
    /// survives as the documented fallback, not as an assumption about everyone.
    func testMissingWidthKeepsTheFiveHourFallback() {
        let ws = NotificationEngine.windowStart(resetsAt: resetsAt, windowSeconds: nil, now: base)
        XCTAssertEqual(ws, Int(resetsAt.timeIntervalSince1970) - Self.fiveHours)
    }

    // MARK: The five that go quiet

    /// A 45-point jump in two minutes is an ordinary turn on this meter, not a spike.
    func testFastBurnIsSilent() async throws {
        let (engine, presenter) = try await makeEngine()
        await engine.evaluateCycle(
            change: nil,
            signal: signal(state: .elevated, util: 70, reset: resetsAt, now: base, shortDelta: 45),
            now: base)
        XCTAssertTrue(presenter.decisions.isEmpty)
    }

    func testOffMachineIsSilent() async throws {
        let (engine, presenter) = try await makeEngine()
        for i in 0..<3 {
            let t = base.addingTimeInterval(Double(i) * 60)
            await engine.evaluateCycle(
                change: nil,
                signal: signal(state: .elevated, util: 70, reset: resetsAt, now: t,
                               last2Delta: 9, lastActivity: base.addingTimeInterval(-7_200)),
                now: t)
        }
        XCTAssertTrue(presenter.decisions.isEmpty)
    }

    func testMultiSurfaceIsSilent() async throws {
        let (engine, presenter) = try await makeEngine()
        await engine.evaluateCycle(
            change: nil,
            signal: signal(state: .elevated, util: 70, reset: resetsAt, now: base,
                           shortDelta: 19, surfaces: 2),
            now: base)
        XCTAssertTrue(presenter.decisions.isEmpty)
    }

    /// Post-reset on a 30-day window fires once a month and says nothing actionable (user ruling).
    func testWindowResetPostIsSilent() async throws {
        let (engine, presenter) = try await makeEngine()
        await engine.evaluateCycle(change: nil,
                                   signal: signal(state: .healthy, util: 90, reset: resetsAt, now: base),
                                   now: base)
        let after = base.addingTimeInterval(3 * 86_400)
        let newReset = resetsAt.addingTimeInterval(TimeInterval(Self.thirtyDays))
        await engine.evaluateCycle(change: nil,
                                   signal: signal(state: .healthy, util: 2, reset: newReset, now: after),
                                   now: after)
        XCTAssertTrue(presenter.decisions.isEmpty)
    }

    func testWindowResetPreIsSilent() async throws {
        let (engine, presenter) = try await makeEngine()
        let nearReset = base.addingTimeInterval(20 * 60)
        await engine.evaluateCycle(change: nil,
                                   signal: signal(state: .overQuota, util: 100, reset: nearReset, now: base),
                                   now: base)
        let later = base.addingTimeInterval(60)
        await engine.evaluateCycle(change: nil,
                                   signal: signal(state: .overQuota, util: 100, reset: nearReset, now: later),
                                   now: later)
        XCTAssertEqual(presenter.count(.windowResetPre), 0)
    }

    // MARK: The regression that matters — every other shape keeps the full set

    /// Same engine, same code path, a five-hour window: fast burn, multi-surface and the reset
    /// pair all still fire. This is the shared-file regression the step is most likely to break.
    func testFiveHourShapeKeepsFastBurn() async throws {
        let (engine, presenter) = try await makeEngine()
        let fiveHourReset = base.addingTimeInterval(3 * 3_600)
        await engine.evaluateCycle(
            change: nil,
            signal: signal(state: .elevated, util: 70, reset: fiveHourReset, now: base,
                           windowSeconds: Self.fiveHours, lowAllowance: false, shortDelta: 45),
            now: base)
        XCTAssertEqual(presenter.kinds, [.fastBurnSpike])
    }

    func testFiveHourShapeKeepsWindowResetPost() async throws {
        let (engine, presenter) = try await makeEngine()
        let firstReset = base.addingTimeInterval(3_600)
        await engine.evaluateCycle(
            change: nil,
            signal: signal(state: .healthy, util: 90, reset: firstReset, now: base,
                           windowSeconds: Self.fiveHours, lowAllowance: false),
            now: base)
        let after = base.addingTimeInterval(2 * 3_600)
        await engine.evaluateCycle(
            change: nil,
            signal: signal(state: .healthy, util: 2, reset: after.addingTimeInterval(5 * 3_600),
                           now: after, windowSeconds: Self.fiveHours, lowAllowance: false),
            now: after)
        XCTAssertEqual(presenter.count(.windowResetPost), 1)
    }

    // MARK: Window reset on Plus — un-muted by correcting the rule, not the mute list (STEP_101)

    /// **The un-mute is structural, and this pins it.** The suppression list above is unchanged:
    /// window reset is still off where the shape genuinely cannot carry a rate, which is the
    /// ruling as it was argued — *"on a 30-day window it fires once a month and carries nothing to
    /// act on"*. Plus escapes it by no longer being that shape, exactly as the §2.3 tier note
    /// stops lying without a second gate (REV-63 §5). One boolean, corrected at its source.
    ///
    /// Seven days, not five hours, is the point: a weekly reset is a normal planning event, and
    /// the Claude tab has always fired it, so this restores cross-tab consistency too.
    func testSevenDayWindowFiresWindowResetOnceTheRuleIsCorrect() async throws {
        let (engine, presenter) = try await makeEngine()
        let sevenDays = 7 * 86_400
        let firstReset = base.addingTimeInterval(3_600)
        await engine.evaluateCycle(
            change: nil,
            signal: signal(state: .healthy, util: 40, reset: firstReset, now: base,
                           windowSeconds: sevenDays, lowAllowance: false),
            now: base)
        let after = base.addingTimeInterval(2 * 3_600)
        await engine.evaluateCycle(
            change: nil,
            signal: signal(state: .healthy, util: 1,
                           reset: after.addingTimeInterval(TimeInterval(sevenDays)),
                           now: after, windowSeconds: sevenDays, lowAllowance: false),
            now: after)
        XCTAssertEqual(presenter.count(.windowResetPost), 1)
    }
}
