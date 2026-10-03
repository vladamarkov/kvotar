import XCTest
import SQLite3
import KvotarCore
@testable import CodexAdapter

/// Step 9 fixture tests for `CodexAccountAdapter` (Baseline §8.1, §8.2, §8.3; task Step 9).
/// D1: all over-quota expectations are working-assumption gated — validate when blocked-state is
/// captured (§20 D1).
final class CodexAccountAdapterTests: XCTestCase {

    /// Points at paths that never exist, so `hasUsageLimitedGoal()` reliably returns `false`
    /// (task Step 12) instead of reading this machine's real `~/.codex/goals_1.sqlite`.
    private static let isolatedMetadataReader = CodexSQLiteMetadataReader(
        statePath: URL(fileURLWithPath: "/nonexistent/state_5.sqlite"),
        goalsPath: URL(fileURLWithPath: "/nonexistent/goals_1.sqlite")
    )

    // MARK: 1 — healthy Enterprise null-window via RPC

    func testHealthyNullWindowViaRPC() async throws {
        let adapter = CodexAccountAdapter(
            rpc: try FakeCodexRPC.healthy(),
            wham: FakeWhamClient.failing(AccountAdapterError.reauthRequired),
            metadataReader: Self.isolatedMetadataReader)
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertEqual(snap.tool, .codex)
        XCTAssertTrue(snap.isNullWindow)
        XCTAssertNil(snap.primaryUsedPct)
        XCTAssertNil(snap.secondaryUsedPct)
        XCTAssertNil(snap.rateLimitReached, "null alone must not enter a warning state")
        XCTAssertEqual(snap.planType, "enterprise")
        XCTAssertEqual(snap.email, "user@domain.com")
        let health = await adapter.health
        XCTAssertEqual(health, .healthy)
    }

    // MARK: 2 — healthy Enterprise null-window via wham

    func testHealthyNullWindowViaWham() async throws {
        let adapter = CodexAccountAdapter(
            rpc: FakeCodexRPC.failing(),
            wham: try FakeWhamClient.fixture("wham_healthy_null_window_enterprise"),
            metadataReader: Self.isolatedMetadataReader)
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertTrue(snap.isNullWindow)
        XCTAssertNil(snap.rateLimitReached)
        XCTAssertEqual(snap.spendControlReached, false)
        XCTAssertEqual(snap.rateLimitResetCreditsCount, 0)
        XCTAssertEqual(snap.planType, "enterprise")
        let health = await adapter.health
        XCTAssertEqual(health, .healthy)
    }

    // MARK: 3 — wham blocked working assumption (D1)

    func testWhamBlockedWorkingAssumption() async throws {
        let adapter = CodexAccountAdapter(
            rpc: FakeCodexRPC.failing(),
            wham: try FakeWhamClient.fixture("wham_blocked_enterprise"),
            metadataReader: Self.isolatedMetadataReader)
        let snap = try await adapter.fetchQuotaSnapshot()

        // D1: working assumption — over-quota + reset countdown from primary_window.reset_at.
        XCTAssertEqual(snap.rateLimitReached, true)
        XCTAssertEqual(snap.primaryUsedPct, 100)
        XCTAssertEqual(snap.secondaryUsedPct, 21)
        XCTAssertEqual(snap.primaryResetsAt, Date(timeIntervalSince1970: 1_781_391_701))
        XCTAssertEqual(snap.secondaryResetsAt, Date(timeIntervalSince1970: 1_781_978_501))
        XCTAssertFalse(snap.isNullWindow)
    }

    // MARK: 4 — RPC failure falls through to wham success

    func testRPCFailureFallsThroughToWham() async throws {
        let adapter = CodexAccountAdapter(
            rpc: FakeCodexRPC.failing(CodexRPCClient.ClientError.timeout(method: "account/read")),
            wham: try FakeWhamClient.fixture("wham_blocked_enterprise"),
            metadataReader: Self.isolatedMetadataReader)
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertEqual(snap.rateLimitReached, true)
        XCTAssertEqual(snap.email, "user@domain.com")
        let health = await adapter.health
        XCTAssertEqual(health, .healthy)
    }

    // MARK: 5 — expired token 401 → reauth required

