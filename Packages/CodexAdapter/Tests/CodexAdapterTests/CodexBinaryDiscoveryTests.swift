import XCTest
import KvotarCore
@testable import CodexAdapter

/// The launch contract and the locator's own behaviour. Neither had a test before 2026-09-09,
/// which is how both halves of the RPC path broke unnoticed (Baseline §8.1, §8.6).
final class CodexBinaryDiscoveryTests: XCTestCase {

    /// **Do not change `never` back to `untrusted`.** codex 0.153.4 rejects it outright —
    /// `error: invalid value 'untrusted' for '--ask-for-approval' [possible values: on-request,
    /// never]` — and exits before reading stdin, so the app-server never starts. `never` is
    /// accepted by 0.145.0 and 0.153.4 alike. The whole array is pinned because `-s read-only` is
    /// the next flag likely to move.
    func testLaunchArgumentsArePinned() {
        XCTAssertEqual(CodexProcessTransportLive.launchArguments,
                       ["-s", "read-only", "-a", "never", "app-server"])
    }

    func testLocatorPrefersAnInjectedBundleAndNeverSpawnsWhichOnAHit() {
        let bundle = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let hit = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let locator = DefaultCodexBinaryLocator(
            appBundleURL: { bundle },
            isExecutable: { $0 == hit },
            home: URL(fileURLWithPath: "/Users/tester"))

        let result = locator.locate()
        XCTAssertEqual(result.url?.path, hit)
        // `which codex` is the last resort; a hit must not reach it (REV-71 §2.4 — that lookup
        // costs a Process and two Pipes, and an exhausted process table made it lie).
        XCTAssertFalse(result.searched.contains("which codex"))
    }

    func testLocatorFallsBackToWhichAndSaysSo() {
        let locator = DefaultCodexBinaryLocator(
            appBundleURL: { nil },
            isExecutable: { _ in false },
            home: URL(fileURLWithPath: "/Users/tester"))

        let result = locator.locate()
        // `which codex` may or may not find one in the test environment; either way the search
        // list records that the fallback was reached only when it actually ran.
        if result.url != nil {
            XCTAssertEqual(result.searched.last, "which codex")
        } else {
            XCTAssertFalse(result.searched.contains("which codex"))
        }
    }

    /// Discovery used to run on every start attempt. Two polls must cost one lookup.
    func testClientCachesDiscoveryAcrossPolls() async throws {
        let transport = FakeCodexTransport()
        transport.responses = [
            "initialize": "{}",
            "account/read": try fixtureString("account_read_healthy_enterprise"),
            "account/rateLimits/read": try fixtureString("ratelimits_null_window_enterprise"),
        ]
        let locator = StubBinaryLocator()
        let client = CodexRPCClient(
            transport: transport,
            locator: locator,
            startupTimeout: .milliseconds(500),
            callTimeout: .milliseconds(500))

        _ = try await client.poll()
        _ = try await client.poll()
        client.shutdown()

        XCTAssertEqual(locator.calls.count, 1)
    }

    /// A missing binary must not re-run discovery on every poll either.
    func testMissingBinaryIsResolvedOncePerCooldown() async {
        let transport = FakeCodexTransport()
        let locator = StubBinaryLocator(path: nil)
        let client = CodexRPCClient(
            transport: transport,
            locator: locator,
            startupTimeout: .milliseconds(200),
            callTimeout: .milliseconds(200),
            restartCooldown: .seconds(300))

        for _ in 0..<3 { _ = try? await client.poll() }
        XCTAssertEqual(locator.calls.count, 1)
        XCTAssertEqual(transport.startCount, 0)
    }
}
