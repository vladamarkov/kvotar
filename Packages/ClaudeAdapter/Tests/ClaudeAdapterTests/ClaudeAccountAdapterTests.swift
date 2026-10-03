import XCTest
import KvotarCore
@testable import ClaudeAdapter

final class ClaudeAccountAdapterTests: XCTestCase {

    private let usageURL = ClaudeAccountAdapter.usageURL
    private let profileURL = ClaudeAccountAdapter.profileURL

    // MARK: - Helpers

    /// Builds an adapter whose usage endpoint returns the given fixture, with optional headers.
    /// The profile endpoint is left unrouted unless `profileFixture` is provided.
    private func makeAdapter(
        token: String? = "tok",
        subscriptionType: String? = nil,
        usageFixture: String? = nil,
        usageStatus: Int = 200,
        usageHeaders: [String: String] = [:],
        profileFixture: String? = nil,
        profileStatus: Int = 200,
        localConfigURL: URL? = nil
    ) throws -> (ClaudeAccountAdapter, MockFetcher) {
        let fetcher = MockFetcher()
        if let usageFixture {
            fetcher.setRoute(usageURL, StubResponse(
                data: try fixtureData(usageFixture), status: usageStatus, headers: usageHeaders))
        } else {
            fetcher.setRoute(usageURL, StubResponse(
                data: Data("{}".utf8), status: usageStatus, headers: usageHeaders))
        }
        if let profileFixture {
            fetcher.setRoute(profileURL, StubResponse(
                data: try fixtureData(profileFixture), status: profileStatus))
        }
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: token, subscriptionType: subscriptionType),
            fetcher: fetcher,
            localConfigURL: localConfigURL
        )
        return (adapter, fetcher)
    }

    // MARK: - Normalization

    func testHealthyNormalization() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_healthy")
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertEqual(snap.tool, .claude)
        XCTAssertNil(snap.nullWindowSource, "a present primary window has no null-window source")
        XCTAssertEqual(snap.primaryUsedPct, 12.0)
        XCTAssertEqual(snap.secondaryUsedPct, 8.0)
        XCTAssertEqual(snap.rateLimitReached, false)
        XCTAssertEqual(snap.extraUsage?.isEnabled, false)
        XCTAssertEqual(snap.source, .oauth, "source provenance drives popover tags (STEP_27)")
        let health = await adapter.health
        XCTAssertEqual(health, .healthy)
    }

    func testResetTimestampsParsed() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_healthy")
        let snap = try await adapter.fetchQuotaSnapshot()
        let expected = ISO8601DateFormatter().date(from: "2026-06-15T21:00:00Z")
        XCTAssertEqual(snap.primaryResetsAt, expected)
    }

    /// The usage endpoint reports `resets_at` with a ±1s wobble between polls. The adapter must
    /// collapse that to one stable value per window, but still adopt a genuine window rollover.
    func testResetsAtDeJitteredAcrossPolls() async throws {
        let fetcher = MockFetcher()
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher)

        func usage(reset: String) -> Data {
            Data("""
            {
              "five_hour": { "resets_at": "\(reset)", "utilization": 90.0 },
              "seven_day": { "resets_at": "2026-06-20T00:00:00Z", "utilization": 30.0 },
              "extra_usage": {
                "is_enabled": false, "monthly_limit": null, "used_credits": null,
                "utilization": null, "currency": null, "disabled_reason": null
              }
            }
            """.utf8)
        }
        let iso = ISO8601DateFormatter()
        let anchor = iso.date(from: "2026-06-15T21:00:00Z")

        // Poll 1 anchors the window.
        fetcher.setRoute(usageURL, StubResponse(data: usage(reset: "2026-06-15T21:00:00Z")))
        let p1 = try await adapter.fetchQuotaSnapshot().primaryResetsAt
        XCTAssertEqual(p1, anchor)

        // Poll 2 wobbles +1s → kept at the anchored value, not the jittered one.
        fetcher.setRoute(usageURL, StubResponse(data: usage(reset: "2026-06-15T21:00:01Z")))
        let p2 = try await adapter.fetchQuotaSnapshot().primaryResetsAt
        XCTAssertEqual(p2, anchor, "sub-second wobble must not move the reset instant")

        // Poll 3 is a genuine +5h rollover → adopted.
        fetcher.setRoute(usageURL, StubResponse(data: usage(reset: "2026-06-16T02:00:00Z")))
        let p3 = try await adapter.fetchQuotaSnapshot().primaryResetsAt
        XCTAssertEqual(p3, iso.date(from: "2026-06-16T02:00:00Z"))
    }

    func testElevatedAndAtRisk() async throws {
        let (elevated, _) = try makeAdapter(usageFixture: "usage_elevated")
        let elevatedPct = try await elevated.fetchQuotaSnapshot().primaryUsedPct
        XCTAssertEqual(elevatedPct, 62.0)

        let (atRisk, _) = try makeAdapter(usageFixture: "usage_at_risk")
        let atRiskPct = try await atRisk.fetchQuotaSnapshot().primaryUsedPct
        XCTAssertEqual(atRiskPct, 88.0)
    }

    func testBadTiming() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_bad_timing")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.primaryUsedPct, 96.0)
        let primary = try XCTUnwrap(snap.primaryUsedPct)
        let secondary = try XCTUnwrap(snap.secondaryUsedPct)
        XCTAssertLessThan(secondary, primary)
    }

    // MARK: - rate_limit_reached (task line 11)

    func testRateLimitReachedWhenOverHundred() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_over_quota_case1")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.rateLimitReached, true)
    }

    // MARK: - extra_usage cases (Baseline §7.1)

    func testExtraUsageEnabledShape() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_extra_enabled")
        let euSnap = try await adapter.fetchQuotaSnapshot()
        let eu = try XCTUnwrap(euSnap.extraUsage)
        XCTAssertTrue(eu.isEnabled)
        XCTAssertEqual(eu.monthlyLimit, 2000)
        XCTAssertEqual(eu.usedCredits, Decimal(0))
        XCTAssertEqual(eu.currency, "USD")
    }

    func testExtraUsageDisabledAllNull() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_extra_disabled")
        let euSnap = try await adapter.fetchQuotaSnapshot()
        let eu = try XCTUnwrap(euSnap.extraUsage)
        XCTAssertFalse(eu.isEnabled)
        XCTAssertNil(eu.monthlyLimit)
        XCTAssertNil(eu.usedCredits)
        XCTAssertNil(eu.currency)
    }

    func testOverQuotaCase1CreditsActive() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_over_quota_case1")
        let euSnap = try await adapter.fetchQuotaSnapshot()
        let eu = try XCTUnwrap(euSnap.extraUsage)
        XCTAssertTrue(eu.isEnabled)
        XCTAssertEqual(eu.usedCredits, Decimal(string: "3.25"))
    }

    func testOverQuotaCase3HardBlock() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_over_quota_case3")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.rateLimitReached, true)
        XCTAssertEqual(snap.extraUsage?.isEnabled, false)
        XCTAssertNil(snap.extraUsage?.usedCredits)
    }

    // MARK: - Case 2 mid-window credits cache (Baseline §7.1)

    func testCase2CachedCreditsSurfacedThenInvalidatedOnReset() async throws {
        let fetcher = MockFetcher()
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher)

        func usage(enabled: Bool, credits: String?, reset: String) -> Data {
            let creditsJSON = credits.map { $0 } ?? "null"
            return Data("""
            {
              "five_hour": { "resets_at": "\(reset)", "utilization": 110.0 },
              "seven_day": { "resets_at": "2026-06-20T00:00:00Z", "utilization": 30.0 },
              "extra_usage": {
                "is_enabled": \(enabled),
                "monthly_limit": 2000,
                "used_credits": \(creditsJSON),
                "utilization": null,
                "currency": "USD",
                "disabled_reason": null
              }
            }
            """.utf8)
        }

        // Poll 1 — enabled with credits in window A.
        fetcher.setRoute(usageURL, StubResponse(
            data: usage(enabled: true, credits: "4.50", reset: "2026-06-15T21:00:00Z")))
        _ = try await adapter.fetchQuotaSnapshot()

        // Poll 2 — disabled, same window → Case 2 surfaces the cached value.
        fetcher.setRoute(usageURL, StubResponse(
            data: usage(enabled: false, credits: nil, reset: "2026-06-15T21:00:00Z")))
        let case2Snap = try await adapter.fetchQuotaSnapshot()
        let case2 = try XCTUnwrap(case2Snap.extraUsage)
        XCTAssertFalse(case2.isEnabled)
        XCTAssertEqual(case2.usedCredits, Decimal(string: "4.50"))
        XCTAssertTrue(case2.usedCreditsIsCached,
                      "§7.1: the Case 2 value must carry last-observed provenance (STEP_27)")

        // Poll 3 — disabled, new window (reset changed) → cache invalidated → Case 3.
        fetcher.setRoute(usageURL, StubResponse(
            data: usage(enabled: false, credits: nil, reset: "2026-06-16T02:00:00Z")))
        let case3Snap = try await adapter.fetchQuotaSnapshot()
        let case3 = try XCTUnwrap(case3Snap.extraUsage)
        XCTAssertNil(case3.usedCredits)
        XCTAssertFalse(case3.usedCreditsIsCached)
    }

    // MARK: - Prepaid wallet: second OAuth call (Baseline §7.1, REV-29)

    private var prepaidURL: URL {
        ClaudeAccountAdapter.prepaidURL(orgId: "00000000-0000-0000-0000-000000000001")!
    }

    /// The org id is read from the profile's `organization.uuid`, then the second call succeeds and
    /// folds `amount`/`auto_reload_settings` into `snapshot.prepaid`. `amount` is cents (live shape).
    func testPrepaidSuccessFoldsWalletIntoSnapshot() async throws {
        let (adapter, fetcher) = try makeAdapter(usageFixture: "usage_extra_enabled",
                                                 profileFixture: "profile")
        fetcher.setRoute(prepaidURL, StubResponse(data: try fixtureData("prepaid_credits")))
        let snap = try await adapter.fetchQuotaSnapshot()
        let prepaid = try XCTUnwrap(snap.prepaid)
        XCTAssertEqual(prepaid.amountCents, 3024)                 // cents → $30.24
        XCTAssertEqual(prepaid.autoReloadOn, false)              // auto_reload_settings null ⇒ off
        XCTAssertNotNil(prepaid.asOf)
        XCTAssertEqual(prepaid.currency, "USD", "the wallet's own currency rides along (STEP_219)")
    }

    /// The currency is display-only, so an unexpected shape costs the code, never the balance
    /// (the REV-91 rule: only what the app acts on may fail).
    func testPrepaidCurrencyOfAnUnexpectedShapeDegradesToNil() async throws {
        let (adapter, fetcher) = try makeAdapter(usageFixture: "usage_extra_enabled",
                                                 profileFixture: "profile")
        fetcher.setRoute(prepaidURL, StubResponse(data: Data(
            #"{"amount": 3024, "currency": {"code": "EUR"}, "auto_reload_settings": null}"#.utf8)))
        let snap = try await adapter.fetchQuotaSnapshot()
        let prepaid = try XCTUnwrap(snap.prepaid)
        XCTAssertEqual(prepaid.amountCents, 3024)
        XCTAssertNil(prepaid.currency)
    }

    /// A failed / unrouted prepaid call must NOT fail the quota poll — the snapshot still returns,
    /// with `prepaid == nil` (the §2.4a card then drops balance/auto-reload, keeps extra_usage).
    func testPrepaidFailureDoesNotBlockQuotaPoll() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_extra_enabled",
                                           profileFixture: "profile")   // prepaid URL unrouted → throws internally
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.primaryUsedPct, 20.0)                // quota poll unaffected
        XCTAssertNil(snap.prepaid)                               // degrade to nil
        let health = await adapter.health
        XCTAssertEqual(health, .healthy, "a prepaid failure must not pollute AdapterHealth")
    }

    /// The prepaid call is rate-limited to `prepaidMinInterval`: a second poll inside the window
    /// serves the cached wallet without re-hitting the endpoint (REV-14 volume guard).
    func testPrepaidCadenceGateSkipsRefetchInsideWindow() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_extra_enabled")))
        fetcher.setRoute(profileURL, StubResponse(data: try fixtureData("profile")))
        fetcher.setRoute(prepaidURL, StubResponse(data: try fixtureData("prepaid_credits")))
        // Frozen clock — both polls land at the same instant, well inside the 15-min interval.
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher, now: { frozen })
        _ = try await adapter.fetchQuotaSnapshot()
        _ = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(fetcher.requestCount(for: prepaidURL), 1,
                       "second poll inside the interval must reuse the cached wallet")
    }

    /// Past `prepaidMinInterval` the wallet is refetched (auto-reload can flip out-of-band). The
    /// `prepaidMinInterval + 1` jump is also longer than `coldPollThreshold`, so the poll straight
    /// after it is a cold wake poll that (correctly, Change B) defers the refetch one cadence; the
    /// following warm poll performs it. This validates the composed defer-then-resume behaviour —
    /// the 900s gate logic itself is unchanged.
    func testPrepaidRefetchesAfterInterval() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_extra_enabled")))
        fetcher.setRoute(profileURL, StubResponse(data: try fixtureData("profile")))
        fetcher.setRoute(prepaidURL, StubResponse(data: try fixtureData("prepaid_credits")))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher, now: { clock.now })
        _ = try await adapter.fetchQuotaSnapshot()                       // poll 1 — fetches (count 1)
        clock.now = clock.now.addingTimeInterval(ClaudeAccountAdapter.prepaidMinInterval + 1)
        _ = try await adapter.fetchQuotaSnapshot()                       // poll 2 — cold wake, deferred
        XCTAssertEqual(fetcher.requestCount(for: prepaidURL), 1,
                       "the first poll after the wake gap defers the refetch (Change B)")
        clock.now = clock.now.addingTimeInterval(60)                     // next warm poll
        _ = try await adapter.fetchQuotaSnapshot()                       // poll 3 — refetches (count 2)
        XCTAssertEqual(fetcher.requestCount(for: prepaidURL), 2)
    }

    /// A thread-safe mutable clock for the cadence tests (the adapter's `now` seam is `@Sendable`).
    /// Lock-guarded because the seam is read across actor hops while the test advances it.
    private final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        var now: Date {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }
        init(_ now: Date) { _now = now }
    }

    // MARK: - Prepaid is Pro/Max-only, and a 401/403 latches for the token (§7.1 — STEP_168, REV-88)

    private var teamPrepaidURL: URL {
        ClaudeAccountAdapter.prepaidURL(orgId: "00000000-0000-0000-0000-000000000021")!
    }

    /// Polls at warm cadence (300 s steps stay under `coldPollThreshold`) across `count` ticks.
    private func pollWarm(_ adapter: ClaudeAccountAdapter, clock: MutableClock, ticks: Int) async throws {
        for _ in 0..<ticks {
            clock.now = clock.now.addingTimeInterval(300)
            _ = try await adapter.fetchQuotaSnapshot()
        }
    }

    /// The tester's shape (2026-09-07 bundle): `organization_type: claude_team`, neither plan
    /// boolean set. The endpoint 403s such a seat, and that 403 preceded all 35 of his one-hour
    /// lockouts — so it is never called, across as many cadence windows as you like.
    func testTeamProfileNeverCallsPrepaid() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_extra_enabled")))
        fetcher.setRoute(profileURL, StubResponse(data: try fixtureData("profile_team")))
        fetcher.setRoute(teamPrepaidURL, StubResponse(data: try fixtureData("prepaid_credits")))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher, now: { clock.now })
        let snap = try await adapter.fetchQuotaSnapshot()
        try await pollWarm(adapter, clock: clock, ticks: 4)        // 20 min — past prepaidMinInterval
        XCTAssertEqual(fetcher.requestCount(for: teamPrepaidURL), 0,
                       "a Team seat must never hit the prepaid endpoint")
        XCTAssertNil(snap.prepaid)
        XCTAssertEqual(snap.primaryUsedPct, 20.0, "the quota poll itself is untouched")
        let health = await adapter.health
        XCTAssertEqual(health, .healthy)
    }

    /// The positive direction the cadence tests above rely on, pinned explicitly: a Max profile
    /// still makes the call and folds the wallet.
    func testMaxProfileStillCallsPrepaid() async throws {
        let (adapter, fetcher) = try makeAdapter(usageFixture: "usage_extra_enabled",
                                                 profileFixture: "profile_max")
        fetcher.setRoute(prepaidURL, StubResponse(data: try fixtureData("prepaid_credits")))
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(fetcher.requestCount(for: prepaidURL), 1)
        XCTAssertEqual(snap.prepaid?.amountCents, 3024)
    }

    /// A 403 from the endpoint latches for the token: the 15-minute cadence gate no longer
    /// retries it, and the wallet degrades to nil as a plain failure already does.
    func testPrepaid403StopsFurtherCallsForTheToken() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_extra_enabled")))
        fetcher.setRoute(profileURL, StubResponse(data: try fixtureData("profile")))
        fetcher.setRoute(prepaidURL, StubResponse(data: Data("{}".utf8), status: 403))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher, now: { clock.now })
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(fetcher.requestCount(for: prepaidURL), 1, "the first call is made")
        XCTAssertNil(snap.prepaid)
        try await pollWarm(adapter, clock: clock, ticks: 8)        // 40 min — two cadence windows
        XCTAssertEqual(fetcher.requestCount(for: prepaidURL), 1,
                       "after a 403 the endpoint is not called again for this token")
        let health = await adapter.health
        XCTAssertEqual(health, .healthy)
    }

    /// A 401 is the same statement from the server and latches the same way.
    func testPrepaid401AlsoLatches() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_extra_enabled")))
        fetcher.setRoute(profileURL, StubResponse(data: try fixtureData("profile")))
        fetcher.setRoute(prepaidURL, StubResponse(data: Data("{}".utf8), status: 401))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher, now: { clock.now })
        _ = try await adapter.fetchQuotaSnapshot()
        try await pollWarm(adapter, clock: clock, ticks: 4)
        XCTAssertEqual(fetcher.requestCount(for: prepaidURL), 1)
    }

    /// The latch is per token: a rotated credential re-reads the profile and gets one fresh call.
    func testTokenChangeReopensThePrepaidGate() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_extra_enabled")))
        fetcher.setRoute(profileURL, StubResponse(data: try fixtureData("profile")))
        fetcher.setRouteSequence(prepaidURL, [
            StubResponse(data: Data("{}".utf8), status: 403),                 // under token A
            StubResponse(data: try fixtureData("prepaid_credits")),           // under token B
        ])
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: SequenceTokenProvider(["A", "A", "B"]), fetcher: fetcher,
            now: { clock.now })
        _ = try await adapter.fetchQuotaSnapshot()                       // A — 403, latched
        try await pollWarm(adapter, clock: clock, ticks: 1)              // A — no call
        XCTAssertEqual(fetcher.requestCount(for: prepaidURL), 1)
        clock.now = clock.now.addingTimeInterval(300)
        let snap = try await adapter.fetchQuotaSnapshot()                // B — gate reopened
        XCTAssertEqual(fetcher.requestCount(for: prepaidURL), 2, "one fresh call for the new token")
        XCTAssertEqual(snap.prepaid?.amountCents, 3024)
    }

    // MARK: - Credential change during an advertised cooldown (§9.3 — STEP_168)

    /// Before any poll there is no baseline: the first read records one and answers false; a
    /// later read of a different token answers true. No request is made at any point.
    func testCredentialChangedRecordsABaselineWhenNoneExists() async throws {
        let fetcher = MockFetcher()
        let adapter = ClaudeAccountAdapter(
            tokenProvider: SequenceTokenProvider(["A", "B"]), fetcher: fetcher)
        let first = await adapter.credentialChanged()
        XCTAssertFalse(first, "no baseline yet — the fresh token becomes it")
        let second = await adapter.credentialChanged()
        XCTAssertTrue(second, "a different token than the recorded baseline")
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 0, "read-only: nothing on the wire")
    }

    /// After a poll the baseline is the token that poll sent; the same token on disk is not a change.
    func testCredentialChangedIsFalseForTheSameToken() async throws {
        let (adapter, fetcher) = try makeAdapter(usageFixture: "usage_healthy")
        _ = try await adapter.fetchQuotaSnapshot()
        let changed = await adapter.credentialChanged()
        XCTAssertFalse(changed)
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 1, "the check itself sends nothing")
    }

    /// A rotation after the poll is the sanctioned early probe.
    func testCredentialChangedIsTrueAfterARotation() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_healthy")))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: SequenceTokenProvider(["A", "B"]), fetcher: fetcher)
        _ = try await adapter.fetchQuotaSnapshot()                       // sent A
        let changed = await adapter.credentialChanged()                  // reads B
        XCTAssertTrue(changed)
    }

    /// The baseline is the token *sent*, so a 429'd request still sets it.
    func testCredentialChangedBaselineIsSetOnA429Too() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: Data("{}".utf8), status: 429,
                                                headers: ["Retry-After": "3600"]))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: SequenceTokenProvider(["A", "B"]), fetcher: fetcher)
        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { _ in }
        let changed = await adapter.credentialChanged()
        XCTAssertTrue(changed, "A was sent and refused; B on disk is a change")
    }

    /// A different but already-expired token is not a reason to probe — the request would only
    /// hit the pre-poll expiry gate.
    func testCredentialChangedIgnoresAnExpiredReplacement() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_healthy")))
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let adapter = ClaudeAccountAdapter(
            tokenProvider: SequenceTokenProvider(["A", "B"],
                                                 expiresAt: [nil, (frozen.timeIntervalSince1970 - 60) * 1000]),
            fetcher: fetcher, now: { frozen })
        _ = try await adapter.fetchQuotaSnapshot()
        let changed = await adapter.credentialChanged()
        XCTAssertFalse(changed, "expired replacement ⇒ no probe")
    }

    /// A Keychain read that fails answers false — never a probe, never a dialog.
    func testCredentialChangedIsFalseWhenTheReadFails() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_healthy")))
        let provider = ToggleThrowingTokenProvider(token: "tok")
        let adapter = ClaudeAccountAdapter(tokenProvider: provider, fetcher: fetcher)
        _ = try await adapter.fetchQuotaSnapshot()
        provider.throwing = true
        let changed = await adapter.credentialChanged()
        XCTAssertFalse(changed)
    }

    // MARK: - Wake stagger: secondary-call deferral (Baseline §20 P1-12, REV-37 — STEP_42)

    /// A true first-ever poll is not a wake: it fetches usage AND the secondary calls (profile,
    /// prepaid) so email/credits are present immediately. A same-instant second poll is steady
    /// state — usage again, profile once/token, prepaid served from cache. Guards the design
    /// decision that a nil anchor (`lastFetchAt == nil`) is not deferred.
    func testColdStartFetchesSecondariesThenSteadyState() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_extra_enabled")))
        fetcher.setRoute(profileURL, StubResponse(data: try fixtureData("profile")))
        fetcher.setRoute(prepaidURL, StubResponse(data: try fixtureData("prepaid_credits")))
        let frozen = Date(timeIntervalSince1970: 1_700_000_000)
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher, now: { frozen })

        let snap = try await adapter.fetchQuotaSnapshot()               // cold start — not a wake
        XCTAssertEqual(fetcher.requestCount(for: profileURL), 1, "cold start fetches profile")
        XCTAssertEqual(fetcher.requestCount(for: prepaidURL), 1, "cold start fetches prepaid")
        XCTAssertNotNil(snap.prepaid)
        XCTAssertNotNil(snap.email)

        _ = try await adapter.fetchQuotaSnapshot()                      // steady state, same instant
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 2, "usage fires every poll")
        XCTAssertEqual(fetcher.requestCount(for: profileURL), 1, "profile once per token")
        XCTAssertEqual(fetcher.requestCount(for: prepaidURL), 1, "prepaid served from cache (gated)")
    }

    /// The first poll after a gap longer than `coldPollThreshold` makes ONLY the usage call — the
    /// secondary calls are deferred one cadence even though the prepaid gate is open by now — and
    /// still returns a valid snapshot (usage alone answers "am I safe?"). The resume on the next
    /// warm poll is covered by `testPrepaidRefetchesAfterInterval`.
    func testWakeGapMakesOnlyUsageCall() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_extra_enabled")))
        fetcher.setRoute(profileURL, StubResponse(data: try fixtureData("profile")))
        fetcher.setRoute(prepaidURL, StubResponse(data: try fixtureData("prepaid_credits")))
        let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher, now: { clock.now })

        _ = try await adapter.fetchQuotaSnapshot()                      // poll 1 — anchors, fetches all
        // Past coldPollThreshold AND past prepaidMinInterval: the prepaid gate is open, so a
        // refetch is due — the deferral is what holds it back at the contended wake moment.
        clock.now = clock.now.addingTimeInterval(ClaudeAccountAdapter.prepaidMinInterval + 1)
        let wakeSnap = try await adapter.fetchQuotaSnapshot()           // poll 2 — cold wake

        XCTAssertEqual(fetcher.requestCount(for: usageURL), 2, "the wake poll still makes the usage call")
        XCTAssertEqual(fetcher.requestCount(for: prepaidURL), 1,
                       "the wake poll defers the prepaid refetch despite the open gate")
        XCTAssertEqual(wakeSnap.primaryUsedPct, 20.0, "usage alone still answers the safety question")
    }

    /// An account with no `extra_usage` object (Enterprise) decodes without failing the poll, and
    /// surfaces `extraUsage == nil` (the §2.4a card is then suppressed entirely).
    func testMissingExtraUsageObjectDecodesAsNil() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: Data("""
        { "five_hour": { "resets_at": "2026-06-15T21:00:00Z", "utilization": 12.0 },
          "seven_day": { "resets_at": "2026-06-20T00:00:00Z", "utilization": 8.0 } }
        """.utf8)))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher)
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.primaryUsedPct, 12.0)                // poll succeeds
        XCTAssertNil(snap.extraUsage)                           // card suppressed
    }

    // MARK: - Not-started shape (STEP_32 capture 2026-07-06 → REV-80 / D-101, STEP_147)

    /// With no active session the endpoint returns `five_hour: { resets_at: null, utilization: 0 }`
    /// — a literal 0, not null (live capture 2026-07-07 12:37 UTC). That is a window that has
    /// **not started**, and since REV-80 / D-101 it is emitted in the same shape Codex uses for
    /// its placeholder: `0%`, no reset, the 18 000 s width, `primaryWindowIsUnanchored` — not a
    /// nil percent (the 2026-07-07 drop this test used to pin). The live weekly values stay intact.
    func testNullFiveHourWindowDecodesWithLiveWeekly() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_null_five_hour")
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertEqual(snap.primaryUsedPct, 0, "the payload's 0 is kept (REV-80 reverses the drop)")
        XCTAssertNil(snap.primaryResetsAt)
        XCTAssertEqual(snap.primaryWindowSeconds, 18_000, "Claude's true width, on every snapshot")
        XCTAssertTrue(snap.primaryWindowIsUnanchored, "the REV-57 not-started shape, from Claude")
        XCTAssertNil(snap.nullWindowSource, "a present object is not a null window (§9.5)")
        XCTAssertEqual(snap.rateLimitReached, false)
        XCTAssertFalse(snap.isNullWindow)
        XCTAssertEqual(snap.secondaryUsedPct, 51.0)
        XCTAssertEqual(snap.secondaryResetsAt,
                       ISO8601DateFormatter().date(from: "2026-07-10T09:00:00Z"))
        let health = await adapter.health
        XCTAssertEqual(health, .healthy)
    }

    /// The same shape with no weekly at all still reads not-started, never null.
    func testPresentFiveHourWithNullResetIsNotStarted() async throws {
        let fetcher = MockFetcher()
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher)
        fetcher.setRoute(usageURL, StubResponse(data: Data("""
        { "five_hour": { "resets_at": null, "utilization": 0 }, "seven_day": null }
        """.utf8)))
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertTrue(snap.primaryWindowIsUnanchored)
        XCTAssertEqual(snap.primaryUsedPct, 0)
        XCTAssertNil(snap.nullWindowSource)
        XCTAssertFalse(snap.isNullWindow, "0% is a reading; both-null needs an absent object")
    }

    /// An **absent** `five_hour` object (Enterprise, §8.0.2 2026-07-16) keeps the nil-percent
    /// normalisation — provider-origin null window, §13 item 12, the monthly layout. Nothing on
    /// that path moved with REV-80.
    func testAbsentFiveHourStaysNullWindow() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_null_both")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertNil(snap.primaryUsedPct)
        XCTAssertNil(snap.primaryResetsAt)
        XCTAssertEqual(snap.nullWindowSource, .provider)
        XCTAssertFalse(snap.primaryWindowIsUnanchored, "no percent ⇒ not the not-started shape")
        XCTAssertNil(snap.rateLimitReached, "no window → over-quota is unknowable, not false")
    }

    func testBothWindowsNullDecodes() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_null_both")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertNil(snap.primaryUsedPct)
        XCTAssertNil(snap.secondaryUsedPct)
        XCTAssertTrue(snap.isNullWindow)
    }

    /// A present-but-unparseable `resets_at` degrades that one window to nil instead of failing
    /// the poll — the other window's live data must survive.
    func testUnparseableResetDegradesWindowInsteadOfFailing() async throws {
        let fetcher = MockFetcher()
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher)
        fetcher.setRoute(usageURL, StubResponse(data: Data("""
        {
          "five_hour": { "resets_at": "not-a-timestamp", "utilization": 12.0 },
          "seven_day": { "resets_at": "2026-07-10T09:00:00Z", "utilization": 51.0 },
          "extra_usage": {
            "is_enabled": false, "monthly_limit": null, "used_credits": null,
            "utilization": null, "currency": null, "disabled_reason": null
          }
        }
        """.utf8)))
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertNil(snap.primaryResetsAt)
        XCTAssertEqual(snap.primaryUsedPct, 12.0)
        XCTAssertEqual(snap.secondaryUsedPct, 51.0)
    }

    /// A null primary window invalidates the Case 2 credits cache — the window the credits
    /// belonged to is gone, so the disabled shape must render Case 3, not a stale cached value.
    func testNullWindowInvalidatesCreditsCache() async throws {
        let fetcher = MockFetcher()
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher)

        func usage(enabled: Bool, credits: String?, reset: String?) -> Data {
            let creditsJSON = credits ?? "null"
            let resetJSON = reset.map { "\"\($0)\"" } ?? "null"
            let utilJSON = reset == nil ? "null" : "110.0"
            return Data("""
            {
              "five_hour": { "resets_at": \(resetJSON), "utilization": \(utilJSON) },
              "seven_day": { "resets_at": "2026-06-20T00:00:00Z", "utilization": 30.0 },
              "extra_usage": {
                "is_enabled": \(enabled),
                "monthly_limit": 2000,
                "used_credits": \(creditsJSON),
                "utilization": null,
                "currency": "USD",
                "disabled_reason": null
              }
            }
            """.utf8)
        }

        fetcher.setRoute(usageURL, StubResponse(
            data: usage(enabled: true, credits: "4.50", reset: "2026-06-15T21:00:00Z")))
        _ = try await adapter.fetchQuotaSnapshot()

        fetcher.setRoute(usageURL, StubResponse(
            data: usage(enabled: false, credits: nil, reset: nil)))
        let euSnap = try await adapter.fetchQuotaSnapshot()
        let eu = try XCTUnwrap(euSnap.extraUsage)
        XCTAssertNil(eu.usedCredits)
        XCTAssertFalse(eu.usedCreditsIsCached)
    }

    // MARK: - Auth / health states

    func testSetupRequiredWhenNoToken() async throws {
        let (adapter, _) = try makeAdapter(token: nil, usageFixture: "usage_healthy")
        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            XCTAssertEqual(error as? AccountAdapterError, .setupRequired)
        }
        let health = await adapter.health
        XCTAssertEqual(health, .setupRequired)
    }

    func testReauthRequiredOn401() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_healthy", usageStatus: 401)
        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            XCTAssertEqual(error as? AccountAdapterError, .reauthRequired)
        }
        let health = await adapter.health
        XCTAssertEqual(health, .reauthRequired)
    }

    // MARK: - 401/403 rotation self-heal (Baseline §8.0.1, REV-37 — STEP_42, Change C)

    /// A rotation landing between our Keychain read and the usage GET yields a 401; a fresh
    /// `credential()` read gives a *different* token, and a single retry succeeds. `.reauthRequired`
    /// is not thrown, the snapshot returns, and exactly one extra usage GET was made.
    func test401RotationSelfHeals() async throws {
        let fetcher = MockFetcher()
        fetcher.setRouteSequence(usageURL, [
            StubResponse(data: Data("{}".utf8), status: 401),               // stale token rejected
            StubResponse(data: try fixtureData("usage_healthy"), status: 200),  // rotated token OK
        ])
        let adapter = ClaudeAccountAdapter(
            tokenProvider: SequenceTokenProvider(["stale", "rotated"]), fetcher: fetcher)

        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.primaryUsedPct, 12.0, "the retry's 200 body is used")
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 2, "exactly one retry")
        let health = await adapter.health
        XCTAssertEqual(health, .healthy, "a rotation race must not leave a reauth-required freeze")
    }

    /// A genuine expired/revoked token: the re-read yields the *same* token, so no retry is made and
    /// `.reauthRequired` surfaces immediately (unchanged behaviour), after a single usage GET.
    func test401SameTokenStillReauths() async throws {
        let fetcher = MockFetcher()
        fetcher.setRouteSequence(usageURL, [
            StubResponse(data: Data("{}".utf8), status: 401),
            StubResponse(data: try fixtureData("usage_healthy"), status: 200),  // would succeed IF retried
        ])
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher)   // same token each read

        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            XCTAssertEqual(error as? AccountAdapterError, .reauthRequired)
        }
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 1, "same token → no retry")
        let health = await adapter.health
        XCTAssertEqual(health, .reauthRequired)
    }

    /// A different token but the retry also 401s (not a rotation race after all): `.reauthRequired`
    /// surfaces, and only one retry was attempted — one retry, never a loop.
    func test401PersistsThrowsAfterOneRetry() async throws {
        let fetcher = MockFetcher()
        fetcher.setRouteSequence(usageURL, [
            StubResponse(data: Data("{}".utf8), status: 401),
            StubResponse(data: Data("{}".utf8), status: 401),
        ])
        let adapter = ClaudeAccountAdapter(
            tokenProvider: SequenceTokenProvider(["stale", "rotated"]), fetcher: fetcher)

        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            XCTAssertEqual(error as? AccountAdapterError, .reauthRequired)
        }
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 2, "exactly one retry, no loop")
        let health = await adapter.health
        XCTAssertEqual(health, .reauthRequired)
    }

    func testRateLimitedWithRetryAfter() async throws {
        let (adapter, _) = try makeAdapter(
            usageFixture: "usage_healthy", usageStatus: 429,
            usageHeaders: ["Retry-After": "90"])
        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            guard case .rateLimited(let retryAfter, let details)? = error as? AccountAdapterError else {
                return XCTFail("expected rateLimited, got \(String(describing: error))")
            }
            XCTAssertEqual(retryAfter, 90)
            XCTAssertEqual(details?.category, "rate_pressure", "90s > floor → rate_pressure (§9.5)")
            XCTAssertEqual(details?.headers["Retry-After"], "90", "the forensic row captures headers")
        }
        let health = await adapter.health
        XCTAssertEqual(health, .rateLimited(retryAfter: 90))
    }

    func testRateLimitedDefaultRetryAfterWhenAbsent() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_healthy", usageStatus: 429)
        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            guard case .rateLimited(let retryAfter, let details)? = error as? AccountAdapterError else {
                return XCTFail("expected rateLimited, got \(String(describing: error))")
            }
            XCTAssertEqual(retryAfter, 120, "absent Retry-After defaults to 120")
            XCTAssertEqual(details?.category, "unknown", "absent Retry-After → unknown category (§9.5)")
        }
    }

    /// §9.5 / §10.6 — the forensic body is captured and redacted: the bearer token is never stored.
    func testRateLimited429BodyRedactsBearerToken() async throws {
        let secret = "SECRET-ACCESS-TOKEN-abc123"
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(
            data: Data("{\"error\":\"rate_limited\",\"leaked\":\"Bearer \(secret)\"}".utf8),
            status: 429, headers: ["Retry-After": "0"]))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: secret), fetcher: fetcher)
        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            guard case .rateLimited(_, let details)? = error as? AccountAdapterError,
                  let body = details?.body else {
                return XCTFail("expected rateLimited with a captured body, got \(String(describing: error))")
            }
            XCTAssertFalse(body.contains(secret), "the bearer token must never be stored (§10.6)")
            XCTAssertTrue(body.contains("<redacted>"), "the token is replaced in place")
            XCTAssertTrue(body.contains("rate_limited"), "the rest of the body is preserved for forensics")
            XCTAssertEqual(details?.category, "transient", "Retry-After: 0 ≤ floor → transient (§9.5)")
        }
    }

    // MARK: - Rate-limit headers (Baseline §9.2)

    func testHeadersStoredInSnapshot() async throws {
        let (adapter, _) = try makeAdapter(
            usageFixture: "usage_healthy",
            usageHeaders: [
                "X-RateLimit-Limit": "1000",
                "X-RateLimit-Remaining": "640",
                "X-RateLimit-Reset": "1800000000",
            ])
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.rateLimitLimit, 1000)
        XCTAssertEqual(snap.rateLimitRemaining, 640)
        XCTAssertEqual(snap.rateLimitReset, Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: - Email (Baseline §8.0.3)

    func testEmailFromProfileEndpoint() async throws {
        let (adapter, _) = try makeAdapter(
            usageFixture: "usage_healthy", profileFixture: "profile")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.email, "dev@example.com")
    }

    func testEmailFallsBackToLocalConfigWhenProfileFails() async throws {
        let (adapter, _) = try makeAdapter(
            usageFixture: "usage_healthy",
            profileFixture: "profile", profileStatus: 500,
            localConfigURL: try fixtureURL("local_claude_config"))
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.email, "fallback@example.com")
    }

    func testProfileFetchedOncePerToken() async throws {
        let (adapter, fetcher) = try makeAdapter(
            usageFixture: "usage_healthy", profileFixture: "profile")
        _ = try await adapter.fetchQuotaSnapshot()
        _ = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(fetcher.requestCount(for: profileURL), 1)
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 2)
    }

    // MARK: - plan_type (Baseline §8.0.3, §9.4)

    func testPlanFromProfileProBoolean() async throws {
        let (adapter, _) = try makeAdapter(
            usageFixture: "usage_healthy", profileFixture: "profile")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.planType, "pro")
    }

    func testPlanFromProfileMaxBoolean() async throws {
        let (adapter, _) = try makeAdapter(
            usageFixture: "usage_healthy", profileFixture: "profile_max")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.planType, "max")
    }

    func testPlanFromKeychainSubscriptionWhenNoProfile() async throws {
        // No profile routed → profile fetch fails → Keychain subscriptionType is used.
        let (adapter, _) = try makeAdapter(
            subscriptionType: "max", usageFixture: "usage_healthy")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.planType, "max")
    }

    func testPlanNormalizesOddKeychainValue() async throws {
        let (adapter, _) = try makeAdapter(
            subscriptionType: "claude_pro_monthly", usageFixture: "usage_healthy")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.planType, "pro")
    }

    func testPlanRetainsRawUnrecognizedKeychainValue() async throws {
        let (adapter, _) = try makeAdapter(
            subscriptionType: "team_enterprise", usageFixture: "usage_healthy")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.planType, "team_enterprise")
    }

    func testProfilePlanTakesPrecedenceOverKeychain() async throws {
        // Keychain says pro, profile authoritatively says max → profile wins.
        let (adapter, _) = try makeAdapter(
            subscriptionType: "pro", usageFixture: "usage_healthy", profileFixture: "profile_max")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.planType, "max")
    }

    func testPlanNilWhenNoSource() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_healthy")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertNil(snap.planType)
    }

    // MARK: - Enterprise monthly spend (Baseline §8.0.4, REV-40 — STEP_46)

    private var enterprisePrepaidURL: URL {
        ClaudeAccountAdapter.prepaidURL(orgId: "00000000-0000-0000-0000-000000000011")!
    }

    /// The 2026-07-16 capture's shape, with synthetic amounts: `spend` normalizes to the unit-generalized
    /// `MonthlyLimit` with the client-derived calendar-month reset; the minor-unit `extra_usage`
    /// mirror is normalized away (D-37 — this is the "$6916.00 of $120.00" bug dying); the
    /// persistent null windows keep their provider-origin null (rank-12, never broken/idle).
    func testEnterpriseSpendMapsToMonthlyLimit() async throws {
        let frozen = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_enterprise_spend")))
        fetcher.setRoute(profileURL,
                         StubResponse(data: try fixtureData("profile_enterprise_usage_based")))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher, now: { frozen })
        let snap = try await adapter.fetchQuotaSnapshot()

        let monthly = try XCTUnwrap(snap.monthlyLimit)
        XCTAssertEqual(monthly.usedAmount, 6916, "raw minor units — $69.16")
        XCTAssertEqual(monthly.limitAmount, 12000, "raw minor units — $120.00")
        XCTAssertEqual(monthly.unit, .money(currency: "USD", exponent: 2))
        XCTAssertEqual(monthly.remainingPercent, 42, "100 − the server's own percent (58)")
        XCTAssertEqual(monthly.resetsAt,
                       ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z"),
                       "client-derived next calendar month start UTC (§8.0.4)")
        XCTAssertEqual(monthly.source, "derived_calendar_month_utc")

        XCTAssertNil(snap.extraUsage,
                     "D-37: spend is canonical — the minor-unit mirror must never reach the " +
                     "Pro/Max decimal-dollar pipeline")
        XCTAssertNil(snap.prepaid)
        XCTAssertNil(snap.primaryUsedPct, "persistent null windows stay null (rank-12)")
        XCTAssertEqual(snap.nullWindowSource, .provider)
        XCTAssertEqual(snap.planType, "enterprise")
        let health = await adapter.health
        XCTAssertEqual(health, .healthy)
    }

    /// Enterprise detection skips `/prepaid/credits` entirely — it hard-403s for Enterprise and
    /// re-hitting a known 403 every 15 min violates the REV-37 minimum-footprint posture. (The
    /// Pro/Max direction — prepaid still fetched — is covered by the cadence tests above.)
    func testEnterpriseProfileSkipsPrepaid() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_enterprise_spend")))
        fetcher.setRoute(profileURL,
                         StubResponse(data: try fixtureData("profile_enterprise_usage_based")))
        fetcher.setRoute(enterprisePrepaidURL,
                         StubResponse(data: try fixtureData("prepaid_credits")))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher)
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(fetcher.requestCount(for: enterprisePrepaidURL), 0,
                       "the prepaid endpoint must never be hit on an Enterprise seat")
        XCTAssertNil(snap.prepaid)
    }

    // MARK: - Model-scoped weekly limits (§8.0.2 `limits[]` — STEP_134)

    /// The live 2026-08-22 body: three `limits[]` entries plus a surface-scoped fourth. Only the
    /// **model**-scoped one becomes a sub-bucket, and the two window fields are untouched by it —
    /// `weekly_all` restates `seven_day` and is read by nothing.
    func testScopedWeeklyLimitMapped() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_scoped_limits")
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertEqual(snap.primaryUsedPct, 38.0, "five_hour still drives the primary window")
        XCTAssertEqual(snap.secondaryUsedPct, 8.0, "seven_day still drives the weekly window")
        XCTAssertEqual(snap.additionalRateLimits.count, 1,
                       "session/weekly_all are not sub-buckets; the surface-scoped entry is unnamed")
        let fable = try XCTUnwrap(snap.additionalRateLimits.first)
        XCTAssertEqual(fable.name, "Fable")
        XCTAssertNil(fable.id, "scope.model.id is null in every capture — the name is the handle")
        XCTAssertEqual(fable.usedPercent, 10.0)
        // STEP_176: the period is the one the entry's `kind` reports (`weekly_scoped` ⇒ a week);
        // there is no second window and none is invented (Baseline §15.2).
        XCTAssertEqual(fable.primaryWindowSeconds, 7 * 86_400, "weekly_scoped names its period")
        XCTAssertNil(fable.secondary, "a single-window scoped limit stays single-window")
        // The payload carries sub-second precision (`…59.577548`), which the parser keeps — so
        // this is a tolerance check, not an equality one. That fraction is exactly why the
        // display compares the scoped reset against the weekly one with `resetJitterTolerance`
        // instead of `==`: live, the two differ by 450 microseconds.
        let weeklyReset = try XCTUnwrap(snap.secondaryResetsAt)
        let scopedReset = try XCTUnwrap(fable.resetsAt)
        XCTAssertEqual(scopedReset.timeIntervalSince1970,
                       try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-28T12:59:59Z"))
                           .timeIntervalSince1970,
                       accuracy: 1.0,
                       "the scoped reset parses through the same path as a window's")
        XCTAssertLessThan(abs(scopedReset.timeIntervalSince(weeklyReset)),
                          QuotaSnapshot.resetJitterTolerance,
                          "live, the scoped and all-models weekly resets are the same boundary")
    }

    /// An account with no `limits[]` at all (every fixture predating 2026-08-22) reports no
    /// sub-buckets — absence renders nothing, never a placeholder row.
    func testNoLimitsArrayYieldsNoScopedLimits() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_healthy")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertTrue(snap.additionalRateLimits.isEmpty)
    }

    /// The F4 lesson applied to the newest field: `limits` arriving as an object of strings
    /// degrades to no sub-buckets and leaves the rest of the poll — windows, health — intact.
    func testLimitsUnexpectedShapeDegradesNeverFailsPoll() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_limits_unexpected_shape")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertTrue(snap.additionalRateLimits.isEmpty)
        XCTAssertEqual(snap.primaryUsedPct, 38.0, "the rest of the body still decodes")
        XCTAssertEqual(snap.secondaryUsedPct, 8.0)
        let health = await adapter.health
        XCTAssertEqual(health, .healthy)
    }

    /// The F4 lesson generalized: an unexpected future `spend` shape (here: a string) degrades
    /// the field to nil — never a failed poll, never polluted health.
    func testSpendUnexpectedShapeDegradesToNilNeverFailsPoll() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_spend_unexpected_shape")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertNil(snap.monthlyLimit)
        let health = await adapter.health
        XCTAssertEqual(health, .healthy)
    }

    /// A used/limit currency (or exponent) mismatch makes "used of limit" a lie in either unit:
    /// the monthly model is dropped (WARNING), but the poll survives — and the mirror stays
    /// suppressed because the spend meter is still *active* (enabled, limit present): a corrupt
    /// Enterprise payload must not leak minor units into the decimal pipeline via the fallback.
    func testSpendCurrencyMismatchDropsMonthlyKeepsMirrorSuppressed() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_spend_currency_mismatch")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertNil(snap.monthlyLimit)
        XCTAssertNil(snap.extraUsage, "an active spend meter suppresses the mirror even when mapping fails")
    }

    /// Live capture 2026-07-16 (Max plan, this machine): Pro/Max payloads ALSO carry `spend` —
    /// a disabled stub (`enabled: false`, `limit: null`, zero used). The D-37 suppression must
    /// key on an *active meter*, never raw presence, or every Pro/Max account loses its §2.4a
    /// card. The mirror flows and the decimal-dollar pipeline is untouched (the named
    /// regression's values ride this fixture too: `used_credits: 3.25` → `$3.25`).
    func testProMaxDisabledSpendStubKeepsExtraUsageFlowing() async throws {
        let (adapter, _) = try makeAdapter(usageFixture: "usage_spend_promax_disabled")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertNil(snap.monthlyLimit, "a disabled null-limit stub builds no monthly model")
        let eu = try XCTUnwrap(snap.extraUsage,
                               "the Pro/Max extra_usage object must survive a spend stub")
        XCTAssertTrue(eu.isEnabled)
        XCTAssertEqual(eu.usedCredits, Decimal(string: "3.25"),
                       "decimal dollars, not minor units — the Pro/Max pipeline is untouched")
        XCTAssertEqual(eu.monthlyLimit, 2000)
        XCTAssertEqual(snap.primaryUsedPct, 13.0, "windows normalize as before")
    }

    // MARK: - Windowed seat: the spend meter is usage credits (REV-102 / D-125 — STEP_218)

    /// The Claude Team shape: windows **and** an active `spend` meter. The meter maps to
    /// org-managed `ExtraUsage` built from `spend` itself (EUR, exponent carried), and there is
    /// no monthly limit — so nothing downstream can rank it as a quota. **`critical` has the shape of
    /// the tester's captured payload, with synthetic amounts** (2026-09-21 14:57 CEST, `docs/evidence/REV102/` — STEP_220);
    /// `normal` and `warning` are still reconstructed from his log, not captured.
    func testWindowedSeatSpendMapsToOrgManagedCredits() async throws {
        for (fixture, used) in [("normal", "16.8"), ("warning", "57.4"), ("critical", "70.25")] {
            let (adapter, fetcher) = try makeAdapter(
                usageFixture: "usage_team_windowed_spend_\(fixture)", profileFixture: "profile_team")
            let snap = try await adapter.fetchQuotaSnapshot()

            XCTAssertNil(snap.monthlyLimit, "\(fixture): a windowed seat has no monthly quota")
            let eu = try XCTUnwrap(snap.extraUsage, "\(fixture): the meter is usage credits")
            XCTAssertTrue(eu.managedByOrganization)
            XCTAssertTrue(eu.isEnabled)
            XCTAssertEqual(eu.currency, "EUR")
            XCTAssertEqual(eu.currencyExponent, 2)
            XCTAssertEqual(eu.usedCredits, Decimal(string: used),
                           "\(fixture): from spend's minor units — never the extra_usage mirror")
            XCTAssertEqual(eu.monthlyLimit, 7000, "minor units, as on the Pro/Max path")
            XCTAssertEqual(eu.monthlyLimitMajor, Decimal(70))
            XCTAssertFalse(eu.usedCreditsIsCached, "§7.1 cached-value rule never applies here")
            XCTAssertEqual(snap.primaryUsedPct, 0, "the un-started five-hour counts as a window")
            XCTAssertNil(snap.primaryResetsAt)
            XCTAssertEqual(snap.secondaryUsedPct, 100)
            XCTAssertEqual(snap.blockEpisode?.limit, .secondary, "the spent weekly owns the block")
            XCTAssertNil(snap.prepaid)
            let teamPrepaidURL = try XCTUnwrap(ClaudeAccountAdapter.prepaidURL(
                orgId: "00000000-0000-0000-0000-000000000021"))
            XCTAssertEqual(fetcher.requestCount(for: teamPrepaidURL), 0,
                           "REV-88: never called on Team")
        }
    }

    /// About a day after the cap is reached the meter switches off (`out_of_credits`, no limit,
    /// used 0 — REV-102 §6 item 1, STEP_222). The fixture is the tester's captured payload
    /// (2026-09-21 ~21:00 CEST, `docs/evidence/REV102/`), verbatim. On a profile that says not
    /// Pro/Max it is still the organization's credits — off, no amounts, the reason carried for
    /// `MoneyModel` and never for display.
    func testSwitchedOffTeamCreditsStayOrgManaged() async throws {
        let (adapter, fetcher) = try makeAdapter(
            usageFixture: "usage_team_windowed_spend_out_of_credits", profileFixture: "profile_team")
        let snap = try await adapter.fetchQuotaSnapshot()

        XCTAssertNil(snap.monthlyLimit)
        let eu = try XCTUnwrap(snap.extraUsage)
        XCTAssertTrue(eu.managedByOrganization, "decided on the first poll — the profile comes first")
        XCTAssertFalse(eu.isEnabled)
        XCTAssertEqual(eu.disabledReason, "out_of_credits")
        XCTAssertNil(eu.monthlyLimit, "the provider no longer sends amounts; nothing is cached")
        XCTAssertNil(eu.usedCredits)
        XCTAssertEqual(eu.currency, "EUR")
        XCTAssertEqual(eu.currencyExponent, 2)
        XCTAssertEqual(snap.blockEpisode?.limit, .secondary, "the spent weekly still owns the block")
        XCTAssertEqual(fetcher.requestCount(for: teamPrepaidURL), 0, "REV-88: never called on Team")
    }

    /// The same payload under a Pro/Max profile, or with no profile at all, takes the self-serve
    /// arm exactly as before: whether Pro/Max can report `out_of_credits` is unobserved, and an
    /// unknown plan is never guessed.
    func testSwitchedOffShapeNeedsANonProMaxProfile() async throws {
        for profile in ["profile_max", nil] {
            let (adapter, _) = try makeAdapter(
                usageFixture: "usage_team_windowed_spend_out_of_credits", profileFixture: profile)
            let snap = try await adapter.fetchQuotaSnapshot()
            let eu = try XCTUnwrap(snap.extraUsage, "\(profile ?? "no profile")")
            XCTAssertFalse(eu.managedByOrganization, "\(profile ?? "no profile")")
            XCTAssertFalse(eu.isEnabled)
            XCTAssertEqual(eu.disabledReason, "out_of_credits", "the self-serve pass-through")
        }
    }

    /// The Pro/Max disabled stub carries the same `can_toggle: false` and a null reason; no
    /// profile may turn it into the organization's card.
    func testProMaxDisabledStubIsUnchangedUnderEveryProfile() async throws {
        for profile in ["profile_team", "profile_max", nil] {
            let (adapter, _) = try makeAdapter(
                usageFixture: "usage_spend_promax_disabled", profileFixture: profile)
            let snap = try await adapter.fetchQuotaSnapshot()
            let eu = try XCTUnwrap(snap.extraUsage)
            XCTAssertFalse(eu.managedByOrganization, "\(profile ?? "no profile")")
            XCTAssertTrue(eu.isEnabled)
            XCTAssertEqual(eu.usedCredits, Decimal(string: "3.25"))
            XCTAssertEqual(eu.monthlyLimit, 2000)
        }
    }

    /// Corrupt money objects on a windowed seat: no credits, no monthly, never a failed poll —
    /// and still no fall-through to the minor-unit mirror (D-37).
    func testWindowedSeatSpendMismatchDropsCredits() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: Data("""
            {
              "five_hour": { "utilization": 0.0, "resets_at": null },
              "seven_day": { "utilization": 100.0, "resets_at": "2026-09-22T02:59:00Z" },
              "extra_usage": { "is_enabled": true, "monthly_limit": 7000, "used_credits": 1680.0,
                               "currency": "EUR" },
              "spend": {
                "used":  { "amount_minor": 1680, "currency": "USD", "exponent": 2 },
                "limit": { "amount_minor": 5000, "currency": "EUR", "exponent": 2 },
                "percent": 24, "severity": "normal", "enabled": true
              }
            }
            """.utf8)))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher)
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertNil(snap.extraUsage)
        XCTAssertNil(snap.monthlyLimit)
    }

    /// `enabled: false` builds no monthly model (§8.0.4: build only when `enabled != false`).
    func testSpendDisabledBuildsNoMonthly() async throws {
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: Data("""
            {
              "five_hour": null,
              "seven_day": null,
              "spend": {
                "used":  { "amount_minor": 0, "currency": "USD", "exponent": 2 },
                "limit": { "amount_minor": 12000, "currency": "USD", "exponent": 2 },
                "percent": 0, "severity": "normal", "enabled": false,
                "disabled_reason": "admin_disabled"
              }
            }
            """.utf8)))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok"), fetcher: fetcher)
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertNil(snap.monthlyLimit)
    }

    /// The legitimate long `Retry-After: 2009` observed on the Enterprise account (REV-39 §4
    /// evidence): the forensic details carry the raw value — no policy change in this step
    /// (capping/scheduling is the coordinator's job, untouched until STEP_45).
    func testRateLimited429RetryAfter2009Forensics() async throws {
        let (adapter, _) = try makeAdapter(
            usageFixture: "usage_429_retry_after_2009",
            usageStatus: 429,
            usageHeaders: ["Retry-After": "2009"])
        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            guard case .rateLimited(let retryAfter, let details)? = error as? AccountAdapterError else {
                return XCTFail("expected rateLimited, got \(String(describing: error))")
            }
            XCTAssertEqual(retryAfter, 2009, "the raw value, uncapped at this layer")
            XCTAssertEqual(details?.category, "rate_pressure", "2009s > floor → rate_pressure (§9.5)")
            XCTAssertEqual(details?.headers["Retry-After"], "2009",
                           "the forensic row carries the raw header")
        }
    }

    // MARK: - Credential expiry gate (§8.0.1/§9.1 — REV-41, STEP_48)

    /// The pure gate/reclassification predicates: strict `now >= expiresAt`, and a non-transient
    /// countdown 429 within skew of the boundary.
    func testCredentialExpiryPredicates() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = now.timeIntervalSince1970 * 1000

        // isCredentialExpired — strict `now >= expiresAt`, nil is never expired.
        XCTAssertTrue(ClaudeAccountAdapter.isCredentialExpired(
            ClaudeCredential(accessToken: "t", expiresAt: nowMs - 1000), now: now))
        XCTAssertTrue(ClaudeAccountAdapter.isCredentialExpired(
            ClaudeCredential(accessToken: "t", expiresAt: nowMs), now: now),
            "the boundary is expired (>=)")
        XCTAssertFalse(ClaudeAccountAdapter.isCredentialExpired(
            ClaudeCredential(accessToken: "t", expiresAt: nowMs + 1000), now: now))
        XCTAssertFalse(ClaudeAccountAdapter.isCredentialExpired(
            ClaudeCredential(accessToken: "t", expiresAt: nil), now: now),
            "a nil expiry is never expired (gate no-op)")

        // isCredentialShaped429 — non-transient countdown within skew of expiry.
        let skew = ClaudeAccountAdapter.credentialSkewTolerance
        let nearMs = (now.timeIntervalSince1970 + skew - 5) * 1000     // 5s inside the band
        let farMs = (now.timeIntervalSince1970 + skew + 5) * 1000      // 5s outside
        XCTAssertTrue(ClaudeAccountAdapter.isCredentialShaped429(
            expiresAt: nearMs, rawRetryAfter: 3600, now: now))
        XCTAssertFalse(ClaudeAccountAdapter.isCredentialShaped429(
            expiresAt: farMs, rawRetryAfter: 3600, now: now), "beyond skew → prefer rate pressure")
        XCTAssertFalse(ClaudeAccountAdapter.isCredentialShaped429(
            expiresAt: nearMs, rawRetryAfter: 0, now: now),
            "a transient Retry-After: 0 is never credential-shaped")
        XCTAssertFalse(ClaudeAccountAdapter.isCredentialShaped429(
            expiresAt: nearMs, rawRetryAfter: nil, now: now),
            "an absent Retry-After is not credential-shaped")
        XCTAssertFalse(ClaudeAccountAdapter.isCredentialShaped429(
            expiresAt: nil, rawRetryAfter: 3600, now: now), "no expiry → not credential-shaped")
    }

    /// A past-`expiresAt` credential gates the poll: no request is sent, `.credentialExpired`
    /// (no details) is thrown, health is `.credentialExpired`.
    func testExpiredCredentialGatesPollNoRequestSent() async throws {
        let frozen = Date(timeIntervalSince1970: 1_000_000)
        let expiredMs = (frozen.timeIntervalSince1970 - 60) * 1000   // expired 60s ago
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_healthy")))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok", expiresAt: expiredMs),
            fetcher: fetcher, now: { frozen })

        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            XCTAssertEqual(error as? AccountAdapterError, .credentialExpired(details: nil),
                           "the gate throws credential-expired with no captured request")
        }
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 0,
                       "the gate must send no request (§8.0.1 — no doomed poll)")
        let health = await adapter.health
        XCTAssertEqual(health, .credentialExpired)
    }

    /// A credential with no `expiresAt` never gates — the adapter polls exactly as before, and a
    /// future expiry likewise polls normally.
    func testAbsentOrFutureExpiryDoesNotGate() async throws {
        // Absent expiry (MockTokenProvider default) → healthy poll.
        let (adapter, fetcher) = try makeAdapter(usageFixture: "usage_healthy")
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.primaryUsedPct, 12.0)
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 1)
        let health = await adapter.health
        XCTAssertEqual(health, .healthy)

        // Future expiry → still a healthy poll.
        let frozen = Date(timeIntervalSince1970: 1_000_000)
        let futureMs = (frozen.timeIntervalSince1970 + 8 * 3600) * 1000
        let fetcher2 = MockFetcher()
        fetcher2.setRoute(usageURL, StubResponse(data: try fixtureData("usage_healthy")))
        let adapter2 = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok", expiresAt: futureMs),
            fetcher: fetcher2, now: { frozen })
        _ = try await adapter2.fetchQuotaSnapshot()
        XCTAssertEqual(fetcher2.requestCount(for: usageURL), 1)
        let health2 = await adapter2.health
        XCTAssertEqual(health2, .healthy)
    }

    /// Belt-and-braces: a valid-looking `expiresAt` (30s in the future — clock reads behind true
    /// time) plus a countdown 429 within skew ⇒ reclassified credential-shaped, not rate-limited.
    /// The disguised countdown survives verbatim in the forensic headers.
    func testCountdown429NearExpiryReclassifiedCredentialShaped() async throws {
        let frozen = Date(timeIntervalSince1970: 2_000_000)
        let expMs = (frozen.timeIntervalSince1970 + 30) * 1000   // 30s ahead — inside the 120s band
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(
            data: try fixtureData("usage_429_expired_token"), status: 429,
            headers: ["Retry-After": "3600"]))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok", expiresAt: expMs),
            fetcher: fetcher, now: { frozen })

        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            guard case .credentialExpired(let details)? = error as? AccountAdapterError else {
                return XCTFail("expected credentialExpired, got \(String(describing: error))")
            }
            XCTAssertEqual(details?.category, "credential_expired")
            XCTAssertEqual(details?.headers["Retry-After"], "3600",
                           "the disguised countdown is preserved in the forensic headers")
        }
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 1,
                       "the request was sent, then the 429 was reclassified")
        let health = await adapter.health
        XCTAssertEqual(health, .credentialExpired)
    }

    /// A countdown 429 far from `expiresAt` stays a genuine rate-limit — the skew guard must not
    /// swallow real rate pressure on a valid token.
    func testCountdown429FarFromExpiryStaysRateLimited() async throws {
        let frozen = Date(timeIntervalSince1970: 3_000_000)
        let expMs = (frozen.timeIntervalSince1970 + 3600) * 1000   // 1h out — well beyond skew
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(
            data: try fixtureData("usage_429_expired_token"), status: 429,
            headers: ["Retry-After": "3600"]))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok", expiresAt: expMs),
            fetcher: fetcher, now: { frozen })

        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            guard case .rateLimited(let ra, let details)? = error as? AccountAdapterError else {
                return XCTFail("expected rateLimited, got \(String(describing: error))")
            }
            XCTAssertEqual(ra, 3600)
            XCTAssertEqual(details?.category, "rate_pressure",
                           "a valid token far from expiry → genuine rate pressure")
        }
        let health = await adapter.health
        XCTAssertEqual(health, .rateLimited(retryAfter: 3600))
    }

    /// Zero-network recovery: while expired the gate blocks every tick; the moment Claude Code
    /// refreshes the credential (expiry flips future) the very next poll succeeds — one request,
    /// no special machinery.
    func testZeroNetworkRecoveryPollsWhenExpiryFlipsFuture() async throws {
        let frozen = Date(timeIntervalSince1970: 4_000_000)
        let provider = MutableExpiryTokenProvider(
            token: "tok", expiresAt: (frozen.timeIntervalSince1970 - 60) * 1000)  // expired
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_healthy")))
        let adapter = ClaudeAccountAdapter(tokenProvider: provider, fetcher: fetcher, now: { frozen })

        // Tick 1 — expired → gated, no request.
        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            XCTAssertEqual(error as? AccountAdapterError, .credentialExpired(details: nil))
        }
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 0)

        // Claude Code refreshes the credential — expiry now 8h out.
        provider.expiresAt = (frozen.timeIntervalSince1970 + 8 * 3600) * 1000

        // Tick 2 — recovers with zero extra machinery: the next poll simply succeeds.
        let snap = try await adapter.fetchQuotaSnapshot()
        XCTAssertEqual(snap.primaryUsedPct, 12.0)
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 1, "recovery sends exactly one request")
        let health = await adapter.health
        XCTAssertEqual(health, .healthy)
    }

    // MARK: - The gate stands alone (STEP_165 — the delegated refresh is retired)

    /// The adapter has no refresh seam left to inject: an expired credential is gated, nothing is
    /// sent, and the health is `.credentialExpired`. Successor to `testNilRefresherIsNoOp` — what
    /// used to be the "omit the refresher" case is now the only case there is.
    func testExpiredCredentialGatesWithNoRefreshSeam() async throws {
        let frozen = Date(timeIntervalSince1970: 10_000_000)
        let expiredMs = (frozen.timeIntervalSince1970 - 60) * 1000
        let fetcher = MockFetcher()
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_healthy")))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: MockTokenProvider(token: "tok", expiresAt: expiredMs),
            fetcher: fetcher, now: { frozen })

        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            XCTAssertEqual(error as? AccountAdapterError, .credentialExpired(details: nil))
        }
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 0, "no request — and no subprocess")
        let health = await adapter.health
        XCTAssertEqual(health, .credentialExpired)
    }

    /// The expiry episode still ends on the credential's own health, and it ends there *only* —
    /// the STEP_86 rule survives as the gate's per-tick re-evaluation, with no schedule behind it.
    /// A poll that clears the gate and then fails for a transport reason leaves nothing suppressed:
    /// the next expiry gates again, and the next healthy read polls again. Successor to
    /// `testHealthyCredentialReArmsWithoutASuccessfulPoll`.
    func testEpisodeEndsOnCredentialHealthNotOnAPoll() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 23_000_000))
        let expiredMs = (clock.now.timeIntervalSince1970 - 60) * 1000
        let futureMs = (clock.now.timeIntervalSince1970 + 8 * 3600) * 1000
        let provider = MutableExpiryTokenProvider(token: "tok", expiresAt: expiredMs)
        let fetcher = MockFetcher()
        // Every poll that gets past the gate fails with a server error — transport, not auth.
        fetcher.setRoute(usageURL, StubResponse(data: try fixtureData("usage_healthy"), status: 500))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: provider, fetcher: fetcher, now: { clock.now })

        // Expired: gated, nothing sent.
        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            XCTAssertEqual(error as? AccountAdapterError, .credentialExpired(details: nil))
        }
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 0)

        // Healthy (Claude Code ran): the gate passes on the very next tick. The poll still fails —
        // a transport failure carries no information about auth (§9.1).
        provider.expiresAt = futureMs
        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            XCTAssertEqual(error as? AccountAdapterError, .httpStatus(500))
        }
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 1, "zero-network recovery: one request")

        // Expired again: gated again, immediately. Nothing latched from the failed poll.
        provider.expiresAt = expiredMs
        await XCTAssertThrowsErrorAsync(try await adapter.fetchQuotaSnapshot()) { error in
            XCTAssertEqual(error as? AccountAdapterError, .credentialExpired(details: nil))
        }
        XCTAssertEqual(fetcher.requestCount(for: usageURL), 1)
        let health = await adapter.health
        XCTAssertEqual(health, .credentialExpired)
    }
}

// MARK: - Async throwing assertion helper

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
