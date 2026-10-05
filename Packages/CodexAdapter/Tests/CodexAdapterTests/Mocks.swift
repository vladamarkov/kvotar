import Foundation
import XCTest
import KvotarCore
@testable import CodexAdapter

/// Scriptable `CodexProcessTransport` fake. Tests configure per-method result bodies; on `send`
/// it parses the request id + method and emits a matching JSON-RPC response line. It can also
/// emit unsolicited lines on start and simulate a crash (stream finishing / start throwing).
///
/// `@unchecked Sendable` with an internal lock — accessed from the client's async send path and
/// its stdout reader task.
final class FakeCodexTransport: CodexProcessTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<String>.Continuation?
    private var running = false

    // Configuration (set before use).
    /// Thrown by `start(binary:)` when non-nil — simulates spawn failure.
    var startError: Error?
    /// Lines emitted immediately after a successful start (e.g. a startup notification).
    var onStartEmit: [String] = []
    /// When true, the stream finishes right after start — simulates an immediate process crash.
    var closeOnStart = false
    /// method -> result body JSON. Methods absent here get no response (the call times out).
    var responses: [String: String] = [:]
    /// A slow exit (STEP_277): `terminate()` leaves the old stream open, so the client's old reader
    /// is still alive when the restart begins. The first request sent to the next process finishes
    /// the held stream, and every response arrives `responseDelay` after its request — long enough
    /// for the old reader's exit to land while the new call is still waiting.
    var holdStreamOnTerminate = false
    var responseDelay: Duration?
    private var heldContinuation: AsyncStream<String>.Continuation?

    // Observability.
    private(set) var startCount = 0
    private(set) var terminateCount = 0
    private(set) var sentLines: [String] = []
    /// Ordered log of "start"/"terminate" so tests can assert the client reaps the old child before
    /// re-spawning (STEP_24 — every start must be immediately preceded by a terminate).
    private(set) var events: [String] = []

    var isRunning: Bool { lock.withLock { running } }

    func start(binary: URL) throws -> AsyncStream<String> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        lock.withLock {
            startCount += 1
            events.append("start")
            self.continuation = continuation
            running = true
        }
        for line in onStartEmit { continuation.yield(line) }
        if closeOnStart {
            lock.withLock { running = false }
            continuation.finish()
        }
        return stream
    }

    func send(_ line: String) throws {
        lock.withLock { sentLines.append(line) }
        guard let (id, method) = Self.parse(line) else { return }
        guard let body = lock.withLock({ responses[method] }) else { return }
        let response = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(body)}"
        let (current, held) = lock.withLock { () -> (AsyncStream<String>.Continuation?, AsyncStream<String>.Continuation?) in
            let held = heldContinuation
            heldContinuation = nil
            return (continuation, held)
        }
        held?.finish()
        if let responseDelay {
            Task {
                try? await Task.sleep(for: responseDelay)
                current?.yield(response)
            }
        } else {
            current?.yield(response)
        }
    }

    func terminate() {
        let continuation = lock.withLock { () -> AsyncStream<String>.Continuation? in
            terminateCount += 1
            events.append("terminate")
            running = false
            let existing = self.continuation
            self.continuation = nil
            if holdStreamOnTerminate, let existing {
                heldContinuation = existing
                return nil
            }
            return existing
        }
        continuation?.finish()
    }

    /// Extracts `(id, method)` from an outgoing request line.
    static func parse(_ line: String) -> (Int, String)? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int,
              let method = object["method"] as? String else { return nil }
        return (id, method)
    }
}

/// Fixed-result binary locator. `path == nil` simulates Codex Desktop not installed.
struct StubBinaryLocator: CodexBinaryLocator {
    var path: String? = "/tmp/codex"
    /// Counts lookups so a test can assert the client caches instead of re-resolving per poll.
    let calls = Counter()

    func locate() -> CodexBinaryCandidates.Resolution {
        calls.increment()
        return CodexBinaryCandidates.Resolution(
            url: path.map { URL(fileURLWithPath: $0) }, searched: ["stub"])
    }
}

/// Minimal thread-safe counter — `locate()` is non-mutating on a `Sendable` struct.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Loads a JSON fixture from the test bundle's `TestFixtures` resource directory as a string.
func fixtureString(_ name: String) throws -> String {
    let url = try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "json"),
        "missing fixture: \(name).json"
    )
    return try String(contentsOf: url, encoding: .utf8)
}

