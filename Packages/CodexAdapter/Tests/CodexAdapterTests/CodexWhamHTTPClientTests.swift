import XCTest
import KvotarCore
@testable import CodexAdapter

/// Step 10 fixture tests for `CodexWhamHTTPClient` (Baseline §8.2, §9.2; task Step 10).
/// D1: the blocked-state expectation is a working-assumption gated by §20 D1.
final class CodexWhamHTTPClientTests: XCTestCase {

    private static let credential = CodexCredential(accessToken: "test-token", accountId: "acct-fixture")

    // MARK: 1 — healthy Enterprise null-window

    func testHealthyNullWindow() async throws {
        let client = CodexWhamHTTPClient(
            fetcher: try FakeCodexHTTPFetcher.fixture("wham_healthy_null_window_enterprise"),
            tokenProvider: FakeCodexAuth(fixedCredential: Self.credential))

        let result = try await client.fetchUsage()

        XCTAssertNil(result.usage.rateLimit)
        XCTAssertEqual(result.usage.planType, "enterprise")
        XCTAssertEqual(result.usage.spendControl?.reached, false)
        XCTAssertEqual(result.usage.rateLimitResetCredits?.availableCount, 0)
    }

    // MARK: 2 — blocked working assumption (D1)

    func testBlockedWorkingAssumption() async throws {
        let client = CodexWhamHTTPClient(
            fetcher: try FakeCodexHTTPFetcher.fixture("wham_blocked_enterprise"),
            tokenProvider: FakeCodexAuth(fixedCredential: Self.credential))

        let result = try await client.fetchUsage()

        // D1: working assumption — validate when blocked-state is captured.
        XCTAssertEqual(result.usage.rateLimit?.limitReached, true)
        XCTAssertEqual(result.usage.rateLimit?.primaryWindow?.usedPercent, 100)
        XCTAssertEqual(result.usage.rateLimit?.secondaryWindow?.usedPercent, 21)
    }

    // MARK: 3 — expired token 401 → reauth required

