import XCTest
import KvotarCore
@testable import CodexAdapter

/// Absolute rules R2, R3 and R4 on the Codex side (STEP_239): `~/.codex/auth.json` is only ever
/// read, and nothing Kvotar sends — to the app-server or to `wham/usage` — asks for a refresh. The
/// fixture `auth.json` carries a refresh token, so a change that started forwarding it would show
/// up in a recorded RPC line or header. `CodexHTTPFetcher` is GET-only: there is no request body.
final class NoRefreshNetworkSeamTests: XCTestCase {

    private let refreshMarker = "REFRESH-MARKER-91ad"
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvotar-codex-norefresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
        super.tearDown()
    }

    func testAFullCycleSpeaksOnlyTheQuotaMethodsAndNeverSendsARefreshToken() async throws {
        try writeAuth(token: "tok-a")
        let transport = FakeCodexTransport()
        transport.responses = [
            "initialize": "{}",
            "account/read": try fixtureString("account_read_healthy_enterprise"),
            "account/rateLimits/read": try fixtureString("ratelimits_null_window_enterprise"),
        ]
        let rpc = CodexRPCClient(transport: transport, locator: StubBinaryLocator(),
                                 startupTimeout: .milliseconds(500),
                                 callTimeout: .milliseconds(300))
        let fetcher = RecordingCodexFetcher()
        let wham = CodexWhamHTTPClient(fetcher: fetcher,
                                       tokenProvider: CodexAuthFileReader(path: authURL))
        let adapter = CodexAccountAdapter(rpc: rpc, wham: wham,
                                          metadataReader: Self.isolatedMetadataReader)

        // 1. Normal poll over the app-server.
        _ = try await adapter.fetchQuotaSnapshot()

        // 2–4. The app-server stops answering: wham/usage answers 200, then 401, then 429.
        transport.responses["account/read"] = nil
        let ok = try fixtureData("wham_healthy_null_window_enterprise")
        for (status, headers) in [(200, [String: String]()), (401, [:]), (429, ["Retry-After": "30"])] {
            fetcher.next = (status, status == 200 ? ok : Data("{}".utf8), headers)
            _ = try? await adapter.fetchQuotaSnapshot()
        }

        // 5. Codex rewrites auth.json between polls.
        try writeAuth(token: "tok-b")
        fetcher.next = (200, ok, [:])
        _ = try? await adapter.fetchQuotaSnapshot()
        rpc.shutdown()

        let allowedMethods: Set<String> = ["initialize", "initialized", "account/read",
                                           "account/rateLimits/read"]
        XCTAssertFalse(transport.sentLines.isEmpty)
        for line in transport.sentLines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let method = object?["method"] as? String ?? "<none>"
            XCTAssertTrue(allowedMethods.contains(method), "R3: app-server method \(method)")
            for banned in ["refresh", "grant_type", refreshMarker] {
                XCTAssertFalse(line.lowercased().contains(banned.lowercased()),
                               "R3: app-server line carries '\(banned)'")
            }
        }

        let requests = fetcher.requests
        XCTAssertGreaterThanOrEqual(requests.count, 4, "the cycle must actually reach wham/usage")
        for request in requests {
            XCTAssertEqual(request.url, CodexWhamHTTPClient.usageURL,
                           "R3: request to an unexpected URL \(request.url)")
            for (name, value) in request.headers {
                for banned in ["refresh", "grant_type", refreshMarker] {
                    XCTAssertFalse((name + value).lowercased().contains(banned.lowercased()),
                                   "R3: header \(name) carries '\(banned)'")
                }
            }
        }
        XCTAssertEqual(requests.last?.headers["Authorization"], "Bearer tok-b",
                       "a rewritten auth.json is picked up by re-reading it, not by refreshing")
    }

    /// R2/R4: reading the credential, alone or through a whole poll, leaves `auth.json`
    /// byte-identical with an unchanged modification time.
    func testReadingAuthJSONLeavesItByteIdentical() async throws {
        try writeAuth(token: "tok-a")
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: authURL.path)
        let before = try Data(contentsOf: authURL)

        let reader = CodexAuthFileReader(path: authURL)
        for _ in 0..<20 { _ = try reader.credential() }
        let fetcher = RecordingCodexFetcher()
        fetcher.next = (200, try fixtureData("wham_healthy_null_window_enterprise"), [:])
        let wham = CodexWhamHTTPClient(fetcher: fetcher, tokenProvider: reader)
        for _ in 0..<3 { _ = try await wham.fetchUsage() }

        XCTAssertEqual(try Data(contentsOf: authURL), before, "R2: auth.json content changed")
        let mtime = try FileManager.default.attributesOfItem(atPath: authURL.path)[.modificationDate]
        XCTAssertEqual(mtime as? Date, past, "R2: auth.json was touched")
    }

    // MARK: - Fixtures

    private static let isolatedMetadataReader = CodexSQLiteMetadataReader(
        statePath: URL(fileURLWithPath: "/nonexistent/state_5.sqlite"),
        goalsPath: URL(fileURLWithPath: "/nonexistent/goals_1.sqlite"))

    private var authURL: URL { scratch.appendingPathComponent("auth.json") }

    private func writeAuth(token: String) throws {
        let json = """
        {"OPENAI_API_KEY":null,"tokens":{"id_token":"id","access_token":"\(token)",\
        "refresh_token":"\(refreshMarker)","account_id":"acct-0001"},"last_refresh":"2026-01-01T00:00:00Z"}
        """
        try json.write(to: authURL, atomically: true, encoding: .utf8)
    }
}

/// Records every request; answers with whatever `next` holds.
private final class RecordingCodexFetcher: CodexHTTPFetcher, @unchecked Sendable {
    struct Request { let url: URL; let headers: [String: String] }
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var _next: (Int, Data, [String: String]) = (200, Data("{}".utf8), [:])

    var requests: [Request] { lock.withLock { recorded } }
    var next: (Int, Data, [String: String]) {
        get { lock.withLock { _next } }
        set { lock.withLock { _next = newValue } }
    }

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let (status, body, responseHeaders) = lock.withLock { () -> (Int, Data, [String: String]) in
            recorded.append(Request(url: url, headers: headers))
            return _next
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: responseHeaders)!
        return (body, response)
    }
}
