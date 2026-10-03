import XCTest
import KvotarCore
@testable import ClaudeAdapter

/// Absolute rules R3 and R4 (STEP_239, Baseline §8.0.1): Kvotar never refreshes a credential and
/// reads the Claude one only through `/usr/bin/security find-generic-password`. Checked at the two
/// seams a regression would have to cross — the process arguments and the HTTP fetcher — across
/// every credential situation the adapter handles. The credential JSON carries a refresh token, so
/// a change that started forwarding it anywhere would show up in a recorded header.
///
/// `HTTPFetcher` is GET-only: a request body cannot exist, so headers and URLs are the whole
/// request surface.
final class NoRefreshNetworkSeamTests: XCTestCase {

    private let refreshMarker = "REFRESH-MARKER-7f3c"
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvotar-norefresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
        super.tearDown()
    }

    /// The default accessor is the one Apple tool the Keychain item trusts.
    func testTheDefaultAccessorIsUsrBinSecurity() {
        XCTAssertEqual(KeychainTokenProvider().securityToolPath, "/usr/bin/security")
    }

    func testAFullCycleReachesOnlyTheQuotaEndpointsAndNeverSendsARefreshToken() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
        let fetcher = RecordingFetcher()
        fetcher.inner.setRoute(ClaudeAccountAdapter.profileURL,
                               StubResponse(data: try fixtureData("profile")))
        fetcher.inner.setRoute(prepaidURL, StubResponse(data: try fixtureData("prepaid_credits")))
        let adapter = ClaudeAccountAdapter(
            tokenProvider: KeychainTokenProvider(securityToolPath: try fakeSecurity()),
            fetcher: fetcher, localConfigURL: scratch.appendingPathComponent("absent.json"),
            now: { clock.now })

        // 1. Normal poll: usage, profile, prepaid.
        try writeCredential("tok-a", expiresIn: 8 * 3600, now: clock.now)
        try routeUsage(fetcher, [StubResponse(data: try fixtureData("usage_healthy"))])
        _ = try await adapter.fetchQuotaSnapshot()

        // 2. Expired credential: the gate sends nothing.
        try writeCredential("tok-a", expiresIn: -60, now: clock.now)
        _ = try? await adapter.fetchQuotaSnapshot()

        // 3. 401, with Claude Code rotating the token between our read and the retry.
        try writeCredential("tok-a", expiresIn: 8 * 3600, now: clock.now)
        try writeCredential("tok-b", expiresIn: 8 * 3600, now: clock.now, next: true)
        try routeUsage(fetcher, [StubResponse(data: Data("{}".utf8), status: 401),
                                 StubResponse(data: try fixtureData("usage_healthy"))])
        _ = try? await adapter.fetchQuotaSnapshot()

        // 4. 401 on a token nobody rotated: re-auth, never a refresh.
        try routeUsage(fetcher, [StubResponse(data: Data("{}".utf8), status: 401)])
        _ = try? await adapter.fetchQuotaSnapshot()

        // 5. 429 with a countdown.
        clock.advance(600)
        try writeCredential("tok-b", expiresIn: 8 * 3600, now: clock.now)
        try routeUsage(fetcher, [StubResponse(data: Data("{}".utf8), status: 429,
                                              headers: ["Retry-After": "30"])])
        _ = try? await adapter.fetchQuotaSnapshot()

        // 6. The credential changes between polls.
        clock.advance(600)
        try writeCredential("tok-c", expiresIn: 8 * 3600, now: clock.now)
        _ = await adapter.credentialChanged()
        try routeUsage(fetcher, [StubResponse(data: try fixtureData("usage_healthy"))])
        _ = try? await adapter.fetchQuotaSnapshot()

        let requests = fetcher.requests
        XCTAssertGreaterThanOrEqual(
            requests.filter { $0.url == ClaudeAccountAdapter.usageURL }.count, 5,
            "the cycle must actually exercise the network seam")
        let allowed: Set<URL> = [ClaudeAccountAdapter.usageURL, ClaudeAccountAdapter.profileURL,
                                 prepaidURL]
        for request in requests {
            XCTAssertTrue(allowed.contains(request.url),
                          "R3: request to an unexpected URL \(request.url)")
            XCTAssertEqual(request.url.host, "api.anthropic.com")
            XCTAssertFalse(request.url.path.lowercased().contains("token"),
                           "R3: request to a token endpoint \(request.url)")
            for (name, value) in request.headers {
                for banned in ["refresh", "grant_type", refreshMarker] {
                    XCTAssertFalse(value.lowercased().contains(banned.lowercased()),
                                   "R3: header \(name) carries '\(banned)'")
                    XCTAssertFalse(name.lowercased().contains(banned.lowercased()),
                                   "R3: header name \(name) carries '\(banned)'")
                }
            }
        }

        let invocations = try String(contentsOf: argsLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertGreaterThanOrEqual(invocations.count, 6)
        for line in invocations {
            XCTAssertEqual(line, "find-generic-password|-s|Claude Code-credentials|-w|",
                           "R4: the Keychain is only ever read, with exactly this argument shape")
        }
    }

    // MARK: - Fixtures

    private var prepaidURL: URL {
        ClaudeAccountAdapter.prepaidURL(orgId: "00000000-0000-0000-0000-000000000001")!
    }

    private var argsLog: URL { scratch.appendingPathComponent("args.log") }
    private var current: URL { scratch.appendingPathComponent("credential.json") }
    private var next: URL { scratch.appendingPathComponent("next.json") }

    /// A stand-in for `/usr/bin/security`: records its arguments, prints the current credential,
    /// then promotes a queued one so the *next* read sees a rotation.
    private func fakeSecurity() throws -> String {
        let url = scratch.appendingPathComponent("security")
        let script = """
        #!/bin/sh
        for a in "$@"; do printf '%s|' "$a"; done >> '\(argsLog.path)'
        echo >> '\(argsLog.path)'
        cat '\(current.path)'
        if [ -f '\(next.path)' ]; then mv '\(next.path)' '\(current.path)'; fi
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func writeCredential(_ token: String, expiresIn seconds: Double, now: Date,
                                 next queued: Bool = false) throws {
        let ms = Int((now.timeIntervalSince1970 + seconds) * 1000)
        let json = """
        {"claudeAiOauth":{"accessToken":"\(token)","refreshToken":"\(refreshMarker)",\
        "expiresAt":\(ms),"scopes":["user:inference"],"subscriptionType":"max"}}
        """
        try json.write(to: queued ? next : current, atomically: true, encoding: .utf8)
    }

    private func routeUsage(_ fetcher: RecordingFetcher, _ stubs: [StubResponse]) throws {
        fetcher.inner.setRouteSequence(ClaudeAccountAdapter.usageURL, stubs)
    }
}

/// `MockFetcher` plus the headers of every request.
private final class RecordingFetcher: HTTPFetcher, @unchecked Sendable {
    struct Request { let url: URL; let headers: [String: String] }
    let inner = MockFetcher()
    private let lock = NSLock()
    private var recorded: [Request] = []

    var requests: [Request] { lock.withLock { recorded } }

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(Request(url: url, headers: headers)) }
        return try await inner.get(url, headers: headers)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}