    func testExpiredTokenReauthRequired() async {
        let adapter = CodexAccountAdapter(
            rpc: FakeCodexRPC.failing(),
            wham: FakeWhamClient.failing(AccountAdapterError.reauthRequired),
            metadataReader: Self.isolatedMetadataReader)
        do {
            _ = try await adapter.fetchQuotaSnapshot()
            XCTFail("expected reauthRequired")
        } catch let error as AccountAdapterError {
            XCTAssertEqual(error, .reauthRequired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let health = await adapter.health
        XCTAssertEqual(health, .reauthRequired)
    }

    // MARK: 6 — `goals_1.sqlite` usage_limited signal turns rateLimitReached on (task Step 12)

    func testUsageLimitedGoalOverridesRateLimitReached() async throws {
        let goalsPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-goals-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: goalsPath) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(goalsPath.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE thread_goals (thread_id TEXT PRIMARY KEY, status TEXT);
            INSERT INTO thread_goals (thread_id, status) VALUES ('t1', 'usage_limited');
            """, nil, nil, nil)
        sqlite3_close(db)

        let adapter = CodexAccountAdapter(
            rpc: try FakeCodexRPC.healthy(),
            wham: FakeWhamClient.failing(AccountAdapterError.reauthRequired),
            metadataReader: CodexSQLiteMetadataReader(
                statePath: URL(fileURLWithPath: "/nonexistent/state_5.sqlite"),
                goalsPath: goalsPath))
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertEqual(snap.rateLimitReached, true,
                       "usage_limited in goals_1.sqlite is a secondary over-quota signal even on an otherwise-healthy null-window poll")
    }

    // MARK: 7 — STEP_27 credits / additional limits / source provenance (D1 working assumption)

    func testRPCCreditsAdditionalLimitsAndSource() async throws {
        let account = try JSONDecoder().decode(
            CodexAccountRead.self, from: fixtureData("account_read_healthy_enterprise"))
        let rateLimits = try JSONDecoder().decode(
            CodexRateLimits.self, from: fixtureData("ratelimits_spark_additional_limit"))
        let adapter = CodexAccountAdapter(
            rpc: FakeCodexRPC(result: .success((account, rateLimits))),
            wham: FakeWhamClient.failing(AccountAdapterError.reauthRequired),
            metadataReader: Self.isolatedMetadataReader)
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertEqual(snap.source, .appServerRPC)
        XCTAssertEqual(snap.creditsBalance, 142.3)
        XCTAssertEqual(snap.additionalRateLimits.count, 1,
                       "the primary limit id must not be duplicated as an additional limit")
        XCTAssertEqual(snap.additionalRateLimits.first?.id, "codex_spark")
        XCTAssertEqual(snap.additionalRateLimits.first?.name, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(snap.additionalRateLimits.first?.usedPercent, 12)
    }

    /// The pre-capture **flat** entry shape (`limit_id` / `used_percent` / `reset_at` at the top
    /// level) was never observed on the wire — the real shape is nested (test 8). It is kept as the
    /// lenient fallback, so this fixture still yields a name and a percent (STEP_176).
    func testWhamCreditsAdditionalLimitsAndSource() async throws {
        let adapter = CodexAccountAdapter(
            rpc: FakeCodexRPC.failing(),
            wham: try FakeWhamClient.fixture("wham_credits_additional_limits"),
            metadataReader: Self.isolatedMetadataReader)
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertEqual(snap.source, .wham)
        XCTAssertEqual(snap.creditsBalance, 142.3)
        XCTAssertEqual(snap.additionalRateLimits.count, 1)
        XCTAssertEqual(snap.additionalRateLimits.first?.id, "codex_spark")
        XCTAssertEqual(snap.additionalRateLimits.first?.usedPercent, 12)
        XCTAssertEqual(snap.additionalRateLimits.first?.resetsAt,
                       Date(timeIntervalSince1970: 1_781_391_701))
    }

    func testConfirmedNullShapesDecodeToUnavailable() async throws {
        // The only real captures carry `credits: null` / `additional_rate_limits: null` — they
        // must normalize to "unavailable" (nil / empty), never to an error.
        let adapter = CodexAccountAdapter(
            rpc: FakeCodexRPC.failing(),
            wham: try FakeWhamClient.fixture("wham_blocked_enterprise"),
            metadataReader: Self.isolatedMetadataReader)
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertNil(snap.creditsBalance)
        XCTAssertTrue(snap.additionalRateLimits.isEmpty)
        XCTAssertEqual(snap.source, .wham)
    }

    func testLenientDecodeOfUnexpectedD1Shapes() throws {
        // D1: an unexpected populated shape for the speculative keys must degrade those fields
        // to nil, not fail the poll. `credits` as a scalar, `additional_rate_limits` as an object.
        let json = """
        {
          "email": "user@domain.com",
          "plan_type": "enterprise",
          "rate_limit": null,
          "credits": 5,
          "additional_rate_limits": { "unexpected": true },
          "spend_control": { "reached": false, "individual_limit": null }
        }
        """
        let usage = try CodexWhamUsage.decode(from: Data(json.utf8))
        XCTAssertNil(usage.credits?.balance)
        XCTAssertNil(usage.additionalRateLimits)
        XCTAssertEqual(usage.email, "user@domain.com")
        XCTAssertNil(usage.rateLimit)
    }

    // MARK: 8 — STEP_176: a model allowance keeps every window (REV-92 / Baseline §15.2)

    /// Sanitized captures from the owner's Pro account, 2026-09-10 (`docs/evidence/REV92/`).
    /// The RPC probe ran at ≈1 789 044 609 (Spark's five-hour deadline sat exactly 18 000 s out —
    /// the REV-57 placeholder) and the wham probe 54 s earlier.
    private static let rpcProbeInstant = Date(timeIntervalSince1970: 1_789_044_609)
    private static let whamProbeInstant = Date(timeIntervalSince1970: 1_789_044_555)

    func testRPCKeepsBothSparkWindowsAndMainStaysWeeklyOnly() async throws {
        let rateLimits = try JSONDecoder().decode(
            CodexRateLimits.self, from: fixtureData("ratelimits_spark_two_windows"))
        let account = try JSONDecoder().decode(
            CodexAccountRead.self, from: fixtureData("account_read_healthy_enterprise"))
        let snap = await makeAdapter().normalize(account: account, rateLimits: rateLimits,
                                                 now: Self.rpcProbeInstant)

        // The main allowance is weekly-only: one 7-day primary, no secondary, and **no invented
        // five-hour row** anywhere on the snapshot.
        XCTAssertEqual(snap.primaryUsedPct, 4)
        XCTAssertEqual(snap.primaryWindowSeconds, 604_800)
        XCTAssertNil(snap.secondaryUsedPct)
        XCTAssertNil(snap.secondaryResetsAt)

        XCTAssertEqual(snap.additionalRateLimits.count, 1, "the main `codex` entry is skipped by id")
        let spark = try XCTUnwrap(snap.additionalRateLimits.first)
        XCTAssertEqual(spark.id, "codex_bengalfox")
        XCTAssertEqual(spark.name, "GPT-5.3-Codex-Spark")
        // Five-hour window: 0 % and a deadline one width out ⇒ unanchored, the 0 % kept.
        XCTAssertEqual(spark.usedPercent, 0)
        XCTAssertEqual(spark.primaryWindowSeconds, 18_000)
        XCTAssertNil(spark.resetsAt, "a placeholder deadline is dropped (REV-57), the width stays")
        // Weekly window: anchored (601 375 s out, not 604 800), its own reset and width.
        let weekly = try XCTUnwrap(spark.secondary)
        XCTAssertEqual(weekly.usedPercent, 0)
        XCTAssertEqual(weekly.windowSeconds, 604_800)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_789_645_984))
        XCTAssertNotEqual(weekly.resetsAt, snap.primaryResetsAt,
                          "Spark's weekly and the main weekly are two resets, 53 s apart")
    }

    /// The same RPC body read an hour earlier: the five-hour deadline is no longer one width out,
    /// so it is a real anchor and survives.
    func testRPCSparkFiveHourAnchorSurvivesWhenNotPlaceholderShaped() throws {
        let rateLimits = try JSONDecoder().decode(
            CodexRateLimits.self, from: fixtureData("ratelimits_spark_two_windows"))
        let spark = CodexAccountAdapter.additionalLimits(
            from: rateLimits, now: Self.rpcProbeInstant.addingTimeInterval(-3600))[0]
        XCTAssertEqual(spark.resetsAt, Date(timeIntervalSince1970: 1_789_062_609))
    }

    func testWhamKeepsBothSparkWindowsFromTheNestedRateLimitObject() async throws {
        let usage = try CodexWhamUsage.decode(from: fixtureData("wham_spark_two_windows"))
        let snap = await makeAdapter().normalize(wham: usage, now: Self.whamProbeInstant)

        XCTAssertEqual(snap.primaryWindowSeconds, 604_800, "main allowance weekly-only on wham too")
        XCTAssertNil(snap.secondaryUsedPct)
        let spark = try XCTUnwrap(snap.additionalRateLimits.first)
        XCTAssertEqual(snap.additionalRateLimits.count, 1)
        XCTAssertEqual(spark.id, "codex_bengalfox", "`metered_feature` is the allowance key — RPC's map key")
        XCTAssertEqual(spark.name, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(spark.usedPercent, 0)
        XCTAssertEqual(spark.primaryWindowSeconds, 18_000)
        XCTAssertNil(spark.resetsAt, "placeholder five-hour deadline dropped on wham as on RPC")
        let weekly = try XCTUnwrap(spark.secondary)
        XCTAssertEqual(weekly.windowSeconds, 604_800)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_789_645_984))
        XCTAssertEqual(weekly.usedPercent, 0)
    }

    /// The two transports must name one allowance identically — same id, same windows — or the
    /// popover's Other Limits would flicker between polls when RPC falls through to wham.
    func testRPCAndWhamAgreeOnSparkIdentityAndWindows() throws {
        let rateLimits = try JSONDecoder().decode(
            CodexRateLimits.self, from: fixtureData("ratelimits_spark_two_windows"))
        let usage = try CodexWhamUsage.decode(from: fixtureData("wham_spark_two_windows"))
        let rpc = CodexAccountAdapter.additionalLimits(from: rateLimits, now: Self.rpcProbeInstant)[0]
        let wham = CodexAccountAdapter.additionalLimits(fromWham: usage.additionalRateLimits,
                                                       now: Self.whamProbeInstant)[0]
        XCTAssertEqual(rpc.id, wham.id)
        XCTAssertEqual(rpc.name, wham.name)
        XCTAssertEqual(rpc.primaryWindowSeconds, wham.primaryWindowSeconds)
        XCTAssertEqual(rpc.secondary?.windowSeconds, wham.secondary?.windowSeconds)
        XCTAssertEqual(rpc.secondary?.resetsAt, wham.secondary?.resetsAt)
    }

    /// Missing fields stay missing: no `windowDurationMins` ⇒ no width, `secondary: null` ⇒ no
    /// secondary window, a `null` primary ⇒ an allowance with only its name. Nothing is inferred
    /// from the main allowance or the plan (Baseline §15.2).
    func testRPCMissingModelWindowFieldsStayUnknown() throws {
        let json = """
        {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 4, "windowDurationMins": 10080,
                        "resetsAt": 1789646037}, "secondary": null},
         "rateLimitsByLimitId": {
           "codex_bengalfox": {"limitId": "codex_bengalfox", "limitName": "GPT-5.3-Codex-Spark",
                               "primary": {"usedPercent": 7, "resetsAt": 1789062609}, "secondary": null},
           "codex_nameless": {"limitId": "codex_nameless", "primary": null, "secondary": null}}}
        """
        let rateLimits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(json.utf8))
        let limits = CodexAccountAdapter.additionalLimits(from: rateLimits, now: Self.rpcProbeInstant)
        XCTAssertEqual(limits.map(\.id), ["codex_bengalfox", "codex_nameless"])
        XCTAssertEqual(limits[0].usedPercent, 7)
        XCTAssertNil(limits[0].primaryWindowSeconds, "no duration reported ⇒ none invented")
        XCTAssertNil(limits[0].secondary)
        XCTAssertEqual(limits[0].resetsAt, Date(timeIntervalSince1970: 1_789_062_609),
                       "without a width the unanchored rule cannot engage, so the deadline stays")
        XCTAssertFalse(limits[1].hasPrimaryWindow)
        XCTAssertNil(limits[1].secondary)
    }

    /// `rateLimitsByLimitId` absent (every capture before 2026-09-10 that lacked the map) ⇒ no
    /// allowances, never a placeholder.
    func testRPCWithoutByIdMapYieldsNoModelLimits() throws {
        let rateLimits = try rpcRateLimits(usedPercent: 4, resetsAt: 1_789_646_037,
                                           windowDurationMins: 10_080)
        XCTAssertTrue(CodexAccountAdapter.additionalLimits(from: rateLimits, now: Self.rpcProbeInstant).isEmpty)
    }

    /// One odd wham entry degrades to its name and nils — it neither throws nor blanks the array.
    func testWhamOddModelEntryDegradesWithoutFailingThePoll() throws {
        let json = """
        {"plan_type": "pro", "rate_limit": null,
         "additional_rate_limits": [
           {"limit_name": "Odd", "metered_feature": 12, "rate_limit": "nope"},
           {"limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
            "rate_limit": {"allowed": true, "limit_reached": false,
                           "primary_window": {"used_percent": 3, "limit_window_seconds": 18000, "reset_at": 1789062555},
                           "secondary_window": null}}]}
        """
        let usage = try CodexWhamUsage.decode(from: Data(json.utf8))
        let limits = CodexAccountAdapter.additionalLimits(fromWham: usage.additionalRateLimits,
                                                          now: Self.whamProbeInstant)
        XCTAssertEqual(limits.count, 2)
        XCTAssertEqual(limits[0].name, "Odd")
        XCTAssertNil(limits[0].id)
        XCTAssertFalse(limits[0].hasPrimaryWindow)
        XCTAssertEqual(limits[1].usedPercent, 3)
        XCTAssertNil(limits[1].secondary)
    }

    // MARK: 9 — REV-38/STEP_43: monthly limit (`individual_limit` / `individualLimit`)

    func testWhamMonthlyLimitDecodesAndNormalizes() async throws {
        // F4 regression: the live 2026-07-15 object shape (string numerics) killed the entire
        // wham decode under the old `individualLimit: Int?` declaration. Fixture covers the
        // string-numeric edges too: fractional `used`, integer-string `limit`.
        let adapter = CodexAccountAdapter(
            rpc: FakeCodexRPC.failing(),
            wham: try FakeWhamClient.fixture("wham_monthly_limit_enterprise"),
            metadataReader: Self.isolatedMetadataReader)
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertTrue(snap.isNullWindow, "healthy monthly account still has null session windows")
        XCTAssertEqual(snap.spendControlReached, false)
        let monthly = try XCTUnwrap(snap.monthlyLimit)
        XCTAssertEqual(monthly.limitAmount, 5000)
        XCTAssertEqual(monthly.usedAmount, 2376.905242651701)
        XCTAssertEqual(monthly.remainingPercent, 52)
        XCTAssertEqual(monthly.resetsAt, Date(timeIntervalSince1970: 1_785_542_401))
        XCTAssertEqual(monthly.source, "group_based_spend_controls")
    }

    func testRPCMonthlyLimitDecodesAndNormalizes() async throws {
        let account = try JSONDecoder().decode(
            CodexAccountRead.self, from: fixtureData("account_read_healthy_enterprise"))
        let rateLimits = try JSONDecoder().decode(
            CodexRateLimits.self, from: fixtureData("ratelimits_monthly_limit"))
        let adapter = CodexAccountAdapter(
            rpc: FakeCodexRPC(result: .success((account, rateLimits))),
            wham: FakeWhamClient.failing(AccountAdapterError.reauthRequired),
            metadataReader: Self.isolatedMetadataReader)
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertEqual(snap.source, .appServerRPC)
        let monthly = try XCTUnwrap(snap.monthlyLimit)
        XCTAssertEqual(monthly.limitAmount, 5000)
        XCTAssertEqual(monthly.usedAmount, 2376.905242651701)
        XCTAssertEqual(monthly.remainingPercent, 52)
        XCTAssertEqual(monthly.resetsAt, Date(timeIntervalSince1970: 1_785_542_400))
        XCTAssertNil(monthly.source, "the RPC capture carries no source field")
    }

    // MARK: 7a — STEP_98: `spendControlReached` is carried by RPC, and used to be dropped

    /// The comment this step deleted claimed the primary transport does not carry the field, and
    /// `normalize` hardcoded `nil` to match. The fixture is a **real retained body** — every one
    /// of the 1,469 `account/rateLimits/read` responses kept back to 2026-07-24 carries
    /// `spendControlReached`, so the claim was never true on any capture we hold.
    func testRPCSpendControlReachedDecodesAndNormalizes() async throws {
        let rateLimits = try JSONDecoder().decode(
            CodexRateLimits.self, from: fixtureData("ratelimits_plus_spend_control"))
        XCTAssertEqual(rateLimits.rateLimits.spendControlReached, false,
                       "the field is present on the wire; it was simply never declared")

        let adapter = CodexAccountAdapter(
            rpc: FakeCodexRPC(result: .success((try accountRead(), rateLimits))),
            wham: FakeWhamClient.failing(AccountAdapterError.reauthRequired),
            metadataReader: Self.isolatedMetadataReader)
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertEqual(snap.source, .appServerRPC)
        XCTAssertEqual(snap.spendControlReached, false,
                       "the RPC value must reach the snapshot instead of being replaced by nil")
    }

    /// The reachability half, and the honest limit on it (STEP_98 "Verification, and its honest
    /// limit"). No retained body carries `spendControlReached: true` and no Enterprise account
    /// exists on this machine, so a genuine positive cannot be observed. The *shape* is proven by
    /// the real fixture above; only the value here is synthesized, which is enough to show the
    /// value now reaches `QuotaSnapshot` — where `StateEngine` tests `== true` — rather than being
    /// discarded on the way. It does not prove the state machine behaves correctly when it flips.
    func testRPCSpendControlReachedTrueReachesTheSnapshot() async throws {
        let json = """
        {"rateLimits": {"limitId": "codex", "planType": "enterprise", "secondary": null,
          "spendControlReached": true,
          "primary": {"windowDurationMins": 43200, "usedPercent": 100, "resetsAt": 1787214867}}}
        """
        let rateLimits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(json.utf8))
        let adapter = CodexAccountAdapter(
            rpc: FakeCodexRPC(result: .success((try accountRead(), rateLimits))),
            wham: FakeWhamClient.failing(AccountAdapterError.reauthRequired),
            metadataReader: Self.isolatedMetadataReader)
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertEqual(snap.spendControlReached, true)
    }

    func testRPCNullWindowSupplementsMonthlyLimitFromWham() async throws {
        // Live regression, 2026-07-16: `account/rateLimits/read` succeeded with Enterprise
        // identity and null session windows, but omitted `individualLimit`; `wham/usage` carried
        // the monthly workspace limit. The RPC success must not erase the monthly layout.
        let adapter = CodexAccountAdapter(
            rpc: try FakeCodexRPC.healthy(),
            wham: try FakeWhamClient.fixture("wham_monthly_limit_enterprise"),
            metadataReader: Self.isolatedMetadataReader)
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertTrue(snap.isNullWindow)
        XCTAssertEqual(snap.source, .wham, "the visible quota story comes from the wham supplement")
        XCTAssertEqual(snap.planType, "enterprise", "the RPC account identity remains authoritative")
        XCTAssertEqual(snap.spendControlReached, false)
        let monthly = try XCTUnwrap(snap.monthlyLimit)
        XCTAssertEqual(monthly.limitAmount, 5000)
        XCTAssertEqual(monthly.usedAmount, 2376.905242651701)
        XCTAssertEqual(monthly.remainingPercent, 52)
        XCTAssertEqual(monthly.resetsAt, Date(timeIntervalSince1970: 1_785_542_401))
    }

    func testMonthlyLimitNullAndAbsentNormalizeToNil() async throws {
        // Legacy pre-limit captures (`individual_limit: null`) and an entirely absent key are
        // both "no monthly limit configured" — nil, never an error (§8.2).
        let nullAdapter = CodexAccountAdapter(
            rpc: FakeCodexRPC.failing(),
            wham: try FakeWhamClient.fixture("wham_healthy_null_window_enterprise"),
            metadataReader: Self.isolatedMetadataReader)
        let nullSnap = try await nullAdapter.fetchQuotaSnapshot()
        XCTAssertNil(nullSnap.monthlyLimit)

        let absentJSON = """
        {
          "email": "user@domain.com",
          "plan_type": "enterprise",
          "rate_limit": null,
          "spend_control": { "reached": false }
        }
        """
        let usage = try CodexWhamUsage.decode(from: Data(absentJSON.utf8))
        XCTAssertNil(usage.spendControl?.individualLimit)
        XCTAssertEqual(usage.spendControl?.reached, false)
    }

    func testMonthlyLimitUnexpectedShapeDegradesToNilNotPollFailure() throws {
        // The F4 lesson generalized: a future shape change on this one field must degrade it to
        // nil, never fail the whole wham decode (mirrors the credits/additional_rate_limits rule).
        let json = """
        {
          "email": "user@domain.com",
          "plan_type": "enterprise",
          "rate_limit": null,
          "spend_control": { "reached": true, "individual_limit": 4000 }
        }
        """
        let usage = try CodexWhamUsage.decode(from: Data(json.utf8))
        XCTAssertNil(usage.spendControl?.individualLimit)
        XCTAssertEqual(usage.spendControl?.reached, true, "reached must survive the degraded field")
    }

    func testMonthlyLimitUnparseableNumericsNormalizeToNil() {
        // String→Double parsing is defensive: any required field failing to parse yields nil
        // (no partial model), on both transports.
        XCTAssertNil(CodexAccountAdapter.monthlyLimit(from: CodexWhamUsage.IndividualLimit(
            limit: "not-a-number", used: "2376.9", remaining: nil, usedPercent: 46,
            remainingPercent: 52, resetAfterSeconds: nil, resetAt: 1_785_542_401, source: nil)))
        XCTAssertNil(CodexAccountAdapter.monthlyLimit(from: CodexRateLimits.IndividualLimit(
            limit: "5000", used: "2376.9", remainingPercent: 52, resetsAt: nil, source: nil)))
    }

    // MARK: 8 — overall Codex budget (§13.3) bounds a slow RPC + slow wham (STEP_24)

    func testOverallBudgetBoundsSlowRPCPlusWham() async {
        // Each leg would take 5s (10s combined); the 300ms budget must cut it off far sooner.
        let adapter = CodexAccountAdapter(
            rpc: SlowCodexRPC(delay: .seconds(5)),
            wham: SlowWhamClient(delay: .seconds(5)),
            metadataReader: Self.isolatedMetadataReader,
            overallBudget: .milliseconds(300))

        let start = Date()
        do {
            _ = try await adapter.fetchQuotaSnapshot()
            XCTFail("expected the overall budget to be exceeded")
        } catch is CodexAccountAdapter.OverallBudgetExceeded {
            // expected
        } catch {
            XCTFail("expected OverallBudgetExceeded, got \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "budget must cancel both legs well before their 10s sum")
    }

    // MARK: 9 — unanchored windows (REV-57 / STEP_85)

    /// 30 days, the Free/Go grain (`43200` min == `2592000` s).
    private static let thirtyDays = 2_592_000
    private static let now = Date(timeIntervalSince1970: 1_786_225_671)

    private func makeAdapter() -> CodexAccountAdapter {
        CodexAccountAdapter(rpc: FakeCodexRPC.failing(),
                            wham: FakeWhamClient.failing(AccountAdapterError.reauthRequired),
                            metadataReader: Self.isolatedMetadataReader)
    }

    /// Decodes through the *shipping* RPC path — a plain `JSONDecoder`, no key strategy — so these
    /// cases also pin the key names. `windowSeconds` was a name that matched nothing for the life of
    /// the file; that is the defect class this decode is here to catch (REV-57 §4.1).
    private func rpcRateLimits(usedPercent: Double, resetsAt: Int,
                               windowDurationMins: Int? = 43_200) throws -> CodexRateLimits {
        let window = windowDurationMins.map { "\"windowDurationMins\": \($0), " } ?? ""
        let json = """
        {"rateLimits": {"limitId": "codex", "planType": "go", "secondary": null,
          "primary": {\(window)"usedPercent": \(usedPercent), "resetsAt": \(resetsAt)}}}
        """
        return try JSONDecoder().decode(CodexRateLimits.self, from: Data(json.utf8))
    }

    // MARK: The secondary window's width reaches the snapshot (STEP_188 — REV-95 §3.1)

    /// Both wires have always reported a width for the weekly window and nothing read it. The
    /// values here are the real ones from the 2026-09-10 capture's scoped `GPT-5.3-Codex-Spark`
    /// allowance (`ratelimits_spark_two_windows.json`) — the same `Window` type — placed on the
    /// main allowance, which no account captured here has ever carried a secondary on.
    func testRPCSecondaryWindowWidthIsNormalizedToSeconds() async throws {
        let json = """
        {"rateLimits": {"limitId": "codex", "planType": "plus",
          "primary": {"windowDurationMins": 300, "usedPercent": 12, "resetsAt": 1789062609},
          "secondary": {"windowDurationMins": 10080, "usedPercent": 31, "resetsAt": 1789645984}}}
        """
        let rateLimits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(json.utf8))
        let adapter = CodexAccountAdapter(
            rpc: FakeCodexRPC(result: .success((try accountRead(), rateLimits))),
            wham: FakeWhamClient.failing(AccountAdapterError.reauthRequired),
            metadataReader: Self.isolatedMetadataReader)
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertEqual(snap.secondaryUsedPct, 31)
        XCTAssertEqual(snap.secondaryWindowSeconds, 604_800, "minutes on the wire, seconds here")
        XCTAssertEqual(snap.primaryWindowSeconds, 18_000)
    }

    func testWhamSecondaryWindowWidthIsCarried() async throws {
        // `wham_blocked_enterprise` carries `secondary_window.limit_window_seconds: 604800`.
        let adapter = CodexAccountAdapter(
            rpc: FakeCodexRPC.failing(),
            wham: try FakeWhamClient.fixture("wham_blocked_enterprise"),
            metadataReader: Self.isolatedMetadataReader)
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertEqual(snap.secondaryWindowSeconds, 604_800, "already seconds on this transport")
    }

    /// The `goals_1.sqlite` signal rebuilds the snapshot too.
    func testUsageLimitedSignalPreservesTheSecondaryWindowWidth() async throws {
        let goalsPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-goals-secondary-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: goalsPath) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(goalsPath.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE thread_goals (thread_id TEXT PRIMARY KEY, status TEXT);
            INSERT INTO thread_goals (thread_id, status) VALUES ('t1', 'usage_limited');
            """, nil, nil, nil)
        sqlite3_close(db)

