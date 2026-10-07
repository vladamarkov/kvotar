import XCTest
import GRDB
@testable import KvotarCore

/// STEP_177 — the daily local report: one bounded read, project × per-event model grouping,
/// exact integer reconciliation, deterministic selection, and failed ≠ empty. Fixture idiom from
/// `HistoryReportReaderTests` (temp store, `writeTokenEvents`, a pricing bundle).
final class DailyLocalReportReaderTests: XCTestCase {

    private var dbPath: String!
    /// 2026-09-10 14:00:00 UTC; the calendar below is UTC so the day is 2026-09-10 00:00 → now.
    private let now = Date(timeIntervalSince1970: 1_789_048_800)
    private let dayStart = Date(timeIntervalSince1970: 1_788_998_400)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory().appending("kvotar-daily-test-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func pricingBundle() throws -> Bundle {
        let table = PricingTable(
            version: "1.0.0", updated: "2026-09-10",
            models: [
                "claude-fable-5-1": ModelPricing(inputPerMtok: 5.00, outputPerMtok: 25.00,
                                                 cacheCreationPerMtok: 6.25, cacheReadPerMtok: 0.125),
                "claude-sonnet-5": ModelPricing(inputPerMtok: 2.00, outputPerMtok: 10.00,
                                                cacheCreationPerMtok: 2.50, cacheReadPerMtok: 0.20),
            ],
            fallback: [
                "claude": ModelPricing(inputPerMtok: 3.00, outputPerMtok: 15.00,
                                       cacheCreationPerMtok: 3.75, cacheReadPerMtok: 0.30),
                "codex": ModelPricing(inputPerMtok: 2.00, outputPerMtok: 8.00,
                                      cacheCreationPerMtok: 0.50, cacheReadPerMtok: 0.50),
            ]
        )
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("daily-pricing-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(table).write(to: dir.appendingPathComponent("pricing.json"))
        return try XCTUnwrap(Bundle(url: dir))
    }

    /// `at` is seconds after local midnight (negative = yesterday).
    private func event(tool: Tool = .claude, session: String = "s1", key: String,
                       project: String? = "/u/proj-a", model: String? = "claude-fable-5-1",
                       at: TimeInterval, startedAt: TimeInterval? = nil,
                       input: Int = 1_000, output: Int = 100,
                       cacheCreation: Int = 0, cacheRead: Int = 0,
                       surface: String? = nil, originator: String? = nil) -> TokenEvent {
        TokenEvent(tool: tool, sessionId: session, project: project, model: model,
                   surfaceBucket: surface ?? (tool == .claude ? "Claude Code" : "Desktop"),
                   startedAt: dayStart.addingTimeInterval(startedAt ?? at),
                   inputTokens: input, outputTokens: output,
                   cacheCreationTokens: cacheCreation, cacheReadTokens: cacheRead,
                   recordedAt: dayStart.addingTimeInterval(at), dedupKey: key,
                   originator: originator)
    }

    private func makeEngine(_ events: [TokenEvent]) async throws -> (AttributionEngine, SQLiteStore) {
        let store = try SQLiteStore(path: dbPath)
        if !events.isEmpty { try await store.writeTokenEvents(events) }
        let engine = AttributionEngine(store: store, claude: NoopLocal(), codex: NoopLocal(),
                                       bundle: try pricingBundle())
        await engine.start()
        return (engine, store)
    }

    private func report(_ events: [TokenEvent], tool: Tool = .claude) async throws
        -> (DailyLocalReport, SQLiteStore) {
        let (engine, store) = try await makeEngine(events)
        let r = try await engine.dailyReport(for: tool, now: now, calendar: utc)
        await engine.stop()
        return (r, store)
    }

    // MARK: - The tester's ambiguity

    /// A big project on Fable all morning; a small project on Sonnet spoke last. The small one
    /// is the recency row, and each project keeps its own model — nothing relabels the other.
    func testLatestProjectMaySmallerAndEveryModelBelongsToItsOwnProject() async throws {
        let (r, _) = try await report([
            event(session: "a1", key: "a1", project: "/u/big", model: "claude-fable-5-1",
                  at: 10 * 3600, input: 900_000, output: 100_000),
            event(session: "a2", key: "a2", project: "/u/big", model: "claude-fable-5-1",
                  at: 11 * 3600, input: 50_000, output: 5_000),
            event(session: "b1", key: "b1", project: "/u/small", model: "claude-sonnet-5",
                  at: 13 * 3600 + 59 * 60, input: 8_000, output: 2_000),
        ])
        XCTAssertEqual(r.projects.map(\.name), ["/u/big", "/u/small"])
        XCTAssertEqual(r.projects[0].models.map(\.model), ["claude-fable-5-1"])
        XCTAssertEqual(r.projects[1].models.map(\.model), ["claude-sonnet-5"])
        XCTAssertEqual(r.projects[0].tokens, 1_055_000)
        XCTAssertEqual(r.projects[1].tokens, 10_000)
        XCTAssertEqual(r.sessionCount, 3)

        let sel = r.selection()
        XCTAssertEqual(sel.rows.map(\.name), ["/u/big", "/u/small"])
        XCTAssertEqual(sel.mostRecentIndex, 1)
        XCTAssertEqual(sel.moreCount, 0)
        XCTAssertEqual(r.lastEventAt, dayStart.addingTimeInterval(13 * 3600 + 59 * 60))
    }

    // MARK: - Reconciliation

    func testClaudeTotalsReconcileExactlyAcrossProjectsAndModels() async throws {
        let events = [
            event(session: "s1", key: "k1", project: "/u/a", model: "claude-fable-5-1", at: 3600,
                  input: 10, output: 20, cacheCreation: 30, cacheRead: 40),
            event(session: "s1", key: "k2", project: "/u/a", model: "claude-sonnet-5", at: 3700,
                  input: 1, output: 2, cacheCreation: 3, cacheRead: 4),
            event(session: "s2", key: "k3", project: "/u/b", model: "claude-fable-5-1", at: 3800,
                  input: 100, output: 200, cacheCreation: 300, cacheRead: 400),
            event(session: "s3", key: "k4", project: nil, model: nil, at: 3900,
                  input: 7, output: 7, cacheCreation: 7, cacheRead: 7),
        ]
        let (r, store) = try await report(events)
        // Every project (the `(no project)` row included) sums to the total.
        XCTAssertEqual(r.projects.reduce(0) { $0 + $1.tokens }, r.totalTokens)
        XCTAssertEqual(r.totalTokens, 100 + 10 + 1_000 + 28)
        // Each project's models sum to the project.
        for p in r.projects {
            XCTAssertEqual(p.models.reduce(0) { $0 + $1.tokens }, p.tokens, "\(p.name ?? "nil")")
        }
        // …and to the same figure the existing per-model read gives for the same span.
        let byModel = try await store.tokenTotalsByModel(tool: .claude, since: dayStart, until: now)
        XCTAssertEqual(DisplayedTokens.total(byModel, tool: .claude), r.totalTokens)
        XCTAssertEqual(r.cacheHitRatio, CacheHit.ratio(tool: .claude, totals: byModel))
        XCTAssertEqual(r.sessionCount, 3)
    }

    func testCodexTotalsUseInputPlusOutputAndCachedSubset() async throws {
        let events = [
            event(tool: .codex, session: "t1", key: "c1", project: "/u/x", model: "gpt-5.5",
                  at: 3600, input: 1_000, output: 100, cacheCreation: 900),   // cached ⊆ input
            event(tool: .codex, session: "t2", key: "c2", project: "/u/y", model: "gpt-5.5",
                  at: 3700, input: 500, output: 50, cacheCreation: 400),
        ]
        let (r, _) = try await report(events, tool: .codex)
        XCTAssertEqual(r.totalTokens, 1_650, "input + output only — the cached slice is inside input")
        XCTAssertEqual(r.cacheHitRatio.map { ($0 * 1000).rounded() / 1000 }, 0.867)
        XCTAssertEqual(r.sessionCount, 2)
    }

    func testTodayValueIsTheSumOfModelValuesOverTheSamePopulation() async throws {
        let (r, store) = try await report([
            event(session: "s1", key: "k1", project: "/u/a", model: "claude-fable-5-1", at: 3600,
                  input: 1_000_000, output: 100_000),
            event(session: "s2", key: "k2", project: "/u/b", model: "claude-sonnet-5", at: 3700,
                  input: 500_000, output: 50_000, cacheRead: 250_000),
        ])
        let engine = EstimatedValueEngine(store: store, bundle: try pricingBundle())
        await engine.loadPricingTable()
        let bounded = try await engine.value(for: .claude, from: dayStart, until: now)
        XCTAssertEqual(r.value, bounded, accuracy: 1e-9)
        XCTAssertEqual(r.projects.reduce(0) { $0 + $1.value }, r.value, accuracy: 1e-9)
        for p in r.projects {
            XCTAssertEqual(p.models.reduce(0) { $0 + $1.value }, p.value, accuracy: 1e-9)
        }
        XCTAssertGreaterThan(r.value, 0)
    }

    // MARK: - Boundaries

    func testPopulationIsHalfOpenAndExcludesFutureDatedEvents() async throws {
        let (r, _) = try await report([
            event(session: "y", key: "y", at: -1),                       // 23:59:59 yesterday
            event(session: "m", key: "m", at: 0),                        // 00:00:00 today
            event(session: "n", key: "n", at: 14 * 3600),                // exactly now — excluded
            event(session: "f", key: "f", at: 14 * 3600 + 60),           // future — excluded
        ])
        XCTAssertEqual(r.sessionCount, 1)
        XCTAssertEqual(r.totalTokens, 1_100)
        XCTAssertEqual(r.lastEventAt, dayStart)
    }

    func testSessionBegunYesterdayWithUsageTodayCountsOnce() async throws {
        let (r, _) = try await report([
            event(session: "old", key: "o1", at: -5 * 3600, startedAt: -6 * 3600),
            event(session: "old", key: "o2", at: 2 * 3600, startedAt: -6 * 3600),
            event(session: "old", key: "o3", at: 3 * 3600, startedAt: -6 * 3600),
        ])
        XCTAssertEqual(r.sessionCount, 1)
        XCTAssertEqual(r.totalTokens, 2_200, "only today's two events")
    }

    func testZeroUsagePlaceholderEarnsNoSessionNoRowNoModel() async throws {
        let (r, _) = try await report([
            event(session: "z", key: "z", project: "/u/z", model: nil, at: 3600,
                  input: 0, output: 0, cacheCreation: 0, cacheRead: 0),
        ])
        XCTAssertEqual(r.sessionCount, 0)
        XCTAssertTrue(r.projects.isEmpty)
        XCTAssertEqual(r.totalTokens, 0)
        XCTAssertNil(r.cacheHitRatio)
    }

    func testZeroDenominatorGivesUnknownCacheRatioNotZero() async throws {
        let (r, _) = try await report([
            event(session: "o", key: "o", at: 3600, input: 0, output: 500),
        ])
        XCTAssertNil(r.cacheHitRatio)
        XCTAssertEqual(r.totalTokens, 500)
    }

    // MARK: - Grouping

    func testASubfolderUsedTodayIsItsOwnRow() async throws {
        // The repo root was used yesterday; today's work sits in a subfolder. The subfolder is
        // its own row: a session stored elsewhere never changes a folder's identity.
        let (r, _) = try await report([
            event(session: "root", key: "r", project: "/u/repo", at: -3 * 3600),
            event(session: "sub", key: "s", project: "/u/repo/Packages/Core", at: 3600),
        ])
        XCTAssertEqual(r.projects.map(\.name), ["/u/repo/Packages/Core"])
        XCTAssertEqual(r.projects[0].tokens, 1_100, "yesterday's root event is not in today's total")
    }

    func testDuplicateBasenamesStayDistinctAndSharedModelRowsMerge() async throws {
        let (r, _) = try await report([
            event(session: "a", key: "a", project: "/a/kvotar", at: 3600),
            event(session: "b", key: "b", project: "/b/kvotar", at: 3700),
            event(session: "c", key: "c", project: "/a/kvotar", at: 3800),
        ])
        XCTAssertEqual(r.projects.map(\.name), ["/a/kvotar", "/b/kvotar"])
        XCTAssertEqual(r.projects[0].tokens, 2_200)
        XCTAssertEqual(r.projects[0].models.count, 1, "two sessions, one model ⇒ one model row")
        XCTAssertEqual(r.projects[0].latestEventAt, dayStart.addingTimeInterval(3800))
    }

    func testUnknownProjectAndUnknownModelRetainTheirTokens() async throws {
        let (r, _) = try await report([
            event(session: "u", key: "u", project: nil, model: nil, at: 3600, input: 42, output: 0),
            event(session: "t", key: "t", project: "/private/tmp/x", model: "claude-sonnet-5",
                  at: 3700, input: 8, output: 0),
        ])
        XCTAssertEqual(r.projects.count, 1, "temp trees and nil fold into one (no project) row")
        XCTAssertNil(r.projects[0].name)
        XCTAssertEqual(r.projects[0].tokens, 50)
        XCTAssertEqual(r.projects[0].models.map(\.model), [nil, "claude-sonnet-5"],
                       "Unknown model keeps its tokens and ranks by them")
        XCTAssertEqual(r.projects[0].models.map(\.tokens), [42, 8])
    }

    // MARK: - Selection

    private func project(_ name: String?, tokens: Int, at: TimeInterval) -> DailyLocalReport.Project {
        DailyLocalReport.Project(name: name, tokens: tokens,
                                 models: [.init(model: "m", tokens: tokens, value: 0)],
                                 latestEventAt: dayStart.addingTimeInterval(at), value: 0)
    }

    private func synthetic(_ projects: [DailyLocalReport.Project]) -> DailyLocalReport {
        DailyLocalReport(tool: .claude, dayStart: dayStart, readUntil: now,
                         totalTokens: projects.reduce(0) { $0 + $1.tokens },
                         sessionCount: projects.count, cacheHitRatio: nil, projects: projects,
                         lastEventAt: projects.map(\.latestEventAt).max(), value: 0)
    }

    func testSelectionOneTwoThreeAndMany() {
        let a = project("/a", tokens: 500, at: 100)
        let b = project("/b", tokens: 400, at: 200)
        let c = project("/c", tokens: 300, at: 900)
        let d = project("/d", tokens: 200, at: 50)
        let e = project(nil, tokens: 100, at: 10)

        let one = synthetic([a]).selection()
        XCTAssertEqual(one.rows.map(\.name), ["/a"]); XCTAssertEqual(one.moreCount, 0)
        XCTAssertEqual(one.mostRecentIndex, 0)

        let two = synthetic([a, b]).selection()
        XCTAssertEqual(two.rows.map(\.name), ["/a", "/b"]); XCTAssertEqual(two.moreCount, 0)
        XCTAssertEqual(two.mostRecentIndex, 1)

        let three = synthetic([a, b, c]).selection()
        XCTAssertEqual(three.rows.map(\.name), ["/a", "/b", "/c"], "newest third is appended")
        XCTAssertEqual(three.mostRecentIndex, 2); XCTAssertEqual(three.moreCount, 0)

        let many = synthetic([a, b, c, d, e]).selection()
        XCTAssertEqual(many.rows.map(\.name), ["/a", "/b", "/c"])
        XCTAssertEqual(many.moreCount, 2, "the (no project) row counts in the overflow")

        let newestInTop = synthetic([a, project("/b", tokens: 400, at: 950), c, d, e]).selection()
        XCTAssertEqual(newestInTop.rows.count, 2)
        XCTAssertEqual(newestInTop.mostRecentIndex, 1)
        XCTAssertEqual(newestInTop.moreCount, 3)

        XCTAssertEqual(synthetic([]).selection().rows.count, 0)
        XCTAssertNil(synthetic([]).selection().mostRecentIndex)
    }

    func testEqualRecencyBreaksByRankAndEqualTokensByName() async throws {
        // Equal tokens: sorted by canonical name, so the order is stable across reads.
        let (r, _) = try await report([
            event(session: "b", key: "b", project: "/u/b", at: 3600),
            event(session: "a", key: "a", project: "/u/a", at: 3600),
            event(session: "c", key: "c", project: "/u/c", at: 3600),
        ])
        XCTAssertEqual(r.projects.map(\.name), ["/u/a", "/u/b", "/u/c"])
        // All three share the same last event: the highest-ranked one is "most recent".
        let sel = r.selection()
        XCTAssertEqual(sel.rows.map(\.name), ["/u/a", "/u/b"])
        XCTAssertEqual(sel.mostRecentIndex, 0)
        XCTAssertEqual(sel.moreCount, 1)
    }

    // MARK: - Empty versus failed

    func testEmptySuccessfulReadIsAnEmptyReportNotAnError() async throws {
        let (r, _) = try await report([])
        XCTAssertTrue(r.isEmpty)
        XCTAssertNil(r.lastEventAt)
        XCTAssertNil(r.cacheHitRatio)
        XCTAssertEqual(r.value, 0)
        XCTAssertEqual(r.dayStart, dayStart)
        XCTAssertEqual(r.readUntil, now)
    }

    func testFailedReadThrowsInsteadOfReturningZeros() async throws {
        let (engine, store) = try await makeEngine([event(session: "s", key: "k", at: 3600)])
        // Pull the table out from under the reader — the one way to make a real read fail
        // without touching file permissions.
        try await store.withPool { pool in
            try pool.write { db in try db.execute(sql: "DROP TABLE local_usage_events") }
        }
        do {
            _ = try await engine.dailyReport(for: .claude, now: now, calendar: utc)
            XCTFail("a failed read must throw")
        } catch {
            // expected
        }
        await engine.stop()
    }

    func testReportStateExposesRetainedReportOnFailure() {
        let r = synthetic([project("/a", tokens: 1, at: 1)])
        XCTAssertNil(DailyLocalReportState.loading.report)
        XCTAssertEqual(DailyLocalReportState.available(r).report, r)
        XCTAssertEqual(DailyLocalReportState.unavailable(retained: r, failedAt: now).report, r)
        XCTAssertNil(DailyLocalReportState.unavailable(retained: nil, failedAt: now).report)
    }

    // MARK: - Helpers

    private struct NoopLocal: LocalAdapter {
        let tokenEvents = AsyncStream<[TokenEvent]> { $0.finish() }
        let deltaSignals = AsyncStream<LocalDeltaSignal> { $0.finish() }
        let localWrites = AsyncStream<Date> { $0.finish() }
        func startWatching() async {}
        func stopWatching() async {}
    }

    // MARK: STEP_197 — the day's work split by local app

    /// The shape the rows exist for: two Codex apps in a day, plus two helper threads Desktop
    /// spawned itself. Three stored buckets, **two** rows — a helper is not an app, it runs
    /// inside one (D-96), and its session carries that app's originator.
    func testCodexHelperThreadsCountInsideTheAppThatSpawnedThem() async throws {
        let events = [
            event(tool: .codex, session: "desk", key: "d1", model: "gpt-5.6-sol", at: 100,
                  input: 4_000, output: 0, surface: "Desktop", originator: "Codex Desktop"),
            event(tool: .codex, session: "sub1", key: "s1", model: "gpt-5.6-sol", at: 200,
                  input: 1_000, output: 0, surface: "Subagent · Bacon", originator: "Codex Desktop"),
            event(tool: .codex, session: "sub2", key: "s2", model: "gpt-5.6-sol", at: 300,
                  input: 500, output: 0, surface: "Subagent · Mill",
                  originator: "codex_work_desktop"),
            event(tool: .codex, session: "cli", key: "c1", model: "gpt-5.6-sol", at: 400,
                  input: 2_000, output: 0, surface: "CLI", originator: "codex-tui"),
        ]
        let (r, _) = try await report(events, tool: .codex)
        XCTAssertEqual(r.surfaces.map(\.bucket), ["Desktop", "CLI"])
        XCTAssertEqual(r.surfaces.map(\.tokens), [5_500, 2_000],
                       "Desktop carries its own subagents; both desktop originators are Desktop")
        XCTAssertEqual(r.surfaces.reduce(0) { $0 + $1.tokens }, r.totalTokens,
                       "the rows are the same events the projects sum, cut a second way")
        XCTAssertEqual(r.surfaces.first(where: { $0.bucket == "CLI" })?.latestEventAt,
                       dayStart.addingTimeInterval(400))
    }

    /// A helper whose originator maps nowhere is honest rather than tidy: its tokens land in a
    /// visible `Unknown` row, never dropped, so the rows still sum to the total.
    func testUnmappedCodexHelperLandsInUnknown() async throws {
        let events = [
            event(tool: .codex, session: "cli", key: "c1", model: "gpt-5.6-sol", at: 100,
                  input: 2_000, output: 0, surface: "CLI", originator: "codex-tui"),
            event(tool: .codex, session: "sub", key: "s1", model: "gpt-5.6-sol", at: 200,
                  input: 900, output: 0, surface: "Subagent · Ghost",
                  originator: "codex_work_mobile"),
        ]
        let (r, _) = try await report(events, tool: .codex)
        XCTAssertEqual(r.surfaces.map(\.bucket), ["CLI", "Unknown"])
        XCTAssertEqual(r.surfaces.reduce(0) { $0 + $1.tokens }, r.totalTokens)
    }

    /// Claude stores no originator and observes one surface by construction (REV-81), so its
    /// helpers fold to `Claude Code` — inventing an `Unknown` row for an ordinary subagent day
    /// would be the wrong kind of honest.
    func testClaudeHelpersFoldIntoClaudeCode() async throws {
        let events = [
            event(key: "m1", at: 100, input: 1_000, output: 0),
            event(session: "sub", key: "s1", at: 200, input: 400, output: 0,
                  surface: "Subagent · Explore"),
        ]
        let (r, _) = try await report(events)
        XCTAssertEqual(r.surfaces.map(\.bucket), ["Claude Code"])
        XCTAssertEqual(r.surfaces.first?.tokens, r.totalTokens)
    }

    /// Codex counts `input + output` here exactly as the project rows do — a cache column added
    /// to one cut and not the other would break the reconciliation the section relies on.
    func testSurfaceTokensFollowThePerToolDisplayRule() async throws {
        let events = [
            event(tool: .codex, session: "desk", key: "d1", model: "gpt-5.6-sol", at: 100,
                  input: 1_000, output: 200, cacheCreation: 700, cacheRead: 900,
                  surface: "Desktop", originator: "Codex Desktop"),
            event(tool: .codex, session: "cli", key: "c1", model: "gpt-5.6-sol", at: 200,
                  input: 300, output: 100, cacheCreation: 500, cacheRead: 400,
                  surface: "CLI", originator: "codex_exec"),
        ]
        let (r, _) = try await report(events, tool: .codex)
        XCTAssertEqual(r.surfaces.map(\.tokens), [1_200, 400])
        XCTAssertEqual(r.surfaces.reduce(0) { $0 + $1.tokens }, r.totalTokens)
    }
}