    func testExpiredToken401() async {
        let client = CodexWhamHTTPClient(
            fetcher: FakeCodexHTTPFetcher(statusCode: 401),
            tokenProvider: FakeCodexAuth(fixedCredential: Self.credential))

        do {
            _ = try await client.fetchUsage()
            XCTFail("expected reauthRequired")
        } catch let error as AccountAdapterError {
            XCTAssertEqual(error, .reauthRequired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: 4 — auth.json unavailable → setup required, no network call

    func testMissingCredentialIsSetupRequired() async {
        let client = CodexWhamHTTPClient(
            fetcher: FakeCodexHTTPFetcher(error: URLError(.notConnectedToInternet)),
            tokenProvider: FakeCodexAuth(fixedCredential: nil))

        do {
            _ = try await client.fetchUsage()
            XCTFail("expected setupRequired")
        } catch let error as AccountAdapterError {
            XCTAssertEqual(error, .setupRequired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: 5 — poll 429 → rateLimited with Retry-After

    func testPoll429UsesRetryAfter() async {
        let client = CodexWhamHTTPClient(
            fetcher: FakeCodexHTTPFetcher(statusCode: 429, headers: ["Retry-After": "45"]),
            tokenProvider: FakeCodexAuth(fixedCredential: Self.credential))

        do {
            _ = try await client.fetchUsage()
            XCTFail("expected rateLimited")
        } catch let error as AccountAdapterError {
            guard case .rateLimited(let retryAfter, let details) = error else {
                return XCTFail("expected rateLimited, got \(error)")
            }
            XCTAssertEqual(retryAfter, 45)
            XCTAssertEqual(details?.category, "rate_pressure", "45s > floor → rate_pressure (§9.5)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: 6 — rate-limit headers captured on success (§9.2)

    func testRateLimitHeadersCaptured() async throws {
        let client = CodexWhamHTTPClient(
            fetcher: try FakeCodexHTTPFetcher.fixture(
                "wham_healthy_null_window_enterprise",
                headers: ["X-RateLimit-Limit": "1000", "X-RateLimit-Remaining": "150"]),
            tokenProvider: FakeCodexAuth(fixedCredential: Self.credential))

        let result = try await client.fetchUsage()

        XCTAssertEqual(result.headers.limit, 1000)
        XCTAssertEqual(result.headers.remaining, 150)
    }

    // MARK: 7 — the real blocked capture (2026-09-08, Plus): D1's missing evidence (REV-91)

    /// `wham_blocked_plus_reached_type_object.json` is the first real over-quota wham payload
    /// this project has captured — the thing D1 has waited for since 2026-07-05. It confirms the
    /// working assumption (`limit_reached: true` beside a 100% primary window) and carries the
    /// object form of `rate_limit_reached_type` that discarded 22 consecutive polls before this
    /// step. The point of the test is that the poll **lands**.
    func testBlockedPlusWithObjectReachedTypeStillDecodes() async throws {
        let client = CodexWhamHTTPClient(
            fetcher: try FakeCodexHTTPFetcher.fixture("wham_blocked_plus_reached_type_object"),
            tokenProvider: FakeCodexAuth(fixedCredential: Self.credential))

        let result = try await client.fetchUsage()

        XCTAssertEqual(result.usage.rateLimit?.limitReached, true)
        XCTAssertEqual(result.usage.rateLimit?.primaryWindow?.usedPercent, 100)
        XCTAssertEqual(result.usage.rateLimit?.primaryWindow?.limitWindowSeconds, 18000)
        XCTAssertEqual(result.usage.rateLimit?.secondaryWindow?.usedPercent, 16)
        XCTAssertEqual(result.usage.planType, "plus")
        XCTAssertEqual(result.usage.rateLimitReachedType, "rate_limit_reached",
                       "the object form must normalize to its `type` string")
        XCTAssertNil(result.usage.credits?.balance,
                     "`balance` is the string \"0\" here — degrades to nil, does not throw")
    }

    // MARK: 8 — both shapes of `rate_limit_reached_type`, and neither may throw (REV-91)

    func testReachedTypeAcceptsStringObjectAndNull() throws {
        func reachedType(_ raw: String) throws -> String? {
            let json = """
            { "plan_type": "plus", "rate_limit": null, "rate_limit_reached_type": \(raw) }
            """
            return try CodexWhamUsage.decode(from: Data(json.utf8)).rateLimitReachedType
        }

        // The historical string form (still what the RPC transport sends).
        XCTAssertEqual(try reachedType("\"rate_limit_reached\""), "rate_limit_reached")
        // The 2026-09-08 object form.
        XCTAssertEqual(try reachedType("{\"type\":\"rate_limit_reached\",\"details\":\"default\"}"),
                       "rate_limit_reached")
        // Healthy.
        XCTAssertNil(try reachedType("null"))
        // A third shape nobody has seen: still not an error.
        XCTAssertNil(try reachedType("[1, 2]"))
        XCTAssertNil(try reachedType("{\"unexpected\": true}"))
    }

    // MARK: 9 — an unexpected shape on any unread field leaves the windows intact (REV-91)

    /// The F4 lesson generalized: only `rate_limit` may fail a poll. Each payload below is
    /// deliberately wrong in one top-level field — and every one of them also carries a wrong
    /// `allowed` and a wrong `reset_after_seconds`, the two unread fields *inside* the strict
    /// part of the shape. All of them must still produce usable windows.
    func testUnexpectedShapesDegradeTheFieldNotThePoll() throws {
        let broken: [String: String] = [
            "email": "\"email\": 42",
            "plan_type": "\"plan_type\": { \"name\": \"plus\" }",
            "spend_control": "\"spend_control\": \"reached\"",
            "rate_limit_reset_credits": "\"rate_limit_reset_credits\": []",
        ]

        for (label, injected) in broken {
            let json = """
            {
              \(injected),
              "rate_limit": {
                "allowed": { "unexpected": true },
                "limit_reached": true,
                "primary_window": {
                  "used_percent": 100,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": { "unexpected": true },
                  "reset_at": 1788871735
                },
                "secondary_window": null
              }
            }
            """
            let usage = try CodexWhamUsage.decode(from: Data(json.utf8))
            XCTAssertEqual(usage.rateLimit?.limitReached, true, "broken field: \(label)")
            XCTAssertEqual(usage.rateLimit?.primaryWindow?.usedPercent, 100, "broken field: \(label)")
            XCTAssertEqual(usage.rateLimit?.primaryWindow?.resetAt, 1788871735, "broken field: \(label)")
            XCTAssertNil(usage.rateLimit?.allowed, "broken field: \(label)")
            XCTAssertNil(usage.rateLimit?.primaryWindow?.resetAfterSeconds, "broken field: \(label)")
        }
    }

    // MARK: 10 — the numbers themselves stay strict (REV-91)

    /// The other half of the rule: a wrong percentage is worse than no reading, so a window
    /// number that cannot be decoded must still fail the poll rather than silently read nil.
    func testWindowNumbersRemainStrict() {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "limit_reached": true,
            "primary_window": { "used_percent": "one hundred", "reset_at": 1788871735 }
          }
        }
        """
        XCTAssertThrowsError(try CodexWhamUsage.decode(from: Data(json.utf8)))
    }
}