/// Loads a JSON fixture from the test bundle's `TestFixtures` resource directory as `Data`.
func fixtureData(_ name: String) throws -> Data {
    Data(try fixtureString(name).utf8)
}

/// Scriptable `CodexRPCPolling` fake for `CodexAccountAdapter` tests. Returns a fixed poll result
/// or throws (e.g. to simulate RPC unavailable → wham fallback).
struct FakeCodexRPC: CodexRPCPolling, @unchecked Sendable {
    var result: Result<(account: CodexAccountRead, rateLimits: CodexRateLimits), Error>

    func start() async throws {}
    func poll() async throws -> (account: CodexAccountRead, rateLimits: CodexRateLimits) {
        try result.get()
    }
    func shutdown() {}

    /// Builds a success result by decoding the confirmed RPC fixtures.
    static func healthy() throws -> FakeCodexRPC {
        let account = try JSONDecoder().decode(
            CodexAccountRead.self, from: fixtureData("account_read_healthy_enterprise"))
        let rateLimits = try JSONDecoder().decode(
            CodexRateLimits.self, from: fixtureData("ratelimits_null_window_enterprise"))
        return FakeCodexRPC(result: .success((account, rateLimits)))
    }

    static func failing(_ error: Error = CodexRPCClient.ClientError.unavailable) -> FakeCodexRPC {
        FakeCodexRPC(result: .failure(error))
    }
}

/// RPC fake that sleeps before throwing — drives the overall-budget test's slow RPC leg. The sleep
/// is cancellation-aware (`Task.sleep`), so it unwinds promptly when the deadline cancels it.
struct SlowCodexRPC: CodexRPCPolling, @unchecked Sendable {
    var delay: Duration
    func start() async throws {}
    func poll() async throws -> (account: CodexAccountRead, rateLimits: CodexRateLimits) {
        try await Task.sleep(for: delay)
        throw CodexRPCClient.ClientError.unavailable
    }
    func shutdown() {}
}

/// Wham fake that sleeps before throwing — the slow fallback leg for the overall-budget test.
struct SlowWhamClient: CodexWhamClient, @unchecked Sendable {
    var delay: Duration
    func fetchUsage() async throws -> CodexWhamResult {
        try await Task.sleep(for: delay)
        throw AccountAdapterError.reauthRequired
    }
}

/// Scriptable `CodexWhamClient` fake. Returns a decoded fixture or throws.
struct FakeWhamClient: CodexWhamClient, @unchecked Sendable {
    var result: Result<CodexWhamResult, Error>

    func fetchUsage() async throws -> CodexWhamResult { try result.get() }

    static func fixture(_ name: String) throws -> FakeWhamClient {
        let usage = try CodexWhamUsage.decode(from: fixtureData(name))
        return FakeWhamClient(result: .success(CodexWhamResult(usage: usage)))
    }

    static func failing(_ error: Error) -> FakeWhamClient {
        FakeWhamClient(result: .failure(error))
    }
}

/// Scriptable `CodexHTTPFetcher` fake for `CodexWhamHTTPClient` tests. Returns a fixed
/// status/body/headers or throws, with no real network.
struct FakeCodexHTTPFetcher: CodexHTTPFetcher, @unchecked Sendable {
    var statusCode: Int = 200
    var body: Data = Data()
    var headers: [String: String] = [:]
    var error: Error?

    func get(_ url: URL, headers requestHeaders: [String: String]) async throws -> (Data, HTTPURLResponse) {
        if let error { throw error }
        let response = HTTPURLResponse(
            url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
        return (body, response)
    }

    static func fixture(_ name: String, statusCode: Int = 200, headers: [String: String] = [:]) throws -> FakeCodexHTTPFetcher {
        FakeCodexHTTPFetcher(statusCode: statusCode, body: try fixtureData(name), headers: headers)
    }
}

/// Fixed-credential `CodexTokenProvider` fake. `fixedCredential == nil` simulates a
/// missing/unreadable `auth.json` (setup-required path).
struct FakeCodexAuth: CodexTokenProvider {
    var fixedCredential: CodexCredential?

    func credential() throws -> CodexCredential? { fixedCredential }
}
