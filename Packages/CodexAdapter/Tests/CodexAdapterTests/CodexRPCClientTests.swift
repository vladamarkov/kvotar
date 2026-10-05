import XCTest
@testable import CodexAdapter

final class CodexRPCClientTests: XCTestCase {

    /// Builds a transport pre-loaded with the two confirmed fixture responses + initialize.
    private func healthyTransport() throws -> FakeCodexTransport {
        let transport = FakeCodexTransport()
        transport.responses = [
            "initialize": "{}",
            "account/read": try fixtureString("account_read_healthy_enterprise"),
            "account/rateLimits/read": try fixtureString("ratelimits_null_window_enterprise"),
        ]
        return transport
    }

    private func makeClient(_ transport: FakeCodexTransport) -> CodexRPCClient {
        CodexRPCClient(
            transport: transport,
            locator: StubBinaryLocator(),
            startupTimeout: .milliseconds(500),
            callTimeout: .milliseconds(500)
        )
    }

    // MARK: 1 — healthy Enterprise account/read decodes

    func testHealthyAccountReadDecodes() async throws {
        let client = makeClient(try healthyTransport())
        let result = try await client.poll()
        XCTAssertEqual(result.account.account.planType, "enterprise")
        XCTAssertEqual(result.account.account.type, "chatgpt")
        XCTAssertEqual(result.account.account.email, "user@domain.com")
        XCTAssertEqual(result.account.requiresOpenaiAuth, true)
        client.shutdown()
    }

    // MARK: 2 — null-window rateLimits treated as valid

    func testNullWindowRateLimitsAreValid() async throws {
        let client = makeClient(try healthyTransport())
        let result = try await client.poll()
        XCTAssertNil(result.rateLimits.rateLimits.primary)
        XCTAssertNil(result.rateLimits.rateLimits.secondary)
        XCTAssertEqual(result.rateLimits.rateLimits.planType, "enterprise")
        XCTAssertEqual(result.rateLimits.rateLimits.limitId, "codex")
        XCTAssertNil(result.rateLimits.rateLimits.rateLimitReachedType)
        XCTAssertEqual(result.rateLimits.rateLimitsByLimitId?["codex"]?.planType, "enterprise")
        client.shutdown()
    }

    // MARK: 3 — unsolicited notification ignored

    func testUnsolicitedNotificationIgnored() async throws {
        let transport = try healthyTransport()
        // Confirmed startup notification (§8.7 D1-B6): has `method`, no `id`.
        transport.onStartEmit = [
            "{\"jsonrpc\":\"2.0\",\"method\":\"remoteControl/status/changed\",\"params\":{\"status\":\"disabled\"}}"
        ]
        let client = makeClient(transport)
        // Poll still succeeds — the notification must not resolve or corrupt any pending call.
        let result = try await client.poll()
        XCTAssertEqual(result.account.account.planType, "enterprise")
        client.shutdown()
    }

    // MARK: 4 — crash + restart, then unavailable after 3 consecutive failures

    func testRestartAfterCrash() async throws {
        let transport = try healthyTransport()
        let client = makeClient(transport)

        // First poll starts + initializes the process successfully.
        _ = try await client.poll()
        let startsAfterFirst = transport.startCount
        XCTAssertEqual(startsAfterFirst, 1)

        // Simulate a crash: terminate the process (stream finishes -> isRunning false).
        transport.terminate()
        XCTAssertFalse(transport.isRunning)

        // Next poll detects the dead process, restarts + re-initializes, and succeeds.
        let result = try await client.poll()
        XCTAssertEqual(result.account.account.planType, "enterprise")
        XCTAssertEqual(transport.startCount, startsAfterFirst + 1)
        client.shutdown()
    }

    /// STEP_277 — the old process's exit lands after the restart has begun. Its reader was
    /// cancelled, but its loop still ends; that end must not fail the new process's `initialize`
    /// (it did, as `transportClosed`, on a slow machine) nor mark the client not started.
    func testTheOldProcessExitDoesNotFailTheRestartedOne() async throws {
        let transport = try healthyTransport()
        let client = makeClient(transport)
        _ = try await client.poll()

        transport.holdStreamOnTerminate = true
        transport.responseDelay = .milliseconds(200)
        transport.terminate()

        let result = try await client.poll()
        XCTAssertEqual(result.account.account.planType, "enterprise")
        XCTAssertEqual(transport.startCount, 2)

        // Still started: the next poll reuses the process instead of restarting it.
        _ = try await client.poll()
        XCTAssertEqual(transport.startCount, 2, "the old exit must not mark the new process stopped")
        client.shutdown()
    }

