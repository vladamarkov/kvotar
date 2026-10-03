import Foundation
import XCTest
@testable import ClaudeAdapter

/// Fixed-credential provider. `token == nil` simulates an inaccessible Keychain
/// (setup-required path); `subscriptionType` feeds the Keychain plan source.
struct MockTokenProvider: ClaudeTokenProvider {
    let token: String?
    var subscriptionType: String? = nil
    /// `claudeAiOauth.expiresAt`, epoch **ms** (§8.0.1). nil ⇒ the STEP_48 gate is a no-op.
    var expiresAt: Double? = nil

    func credential() throws -> ClaudeCredential? {
        guard let token else { return nil }
        return ClaudeCredential(accessToken: token, subscriptionType: subscriptionType,
                                expiresAt: expiresAt)
    }
}

/// Credential provider whose `expiresAt` can be flipped between reads — models Claude Code
/// refreshing the token mid-run (the STEP_48 zero-network recovery case). `@unchecked Sendable`
/// with a lock: read from the adapter actor across awaits.
final class MutableExpiryTokenProvider: ClaudeTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let token: String
    private var _expiresAt: Double?

    init(token: String, expiresAt: Double?) {
        self.token = token
        self._expiresAt = expiresAt
    }

    var expiresAt: Double? {
        get { lock.withLock { _expiresAt } }
        set { lock.withLock { _expiresAt = newValue } }
    }

    func credential() throws -> ClaudeCredential? {
        lock.withLock { ClaudeCredential(accessToken: token, expiresAt: _expiresAt) }
    }
}

/// Returns a queue of tokens on successive `credential()` reads (first → old, second → new, …),
/// repeating the last once drained. Models a credential rotated by a concurrent client between
/// reads (Change C). `@unchecked Sendable` with a lock — read from the adapter actor across awaits.
final class SequenceTokenProvider: ClaudeTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]
    private let subscriptionType: String?
    /// Optional per-token `expiresAt` (epoch ms), aligned by index; missing ⇒ nil (never expired).
    private let expiresAt: [Double?]
    private var index = 0

    init(_ tokens: [String], subscriptionType: String? = nil, expiresAt: [Double?] = []) {
        precondition(!tokens.isEmpty, "SequenceTokenProvider needs at least one token")
        self.tokens = tokens
        self.subscriptionType = subscriptionType
        self.expiresAt = expiresAt
    }

    func credential() throws -> ClaudeCredential? {
        lock.withLock {
            let i = min(index, tokens.count - 1)
            index += 1
            return ClaudeCredential(accessToken: tokens[i], subscriptionType: subscriptionType,
                                    expiresAt: i < expiresAt.count ? expiresAt[i] : nil)
        }
    }
}

/// A provider that can be switched into throwing mid-test — models a Keychain read that fails
/// (locked, `security` unavailable) after a normal poll. `@unchecked Sendable` with a lock.
final class ToggleThrowingTokenProvider: ClaudeTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let token: String
    private var _throwing = false

    init(token: String) { self.token = token }

    var throwing: Bool {
        get { lock.withLock { _throwing } }
        set { lock.withLock { _throwing = newValue } }
    }

    func credential() throws -> ClaudeCredential? {
        try lock.withLock {
            if _throwing { throw URLError(.cannotOpenFile) }
            return ClaudeCredential(accessToken: token)
        }
    }
}

/// A stubbed HTTP response for one URL.
struct StubResponse {
    let data: Data
    let status: Int
    let headers: [String: String]

    init(data: Data, status: Int = 200, headers: [String: String] = [:]) {
        self.data = data
        self.status = status
        self.headers = headers
    }
}

/// Fixture-backed `HTTPFetcher`. Routes by absolute URL; records requests for assertions.
/// `@unchecked Sendable` with an internal lock — accessed from the adapter actor across awaits.
final class MockFetcher: HTTPFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: StubResponse] = [:]
    private var sequences: [String: [StubResponse]] = [:]
    private var recordedRequests: [URL] = []

    func setRoute(_ url: URL, _ stub: StubResponse) {
        lock.withLock { routes[url.absoluteString] = stub }
    }

    /// Queues successive responses for one URL: each `get` pops the front, keeping the last when
    /// drained. Lets the same URL answer 401 then 200 (Change C rotation self-heal). Checked before
    /// the plain `routes` entry.
    func setRouteSequence(_ url: URL, _ stubs: [StubResponse]) {
        lock.withLock { sequences[url.absoluteString] = stubs }
    }

    func requestCount(for url: URL) -> Int {
        lock.withLock {
            recordedRequests.filter { $0.absoluteString == url.absoluteString }.count
        }
    }

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let stub: StubResponse? = lock.withLock {
            recordedRequests.append(url)
            let key = url.absoluteString
            if var queue = sequences[key], !queue.isEmpty {
                let next = queue.count > 1 ? queue.removeFirst() : queue[0]
                sequences[key] = queue
                return next
            }
            return routes[key]
        }

        guard let stub else { throw URLError(.unsupportedURL) }
        let response = HTTPURLResponse(
            url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers
        )!
        return (stub.data, response)
    }
}

/// Loads a JSON fixture from the test bundle's `TestFixtures` resource directory.
func fixtureData(_ name: String) throws -> Data {
    let url = try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "json"),
        "missing fixture: \(name).json"
    )
    return try Data(contentsOf: url)
}

/// URL of a JSON fixture (used for the `~/.claude.json` local-config fallback path).
func fixtureURL(_ name: String) throws -> URL {
    try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "json"),
        "missing fixture: \(name).json"
    )
}
