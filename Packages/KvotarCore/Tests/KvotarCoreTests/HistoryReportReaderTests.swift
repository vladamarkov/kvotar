import XCTest
@testable import KvotarCore

/// STEP_109 — the History window's reader and its three store queries, over a real temp
/// `SQLiteStore` and a fixture pricing bundle (the `EstimatedValueEngineTests` idiom).
final class HistoryReportReaderTests: XCTestCase {

    private var dbPath: String!
    /// A fixed "now" so bucket boundaries are deterministic: 2026-08-16 12:00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_786_881_600)

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory().appending("kvotar-history-test-\(UUID().uuidString).db")
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
            version: "1.0.0", updated: "2026-06-08",
            models: [
                "claude-sonnet-4-6": ModelPricing(inputPerMtok: 3.00, outputPerMtok: 15.00,
                                                  cacheCreationPerMtok: 3.75, cacheReadPerMtok: 0.30),
                "claude-opus-4-8": ModelPricing(inputPerMtok: 15.00, outputPerMtok: 75.00,
                                                cacheCreationPerMtok: 18.75, cacheReadPerMtok: 1.50),
            ],
            fallback: ["codex": ModelPricing(inputPerMtok: 2.00, outputPerMtok: 8.00,
                                             cacheCreationPerMtok: 0.50, cacheReadPerMtok: 0.50)]
        )
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-pricing-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(table).write(to: dir.appendingPathComponent("pricing.json"))
        return try XCTUnwrap(Bundle(url: dir))
    }

    private func event(tool: Tool = .claude, session: String = "s1", key: String,
                       project: String? = "/u/proj-a", model: String? = "claude-sonnet-4-6",
                       daysAgo: Double, input: Int = 1_000, output: Int = 100,
                       cacheCreation: Int = 0, cacheRead: Int = 0) -> TokenEvent {
        TokenEvent(tool: tool, sessionId: session, project: project, model: model,
                   surfaceBucket: tool == .claude ? "Claude Code" : "Desktop",
                   startedAt: now.addingTimeInterval(-daysAgo * 86_400),
                   inputTokens: input, outputTokens: output,
                   cacheCreationTokens: cacheCreation, cacheReadTokens: cacheRead,
                   recordedAt: now.addingTimeInterval(-daysAgo * 86_400), dedupKey: key)
    }

    private func makeReader(_ events: [TokenEvent]) async throws -> (HistoryReportReader, SQLiteStore) {
        let store = try SQLiteStore(path: dbPath)
        if !events.isEmpty { try await store.writeTokenEvents(events) }
        let engine = EstimatedValueEngine(store: store, bundle: try pricingBundle())
        await engine.loadPricingTable()
        return (HistoryReportReader(store: store, valueEngine: engine), store)
    }

    // MARK: - Empty corpus

    func testEmptyCorpusYieldsEmptyReportNotZeros() async throws {
        let (reader, _) = try await makeReader([])
        let report = await reader.report(now: now)

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.tools.count, 2)
        for t in report.tools {
            XCTAssertTrue(t.isEmpty)
            XCTAssertNil(t.cacheHitRatio, "no denominator ⇒ nil, never a fabricated 0%")
            XCTAssertNil(t.evidenceFrom)
            XCTAssertTrue(t.projects.isEmpty)
            XCTAssertTrue(t.topSessions.isEmpty)
        }
        XCTAssertEqual(report.pricingVersion, "1.0.0")
    }

    // MARK: - Period + week buckets

    func testWeekBucketsAreFourFullWeeksPlusOnePartialNewestFirst() async throws {
        let (reader, _) = try await makeReader([
            event(key: "a", daysAgo: 1),    // week 0 (0–7d)
            event(key: "b", daysAgo: 10),   // week 1 (7–14d)
            event(key: "c", daysAgo: 29),   // partial (28–30d)
            event(key: "d", daysAgo: 31),   // outside the period entirely
        ])
        let report = await reader.report(now: now)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })

        XCTAssertEqual(claude.weeks.count, 5)
        XCTAssertEqual(claude.weeks.map(\.isPartial), [false, false, false, false, true])
        // Newest first, contiguous, and the partial one is exactly the 2-day remainder.
        XCTAssertEqual(claude.weeks[0].end, now)
        for i in 1..<claude.weeks.count {
            XCTAssertEqual(claude.weeks[i].end, claude.weeks[i - 1].start)
        }
        XCTAssertEqual(claude.weeks[4].end.timeIntervalSince(claude.weeks[4].start), 2 * 86_400, accuracy: 1)
        // Tokens land in the right buckets and the 31-day-old event is excluded.
        XCTAssertEqual(claude.weeks[0].tokens, 1_100)
        XCTAssertEqual(claude.weeks[1].tokens, 1_100)
        XCTAssertEqual(claude.weeks[2].tokens, 0)
        XCTAssertEqual(claude.weeks[4].tokens, 1_100)
        XCTAssertEqual(claude.totalTokens, 3_300)
        // Evidence reaches back to the oldest event, even the one outside the period.
        XCTAssertEqual(claude.evidenceFrom, now.addingTimeInterval(-31 * 86_400))
    }

    func testBusiestCompleteWeekIgnoresThePartialBucket() async throws {
        var events: [TokenEvent] = []
        for i in 0..<3 { events.append(event(key: "w0-\(i)", daysAgo: 1)) }               // 3,300 tokens
        for i in 0..<10 { events.append(event(key: "p-\(i)", daysAgo: 29)) }              // 11,000 in the partial
        let (reader, _) = try await makeReader(events)
        let report = await reader.report(now: now)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })

        XCTAssertEqual(claude.busiestCompleteWeek?.tokens, 3_300,
                       "the 11,000-token partial bucket must not win the comparison")
        XCTAssertEqual(claude.currentWeek?.tokens, 3_300)
    }

    // MARK: - Shared rules: cache hit and displayed tokens

    /// The case the `CacheHit` extraction exists for: a Codex period spanning the 2026-07-13
    /// storage-convention boundary holds rows with the cached count in `cache_read` *and* rows
    /// with it in `cache_creation`. Reading one column would halve the ratio.
    func testCodexCacheHitUnionsBothStorageConventionsAcrossThePeriod() async throws {
        let (reader, _) = try await makeReader([
            event(tool: .codex, session: "t1", key: "old", model: nil, daysAgo: 20,
                  input: 1_000, output: 10, cacheCreation: 0, cacheRead: 800),   // pre-boundary shape
            event(tool: .codex, session: "t2", key: "new", model: nil, daysAgo: 2,
                  input: 1_000, output: 10, cacheCreation: 800, cacheRead: 0),   // post-boundary shape
        ])
        let report = await reader.report(now: now)
        let codex = try XCTUnwrap(report.tools.first { $0.tool == .codex })

        XCTAssertEqual(try XCTUnwrap(codex.cacheHitRatio), 0.8, accuracy: 0.0001)
        // Codex displayed count is input + output — the cache columns are subsets, never added.
        XCTAssertEqual(codex.totalTokens, 2_020)
    }

    func testClaudeDisplayedTokensIncludeAllFourColumns() async throws {
        let (reader, _) = try await makeReader([
            event(key: "a", daysAgo: 1, input: 100, output: 50, cacheCreation: 20, cacheRead: 30),
        ])
        let report = await reader.report(now: now)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })
        XCTAssertEqual(claude.totalTokens, 200)
        XCTAssertEqual(try XCTUnwrap(claude.cacheHitRatio), 30.0 / 150.0, accuracy: 0.0001)
    }

    // MARK: - Project grouping (pure rules, dogfood-shaped paths)

    func testNonProjectDirectoriesAreRecognised() {
        for p in [nil, "", "/", "/tmp", "/private/tmp", "/tmp/kvotar-cli",
                  "/private/tmp/claude-501/-Users-x-kvotar/abc/scratchpad",
                  "/var/folders/ab/T/x", "/private/var/folders/ab/T/x",
                  "/Users/alice", "/home/alice"] {
            XCTAssertTrue(ProjectGrouping.isNonProject(p), "\(p ?? "nil") should be non-project")
        }
        for p in ["/Users/alice/Documents/programming/kvotar", "/Users/alice/.buzz",
                  "/Users/alice/tmp/thing", "/opt/work"] {
            XCTAssertFalse(ProjectGrouping.isNonProject(p), "\(p) is a project")
        }
    }

    func testEveryStoredFolderIsItsOwnProjectRow() {
        let repo = "/Users/v/Documents/programming/kvotar"
        // A sub-folder is its own row, never rolled into the repo above it.
        XCTAssertEqual(ProjectGrouping.canonical(repo + "/dist"), repo + "/dist")
        XCTAssertEqual(ProjectGrouping.canonical(repo + "/Packages/KvotarCore"), repo + "/Packages/KvotarCore")
        XCTAssertEqual(ProjectGrouping.canonical(repo), repo)
        // Siblings that merely share a name prefix stay separate.
        XCTAssertEqual(ProjectGrouping.canonical("/Users/v/Documents/programming/kvotar-sentinel"),
                       "/Users/v/Documents/programming/kvotar-sentinel")
        XCTAssertEqual(ProjectGrouping.canonical("/Users/v/Documents/programming/kvotar copy"),
                       "/Users/v/Documents/programming/kvotar copy")
        // The path is standardised, so one folder spelt two ways is one row.
        XCTAssertEqual(ProjectGrouping.canonical(repo + "/dist/../dist/"), repo + "/dist")
        // Non-projects → nil.
        XCTAssertNil(ProjectGrouping.canonical("/private/tmp"))
        XCTAssertNil(ProjectGrouping.canonical("/Users/v"))
        XCTAssertNil(ProjectGrouping.canonical(nil))
    }

    func testAContainerFolderSessionNeverAbsorbsTheReposBeneathIt() async throws {
        // The reported case: one session launched from ~/Documents, eight from a repo beneath it
        // with no sub-folder sessions of its own. The old longest-stored-root rule showed all
        // nine as `Documents`; now the container keeps its one-session row and the repo its own.
        let docs = "/Users/v/Documents"
        let repo = docs + "/programming/kvotar-public"
        var events: [TokenEvent] = []
        events.append(event(session: "docs", key: "d", project: docs, daysAgo: 20, input: 100))
        for i in 0..<8 {
            events.append(event(session: "repo-\(i)", key: "r\(i)", project: repo, daysAgo: 1, input: 1_000))
        }
        let (reader, _) = try await makeReader(events)
        let report = await reader.report(now: now)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })

        XCTAssertEqual(claude.projects.map(\.name), [repo, docs])
        XCTAssertEqual(claude.projects[0].sessions, 8, "kvotar-public: the rest")
        XCTAssertEqual(claude.projects[0].tokens, 8 * 1_100)
        XCTAssertEqual(claude.projects[1].sessions, 1, "Documents: the one container session")
        XCTAssertEqual(claude.projects[1].tokens, 200)
    }

    func testReaderGroupsProjectRowsBeforeTruncationAndLabelsSessionsTheSameWay() async throws {
        let repo = "/Users/v/Documents/programming/kvotar"
        var events: [TokenEvent] = []
        events.append(event(session: "root", key: "r", project: repo, daysAgo: 1, input: 1_000))
        events.append(event(session: "dist", key: "d", project: repo + "/dist", daysAgo: 1, input: 1_000))
        // Six distinct non-project folders: without pre-truncation grouping the top-5 cut would
        // drop some of them before they could fold into the one "(no project)" row.
        for (i, path) in ["/private/tmp", "/tmp/kvotar-cli", "/Users/v", "/home/v",
                          "/var/folders/ab/T/x", "/private/tmp/claude-501/scratchpad"].enumerated() {
            events.append(event(session: "np-\(i)", key: "n\(i)", project: path, daysAgo: 1, input: 50))
        }
        events.append(event(session: "other", key: "o", project: "/Users/v/other-repo", daysAgo: 1, input: 10))
        let (reader, _) = try await makeReader(events)
        let report = await reader.report(now: now)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })

        XCTAssertEqual(claude.projects.count, 4)
        let noProject = try XCTUnwrap(claude.projects.first { $0.name == nil })
        XCTAssertEqual(noProject.sessions, 6, "temp trees + home folders fold into one row")
        XCTAssertEqual(noProject.tokens, 6 * 150)
        // A sub-folder is its own row beside the repo root.
        XCTAssertEqual(claude.projects.filter { $0.name == repo || $0.name == repo + "/dist" }.count, 2)
        // Session labels use the same canonical project.
        let dist = try XCTUnwrap(claude.topSessions.first { $0.sessionId == "dist" })
        XCTAssertEqual(dist.project, repo + "/dist")
        // Nothing lost: grouped project tokens still sum to the period total.
        XCTAssertEqual(claude.projects.reduce(0) { $0 + $1.tokens }, claude.totalTokens)
    }

    // MARK: - Projects and sessions

    func testProjectRowsSumToPeriodTotalAndAreLargestFirst() async throws {
        let (reader, _) = try await makeReader([
            event(session: "s1", key: "a", project: "/u/small", daysAgo: 1),
            event(session: "s2", key: "b", project: "/u/big", daysAgo: 2),
            event(session: "s3", key: "c", project: "/u/big", daysAgo: 3),
            event(session: "s4", key: "d", project: nil, daysAgo: 4),
        ])
        let report = await reader.report(now: now)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })

        XCTAssertEqual(claude.projects.count, 3)
        XCTAssertEqual(claude.projects.first?.name, "/u/big")
        XCTAssertEqual(claude.projects.first?.sessions, 2)
        XCTAssertEqual(claude.projects.first?.tokens, 2_200)
        XCTAssertEqual(claude.projects.reduce(0) { $0 + $1.tokens }, claude.totalTokens)
        XCTAssertTrue(claude.projects.contains { $0.name == nil && $0.tokens == 1_100 },
                      "a nil project keeps its tokens — never dropped")
        XCTAssertEqual(claude.sessions, 4)
    }

    // MARK: - Per-day project rows (STEP_178 — the popover's `N more projects ›` destination)

    /// A day carries its own project rows, folded from a bounded hourly read on the caller's
    /// calendar and summing to that day's tokens by construction — which is what lets the
    /// popover's overflow count and this list agree.
    func testDayProjectRowsSumToTheDayAndAreLargestFirst() async throws {
        let (reader, _) = try await makeReader([
            event(session: "s1", key: "a", project: "/u/big", daysAgo: 1),
            event(session: "s2", key: "b", project: "/u/big", daysAgo: 1),
            event(session: "s3", key: "c", project: "/u/small", daysAgo: 1),
            event(session: "s4", key: "d", project: nil, daysAgo: 1),
            // A different day, so the day rows cannot be the period rows in disguise.
            event(session: "s5", key: "e", project: "/u/other", daysAgo: 4),
        ])
        let report = await reader.report(now: now)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })
        let calendar = Calendar.current
        let target = calendar.startOfDay(for: now.addingTimeInterval(-86_400))
        let day = try XCTUnwrap(claude.days.first { calendar.isDate($0.start, inSameDayAs: target) })

        XCTAssertEqual(day.projects.count, 3)
        XCTAssertEqual(day.projects.first?.project, "/u/big")
        XCTAssertEqual(day.projects.first?.tokens, 2_200)
        XCTAssertEqual(day.projects.reduce(0) { $0 + $1.tokens }, day.tokens,
                       "the day's project rows sum to the day")
        XCTAssertTrue(day.projects.contains { $0.project == nil && $0.tokens == 1_100 },
                      "a nil project keeps its tokens — never dropped")
        XCTAssertFalse(day.projects.contains { $0.project == "/u/other" },
                       "another day's work never leaks into this one")
    }

    /// The day rows are one per stored folder, the same basis the popover's own daily report
    /// uses (Baseline §15.2) — a sub-folder used today is its own row, whatever else is stored.
    func testDayProjectRowsAreOnePerStoredFolder() async throws {
        let (reader, _) = try await makeReader([
            // The repo root has its own stored session, outside the 30-day period.
            event(session: "old", key: "o", project: "/u/repo", daysAgo: 200),
            // Today, only a subfolder was used.
            event(session: "new", key: "n", project: "/u/repo/Packages/Core", daysAgo: 1),
        ])
        let report = await reader.report(now: now)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })
        let calendar = Calendar.current
        let target = calendar.startOfDay(for: now.addingTimeInterval(-86_400))
        let day = try XCTUnwrap(claude.days.first { calendar.isDate($0.start, inSameDayAs: target) })
        XCTAssertEqual(day.projects.map(\.project), ["/u/repo/Packages/Core"],
                       "a stored session elsewhere never changes a folder's row")
    }

    /// Session value is priced **per event model**, not at the session-level model (STEP_93):
    /// a session whose events split sonnet/opus must price each slice at its own rate.
    func testTopSessionsPricePerEventModelAndTruncateToLimit() async throws {
        var events: [TokenEvent] = []
        // One big mixed-model session: 1,000 in / 100 out on sonnet + the same on opus.
        events.append(event(session: "mixed", key: "m1", model: "claude-sonnet-4-6", daysAgo: 1))
        events.append(event(session: "mixed", key: "m2", model: "claude-opus-4-8", daysAgo: 1))
        // Six small single-event sessions — only five may survive, none of them the mixed one.
        for i in 0..<6 {
            events.append(event(session: "small-\(i)", key: "s\(i)", daysAgo: 2, input: 10, output: 1))
        }
        let (reader, _) = try await makeReader(events)
        let report = await reader.report(now: now)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })

        XCTAssertEqual(claude.topSessions.count, HistoryReport.topRowLimit)
        let top = try XCTUnwrap(claude.topSessions.first)
        XCTAssertEqual(top.sessionId, "mixed")
        XCTAssertEqual(top.tokens, 2_200)
        // sonnet: 1000×3 + 100×15 = 4,500 per Mtok → $0.0045; opus: 1000×15 + 100×75 = 22,500 → $0.0225
        XCTAssertEqual(top.value, 0.027, accuracy: 0.000_001)
        // The session-level `model` is last-non-null-wins and is display-only here.
        XCTAssertNotNil(top.model)
    }

    // MARK: - Store queries directly

    func testSessionTotalsLastSeenIsInsidePeriodAndOldestEventDateIsGlobal() async throws {
        let (_, store) = try await makeReader([
            event(session: "s1", key: "old", daysAgo: 40),   // outside the 30-day period
            event(session: "s1", key: "in", daysAgo: 5),
        ])
        let start = now.addingTimeInterval(-30 * 86_400)
        let rows = try await store.sessionTotals(tool: .claude, since: start, until: now)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.lastSeenAt, now.addingTimeInterval(-5 * 86_400))
        XCTAssertEqual(rows.first?.totals.inputTokens, 1_000, "the 40-day-old row is excluded")

        let oldestClaude = try await store.oldestEventDate(tool: .claude)
        XCTAssertEqual(oldestClaude, now.addingTimeInterval(-40 * 86_400))
        let oldestCodex = try await store.oldestEventDate(tool: .codex)
        XCTAssertNil(oldestCodex)
    }

    // MARK: - Events (poll-side substrate)

    func testEventsReadAccountChangesAndLimitHitsInsideThePeriodOnly() async throws {
        let (reader, store) = try await makeReader([event(key: "a", daysAgo: 1)])
        let day = 86_400.0
        // Two plan changes inside the period (oldest first on read), one outside.
        try await store.writeDiscontinuityEvents(
            tool: .codex, observedAt: now.addingTimeInterval(-40 * day),
            events: [.init(eventType: .planChanged, oldValue: "business", newValue: "free")])
        try await store.writeDiscontinuityEvents(
            tool: .codex, observedAt: now.addingTimeInterval(-20 * day),
            events: [.init(eventType: .planChanged, oldValue: "free", newValue: "go")])
        try await store.writeDiscontinuityEvents(
            tool: .codex, observedAt: now.addingTimeInterval(-4 * day),
            events: [.init(eventType: .planChanged, oldValue: "go", newValue: "plus"),
                     .init(eventType: .windowReset, windowType: "weekly", utilizationPct: 12)])
        // Three over_quota fires inside, one outside, one at_risk that must not count.
        for daysAgo in [3.0, 9.0, 25.0, 45.0] {
            try await store.writeNotificationEvent(
                tool: .codex, eventType: .overQuota,
                firedAt: Int(now.addingTimeInterval(-daysAgo * day).timeIntervalSince1970),
                windowStart: Int(now.addingTimeInterval(-daysAgo * day).timeIntervalSince1970) - 60,
                copyVariant: nil)
        }
        try await store.writeNotificationEvent(
            tool: .codex, eventType: .atRisk,
            firedAt: Int(now.addingTimeInterval(-2 * day).timeIntervalSince1970),
            windowStart: 0, copyVariant: nil)

        let report = await reader.report(now: now)
        let codex = try XCTUnwrap(report.tools.first { $0.tool == .codex })
        XCTAssertEqual(codex.accountChanges.map { "\($0.oldValue ?? "")→\($0.newValue ?? "")" },
                       ["free→go", "go→plus"])
        // `window_reset` is not one of the five kinds this block re-homes, so it is not read.
        XCTAssertEqual(codex.accountChanges.map(\.kind), [.planChanged, .planChanged])
        XCTAssertEqual(codex.limitHitCount, 3)
        XCTAssertEqual(codex.lastLimitHitAt, now.addingTimeInterval(-3 * day))
        // No rollups written in this fixture ⇒ no watching-since date; the formatter says so.
        XCTAssertNil(codex.watchingSince)
        // Claude untouched.
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })
        XCTAssertTrue(claude.accountChanges.isEmpty)
        XCTAssertEqual(claude.limitHitCount, 0)
    }

    /// The window facts join the plan changes in one list (D-81), and a flapping name pair is
    /// collapsed on the way out — the stored rows stay exactly where they are.
    func testAccountChangesCarryWindowFactsAndCollapseAFlappingPlanPair() async throws {
        let (reader, store) = try await makeReader([event(key: "a", daysAgo: 1)])
        let day = 86_400.0
        for i in 0..<6 {
            try await store.writeDiscontinuityEvents(
                tool: .codex, observedAt: now.addingTimeInterval(-20 * day + Double(i) * 70),
                events: [.init(eventType: .planChanged,
                               oldValue: i.isMultiple(of: 2) ? "enterprise" : "business",
                               newValue: i.isMultiple(of: 2) ? "business" : "enterprise")])
        }
        try await store.writeDiscontinuityEvents(
            tool: .codex, observedAt: now.addingTimeInterval(-10 * day),
            events: [.init(eventType: .windowWidthChanged, windowType: "5_day",
                           oldValue: "604800", newValue: "432000")])
        try await store.writeDiscontinuityEvents(
            tool: .codex, observedAt: now.addingTimeInterval(-2 * day),
            events: [.init(eventType: .planChanged, oldValue: "business", newValue: "free")])

        let report = await reader.report(now: now)
        let codex = try XCTUnwrap(report.tools.first { $0.tool == .codex })
        XCTAssertEqual(codex.accountChanges.map(\.kind), [.windowWidthChanged, .planChanged])
        XCTAssertEqual(codex.accountChanges.last?.newValue, "free")
        // Nothing was deleted: the substrate still holds every row the detector wrote.
        let stored = try await store.discontinuityEvents(
            tool: .codex, since: now.addingTimeInterval(-30 * day), until: now,
            types: ["plan_changed"])
        XCTAssertEqual(stored.count, 7)
    }

    // MARK: - Tokens per day (STEP_116)

    /// The strip's axis is the calendar, so every test here pins a zone explicitly — `.current`
    /// would make these pass or fail depending on where the machine is.
    private func calendar(_ zone: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        return cal
    }

    func testDaysCoverEveryLocalDayOfThePeriodOldestFirstWithAClippedFirstDay() async throws {
        let cal = calendar("UTC")
        let (reader, _) = try await makeReader([
            event(key: "a", daysAgo: 1), event(key: "b", daysAgo: 5),
        ])
        let report = await reader.report(now: now, calendar: cal)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })

        // 30×24 h from noon touches 31 local days: the first is a half-day sliver, not a day.
        XCTAssertEqual(claude.days.count, 31)
        XCTAssertEqual(claude.days.first?.start, report.periodStart)
        XCTAssertEqual(claude.days.first?.isPartial, true)
        XCTAssertEqual(claude.days.dropFirst().filter(\.isPartial).count, 0)
        XCTAssertEqual(claude.days.last?.start, cal.startOfDay(for: now))
        XCTAssertEqual(claude.days[1].start, cal.startOfDay(for: report.periodStart)
            .addingTimeInterval(86_400))
        XCTAssertEqual(claude.days.map(\.start), claude.days.map(\.start).sorted(),
                       "oldest first — the strip reads left to right")
    }

    func testDaySumsEqualThePeriodTotal() async throws {
        let cal = calendar("UTC")
        let (reader, _) = try await makeReader([
            event(key: "a", daysAgo: 0.2, input: 300, output: 40, cacheCreation: 90, cacheRead: 7),
            event(key: "b", daysAgo: 3.5, input: 1_000, output: 100),
            event(key: "c", daysAgo: 29.9, input: 5, output: 5),
            event(tool: .codex, session: "cx", key: "d", model: nil, daysAgo: 2,
                  input: 700, output: 60, cacheRead: 500),
        ])
        let report = await reader.report(now: now, calendar: cal)
        for t in report.tools {
            XCTAssertEqual(t.days.reduce(0) { $0 + $1.tokens }, t.totalTokens,
                           "the strip reads the same population as the period total, by construction")
        }
        // And therefore also to the weekly rows taken together. (Not to an *individual* week: the
        // week buckets are instant-based — `now − 7d` — and a day is a calendar day, so their
        // boundaries cross.)
        for t in report.tools {
            XCTAssertEqual(t.days.reduce(0) { $0 + $1.tokens },
                           t.weeks.reduce(0) { $0 + $1.tokens })
        }
    }

    func testADayWithNoWorkIsPresentWithZeros() async throws {
        let cal = calendar("UTC")
        let (reader, _) = try await makeReader([event(key: "a", daysAgo: 1)])
        let report = await reader.report(now: now, calendar: cal)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })

        let quiet = try XCTUnwrap(claude.days.first { $0.start == cal.startOfDay(
            for: now.addingTimeInterval(-10 * 86_400)) })
        XCTAssertEqual(quiet.tokens, 0)
        XCTAssertEqual(quiet.sessions, 0)
        XCTAssertFalse(quiet.hitLimit)
        XCTAssertEqual(claude.days.filter { $0.tokens > 0 }.count, 1)
    }

    func testASessionSpanningLocalMidnightCountsInBothDays() async throws {
        let cal = calendar("UTC")
        // 23:30 and 00:30 UTC either side of the Aug 15 → Aug 16 boundary, one session.
        let (reader, _) = try await makeReader([
            event(session: "night", key: "a", daysAgo: 12.5 / 24),
            event(session: "night", key: "b", daysAgo: 11.5 / 24),
        ])
        let report = await reader.report(now: now, calendar: cal)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })
        let busy = claude.days.filter { $0.sessions > 0 }

        XCTAssertEqual(busy.count, 2, "one session, two days — it was active in both")
        XCTAssertEqual(busy.map(\.sessions), [1, 1])
        XCTAssertEqual(busy.last?.start, cal.startOfDay(for: now))
    }

    func testLimitHitLandsOnItsOwnLocalDay() async throws {
        let cal = calendar("UTC")
        let (reader, store) = try await makeReader([event(key: "a", daysAgo: 1)])
        let hitAt = now.addingTimeInterval(-3 * 86_400)
        try await store.writeNotificationEvent(
            tool: .claude, eventType: .overQuota, firedAt: Int(hitAt.timeIntervalSince1970),
            windowStart: Int(hitAt.timeIntervalSince1970) - 60, copyVariant: nil)

        let report = await reader.report(now: now, calendar: cal)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })
        XCTAssertEqual(claude.days.filter(\.hitLimit).map(\.start), [cal.startOfDay(for: hitAt)])
        // The Events figures are derived from the same read and must not have moved.
        XCTAssertEqual(claude.limitHitCount, 1)
        XCTAssertEqual(claude.lastLimitHitAt, hitAt)
    }

    func testTheSameEventBucketsIntoADifferentDayInADifferentZone() async throws {
        // 00:30 UTC on Aug 16 is still Aug 15, 20:30 in New York.
        let events = [event(key: "a", daysAgo: 11.5 / 24)]
        let (reader, _) = try await makeReader(events)

        let utc = calendar("UTC")
        let ny = calendar("America/New_York")
        let inUTC = await reader.report(now: now, calendar: utc)
        let inNY = await reader.report(now: now, calendar: ny)

        let utcDay = try XCTUnwrap(inUTC.tools.first { $0.tool == .claude }?
            .days.first { $0.tokens > 0 })
        let nyDay = try XCTUnwrap(inNY.tools.first { $0.tool == .claude }?
            .days.first { $0.tokens > 0 })
        XCTAssertEqual(utcDay.start, utc.startOfDay(for: now))
        XCTAssertEqual(nyDay.start, ny.startOfDay(for: now.addingTimeInterval(-86_400)))
        // Both reports still account for every token — the day it lands on moved, nothing else.
        XCTAssertEqual(utcDay.tokens, nyDay.tokens)
    }

    func testTokenTotalsByModelSessionFilterScopesToOneSession() async throws {
        let (_, store) = try await makeReader([
            event(session: "s1", key: "a", daysAgo: 1),
            event(session: "s2", key: "b", daysAgo: 1, input: 5),
        ])
        let start = now.addingTimeInterval(-30 * 86_400)
        let all = try await store.tokenTotalsByModel(tool: .claude, since: start, until: now)
        let s2 = try await store.tokenTotalsByModel(tool: .claude, since: start, until: now, sessionId: "s2")
        XCTAssertEqual(all.reduce(0) { $0 + $1.inputTokens }, 1_005)
        XCTAssertEqual(s2.reduce(0) { $0 + $1.inputTokens }, 5)
    }

    // MARK: - STEP_114 — hourly totals and the work-per-1 % series

    func testHourlyTokenTotalsByModelBucketByUTCHourAndSumToPeriodTotal() async throws {
        // Two events 30 min apart inside one UTC hour, one more the next hour, another model.
        let (_, store) = try await makeReader([
            event(key: "a", daysAgo: 1.0),                                   // now − 24h
            event(key: "b", daysAgo: 1.0 - 1800.0 / 86_400),                 // + 30 min
            event(key: "c", model: "claude-opus-4-8", daysAgo: 1.0 - 3600.0 / 86_400,
                  input: 10, output: 1),
        ])
        let since = now.addingTimeInterval(-2 * 86_400)
        let hourly = try await store.hourlyTokenTotalsByModel(tool: .claude, since: since, until: now)
        let firstHour = Int(now.addingTimeInterval(-86_400).timeIntervalSince1970)
        XCTAssertEqual(hourly.count, 2)
        XCTAssertEqual(hourly[0].hourStart, Date(timeIntervalSince1970: TimeInterval(firstHour - firstHour % 3600)))
        XCTAssertEqual(hourly[0].totals.model, "claude-sonnet-4-6")
        XCTAssertEqual(hourly[0].totals.inputTokens, 2_000, "both events in the hour fold together")
        XCTAssertEqual(hourly[1].totals.model, "claude-opus-4-8")
        let whole = try await store.tokenTotalsByModel(tool: .claude, since: since, until: now)
        XCTAssertEqual(hourly.map(\.totals.inputTokens).reduce(0, +),
                       whole.map(\.inputTokens).reduce(0, +))
    }

    func testWorkPerPercentSeriesIsPopulatedFromRollupsLocalWorkAndMarkers() async throws {
        // A weekly window climbing 10 → 20 → 30 across three hours a day ago; sonnet events in the
        // second and third hours; one plan change inside the span and one window fact.
        let h0 = Int(now.addingTimeInterval(-86_400).timeIntervalSince1970)
        let hourStart = h0 - h0 % 3600
        let (reader, store) = try await makeReader([
            event(key: "a", daysAgo: Double(Int(now.timeIntervalSince1970) - (hourStart + 3600 + 60)) / 86_400,
                  input: 1_000_000, output: 0),
            event(key: "b", daysAgo: Double(Int(now.timeIntervalSince1970) - (hourStart + 7200 + 60)) / 86_400,
                  input: 1_000_000, output: 0),
        ])
        let anchor = hourStart + 5 * 86_400
        try await store.withPool { pool in
            try pool.write { db in
                for (i, pct) in [10.0, 20.0, 30.0].enumerated() {
                    try db.execute(sql: """
                        INSERT INTO poll_snapshots (tool, polled_at, primary_used_pct,
                            secondary_used_pct, secondary_resets_at)
                        VALUES ('claude', ?, NULL, ?, ?)
                        """, arguments: [hourStart + i * 3600 + 120, pct, anchor])
                }
                // The latest row per tool is retention-exempt (never rolled up) — give the
                // cleanup a newer one to hold so the three above all reach `history_rollups`.
                try db.execute(sql: """
                    INSERT INTO poll_snapshots (tool, polled_at, primary_used_pct,
                        secondary_used_pct, secondary_resets_at)
                    VALUES ('claude', ?, NULL, 31, ?)
                    """, arguments: [Int(Date().timeIntervalSince1970), anchor])
            }
        }
        try await store.runRetentionCleanup()
        try await store.writeDiscontinuityEvents(
            tool: .claude, observedAt: Date(timeIntervalSince1970: TimeInterval(hourStart + 4000)),
            events: [DiscontinuityObservation(eventType: .planChanged, oldValue: "pro", newValue: "max"),
                     DiscontinuityObservation(eventType: .windowRemoved, windowType: "five_hour",
                                              oldValue: "18000", newValue: nil, utilizationPct: 40)])

        let report = await reader.report(now: now)
        let claude = report.tools.first { $0.tool == .claude }!
        let series = claude.workPerPercent
        XCTAssertEqual(series.slots.count, 1)
        let weekly = series.slots[0]
        XCTAssertFalse(weekly.isPrimary)
        XCTAssertEqual(weekly.windowSeconds, 604_800)
        XCTAssertEqual(weekly.points.count, 1)
        let point = weekly.points[0]
        XCTAssertEqual(point.deltaPct, 20)
        // 2 M input tokens of sonnet at $3/Mtok = $6 → $0.30 per 1 %.
        XCTAssertEqual(point.dollars, 6, accuracy: 1e-9)
        XCTAssertEqual(point.dollarsPerPct!, 0.3, accuracy: 1e-9)
        XCTAssertEqual(point.tokens, 2_000_000)
        XCTAssertEqual(point.perModel.map(\.model), ["claude-sonnet-4-6"])
        XCTAssertFalse(point.isComplete)
        XCTAssertEqual(series.markers.map(\.eventType), ["plan_changed", "window_removed"])
        let codex = report.tools.first { $0.tool == .codex }!
        XCTAssertTrue(codex.workPerPercent.isEmpty)
    }

    // MARK: - Limit blocks (REV-73 / D-80 — STEP_120)

    /// A rollup hour, with only the columns the block derivation reads.
    private func limitRollup(hourStart: Int, pMax: Double?, pLast: Double?, reset: Int?,
                             tool: Tool = .claude) -> HistoryRollup {
        HistoryRollup(
            tool: tool.rawValue, hourStart: hourStart, snapshotCount: 30,
            primaryUsedPctMin: nil, primaryUsedPctMax: pMax, primaryUsedPctLast: pLast,
            secondaryUsedPctMin: nil, secondaryUsedPctMax: nil, secondaryUsedPctLast: nil,
            primaryResetsAtLast: reset, secondaryResetsAtLast: nil,
            primaryWindowLimitLast: nil, secondaryWindowLimitLast: nil, rateLimitReachedMax: 1,
            extraUsageIsEnabledLast: nil, spendControlReachedLast: nil,
            rateLimitResetCreditsCountLast: nil, monthlyLimitLast: nil, monthlyUsedLast: nil,
            monthlyResetsAtLast: nil, monthlyCurrencyLast: nil, monthlyExponentLast: nil,
            planType: nil, lastPolledAt: hourStart + 3540)
    }

    private func derive(firedAt: Int, windowStart: Int,
                        _ rollups: [HistoryRollup]) -> HistoryReport.LimitBlock {
        var byHour: [Int: HistoryRollup] = [:]
        for r in rollups { byHour[r.hourStart] = r }
        return HistoryReportReader.limitBlock(
            hit: SQLiteStore.LimitHit(
                firedAt: Date(timeIntervalSince1970: TimeInterval(firedAt)),
                windowStart: Date(timeIntervalSince1970: TimeInterval(windowStart))),
            rollupsByHour: byHour)
    }

    /// The Aug 12 corpus block: it fired mid-window and the window ran on for hours, so the fired
    /// hour's own `_last` is the blocking window's reset.
    func testABlockThatOutlivesItsHourReadsTheResetFromThatHour() {
        let hour = 1_786_539_600                      // 2026-08-12 15:00 local
        let fired = hour + 2_090                      // 15:34:50
        let reset = hour + 14_399                     // 18:59:59
        let block = derive(firedAt: fired, windowStart: reset - 18_000,
                           [limitRollup(hourStart: hour - 3600, pMax: 50, pLast: 50,
                                        reset: hour + 14_400),
                            limitRollup(hourStart: hour, pMax: 100, pLast: 100, reset: reset)])
        XCTAssertEqual(block.resetAt, Date(timeIntervalSince1970: TimeInterval(reset)))
        XCTAssertEqual(block.lockoutSeconds, 12_309)
        XCTAssertEqual(block.windowSeconds, 18_000)
    }

    /// The Jul 21 corpus block: it fired seven minutes before its own reset, so the fired hour's
    /// `_last` has already advanced to the *next* window — and the previous hour still holds the
    /// value that matters. This is the whole reason two candidate hours are read.
    func testABlockOnTheDoorstepTakesTheResetFromThePreviousHour() {
        let hour = 1_784_653_200                      // 2026-07-21 19:00 local
        let fired = hour + 195                        // 19:03:15
        let reset = hour + 600                        // 19:10:00
        let block = derive(firedAt: fired, windowStart: reset - 18_000,
                           [limitRollup(hourStart: hour - 3600, pMax: 94, pLast: 94, reset: reset),
                            // The rollover happened inside the fired hour: 4 → 100 → 16.
                            limitRollup(hourStart: hour, pMax: 100, pLast: 16,
                                        reset: reset + 18_000)])
        XCTAssertEqual(block.lockoutSeconds, 405, "seven minutes, not five hours")
        XCTAssertEqual(block.windowSeconds, 18_000)
    }

    /// The rollover guard. The fired hour rolled over, so the blocking reset lies inside it — and
    /// when no candidate does, the value was overwritten and the reset is unknown. Reading the
    /// smallest candidate anyway is what makes a four-minute Codex block print `7d` (REV-73 §2.2).
    func testARolledOverHourWithNoCandidateInsideItYieldsNoDuration() {
        let hour = 1_786_561_200                      // 2026-08-12 21:00 local
        let fired = hour + 2_753                      // 21:45:53
        let block = derive(firedAt: fired, windowStart: fired - 604_800,
                           // The previous hour holds a stale 30-day anchor, the fired hour the
                           // next weekly window's reset. Neither is this block's.
                           [limitRollup(hourStart: hour - 3600, pMax: 97, pLast: 97,
                                        reset: fired + 2_505_000),
                            limitRollup(hourStart: hour, pMax: 100, pLast: 2,
                                        reset: fired + 605_053)])
        XCTAssertNil(block.resetAt)
        XCTAssertNil(block.windowSeconds)
        XCTAssertNil(block.lockoutSeconds)
    }

    /// The width sanity-checks the reset. The Aug 1 corpus block keys to a window *starting*
    /// Aug 30 — a five-hour default width against a monthly reset — so the implied lockout is
    /// hundreds of times its own window. Both facts go, together.
    func testAWindowKeyThatContradictsItsResetLosesBothFacts() {
        let hour = 1_785_538_800
        let fired = hour + 3_545
        let reset = fired + 2_583_619                 // 29 days out
        let block = derive(firedAt: fired, windowStart: reset - 18_000,
                           [limitRollup(hourStart: hour, pMax: 100, pLast: 100, reset: reset)])
        XCTAssertNil(block.resetAt)
        XCTAssertNil(block.windowSeconds)
    }

    /// No rollup hour at all — the block fired inside the two hours `poll_snapshots` still holds,
    /// or the app was not polling. The row survives; the duration is not invented.
    func testAMissingRollupHourKeepsTheBlockAndOmitsTheDuration() {
        let block = derive(firedAt: 1_786_539_600, windowStart: 1_786_521_600, [])
        XCTAssertEqual(block.firedAt, Date(timeIntervalSince1970: 1_786_539_600))
        XCTAssertNil(block.resetAt)
        XCTAssertNil(block.windowSeconds)
    }

    /// A reset observed to the second gives a width of 17 999 s for a five-hour window, and
    /// `DisplayFormatter.windowGrain` deliberately refuses to name a width that is not a whole
    /// number of hours. Rounding happens once, here.
    func testTheDerivedWidthIsRoundedToTheMinute() {
        let hour = 1_786_957_200
        let fired = hour + 3_056
        let reset = hour + 13_199
        let block = derive(firedAt: fired, windowStart: reset - 17_999,
                           [limitRollup(hourStart: hour, pMax: 100, pLast: 100, reset: reset)])
        XCTAssertEqual(block.windowSeconds, 18_000)
        XCTAssertEqual(block.lockoutSeconds, 10_143)
    }

    /// End to end: two recorded blocks joined to the rollups the cleanup job wrote, plus the hour
    /// profile beside them, both read off the same period as the day strip.
    func testTheReportCarriesBlocksAndAnHourProfileInLocalTime() async throws {
        let cal = calendar("UTC")
        let h0 = Int(now.addingTimeInterval(-3 * 86_400).timeIntervalSince1970)
        let hourStart = h0 - h0 % 3600
        let fired = hourStart + 600
        let reset = hourStart + 3_000
        let (reader, store) = try await makeReader([
            event(key: "a", daysAgo: Double(Int(now.timeIntervalSince1970) - (hourStart + 120)) / 86_400,
                  input: 1_000, output: 0),
        ])
        try await store.writeNotificationEvent(
            tool: .claude, eventType: .overQuota, firedAt: fired,
            windowStart: reset - 18_000, copyVariant: "case_3")
        try await store.withPool { pool in
            try pool.write { db in
                for i in 0..<3 {
                    try db.execute(sql: """
                        INSERT INTO poll_snapshots (tool, polled_at, primary_used_pct,
                            primary_resets_at, rate_limit_reached)
                        VALUES ('claude', ?, 100, ?, 1)
                        """, arguments: [hourStart + i * 1200 + 60, reset])
                }
                try db.execute(sql: """
                    INSERT INTO poll_snapshots (tool, polled_at, primary_used_pct)
                    VALUES ('claude', ?, 4)
                    """, arguments: [Int(Date().timeIntervalSince1970)])
            }
        }
        try await store.runRetentionCleanup()

        let report = await reader.report(now: now, calendar: cal)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })
        XCTAssertEqual(claude.limitBlocks.count, 1)
        XCTAssertEqual(claude.limitBlocks[0].lockoutSeconds, 2_400)
        XCTAssertEqual(claude.limitBlocks[0].windowSeconds, 18_000)
        XCTAssertEqual(claude.limitHitCount, 1, "the tally is derived from the same list")
        XCTAssertEqual(claude.lastLimitHitAt,
                       Date(timeIntervalSince1970: TimeInterval(fired)))

        XCTAssertEqual(claude.workByHour.count, 24)
        let hour = cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(hourStart)))
        XCTAssertEqual(claude.workByHour[hour], 1_000)
        XCTAssertEqual(claude.workByHour.reduce(0, +), claude.totalTokens,
                       "the hour profile and the period total read the same rows")
    }

    // MARK: - Selected-day model totals, day value, critical observations (STEP_158 — REV-84)

    /// Raw INSERT with a chosen timestamp — `writeStateTransition` stamps `Date()` internally
    /// (the `SQLiteStoreRetentionTests` idiom).
    private func insertTransition(_ store: SQLiteStore, tool: Tool = .claude, at: Date,
                                  to state: String, util: Double? = nil) async throws {
        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO state_transitions
                        (tool, timestamp, from_state, to_state, triggered_by, utilization_pct)
                    VALUES (?, ?, 'healthy', ?, 'poll', ?)
                    """, arguments: [tool.rawValue, Int(at.timeIntervalSince1970), state, util])
            }
        }
    }

    func testDayModelTotalsCarryEachModelAndAnUnknownBucket() async throws {
        let cal = calendar("UTC")
        let (reader, _) = try await makeReader([
            event(key: "a", daysAgo: 1, input: 1_000, output: 100),                  // sonnet
            event(key: "b", daysAgo: 1 + 2 / 24, input: 500, output: 50),            // sonnet, another hour
            event(key: "c", model: "claude-opus-4-8", daysAgo: 1, input: 10_000, output: 1_000),
            event(session: "s-unknown", key: "d", model: nil, daysAgo: 1, input: 7, output: 3),
        ])
        let report = await reader.report(now: now, calendar: cal)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })
        let day = try XCTUnwrap(claude.days.first { $0.tokens > 0 })

        // Largest displayed count first; the unknown model is an honest bucket, never dropped.
        XCTAssertEqual(day.modelTotals.map(\.model),
                       ["claude-opus-4-8", "claude-sonnet-4-6", nil])
        let sonnet = try XCTUnwrap(day.modelTotals.first { $0.model == "claude-sonnet-4-6" })
        XCTAssertEqual(sonnet.inputTokens, 1_500, "two hourly rows of one model merge into one day row")
        XCTAssertEqual(sonnet.outputTokens, 150)
        // The day's value is its models priced through the one engine: opus at $15/$75 dominates.
        let opusDollars: Double = (10_000.0 * 15.0 + 1_000.0 * 75.0) / 1_000_000.0
        let sonnetDollars: Double = (1_500.0 * 3.0 + 150.0 * 15.0) / 1_000_000.0
        XCTAssertEqual(day.value, opusDollars + sonnetDollars, accuracy: 0.000_001,
                       "the nil-model event has no Claude fallback rate and prices at 0")
    }

    func testDayTokensEqualTheDisplayedTotalOfTheirModelTotals() async throws {
        let cal = calendar("UTC")
        let (reader, _) = try await makeReader([
            event(key: "a", daysAgo: 0.2, input: 300, output: 40, cacheCreation: 90, cacheRead: 7),
            event(key: "b", model: "claude-opus-4-8", daysAgo: 3.5, input: 1_000, output: 100),
            event(key: "c", daysAgo: 29.9, input: 5, output: 5),
            event(tool: .codex, session: "cx", key: "d", model: nil, daysAgo: 2,
                  input: 700, output: 60, cacheRead: 500),
        ])
        let report = await reader.report(now: now, calendar: cal)
        for t in report.tools {
            for day in t.days {
                XCTAssertEqual(day.tokens, DisplayedTokens.total(day.modelTotals, tool: t.tool),
                               "one population, two folds — the strip and the detail cannot disagree")
                if day.tokens == 0 {
                    XCTAssertTrue(day.modelTotals.isEmpty, "a quiet day is empty, not a grid of zeros")
                    XCTAssertEqual(day.value, 0)
                }
            }
        }
        // The provider conventions stay distinct: Claude counts all four columns, Codex two.
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })
        let codex = try XCTUnwrap(report.tools.first { $0.tool == .codex })
        XCTAssertEqual(claude.days.first { $0.start == cal.startOfDay(for: now) }?.tokens, 437)
        XCTAssertEqual(codex.days.first { $0.tokens > 0 }?.tokens, 760,
                       "cache read is inside the Codex input count, never added on top")
    }

    func testDayValuesAndTokensReconcileToThePeriodTotalsInANonUTCZone() async throws {
        let cal = calendar("America/New_York")
        let (reader, _) = try await makeReader([
            event(key: "a", daysAgo: 0.1, input: 300, output: 40),
            event(key: "b", model: "claude-opus-4-8", daysAgo: 12, input: 2_000, output: 200,
                  cacheCreation: 1_000, cacheRead: 400),
            event(key: "c", daysAgo: 29.95, input: 50, output: 5),   // the clipped first day
            event(tool: .codex, session: "cx", key: "d", model: nil, daysAgo: 6,
                  input: 900, output: 80, cacheRead: 200),
        ])
        let report = await reader.report(now: now, calendar: cal)
        for t in report.tools {
            XCTAssertEqual(t.days.reduce(0) { $0 + $1.tokens }, t.totalTokens)
            XCTAssertEqual(t.days.reduce(0.0) { $0 + $1.value }, t.value, accuracy: 0.000_001,
                           "day values sum to the 30-day Est. token value — one pricing path")
        }
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })
        XCTAssertEqual(claude.days.first?.isPartial, true)
        XCTAssertGreaterThan(claude.days.first?.tokens ?? 0, 0,
                             "the clipped sliver keeps its tokens and its value in the identity")
    }

    func testCriticalObservationsAreTypedBoundedAndOldestFirst() async throws {
        let (reader, store) = try await makeReader([event(key: "a", daysAgo: 1)])
        try await insertTransition(store, at: now.addingTimeInterval(-5 * 86_400), to: "bad_timing",
                                   util: 88)
        try await insertTransition(store, at: now.addingTimeInterval(-2 * 86_400), to: "at_risk",
                                   util: 92)
        try await insertTransition(store, at: now.addingTimeInterval(-1 * 86_400), to: "over_quota")
        try await insertTransition(store, tool: .codex, at: now.addingTimeInterval(-3 * 86_400),
                                   to: "spend_control", util: 100)
        // None of these may surface: calmer destinations, an unfamiliar state, out-of-period rows.
        try await insertTransition(store, at: now.addingTimeInterval(-4 * 86_400), to: "elevated")
        try await insertTransition(store, at: now.addingTimeInterval(-4 * 86_400), to: "fast_burn_spike")
        try await insertTransition(store, at: now.addingTimeInterval(-4 * 86_400), to: "null_window")
        try await insertTransition(store, at: now.addingTimeInterval(-4 * 86_400), to: "idle_fallback")
        try await insertTransition(store, at: now.addingTimeInterval(-4 * 86_400), to: "some_future_state")
        try await insertTransition(store, at: now.addingTimeInterval(-31 * 86_400), to: "at_risk")

        let report = await reader.report(now: now)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })
        let codex = try XCTUnwrap(report.tools.first { $0.tool == .codex })

        XCTAssertEqual(claude.criticalObservations.map(\.state),
                       [.badTiming, .atRisk, .overQuota], "oldest first, critical only, in period")
        XCTAssertEqual(claude.criticalObservations.map(\.utilizationPct), [88, 92, nil])
        XCTAssertEqual(codex.criticalObservations.map(\.state), [.spendControl],
                       "observations stay provider-scoped")
        XCTAssertEqual(codex.criticalObservations.first?.utilizationPct, 100)
    }

    // MARK: - Per-model value (STEP_159 amendment — REV-84 §5.1/§5.3 model rows carry a value)

    func testDayModelValuesAlignWithTheirTotalsAndSumToTheDayValue() async throws {
        let cal = calendar("UTC")
        let (reader, _) = try await makeReader([
            event(key: "a", daysAgo: 1, input: 1_000, output: 100),
            event(key: "b", model: "claude-opus-4-8", daysAgo: 1, input: 10_000, output: 1_000),
            event(session: "s-unknown", key: "c", model: nil, daysAgo: 1, input: 7, output: 3),
        ])
        let report = await reader.report(now: now, calendar: cal)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })
        let day = try XCTUnwrap(claude.days.first { $0.tokens > 0 })

        XCTAssertEqual(day.modelValues.map(\.model), day.modelTotals.map(\.model),
                       "index-aligned with modelTotals, unknown bucket included")
        XCTAssertEqual(day.modelValues.reduce(0) { $0 + $1.value }, day.value,
                       "the day value is the same rows in the same order — exact, not approximate")
        let opus = try XCTUnwrap(day.modelValues.first { $0.model == "claude-opus-4-8" })
        XCTAssertEqual(opus.value, (10_000.0 * 15.0 + 1_000.0 * 75.0) / 1_000_000.0,
                       accuracy: 0.000_001)
        let unknown = try XCTUnwrap(day.modelValues.first { $0.model == nil })
        XCTAssertEqual(unknown.value, 0, "no Claude fallback rate — an honest zero, never a guess")
    }

    /// The recap's `≈` (REV-104 §2.3, STEP_228): a model with its own row is exact; a model the
    /// table does not know, or no model at all, takes the provider fallback.
    func testDayModelValuesMarkFallbackPricing() async throws {
        let cal = calendar("UTC")
        let (reader, _) = try await makeReader([
            event(key: "a", daysAgo: 1),
            event(key: "b", model: "claude-new-model", daysAgo: 1),
            event(session: "s-unknown", key: "c", model: nil, daysAgo: 1),
        ])
        let report = await reader.report(now: now, calendar: cal)
        let claude = try XCTUnwrap(report.tools.first { $0.tool == .claude })
        let day = try XCTUnwrap(claude.days.first { $0.tokens > 0 })
        let marks = Dictionary(uniqueKeysWithValues: day.modelValues.map {
            ($0.model ?? "nil", $0.pricedAtFallback)
        })
        XCTAssertEqual(marks, ["claude-sonnet-4-6": false, "claude-new-model": true, "nil": true])
    }

    func testPeriodModelValuesSumToThePeriodValueForBothTools() async throws {
        let (reader, _) = try await makeReader([
            event(key: "a", daysAgo: 1, input: 1_000, output: 100),
            event(key: "b", model: "claude-opus-4-8", daysAgo: 12, input: 2_000, output: 200,
                  cacheCreation: 1_000, cacheRead: 400),
            event(tool: .codex, session: "cx", key: "c", model: nil, daysAgo: 2,
                  input: 700, output: 60, cacheRead: 500),
        ])
        let report = await reader.report(now: now)
        for t in report.tools where !t.isEmpty {
            XCTAssertEqual(t.modelValues.map(\.model), t.modelTotals.map(\.model))
            XCTAssertEqual(t.modelValues.reduce(0) { $0 + $1.value }, t.value,
                           accuracy: 0.000_001, "one pricing path — per-model rows sum to the total")
        }
        let codex = try XCTUnwrap(report.tools.first { $0.tool == .codex })
        XCTAssertGreaterThan(codex.modelValues.first?.value ?? 0, 0,
                             "the nil-model Codex row prices at the codex fallback rate")
    }
}
