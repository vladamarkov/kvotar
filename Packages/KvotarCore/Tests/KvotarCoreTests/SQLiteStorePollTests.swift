import XCTest
import GRDB
@testable import KvotarCore

final class SQLiteStorePollTests: XCTestCase {

    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory()
            .appending("kvotar-poll-test-\(UUID().uuidString).db")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        dbPath = nil
        super.tearDown()
    }

    private func makeSnapshot(
        email: String? = "dev@example.com",
        planType: String? = "max",
        reached: Bool = false
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: .claude,
            primaryUsedPct: 42.5,
            primaryResetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            secondaryUsedPct: 30.0,
            secondaryResetsAt: Date(timeIntervalSince1970: 1_800_100_000),
            rateLimitReached: reached,
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 2000, currency: "USD"),
            rateLimitLimit: 1000,
            rateLimitRemaining: 640,
            rateLimitReset: Date(timeIntervalSince1970: 1_800_050_000),
            email: email,
            planType: planType
        )
    }

    func testWritePollPersistsAccountAndSnapshotInOneTransaction() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writePoll(snapshot: makeSnapshot())

        try await store.withPool { pool in
            try pool.read { db in
                let account = try Row.fetchOne(
                    db, sql: "SELECT * FROM accounts WHERE tool = ?", arguments: ["claude"])
                XCTAssertEqual(account?["email"], "dev@example.com")
                XCTAssertEqual(account?["plan_type"], "max")

                let snap = try Row.fetchOne(
                    db, sql: "SELECT * FROM poll_snapshots WHERE tool = ?", arguments: ["claude"])
                XCTAssertEqual(snap?["primary_used_pct"], 42.5)
                XCTAssertEqual(snap?["secondary_used_pct"], 30.0)
                XCTAssertEqual(snap?["rate_limit_reached"], 0)
                XCTAssertEqual(snap?["extra_usage_is_enabled"], 1)
                XCTAssertEqual(snap?["ratelimit_limit"], 1000)
                XCTAssertEqual(snap?["ratelimit_remaining"], 640)
            }
        }
    }

    func testWritePollStoresTimestampsAsInt() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writePoll(snapshot: makeSnapshot())

        try await store.withPool { pool in
            try pool.read { db in
                // Decoding as Int must succeed — a REAL-stored Double would break this.
                let resetAt = try Int.fetchOne(
                    db, sql: "SELECT primary_resets_at FROM poll_snapshots WHERE tool = ?",
                    arguments: ["claude"])
                XCTAssertEqual(resetAt, 1_800_000_000)
            }
        }
    }

    func testWritePollUpsertsAccountAndAppendsSnapshots() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writePoll(snapshot: makeSnapshot(reached: false))
        try await store.writePoll(snapshot: makeSnapshot(reached: true))

        try await store.withPool { pool in
            try pool.read { db in
                let accountCount = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM accounts")
                XCTAssertEqual(accountCount, 1, "accounts is current-only (upsert)")

                let snapCount = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM poll_snapshots")
                XCTAssertEqual(snapCount, 2, "poll_snapshots appends per poll")
            }
        }
    }

    // MARK: readLatestPollSnapshot (STEP_32 — launch restore)

    func testReadLatestPollSnapshotRoundTrip() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writePoll(snapshot: makeSnapshot(reached: false))
        try await store.writePoll(snapshot: makeSnapshot(reached: true))

        let restored = try await store.readLatestPollSnapshot(tool: .claude)
        let (snap, polledAt) = try XCTUnwrap(restored)
        XCTAssertEqual(snap.tool, .claude)
        XCTAssertEqual(snap.primaryUsedPct, 42.5)
        XCTAssertEqual(snap.primaryResetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(snap.secondaryUsedPct, 30.0)
        XCTAssertEqual(snap.secondaryResetsAt, Date(timeIntervalSince1970: 1_800_100_000))
        XCTAssertEqual(snap.rateLimitReached, true, "the newest of the two rows must win")
        XCTAssertEqual(snap.email, "dev@example.com")
        XCTAssertEqual(snap.planType, "max")
        // Lossy-by-design fields restore as their documented placeholders.
        XCTAssertEqual(snap.extraUsage?.isEnabled, true)
        XCTAssertNil(snap.extraUsage?.monthlyLimit)
        XCTAssertNil(snap.source)
        XCTAssertLessThanOrEqual(abs(polledAt.timeIntervalSinceNow), 60)
    }

    func testReadLatestPollSnapshotNullableWindows() async throws {
        let store = try SQLiteStore(path: dbPath)
        let nullWindow = QuotaSnapshot(
            tool: .claude, primaryUsedPct: nil, primaryResetsAt: nil,
            secondaryUsedPct: 51.0, secondaryResetsAt: Date(timeIntervalSince1970: 1_800_100_000),
            rateLimitReached: nil, extraUsage: .disabled)
        try await store.writePoll(snapshot: nullWindow)

        let restored = try await store.readLatestPollSnapshot(tool: .claude)
        let (snap, _) = try XCTUnwrap(restored)
        XCTAssertNil(snap.primaryUsedPct)
        XCTAssertNil(snap.primaryResetsAt)
        XCTAssertNil(snap.rateLimitReached)
        XCTAssertEqual(snap.secondaryUsedPct, 51.0)
    }

    func testReadLatestPollSnapshotNilWhenNeverPolled() async throws {
        let store = try SQLiteStore(path: dbPath)
        let restored = try await store.readLatestPollSnapshot(tool: .codex)
        XCTAssertNil(restored)
    }

    func testReadForecastSeedSamplesFiltersAndOrdersRawEvidence() async throws {
        let store = try SQLiteStore(path: dbPath)
        let now = 1_800_000_000
        try await store.withPool { pool in
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO poll_snapshots
                        (tool, polled_at, primary_used_pct, primary_resets_at, primary_window_seconds)
                    VALUES
                        ('claude', ?, 9, ?, NULL),
                        ('codex', ?, 98, ?, 604800),
                        ('claude', ?, NULL, ?, NULL),
                        ('claude', ?, 11, ?, 18000),
                        ('claude', ?, 10, ?, 18000)
                    """, arguments: [
                        now - 4000, now + 18_000,
                        now - 200, now + 604_800,
                        now - 150, now + 18_000,
                        now - 100, now + 18_000,
                        now - 300, now + 18_000,
                    ])
            }
        }

        let samples = try await store.readForecastSeedSamples(
            tool: .claude, since: Date(timeIntervalSince1970: TimeInterval(now - 3600)))
        XCTAssertEqual(samples.map(\.usedPct), [10, 11])
        XCTAssertEqual(samples.map(\.polledAt), [
            Date(timeIntervalSince1970: TimeInterval(now - 300)),
            Date(timeIntervalSince1970: TimeInterval(now - 100)),
        ])
        XCTAssertEqual(samples.last?.windowSeconds, 18_000)
        XCTAssertEqual(samples.last?.resetsAt,
                       Date(timeIntervalSince1970: TimeInterval(now + 18_000)))
    }

    // MARK: primary_window_seconds (P1-28 — v18, STEP_101)

    /// **The hole P1-28 named.** The provider reports the window width on every Codex poll and
    /// nothing persisted it, so between launch and the first successful poll `primaryWindowLength`
    /// fell back to five hours: attribution anchored against a window 144x too short on a 30-day
    /// plan, the quota row read `Used` instead of `Weekly used`, and the §11.3 shape backstop
    /// could not be evaluated at all.
    func testPrimaryWindowSecondsRoundTrips() async throws {
        let store = try SQLiteStore(path: dbPath)
        let weekly = QuotaSnapshot(
            tool: .codex, primaryUsedPct: 3,
            primaryResetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            primaryWindowSeconds: 7 * 86_400,
            secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: false,
            planType: "plus")
        try await store.writePoll(snapshot: weekly)

        let restored = try await store.readLatestPollSnapshot(tool: .codex)
        let (snap, _) = try XCTUnwrap(restored)
        XCTAssertEqual(snap.primaryWindowSeconds, 7 * 86_400)
        XCTAssertEqual(snap.primaryWindowLength, TimeInterval(7 * 86_400),
                       "no more five-hour fallback on the restore path")
        XCTAssertEqual(snap.primaryWindowStart,
                       Date(timeIntervalSince1970: 1_800_000_000 - TimeInterval(7 * 86_400)))
    }

    /// Claude reports no width, and rows written before `v18` carry none — both restore as nil and
    /// take the documented five-hour fallback, which is Claude's true width.
    func testPrimaryWindowSecondsRestoresNilWhereTheProviderReportsNone() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writePoll(snapshot: makeSnapshot(reached: false))
        let restored = try await store.readLatestPollSnapshot(tool: .claude)
        let (snap, _) = try XCTUnwrap(restored)
        XCTAssertNil(snap.primaryWindowSeconds)
        XCTAssertEqual(snap.primaryWindowLength, 18_000)
    }

    /// The restored width is what makes the §11.3 backstop evaluable before the first poll — the
    /// reason P1-28 rode STEP_101 rather than waiting for a step of its own.
    func testRestoredWidthFeedsTheLowAllowanceBackstop() async throws {
        let store = try SQLiteStore(path: dbPath)
        let monthly = QuotaSnapshot(
            tool: .codex, primaryUsedPct: 40,
            primaryResetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            primaryWindowSeconds: 30 * 86_400,
            secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: false,
            planType: "starter_2027")
        try await store.writePoll(snapshot: monthly)

        let restored = try await store.readLatestPollSnapshot(tool: .codex)
        let (snap, _) = try XCTUnwrap(restored)
        XCTAssertTrue(snap.isLowAllowanceShape,
                      "an unfamiliar plan on the measured consumer shape must mute on restore too")
    }

    // MARK: monthly limit columns (REV-38, STEP_43 — v5 migration)

    func testWritePollPersistsAndRestoresMonthlyLimit() async throws {
        let store = try SQLiteStore(path: dbPath)
        let monthly = QuotaSnapshot(
            tool: .codex, primaryUsedPct: nil, primaryResetsAt: nil,
            secondaryUsedPct: nil, secondaryResetsAt: nil,
            rateLimitReached: nil, extraUsage: .disabled,
            spendControlReached: false,
            monthlyLimit: MonthlyLimit(
                limitAmount: 5000, usedAmount: 2376.905242651701, remainingPercent: 52,
                resetsAt: Date(timeIntervalSince1970: 1_785_542_401),
                source: "group_based_spend_controls"),
            email: "user@domain.com", planType: "enterprise")
        try await store.writePoll(snapshot: monthly)

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM poll_snapshots WHERE tool = ?", arguments: ["codex"])
                XCTAssertEqual(row?["monthly_limit"], 5000.0)
                XCTAssertEqual(row?["monthly_used"], 2376.905242651701)
                XCTAssertEqual(row?["monthly_remaining_pct"], 52)
                // Int decode must succeed — a REAL-stored Double would break this (PATTERNS rule).
                let resetsAt = try Int.fetchOne(
                    db, sql: "SELECT monthly_resets_at FROM poll_snapshots WHERE tool = ?",
                    arguments: ["codex"])
                XCTAssertEqual(resetsAt, 1_785_542_401)
            }
        }

        let restored = try await store.readLatestPollSnapshot(tool: .codex)
        let (snap, _) = try XCTUnwrap(restored)
        let m = try XCTUnwrap(snap.monthlyLimit)
        XCTAssertEqual(m.limitAmount, 5000)
        XCTAssertEqual(m.usedAmount, 2376.905242651701)
        XCTAssertEqual(m.remainingPercent, 52)
        XCTAssertEqual(m.resetsAt, Date(timeIntervalSince1970: 1_785_542_401))
        XCTAssertNil(m.source, "source is control metadata — deliberately not persisted")
    }

    func testWritePollWithoutMonthlyLimitLeavesColumnsNull() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writePoll(snapshot: makeSnapshot())

        let restored = try await store.readLatestPollSnapshot(tool: .claude)
        let (snap, _) = try XCTUnwrap(restored)
        XCTAssertNil(snap.monthlyLimit)
    }

    // MARK: monthly unit columns (REV-40, STEP_46 — v6 migration)

    /// A `.credits` monthly writes NULL,NULL to the unit pair and restores `.credits` — the shape
    /// of every Codex and pre-migration row, so existing data needs no backfill.
    func testCreditsMonthlyRestoresCreditsUnitFromNullColumns() async throws {
        let store = try SQLiteStore(path: dbPath)
        let monthly = QuotaSnapshot(
            tool: .codex, primaryUsedPct: nil, primaryResetsAt: nil,
            secondaryUsedPct: nil, secondaryResetsAt: nil,
            rateLimitReached: nil,
            monthlyLimit: MonthlyLimit(
                limitAmount: 5000, usedAmount: 2376.9, remainingPercent: 52,
                resetsAt: Date(timeIntervalSince1970: 1_785_542_400)))
        try await store.writePoll(snapshot: monthly)

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM poll_snapshots WHERE tool = ?", arguments: ["codex"])
                XCTAssertNil(row?["monthly_currency"] as String?)
                XCTAssertNil(row?["monthly_exponent"] as Int?)
            }
        }
        let restored = try await store.readLatestPollSnapshot(tool: .codex)
        let (snap, _) = try XCTUnwrap(restored)
        XCTAssertEqual(snap.monthlyLimit?.unit, .credits)
    }

    /// A `.money` monthly (Claude Enterprise spend) persists currency + exponent and restores
    /// them; the amount REALs hold raw minor units exactly.
    func testMoneyMonthlyPersistsAndRestoresUnit() async throws {
        let store = try SQLiteStore(path: dbPath)
        let monthly = QuotaSnapshot(
            tool: .claude, primaryUsedPct: nil, primaryResetsAt: nil,
            secondaryUsedPct: nil, secondaryResetsAt: nil,
            rateLimitReached: nil,
            monthlyLimit: MonthlyLimit(
                limitAmount: 12000, usedAmount: 6916, remainingPercent: 42,
                resetsAt: Date(timeIntervalSince1970: 1_785_542_400),
                unit: .money(currency: "USD", exponent: 2),
                source: "derived_calendar_month_utc"))
        try await store.writePoll(snapshot: monthly)

        try await store.withPool { pool in
            try pool.read { db in
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM poll_snapshots WHERE tool = ?", arguments: ["claude"])
                XCTAssertEqual(row?["monthly_currency"], "USD")
                XCTAssertEqual(row?["monthly_exponent"], 2)
                XCTAssertEqual(row?["monthly_limit"], 12000.0, "raw minor units, exactly")
                XCTAssertEqual(row?["monthly_used"], 6916.0)
            }
        }
        let restored = try await store.readLatestPollSnapshot(tool: .claude)
        let (snap, _) = try XCTUnwrap(restored)
        let m = try XCTUnwrap(snap.monthlyLimit)
        XCTAssertEqual(m.unit, .money(currency: "USD", exponent: 2))
        XCTAssertEqual(m.limitAmount, 12000)
        XCTAssertEqual(m.usedAmount, 6916)
        XCTAssertNil(m.source, "source is control metadata — deliberately not persisted")
    }

    // MARK: lastActiveWindow (REV-46, STEP_64 — idle "last window" retrospective;
    //       source repointed at `quota_series` by REV-55/STEP_82)

    /// A window whose `resets_at` has passed, given `now`. `makeSnapshot`'s reset time is
    /// 2027-01-15 — in the future at the time of writing — and the `resets_at <= now` guard would
    /// (correctly) reject it, so these cases pass an explicit clock instead of the wall one.
    private let afterReset = Date(timeIntervalSince1970: 1_800_000_000 + 60)

    /// The query looks past the newest (null) poll to the last window we actually saw, and derives
    /// `[resets_at − 5h, resets_at]`.
    func testLastActiveWindowDerivesSpanFromNewestWindowPoll() async throws {
        let store = try SQLiteStore(path: dbPath)
        // An active window (resets_at = 1_800_000_000), then an overnight null-window poll.
        try await store.writePoll(snapshot: makeSnapshot())
        let nullWindow = QuotaSnapshot(
            tool: .claude, primaryUsedPct: nil, primaryResetsAt: nil,
            secondaryUsedPct: 51.0, secondaryResetsAt: Date(timeIntervalSince1970: 1_800_100_000),
            rateLimitReached: nil, extraUsage: .disabled)
        try await store.writePoll(snapshot: nullWindow)

        let window = try await store.lastActiveWindow(tool: .claude, now: afterReset)
        let interval = try XCTUnwrap(window, "must look past the null poll to the last real window")
        XCTAssertEqual(interval.end, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(interval.start, Date(timeIntervalSince1970: 1_800_000_000 - 18_000))
    }

    /// No active window was ever persisted (fresh install / only null polls) → nil, no fabrication.
    func testLastActiveWindowNilWhenNoWindowEverSeen() async throws {
        let store = try SQLiteStore(path: dbPath)
        let noRows = try await store.lastActiveWindow(tool: .claude, now: afterReset)
        XCTAssertNil(noRows, "no rows at all")

        let nullWindow = QuotaSnapshot(
            tool: .claude, primaryUsedPct: nil, primaryResetsAt: nil,
            secondaryUsedPct: 51.0, secondaryResetsAt: nil,
            rateLimitReached: nil, extraUsage: .disabled)
        try await store.writePoll(snapshot: nullWindow)
        let onlyNull = try await store.lastActiveWindow(tool: .claude, now: afterReset)
        XCTAssertNil(onlyNull, "only null-window rows")
    }

    /// A window that has not ended yet is not the *last* window (REV-55 §2.5). `quota_series` is
    /// permanent, so its newest row can name a live window; recapping it would put a future clock
    /// time in the §2.5a `Window` row. nil lands on D-41's specced no-prior-window path.
    func testLastActiveWindowNilWhileTheWindowIsStillOpen() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writePoll(snapshot: makeSnapshot())
        let stillOpen = try await store.lastActiveWindow(
            tool: .claude, now: Date(timeIntervalSince1970: 1_800_000_000 - 60))
        XCTAssertNil(stillOpen, "resets_at is one minute away — the window has not ended")
    }

    /// **The regression pin for REV-55.** The retrospective must survive an ordinary night. The
    /// retired query read `poll_snapshots`, which the §17.2 pass purges at 2 hours with only the
    /// newest row per tool exempt — and during an idle stretch that exempt row *is* the null poll,
    /// so the proof a window existed was deleted and the gate silently failed open (live
    /// 2026-07-25: "THIS 5-HOUR WINDOW" over 101 hours of rows). Neither suite ran the retention
    /// pass, which is why nothing caught it. `quota_series` is permanent, so the read now holds.
    func testLastActiveWindowSurvivesRetentionCleanup() async throws {
        let store = try SQLiteStore(path: dbPath)
        // Fixtures are laid out relative to real `now` — `runRetentionCleanup` reads the wall clock.
        let realNow = Date()
        let windowEnd = realNow.addingTimeInterval(-4 * 3600)     // window closed 4h ago
        let windowPoll = QuotaSnapshot(
            tool: .claude, primaryUsedPct: 61.0, primaryResetsAt: windowEnd,
            secondaryUsedPct: 30.0, secondaryResetsAt: nil,
            rateLimitReached: false, extraUsage: .disabled)
        // Polled 5h ago: past the 2h cutoff, and superseded so the newest-row exemption misses it.
        try await store.writePoll(snapshot: windowPoll, now: realNow.addingTimeInterval(-5 * 3600))
        let nullPoll = QuotaSnapshot(
            tool: .claude, primaryUsedPct: nil, primaryResetsAt: nil,
            secondaryUsedPct: 51.0, secondaryResetsAt: nil,
            rateLimitReached: nil, extraUsage: .disabled)
        try await store.writePoll(snapshot: nullPoll, now: realNow)

        try await store.runRetentionCleanup()

        // Precondition: the evidence the retired query depended on is genuinely gone.
        let survivingWindowRows = try await store.withPool { pool in
            try pool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM poll_snapshots
                    WHERE tool = 'claude' AND primary_resets_at IS NOT NULL
                    """) ?? -1
            }
        }
        XCTAssertEqual(survivingWindowRows, 0, "the 2h purge took the only proof of the window")

        let resolved = try await store.lastActiveWindow(tool: .claude, now: realNow)
        let interval = try XCTUnwrap(
            resolved,
            "the retrospective must survive an idle stretch longer than poll_snapshots retention")
        XCTAssertEqual(interval.end.timeIntervalSince1970, windowEnd.timeIntervalSince1970,
                       accuracy: 1)
        XCTAssertEqual(interval.start.timeIntervalSince1970,
                       windowEnd.timeIntervalSince1970 - 18_000, accuracy: 1)
    }

    // MARK: readMonthlyUsedSamples (REV-47, STEP_65 — trailing spend rate input)

    /// Only rows with a monthly reading count, only inside the lookback, oldest first. Raw
    /// inserts pin `polled_at` (`writePoll` stamps its own clock).
    func testReadMonthlyUsedSamplesFiltersAndOrders() async throws {
        let store = try SQLiteStore(path: dbPath)
        let now = 1_800_000_000
        try await store.withPool { pool in
            try pool.write { db in
                for (at, used, resetsAt) in [
                    (now - 7200, 100.0, 1_802_000_000),   // outside the lookback — excluded
                    (now - 3000, 300.0, 1_802_000_000),
                    (now - 600, 500.0, 1_802_000_000),
                ] {
                    try db.execute(sql: """
                        INSERT INTO poll_snapshots (tool, polled_at, monthly_used, monthly_resets_at)
                        VALUES (?, ?, ?, ?)
                        """, arguments: ["claude", at, used, resetsAt])
                }
                // A windowed poll with no monthly meter — must never appear as a sample.
                try db.execute(sql: """
                    INSERT INTO poll_snapshots (tool, polled_at, primary_used_pct)
                    VALUES (?, ?, ?)
                    """, arguments: ["claude", now - 1200, 42.5])
                // Another tool's monthly row — excluded by the tool scope.
                try db.execute(sql: """
                    INSERT INTO poll_snapshots (tool, polled_at, monthly_used, monthly_resets_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: ["codex", now - 900, 999.0, 1_802_000_000])
            }
        }

        let samples = try await store.readMonthlyUsedSamples(
            tool: .claude, since: Date(timeIntervalSince1970: TimeInterval(now - 3900)))
        XCTAssertEqual(samples.map(\.usedAmount), [300.0, 500.0], "filtered, oldest first")
        XCTAssertEqual(samples.map(\.polledAt),
                       [Date(timeIntervalSince1970: TimeInterval(now - 3000)),
                        Date(timeIntervalSince1970: TimeInterval(now - 600))])
        XCTAssertEqual(samples.last?.resetsAt, Date(timeIntervalSince1970: 1_802_000_000))

        // The mirror scope (REV-48 — STEP_67): Codex Enterprise reads its own credits samples
        // out of the same table, and sees none of Claude's.
        let codexSamples = try await store.readMonthlyUsedSamples(
            tool: .codex, since: Date(timeIntervalSince1970: TimeInterval(now - 3900)))
        XCTAssertEqual(codexSamples.map(\.usedAmount), [999.0], "tool scope cuts both ways")
    }

    func testReadMonthlyUsedSamplesEmptyWhenNoMonthlyRows() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writePoll(snapshot: makeSnapshot())   // windowed poll, no monthly meter
        let samples = try await store.readMonthlyUsedSamples(
            tool: .claude, since: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(samples.isEmpty)
    }

    func testWritePollWithoutIdentityDoesNotTouchAccounts() async throws {
        let store = try SQLiteStore(path: dbPath)
        try await store.writePoll(snapshot: makeSnapshot(email: nil, planType: nil))

        try await store.withPool { pool in
            try pool.read { db in
                let accountCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts")
                XCTAssertEqual(accountCount, 0)
                let snapCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM poll_snapshots")
                XCTAssertEqual(snapCount, 1)
            }
        }
    }
}
