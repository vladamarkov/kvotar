import XCTest
import GRDB
@testable import KvotarCore

/// Replay of the field episode this step exists for (STEP_193).
///
/// Source: the tester's bundle `Kvotar-diagnostics-20260908-0941-0.3.0-11-release` (Codex Plus,
/// build 11). Their weekly quota reached 100 % at 15:42Z on 4 Sep 2026 and stayed there until the
/// Monday reset at 06:55Z on 7 Sep. In that stretch the shipped build wrote **eleven**
/// `over_quota` rows — each under a different `window_start`, one per five-hour rollover
/// underneath the block — plus a twelfth for a genuinely separate primary block later on the
/// Monday, and flipped `over_quota ↔ idle_fallback` thirteen times as poll gaps carried the
/// primary's reset past.
///
/// **Read from `history_rollups`, not `quota_series`.** The step contract named the latter, but
/// this bundle is schema `v21`: `quota_series` there carries the primary window only (the
/// secondary columns arrive with `v24`/STEP_188), and `poll_snapshots` keeps two hours, which
/// leaves fifteen rows from the day the bundle was taken. `history_rollups` is permanent, hourly,
/// and carries both windows, both resets and both block flags — everything ranks 2 and 3 read.
///
/// The bundle lives outside the repository and carries a tester's data, so it is not committed and
/// this test is skipped unless it is present. It is replayed from a **copy**; the bundle file is
/// never opened in place. Run with:
///
///     KVOTAR_LIVE=1 KVOTAR_BUNDLE_DB=<path to the bundle's kvotar.db> swift test --filter BlockEpisodeReplayTests
final class BlockEpisodeReplayTests: XCTestCase {

    /// 4 Sep 05:33Z → 7 Sep 16:53Z — the block, the Monday reset, and the separate block after it.
    private static let episodeWindow = (start: 1_788_500_000, end: 1_788_800_000)

    /// One hour of the tester's history, as the account reported it.
    private struct Hour {
        let at: Date
        let snapshot: QuotaSnapshot
    }

    private func load(from path: String) throws -> [Hour] {
        let queue = try DatabaseQueue(path: path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT hour_start, primary_used_pct_last, primary_resets_at_last,
                       secondary_used_pct_last, secondary_resets_at_last,
                       rate_limit_reached_max, spend_control_reached_last
                  FROM history_rollups
                 WHERE tool = 'codex' AND hour_start BETWEEN ? AND ?
                 ORDER BY hour_start
                """, arguments: [Self.episodeWindow.start, Self.episodeWindow.end])
            .map { row in
                let date = { (seconds: Int?) in seconds.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
                return Hour(
                    // The rollup is an hour; its readings are placed at the hour's midpoint, which
                    // is the finest grain this evidence honestly supports.
                    at: Date(timeIntervalSince1970: TimeInterval(row["hour_start"] as Int) + 1800),
                    snapshot: QuotaSnapshot(
                        tool: .codex,
                        primaryUsedPct: row["primary_used_pct_last"],
                        primaryResetsAt: date(row["primary_resets_at_last"]),
                        secondaryUsedPct: row["secondary_used_pct_last"],
                        secondaryResetsAt: date(row["secondary_resets_at_last"]),
                        rateLimitReached: (row["rate_limit_reached_max"] as Int?).map { $0 != 0 },
                        spendControlReached: (row["spend_control_reached_last"] as Int?).map { $0 != 0 }))
            }
        }
    }

    func testTheTesterEpisodeSendsOneBannerPerBlock() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KVOTAR_LIVE"] == "1",
                          "set KVOTAR_LIVE=1 to replay the tester bundle")
        let path = ProcessInfo.processInfo.environment["KVOTAR_BUNDLE_DB"]
        try XCTSkipUnless(path != nil, "set KVOTAR_BUNDLE_DB to the tester bundle's kvotar.db")
        let source = NSString(string: path ?? "").expandingTildeInPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source),
                          "bundle not present at \(source)")

        // Never open the tester's file in place.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kvotar-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("bundle.db")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)

        let hours = try load(from: copy.path)
        XCTAssertGreaterThan(hours.count, 50, "the episode should span three days of hourly rollups")

        // A fresh store for the engines — the replay writes its own notification rows and settings,
        // never the tester's.
        let store = try SQLiteStore(path: scratch.appendingPathComponent("replay.db").path)
        let presenter = MockReplayPresenter()
        let stateEngine = StateEngine(store: nil)
        let notifications = NotificationEngine(store: store, presenter: presenter)

        var previous: AppState?
        var flips = 0
        var episodeKeys: Set<String> = []
        for hour in hours {
            let inputs = StateInputs(
                tool: .codex, snapshot: hour.snapshot, health: .healthy,
                forecast: Forecast(tool: .codex, tier: .unknown, runwayMinutes: nil,
                                   burnRatePerMin: nil, isEstimate: false, pollCount: 0),
                trigger: .poll, now: hour.at)
            let evaluation = await stateEngine.evaluate(inputs)
            if let key = evaluation.blockEpisode?.key { episodeKeys.insert(key) }
            if let from = previous {
                let flipped = (from == .overQuota && evaluation.state == .idleFallback)
                    || (from == .idleFallback && evaluation.state == .overQuota)
                if flipped { flips += 1 }
            }
            previous = evaluation.state
            let signal = NotificationSignal(
                tool: .codex, state: evaluation.state,
                utilizationPct: hour.snapshot.primaryUsedPct, runwayMinutes: nil,
                resetsAt: hour.snapshot.primaryResetsAt,
                blockEpisode: evaluation.blockEpisode, now: hour.at)
            await notifications.evaluateCycle(change: evaluation.change, signal: signal, now: hour.at)
        }

        // Two blocks in this stretch, and they are genuinely two: the weekly spent from 4 Sep to
        // the Monday reset, and a five-hour block later that Monday after the weekly had refilled.
        XCTAssertEqual(presenter.overQuotaCount, 2,
                       "one banner per block — the shipped build sent twelve here")
        // Two limits, not two keys: the provider wobbled the weekly's reset by a second inside the
        // block, so the raw keys are more numerous than the episodes — which is why the engine
        // compares them within `QuotaSnapshot.resetJitterTolerance` rather than by string.
        XCTAssertEqual(Set(episodeKeys.map { $0.split(separator: "|")[0] }), ["secondary", "primary"],
                       "the weekly is what was spent, and what the episode keys on")
        XCTAssertEqual(flips, 0,
                       "the block is held on the weekly's reset — the shipped build flipped to "
                       + "Idle thirteen times as the primary's reset passed in poll gaps")
    }
}

/// Lock-guarded rather than an actor, so the accessor is synchronous inside an assertion — the
/// same construction `NotificationEngineTests` uses.
private final class MockReplayPresenter: NotificationPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _fired: [NotificationEventType] = []
    func present(_ decision: NotificationDecision) async {
        lock.withLock { _fired.append(decision.eventType) }
    }
    var overQuotaCount: Int { lock.withLock { _fired.filter { $0 == .overQuota }.count } }
}