    func testUnavailableAfterThreeRestartFailures() async {
        let transport = FakeCodexTransport()
        transport.startError = CocoaError(.fileNoSuchFile)  // spawn always fails
        let client = makeClient(transport)

        for _ in 0..<3 {
            do {
                _ = try await client.poll()
                XCTFail("expected start failure")
            } catch {}
        }

        // After 3 consecutive failures the client reports unavailable (fall through to wham).
        do {
            _ = try await client.poll()
            XCTFail("expected unavailable")
        } catch let error as CodexRPCClient.ClientError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        client.shutdown()
    }

    // MARK: STEP_24 — terminate old child before every (re)start

    func testTerminatesOldChildBeforeEveryStart() async throws {
        let transport = try healthyTransport()
        let client = makeClient(transport)

        _ = try await client.poll()          // cold start: terminate (no-op) → start
        transport.terminate()                // simulate crash
        _ = try await client.poll()          // restart: terminate → start
        client.shutdown()

        // Every "start" must be immediately preceded by a "terminate" — the old app-server child is
        // always reaped before a new one is spawned, so a failed init cannot orphan a live process.
        for (i, event) in transport.events.enumerated() where event == "start" {
            XCTAssertTrue(i > 0 && transport.events[i - 1] == "terminate",
                          "start at index \(i) not preceded by terminate: \(transport.events)")
        }
        XCTAssertEqual(transport.startCount, 2)
    }

    // MARK: STEP_24 — cancelling an in-flight call resolves promptly and drains the pending map

    func testCancelledCallResolvesPromptlyWithoutOrphaning() async throws {
        let transport = FakeCodexTransport()
        transport.responses = ["initialize": "{}"]  // no account/read response → the call hangs
        // Long call timeout so a prompt cancellation is unambiguously faster than the timeout path.
        let client = CodexRPCClient(
            transport: transport, locator: StubBinaryLocator(),
            startupTimeout: .seconds(5), callTimeout: .seconds(5))

        let task = Task { try await client.poll() }
        // Let `account/read` register its continuation before cancelling.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(client.pendingCount, 1, "the account/read call should be in flight")

        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected the cancelled poll to throw")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "cancellation must resolve well under the 5s call timeout")
        XCTAssertEqual(client.pendingCount, 0, "the pending continuation must be drained on cancel")
        client.shutdown()
    }

    // MARK: STEP_24 — the 3-failure lockout recovers after the cooldown elapses

    func testLockoutRecoversAfterCooldown() async throws {
        let transport = try healthyTransport()
        transport.startError = CocoaError(.fileNoSuchFile)  // first spawns fail
        let client = CodexRPCClient(
            transport: transport, locator: StubBinaryLocator(),
            startupTimeout: .milliseconds(500), callTimeout: .milliseconds(500),
            restartCooldown: .milliseconds(300))

        for _ in 0..<3 {
            do { _ = try await client.poll(); XCTFail("expected start failure") } catch {}
        }

        // Immediately after the 3rd failure: locked out, before the cooldown elapses.
        do {
            _ = try await client.poll()
            XCTFail("expected unavailable while locked out")
        } catch let error as CodexRPCClient.ClientError {
            XCTAssertEqual(error, .unavailable)
        }

        // Recover the transport and wait past the cooldown → the client attempts a fresh restart.
        transport.startError = nil
        try await Task.sleep(for: .milliseconds(400))
        let result = try await client.poll()
        XCTAssertEqual(result.account.account.planType, "enterprise")
        client.shutdown()
    }

    // MARK: binary discovery

    func testMissingBinaryIsUnavailable() async {
        let transport = FakeCodexTransport()
        let client = CodexRPCClient(
            transport: transport,
            locator: StubBinaryLocator(path: nil),
            startupTimeout: .milliseconds(500),
            callTimeout: .milliseconds(500)
        )
        do {
            _ = try await client.poll()
            XCTFail("expected unavailable")
        } catch let error as CodexRPCClient.ClientError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(transport.startCount, 0)
    }

    // MARK: timeout