        let json = """
        {"rateLimits": {"limitId": "codex", "planType": "plus",
          "primary": {"windowDurationMins": 300, "usedPercent": 99, "resetsAt": 1789062609},
          "secondary": {"windowDurationMins": 10080, "usedPercent": 31, "resetsAt": 1789645984}}}
        """
        let rateLimits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(json.utf8))
        let adapter = CodexAccountAdapter(
            rpc: FakeCodexRPC(result: .success((try accountRead(), rateLimits))),
            wham: FakeWhamClient.failing(AccountAdapterError.reauthRequired),
            metadataReader: CodexSQLiteMetadataReader(
                statePath: URL(fileURLWithPath: "/nonexistent/state_5.sqlite"),
                goalsPath: goalsPath))
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertEqual(snap.rateLimitReached, true, "the signal applied")
        XCTAssertEqual(snap.secondaryWindowSeconds, 604_800)
    }

    private func accountRead() throws -> CodexAccountRead {
        try JSONDecoder().decode(CodexAccountRead.self, from: Data("""
        {"account": {"type": "chatgpt", "email": "user@domain.com", "planType": "go"}}
        """.utf8))
    }

    private func whamUsage(usedPercent: Double, resetAt: Int,
                           limitWindowSeconds: Int? = 2_592_000) throws -> CodexWhamUsage {
        let window = limitWindowSeconds.map { "\"limit_window_seconds\": \($0), " } ?? ""
        return try CodexWhamUsage.decode(from: Data("""
        {"plan_type": "go", "rate_limit": {"allowed": true, "limit_reached": false,
          "secondary_window": null,
          "primary_window": {\(window)"used_percent": \(usedPercent), "reset_at": \(resetAt)}}}
        """.utf8))
    }

    // MARK: 10 — the low-allowance shape, as the adapter actually builds it (REV-59 / STEP_88)

    /// **The predicate must hold on a snapshot this adapter really produced, not on one a test
    /// assembled.** Written after the first version shipped a "no credits" clause of
    /// `extraUsage == nil` — which no Codex snapshot can ever satisfy, because both transports
    /// hard-code `extraUsage: .disabled` as an Alpha-deferred placeholder (§8.1, P2-7/A2). The
    /// rule read correctly, matched nothing, and the live `go` account kept classifying Bad timing
    /// at 97%. Both transports are pinned, because a snapshot that suppressed burn on RPC and
    /// restored it on the wham fallback would re-open the storm at the worst moment.
    func testLowAllowanceShapeHoldsOnARealRPCSnapshot() async throws {
        let adapter = makeAdapter()
        // Anchored three days in: the reset is 27 days out, so this is a live window, not the
        // unanchored hypothetical above.
        let resetsAt = Int(Self.now.timeIntervalSince1970) + Self.thirtyDays - 3 * 86_400
        let snap = await adapter.normalize(
            account: try accountRead(),
            rateLimits: try rpcRateLimits(usedPercent: 97, resetsAt: resetsAt),
            now: Self.now)

        XCTAssertEqual(snap.extraUsage, .disabled,
                       "the placeholder that broke the first predicate — pinned so it stays visible")
        XCTAssertTrue(snap.isLowAllowanceShape)
    }

    func testLowAllowanceShapeHoldsOnARealWhamSnapshot() async throws {
        let adapter = makeAdapter()
        let resetAt = Int(Self.now.timeIntervalSince1970) + Self.thirtyDays - 3 * 86_400
        let snap = await adapter.normalize(wham: try whamUsage(usedPercent: 97, resetAt: resetAt),
                                           now: Self.now)
        XCTAssertTrue(snap.isLowAllowanceShape)
    }

    /// **Plus must not match — the defect STEP_101 exists for.** This is the real capture from the
    /// 2026-08-12 upgrade: one 7-day window, no secondary, no monthly limit, `hasCredits: false`.
    /// The old rule tested `primary ≥ 7 days`, so it matched exactly, and every Codex alert but
    /// Over quota went silent while the popover told a user at 3% used that "one working session
    /// can use most of it". Measured across 88 turns, Plus moves the meter 0.08% per turn against
    /// `go`'s ~7.1% — the regime the mute was written for is ~90x away.
    func testPlusShapeDoesNotMatch() async throws {
        let limits = try JSONDecoder().decode(
            CodexRateLimits.self, from: try fixtureData("ratelimits_plus_spend_control"))
        let account = try JSONDecoder().decode(CodexAccountRead.self, from: Data("""
        {"account": {"type": "chatgpt", "email": "user@domain.com", "planType": "plus"}}
        """.utf8))
        let adapter = makeAdapter()
        let snap = await adapter.normalize(account: account, rateLimits: limits, now: Self.now)

        XCTAssertEqual(snap.primaryWindowSeconds, 7 * 86_400,
                       "exactly the width the old ≥ 7-day test caught it on")
        XCTAssertNil(snap.secondaryUsedPct)
        XCTAssertNil(snap.monthlyLimit)
        XCTAssertFalse(snap.isLowAllowanceShape)
    }

    /// The five-hour + weekly pairing — every one in the corpus belongs to Enterprise/Business —
    /// must not match, or the accounts with a real burn story lose their card.
    ///
    /// The account read is Enterprise here, matching the rate-limit payload. It used to reuse the
    /// `go` helper and pass on window shape alone; since STEP_101 the plan name is decisive, so a
    /// `go` account stays muted whatever shape it reports — deliberate, and the reason the two
    /// halves of a fixture now have to agree with each other.
    func testFiveHourPlusWeeklyShapeDoesNotMatch() async throws {
        let json = """
        {"rateLimits": {"limitId": "codex", "planType": "enterprise",
          "primary": {"windowDurationMins": 300, "usedPercent": 62, "resetsAt": 1786230000},
          "secondary": {"windowDurationMins": 10080, "usedPercent": 40, "resetsAt": 1786800000}}}
        """
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(json.utf8))
        let account = try JSONDecoder().decode(CodexAccountRead.self, from: Data("""
        {"account": {"type": "chatgpt", "email": "user@domain.com", "planType": "enterprise"}}
        """.utf8))
        let adapter = makeAdapter()
        let snap = await adapter.normalize(account: account, rateLimits: limits, now: Self.now)
        XCTAssertFalse(snap.isLowAllowanceShape)
    }

    /// The live shape: 0% used, `reset_at` exactly one window-width from *this* request. No window
    /// has started — the provider is answering a hypothetical (spike F4/R20).
    func testUnanchoredWindowDropsResetViaRPC() async throws {
        let adapter = makeAdapter()
        let resetsAt = Int(Self.now.timeIntervalSince1970) + Self.thirtyDays
        let snap = await adapter.normalize(
            account: try accountRead(),
            rateLimits: try rpcRateLimits(usedPercent: 0, resetsAt: resetsAt),
            now: Self.now)

        XCTAssertEqual(snap.primaryUsedPct, 0, "0% is true and must survive — only the deadline was fiction")
        XCTAssertNil(snap.primaryResetsAt, "an unanchored window has no reset to report")
        XCTAssertEqual(snap.primaryWindowSeconds, Self.thirtyDays)
        XCTAssertTrue(snap.primaryWindowIsUnanchored)
        XCTAssertFalse(snap.isNullWindow, "unanchored is the partial case — utilization is still known")
    }

    /// The wham fallback must reach the same verdict from the same facts in different units,
    /// or a transport switch would silently re-open the storm (REV-57 §5).
    func testUnanchoredWindowDropsResetViaWham() async throws {
        let adapter = makeAdapter()
        let resetAt = Int(Self.now.timeIntervalSince1970) + Self.thirtyDays
        let snap = await adapter.normalize(wham: try whamUsage(usedPercent: 0, resetAt: resetAt),
                                           now: Self.now)

        XCTAssertEqual(snap.primaryUsedPct, 0)
        XCTAssertNil(snap.primaryResetsAt)
        XCTAssertEqual(snap.primaryWindowSeconds, Self.thirtyDays)
        XCTAssertTrue(snap.primaryWindowIsUnanchored)
    }

    /// **The regression pin.** A real 30-day window in progress — anchored at first use, so its
    /// reset is far nearer than a full width — must pass through untouched. The rule exists to
    /// ignore a window that never started, never to blind us to one that did.
    func testAnchoredWindowIsUntouched() async throws {
        let adapter = makeAdapter()
        // 57% used, anchored ~3 days ago: reset is 27 days out, not 30.
        let resetsAt = Int(Self.now.timeIntervalSince1970) + Self.thirtyDays - 3 * 86_400
        let snap = await adapter.normalize(
            account: try accountRead(),
            rateLimits: try rpcRateLimits(usedPercent: 57, resetsAt: resetsAt),
            now: Self.now)

        XCTAssertEqual(snap.primaryUsedPct, 57)
        XCTAssertEqual(snap.primaryResetsAt, Date(timeIntervalSince1970: TimeInterval(resetsAt)))
        XCTAssertFalse(snap.primaryWindowIsUnanchored)
    }

    /// No reported width ⇒ the rule cannot engage. This is the property that makes Claude
    /// structurally immune (it reports no window duration), so it is pinned rather than assumed.
    func testUnknownWindowDurationLeavesResetAlone() async throws {
        let adapter = makeAdapter()
        let resetsAt = Int(Self.now.timeIntervalSince1970) + Self.thirtyDays
        let snap = await adapter.normalize(
            account: try accountRead(),
            rateLimits: try rpcRateLimits(usedPercent: 0, resetsAt: resetsAt, windowDurationMins: nil),
            now: Self.now)

        XCTAssertNil(snap.primaryWindowSeconds)
        XCTAssertEqual(snap.primaryResetsAt, Date(timeIntervalSince1970: TimeInterval(resetsAt)))
        XCTAssertFalse(snap.primaryWindowIsUnanchored)
    }

    /// The tolerance boundary, from both sides. The provider's `reset_at` wobbles ±1s, and polls
    /// do not land on the instant the payload was built, so the match is fuzzy by exactly the
    /// jitter tolerance — no more.
    func testUnanchoredToleranceBoundary() {
        let base = Self.now.timeIntervalSince1970
        func unanchored(offsetFromFullWidth: TimeInterval) -> Bool {
            CodexAccountAdapter.isUnanchoredWindow(
                usedPct: 0,
                resetsAt: Date(timeIntervalSince1970: base + Double(Self.thirtyDays) + offsetFromFullWidth),
                windowSeconds: Self.thirtyDays, now: Self.now)
        }
        XCTAssertTrue(unanchored(offsetFromFullWidth: 0))
        XCTAssertTrue(unanchored(offsetFromFullWidth: 60), "±60s is the shared jitter tolerance")
        XCTAssertTrue(unanchored(offsetFromFullWidth: -60))
        XCTAssertFalse(unanchored(offsetFromFullWidth: 61))
        XCTAssertFalse(unanchored(offsetFromFullWidth: -61))
        // Non-zero utilization is the second clause: an anchored window one full width out (i.e.
        // one that just reset) keeps its reset.
        XCTAssertFalse(CodexAccountAdapter.isUnanchoredWindow(
            usedPct: 1, resetsAt: Date(timeIntervalSince1970: base + Double(Self.thirtyDays)),
            windowSeconds: Self.thirtyDays, now: Self.now))
    }

    // MARK: 9a — the invariance clause, replayed from the wire (REV-64 §4 / STEP_102)

    /// The four captured `account/rateLimits/read` bodies, with the instant each was **asked for**.
    /// Verbatim from `raw_payloads` on the dogfood database, 2026-08-13 (times UTC); the capture
    /// instant is metadata about the request, not part of the body, so it lives here.
    ///
    /// `reset − now` is the quantity the whole rule turns on: **invariant** across polls while the
    /// provider is recomputing a placeholder, **shrinking with the clock** once a real window has
    /// anchored.
    ///
    /// | fixture | asked at | reset − now | drift |
    /// |---|---|---|---|
    /// | `placeholder_t0` | 08:32:57 | 604800 | — |
    /// | `placeholder_t1` | 08:34:00 | 604800 | 0s |
    /// | `anchor_opened` | 08:34:47 | 604780 | **20s** |
    /// | `anchor_tracking` | 08:35:49 | 604718 | 62s across a 62s gap |
    private static let placeholderT0 = (fixture: "ratelimits_plus_placeholder_t0",
                                        askedAt: 1_786_609_977.0)
    private static let placeholderT1 = (fixture: "ratelimits_plus_placeholder_t1",
                                        askedAt: 1_786_610_040.0)
    private static let anchorOpened = (fixture: "ratelimits_plus_anchor_opened",
                                       askedAt: 1_786_610_087.0)
    private static let anchorTracking = (fixture: "ratelimits_plus_anchor_tracking",
                                         askedAt: 1_786_610_149.0)
    /// The overnight withdrawal, same database: a live 3% window at 01:48:13, gone by 03:42:02,
    /// still gone at 05:10:47 — 89 minutes later, and still invariant.
    private static let windowLive = (fixture: "ratelimits_plus_window_live",
                                     askedAt: 1_786_585_693.0)
    private static let windowWithdrawn = (fixture: "ratelimits_plus_window_withdrawn",
                                          askedAt: 1_786_592_522.0)
    private static let windowWithdrawnLater = (fixture: "ratelimits_plus_window_withdrawn_later",
                                               askedAt: 1_786_597_847.0)

    private func plusAccountRead() throws -> CodexAccountRead {
        try JSONDecoder().decode(CodexAccountRead.self, from: Data("""
        {"account": {"type": "chatgpt", "email": "user@domain.com", "planType": "plus"}}
        """.utf8))
    }

    /// Replays captured polls through the adapter in order, returning each resulting snapshot.
    /// Going through the **actor** rather than the static is the point: the retained raw pair is
    /// adapter state, and a test that fed the static directly would not prove it is carried.
    private func replay(
        _ polls: [(fixture: String, askedAt: Double)]
    ) async throws -> [QuotaSnapshot] {
        let adapter = makeAdapter()
        var out: [QuotaSnapshot] = []
        for poll in polls {
            let limits = try JSONDecoder().decode(
                CodexRateLimits.self, from: try fixtureData(poll.fixture))
            out.append(await adapter.normalize(
                account: try plusAccountRead(), rateLimits: limits,
                now: Date(timeIntervalSince1970: poll.askedAt)))
        }
        return out
    }

    /// **The defect, and the proof it is fixed.** Twenty seconds after a real weekly window opened,
    /// its true anchor sat 604,780s out — inside the 60s band — so the two-clause rule discarded it
    /// and the card read `Weekly · not started` for a window that had just started. The 20s of
    /// drift against a still poll is what tells them apart.
    func testRealAnchorSurvivesTheWindowStart() async throws {
        let snaps = try await replay([Self.placeholderT1, Self.anchorOpened])

        XCTAssertTrue(snaps[0].primaryWindowIsUnanchored, "08:34:00 is still the placeholder")
        XCTAssertFalse(snaps[1].primaryWindowIsUnanchored,
                       "08:34:47 is a real anchor — dropped pre-STEP_102, which is the defect")
        XCTAssertEqual(snaps[1].primaryResetsAt,
                       Date(timeIntervalSince1970: 1_787_214_867),
                       "the anchor the provider actually reported, kept verbatim")
        XCTAssertEqual(snaps[1].primaryUsedPct, 0,
                       "0% at a genuine start is normal — the clause that could not disambiguate")
    }

    /// The other side: two polls of a genuine placeholder still read as unanchored. `reset − now`
    /// is 604800 in both, drift 0s.
    func testPlaceholderSequenceStaysUnanchored() async throws {
        let snaps = try await replay([Self.placeholderT0, Self.placeholderT1])

        XCTAssertTrue(snaps[0].primaryWindowIsUnanchored)
        XCTAssertTrue(snaps[1].primaryWindowIsUnanchored,
                      "0s drift across 63s of wall clock — the provider is recomputing")
        XCTAssertNil(snaps[1].primaryResetsAt)
        XCTAssertEqual(snaps[1].primaryUsedPct, 0, "0% survives; only the deadline was fiction")
    }

    /// **The withdrawal itself, as the adapter sees it** — the input `StateEngine`'s demolition
    /// branch keys on (REV-64 §5). A live 3% window with a fixed anchor six days out, then a poll
    /// in which the provider has replaced it with a fresh placeholder. The adapter must report the
    /// first as anchored and the second as unanchored; the engine turns that pair into the
    /// `window_demolished` row.
    func testLiveWindowThenWithdrawalReadsAnchoredThenUnanchored() async throws {
        let snaps = try await replay([Self.windowLive, Self.windowWithdrawn])

        XCTAssertFalse(snaps[0].primaryWindowIsUnanchored, "01:48 — a real window, 3% spent")
        XCTAssertEqual(snaps[0].primaryUsedPct, 3)
        XCTAssertEqual(snaps[0].primaryResetsAt, Date(timeIntervalSince1970: 1_787_169_006),
                       "the anchor that held to the second across hundreds of polls")
        XCTAssertTrue(snaps[1].primaryWindowIsUnanchored,
                      "03:42 — the window is gone and the deadline is a placeholder again")
        XCTAssertEqual(snaps[1].primaryUsedPct, 0, "the counter was zeroed")
        XCTAssertNil(snaps[1].primaryResetsAt)
    }

    /// **Gap-independence — the property that defeated all four of REV-57's original guards.**
    /// These two polls are 89 minutes apart (the machine slept between them) and the verdict is
    /// unchanged, because invariance is not expressed as a fraction of the cadence.
    func testWithdrawnWindowStaysUnanchoredAcrossAnEightyNineMinuteGap() async throws {
        let snaps = try await replay([Self.windowWithdrawn, Self.windowWithdrawnLater])

        XCTAssertEqual(Self.windowWithdrawnLater.askedAt - Self.windowWithdrawn.askedAt, 5_325,
                       "the real gap between these two captures, in seconds")
        XCTAssertTrue(snaps[0].primaryWindowIsUnanchored)
        XCTAssertTrue(snaps[1].primaryWindowIsUnanchored,
                      "0s drift across 5,325s — a sleeping machine must not change the verdict")
    }

    /// Once anchored, a real window keeps its anchor as usage climbs — the reset stands still while
    /// `reset − now` shrinks by exactly the poll gap (62s across 62s).
    /// The full captured run, in order, so the window start has the predecessor it really had.
    func testAnchoredWindowTracksTheClock() async throws {
        let snaps = try await replay([Self.placeholderT1, Self.anchorOpened, Self.anchorTracking])

        XCTAssertFalse(snaps[2].primaryWindowIsUnanchored)
        XCTAssertEqual(snaps[2].primaryUsedPct, 1)
        XCTAssertEqual(snaps[2].primaryResetsAt, snaps[1].primaryResetsAt,
                       "the anchor is fixed in absolute time — that is what makes it real")
    }

    /// **The first poll of a process has no predecessor**, so it falls back to the two-clause rule
    /// — bounded at one poll, and REV-64 §11 rules against persisting the pair across relaunches.
    /// Replayed alone, the real anchor at 08:34:47 is therefore still dropped; it is only the
    /// *sequence* that recovers it (the test above). Pinned so the bound stays visible.
    func testFirstPollWithoutAPredecessorFallsBackToTwoClauses() async throws {
        let snaps = try await replay([Self.anchorOpened])
        XCTAssertTrue(snaps[0].primaryWindowIsUnanchored,
                      "no predecessor ⇒ REV-57's rule, unchanged — the documented one-poll bound")
    }

    /// The drift tolerance from both sides, on the static, holding the other two clauses satisfied.
    func testAnchorDriftToleranceBoundary() {
        let width = 604_800
        let askedAt = Date(timeIntervalSince1970: 1_786_610_040)
        let now = askedAt.addingTimeInterval(60)
        func unanchored(drift: TimeInterval) -> Bool {
            // `reset − now` shrinks by `drift`; the previous pair sat at exactly one full width.
            CodexAccountAdapter.isUnanchoredWindow(
                usedPct: 0,
                resetsAt: now.addingTimeInterval(TimeInterval(width) - drift),
                windowSeconds: width, now: now,
                previous: (askedAt: askedAt,
                           resetsAt: askedAt.addingTimeInterval(TimeInterval(width))))
        }
        XCTAssertTrue(unanchored(drift: 0), "observed placeholder drift is exactly 0s")
        XCTAssertTrue(unanchored(drift: 5))
        XCTAssertTrue(unanchored(drift: -5))
        XCTAssertFalse(unanchored(drift: 6))
        XCTAssertFalse(unanchored(drift: 20), "the real 10:34:47 anchor, in isolation")
    }

    // MARK: 10 — end-to-end: the storm, replayed (REV-57 §10, STEP_81 discipline)

    /// **The pre-fix failing case.** Three consecutive polls in the exact live shape — the bodies
    /// below are the real `account/rateLimits/read` payloads captured from `raw_payloads` at
    /// 23:44:35 / 23:45:42 / 23:46:48 on 2026-08-08, `resetsAt` advancing by the poll gap each time —
    /// driven through the whole path the app uses: `normalize` → `NotificationSignal` →
    /// `NotificationEngine.evaluateCycle`.
    ///
    /// Before the adapter rule this fired **2** notifications — one for every poll after the first,
    /// which only seeds the anchor there is nothing yet to compare against — and that is precisely
    /// the cadence at which the user received 89 of them. It must now fire **none**. The companion
    /// `NotificationEngineTests.testSlidingResetAnchorDefeatsEveryGuard` pins the other half: fed the
    /// raw anchors directly, the engine still misfires — so this test is passing because the shape no
    /// longer reaches it, not because the engine learned to cope.
    func testUnanchoredPollSequenceFiresNoResetNotifications() async throws {
        let adapter = makeAdapter()
        let presenter = RecordingPresenter()
        let engine = NotificationEngine(store: nil, presenter: presenter)

        // Verbatim from the live DB: polled_at → resetsAt, each exactly +2592000s.
        let polls: [(polledAt: Int, resetsAt: Int)] = [
            (1_786_225_475, 1_788_817_475),
            (1_786_225_542, 1_788_817_542),
            (1_786_225_608, 1_788_817_608),
        ]

        for poll in polls {
            let now = Date(timeIntervalSince1970: TimeInterval(poll.polledAt))
            let snapshot = await adapter.normalize(
                account: try accountRead(),
                rateLimits: try rpcRateLimits(usedPercent: 0, resetsAt: poll.resetsAt),
                now: now)
            let signal = NotificationSignal(
                tool: .codex, state: .healthy, utilizationPct: snapshot.primaryUsedPct,
                runwayMinutes: nil, resetsAt: snapshot.primaryResetsAt, now: now)
            await engine.evaluateCycle(change: nil, signal: signal, now: now)
        }

        XCTAssertEqual(presenter.count(.windowResetPost), 0,
                       "an unanchored window must not announce a reset — this fired 2 pre-fix")
        XCTAssertTrue(presenter.decisions.isEmpty, "no notification of any kind is warranted at 0%")
    }
}

/// Collects delivered notifications for assertion. Mirrors the Core suite's presenter; duplicated
/// rather than shared because the Core test target is not a dependency of this one.
private final class RecordingPresenter: NotificationPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [NotificationDecision] = []
    func present(_ decision: NotificationDecision) async {
        lock.withLock { stored.append(decision) }
    }
    var decisions: [NotificationDecision] { lock.withLock { stored } }
    func count(_ type: NotificationEventType) -> Int {
        decisions.filter { $0.eventType == type }.count
    }
}