    func testCallTimesOutWhenNoResponse() async {
        let transport = FakeCodexTransport()
        transport.responses = ["initialize": "{}"]  // no account/read response -> timeout
        let client = makeClient(transport)
        do {
            _ = try await client.poll()
            XCTFail("expected timeout")
        } catch let error as CodexRPCClient.ClientError {
            XCTAssertEqual(error, .timeout(method: "account/read"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        client.shutdown()
    }

    // MARK: request/response id matching across interleaved output

    func testInterleavedNotificationBetweenResponses() async throws {
        let transport = try healthyTransport()
        transport.onStartEmit = [
            "{\"jsonrpc\":\"2.0\",\"method\":\"remoteControl/status/changed\",\"params\":{}}"
        ]
        let client = makeClient(transport)
        // Two sequential polls exercise incrementing ids and clean matching.
        _ = try await client.poll()
        let second = try await client.poll()
        XCTAssertEqual(second.rateLimits.rateLimits.planType, "enterprise")
        client.shutdown()
    }

    // MARK: shape drift on the primary transport (REV-91)

    /// `Limits` had no custom decoder until REV-91, which left the **primary** transport more
    /// brittle than the wham fallback: any one field could discard a poll. `rateLimitReachedType`
    /// is the field that actually drifted on wham (object instead of string, 2026-09-08), and the
    /// two transports are already known to disagree on it — so it must read either shape here too.
    func testReachedTypeAcceptsBothShapes() throws {
        func decode(_ raw: String) throws -> CodexRateLimits {
            let json = """
            { "rateLimits": { "limitId": "codex", "planType": "plus",
                              "rateLimitReachedType": \(raw) } }
            """
            return try JSONDecoder().decode(CodexRateLimits.self, from: Data(json.utf8))
        }

        XCTAssertEqual(try decode("\"rate_limit_reached\"").rateLimits.rateLimitReachedType,
                       "rate_limit_reached")
        XCTAssertEqual(
            try decode("{\"type\":\"rate_limit_reached\",\"details\":\"default\"}")
                .rateLimits.rateLimitReachedType,
            "rate_limit_reached")
        XCTAssertNil(try decode("null").rateLimits.rateLimitReachedType)
        XCTAssertNil(try decode("[]").rateLimits.rateLimitReachedType)
    }

    /// Only the window numbers may fail an RPC poll. Everything else degrades to nil — including
    /// `rateLimitsByLimitId`, which feeds a secondary display section, and `spendControlReached`,
    /// whose *absence* already cost this project a whole unreachable state once (STEP_98).
    func testUnexpectedShapesDegradeTheFieldNotThePoll() throws {
        let json = """
        {
          "rateLimits": {
            "limitId": { "unexpected": true },
            "limitName": [],
            "planType": 7,
            "rateLimitReachedType": { "type": "rate_limit_reached" },
            "spendControlReached": "yes",
            "credits": 5,
            "individualLimit": "5000",
            "primary": { "usedPercent": 100, "windowDurationMins": 300,
                         "resetsInSeconds": {}, "resetsAt": 1788871735 }
          },
          "rateLimitsByLimitId": "not-a-map"
        }
        """
        let decoded = try JSONDecoder().decode(CodexRateLimits.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.rateLimits.primary?.usedPercent, 100, "the windows survive")
        XCTAssertEqual(decoded.rateLimits.primary?.windowDurationMins, 300)
        XCTAssertEqual(decoded.rateLimits.primary?.resetsAt, 1788871735)
        XCTAssertEqual(decoded.rateLimits.rateLimitReachedType, "rate_limit_reached")
        XCTAssertNil(decoded.rateLimits.primary?.resetsInSeconds)
        XCTAssertNil(decoded.rateLimits.limitId)
        XCTAssertNil(decoded.rateLimits.planType)
        XCTAssertNil(decoded.rateLimits.spendControlReached)
        XCTAssertNil(decoded.rateLimits.credits?.balance)
        XCTAssertNil(decoded.rateLimits.individualLimit)
        XCTAssertNil(decoded.rateLimitsByLimitId)
    }

    /// The other half of the rule — a window number that cannot be read fails the poll rather
    /// than silently reading nil.
    func testWindowNumbersRemainStrict() {
        let json = """
        { "rateLimits": { "primary": { "usedPercent": "one hundred" } } }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(CodexRateLimits.self, from: Data(json.utf8)))
    }
}
