import Foundation
import KvotarCore

/// Persistent NDJSON JSON-RPC client for the Codex `app-server` subprocess (Baseline §8.1, §8.7;
/// PATTERNS.md §Codex RPC client; task Step 8).
///
/// Transport only: it spawns/initializes the process, matches responses to requests, and decodes
/// the two confirmed result shapes. It does **not** map to `QuotaSnapshot`, apply RPC-vs-wham
/// precedence, conform to `AccountAdapter`, or write to `SQLiteStore` — those belong to Steps 9/10
/// and the PollEngine step.
///
/// `final class` (not an actor) because the stdout reader runs on a `DispatchQueue`. Shared mutable
/// state is guarded by `lock`; `pendingRequests` is written from both the calling async context
/// (on send) and the reader task (on response arrival), the one place a lock replaces actor
/// isolation (PATTERNS.md §Codex RPC client). The lock is never held across an `await`.
public final class CodexRPCClient: CodexRPCPolling, @unchecked Sendable {

    public enum ClientError: Error, Equatable {
        /// Binary not found, or the process failed to (re)start 3 times consecutively — the caller
        /// falls through to wham/usage and shows "Codex Desktop not installed" (Baseline §8.6).
        case unavailable
        /// A call exceeded its timeout.
        case timeout(method: String)
        /// The process exited while a call was in flight.
        case transportClosed
        /// The RPC returned an `error` object.
        case rpcError(String)
        /// A result payload could not be decoded into the expected shape.
        case decoding(String)
    }

    static let maxConsecutiveRestartFailures = 3

    private let transport: CodexProcessTransport
    private let locator: CodexBinaryLocator
    /// Diagnostics capture hook (§10.7a, REV-52 / STEP_72). The RPC path has no HTTP seam to
    /// decorate, so capture is an injected observer here instead — fired with the JSON-RPC
    /// `method`, which is already the stable endpoint name (`account/read`,
    /// `account/rateLimits/read`), so nothing needs mapping. Nil by default: every existing test
    /// constructs this client exactly as before.
    private let onResponse: (@Sendable (String, Data) -> Void)?
    private let appVersion: String
    private let startupTimeout: Duration
    private let callTimeout: Duration
    private let restartCooldown: Duration

    private let lock = NSLock()
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextId = 0
    private var consecutiveRestartFailures = 0
    /// Wall-clock time of the most recent start/initialize failure (guarded by `lock`) — drives the
    /// post-lockout cooldown so `unavailable` is not permanent until app restart.
    private var lastRestartFailureAt: Date?
    /// Last discovery result and when it was taken (guarded by `lock`). Without this, `locate()`
    /// ran on every start attempt and every miss spawned `which` — a `Process` and two `Pipe`s,
    /// four descriptors, every two minutes. REV-71 §2.4 blames exactly that cost for making an
    /// exhausted process table look like a genuinely absent binary, so caching the *positive*
    /// result is part of the fix and not only an optimisation.
    private var binaryCache: (url: URL?, at: Date)?
    /// Latched so a missing binary is reported once per episode rather than once per poll. It cost
    /// 3296 ERROR lines in a single 5 MB log generation, burning the rotation ring STEP_135 sized
    /// to hold about five weeks.
    private var binaryMissingLogged = false
    private var readerTask: Task<Void, Never>?
    private var started = false

    private var restartCooldownSeconds: TimeInterval {
        Double(restartCooldown.components.seconds)
            + Double(restartCooldown.components.attoseconds) / 1e18
    }

    /// Binary discovery, cached for `restartCooldown` and invalidated whenever a start fails, so a
    /// Codex update that moves the binary recovers without an app restart.
    ///
    /// The lock is deliberately **not** held across `locator.locate()`: the `which` fallback blocks
    /// on `waitUntilExit`, and this is the same lock that guards every pending continuation. A
    /// racing double lookup is far cheaper than serialising a subprocess behind it.
    private func resolveBinary(now: Date) -> URL? {
        let cached = lock.withLock { () -> (url: URL?, at: Date)? in
            guard let binaryCache,
                  now.timeIntervalSince(binaryCache.at) < restartCooldownSeconds else { return nil }
            return binaryCache
        }
        if let cached { return cached.url }

        let resolution = locator.locate()

        // One line per episode, not per poll — and the miss says what it looked at, which is the
        // STEP_117 honesty rule applied to the function it was written for.
        enum Report { case quiet, missing, recovered }
        let report: Report = lock.withLock {
            binaryCache = (resolution.url, now)
            guard resolution.url != nil else {
                if binaryMissingLogged { return .quiet }
                binaryMissingLogged = true
                return .missing
            }
            guard binaryMissingLogged else { return .quiet }
            binaryMissingLogged = false
            return .recovered
        }

        switch report {
        case .quiet:
            break
        case .missing:
            Logger.error("Codex binary not found — falling through to wham/usage",
                         component: .codexAccountAdapter,
                         metadata: ["searched": resolution.searched.joined(separator: ", ")])
        case .recovered:
            Logger.info("Codex binary found", component: .codexAccountAdapter,
                        metadata: ["path": resolution.url?.path ?? ""])
        }
        return resolution.url
    }

    /// Test-facing: number of in-flight requests still awaiting a response. Used to assert that a
    /// cancelled `call()` drains its pending continuation instead of orphaning it.
    var pendingCount: Int { lock.withLock { pendingRequests.count } }

    /// - Parameters:
    ///   - startupTimeout: budget for spawn + `initialize` (Baseline §8.7 / ARCHITECTURE §Timeout
    ///     chain: 8s total covering startup and the first poll pair). This client bounds only its
    ///     own calls; the overall 18s Codex budget across RPC + wham is enforced by
    ///     `CodexAccountAdapter.fetchQuotaSnapshot`'s deadline (§13.3).
    ///   - callTimeout: per-poll call timeout (2s each, §8.7).
    ///   - restartCooldown: after `maxConsecutiveRestartFailures` consecutive start failures the
    ///     client reports `unavailable`; once this cooldown elapses since the last failure it allows
    ///     one fresh restart attempt (default 300s, consistent with §9's 5-minute cadence ceiling).
    public init(
        transport: CodexProcessTransport = CodexProcessTransportLive(),
        locator: CodexBinaryLocator = DefaultCodexBinaryLocator(),
        appVersion: String = "pre-alpha",
        startupTimeout: Duration = .seconds(8),
        callTimeout: Duration = .seconds(2),
        restartCooldown: Duration = .seconds(300),
        onResponse: (@Sendable (String, Data) -> Void)? = nil
    ) {
        self.transport = transport
        self.locator = locator
        self.onResponse = onResponse
        self.appVersion = appVersion
        self.startupTimeout = startupTimeout
        self.callTimeout = callTimeout
        self.restartCooldown = restartCooldown
    }

    // MARK: - Lifecycle

    /// Spawns and initializes the process if not already running. Idempotent.
    public func start() async throws {
        try await ensureStarted()
    }

    /// Terminates the process and fails any in-flight calls.
    public func shutdown() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            started = false
            let existing = readerTask
            readerTask = nil
            return existing
        }
        task?.cancel()
        transport.terminate()
    }

    // MARK: - Poll (Baseline §8.7 per-poll sequence)

    /// One poll: `account/read` then `account/rateLimits/read`, each with the 2s call timeout.
    /// Restarts + re-initializes the process first if it is not running (crash recovery, §8.7).
    public func poll() async throws -> (account: CodexAccountRead, rateLimits: CodexRateLimits) {
        try await ensureStarted()

        let accountData = try await call(method: "account/read", paramsJSON: "{}", timeout: callTimeout)
        let rateLimitData = try await call(method: "account/rateLimits/read", paramsJSON: "{}", timeout: callTimeout)

        let account = try decode(CodexAccountRead.self, from: accountData)
        let rateLimits = try decode(CodexRateLimits.self, from: rateLimitData)

        Logger.info("Codex RPC poll complete", component: .codexAccountAdapter,
                    metadata: [
                        "plan": account.account.planType ?? "unknown",
                        "primary": rateLimits.rateLimits.primary == nil ? "null" : "tracked",
                        "email": account.account.email == nil ? "none" : "<redacted>",
                    ])
        return (account, rateLimits)
    }

    // MARK: - Startup / crash recovery

    private func ensureStarted() async throws {
        if lock.withLock({ started }) && transport.isRunning { return }

        // Lockout with cooldown: after N consecutive failures report `unavailable`, but reset and
        // allow one fresh restart once `restartCooldown` has elapsed — the lockout is no longer
        // permanent until app restart.
        let lockedOut: Bool = lock.withLock {
            guard consecutiveRestartFailures >= Self.maxConsecutiveRestartFailures else { return false }
            if let last = lastRestartFailureAt,
               Date().timeIntervalSince(last) >= restartCooldownSeconds {
                consecutiveRestartFailures = 0
                return false
            }
            return true
        }
        if lockedOut { throw ClientError.unavailable }

        guard let binary = resolveBinary(now: Date()) else { throw ClientError.unavailable }

        // Tear down any stale reader and reap any stale child before restarting — a failed init with
        // the previous process still alive would otherwise orphan a live app-server on every retry.
        // `terminate()` is idempotent when no process is running (cold start).
        lock.withLock {
            started = false
            readerTask?.cancel()
            readerTask = nil
        }
        transport.terminate()

        do {
            let stream = try transport.start(binary: binary)
            startReader(stream)
            let initParams = "{\"clientInfo\":{\"name\":\"Kvotar\",\"version\":\"\(appVersion)\"}}"
            _ = try await call(method: "initialize", paramsJSON: initParams, timeout: startupTimeout)
            lock.withLock {
                started = true
                consecutiveRestartFailures = 0
            }
        } catch {
            let failures = lock.withLock { () -> Int in
                consecutiveRestartFailures += 1
                lastRestartFailureAt = Date()
                started = false
                readerTask?.cancel()
                readerTask = nil
                // A binary that no longer starts is a binary worth looking for again — a Codex
                // update that moved it re-resolves on the next attempt rather than at the TTL.
                binaryCache = nil
                return consecutiveRestartFailures
            }
            // The child's own first stderr line. Without it, an argument the binary stopped
            // accepting reads here as a bare timeout — which is exactly how `-a untrusted` stayed
            // undiagnosed (Baseline §8.1, 2026-09-09).
            Logger.error("Codex app-server start/initialize failed",
                         component: .codexAccountAdapter,
                         metadata: ["consecutive": "\(failures)", "error": "\(error)",
                                    "binary": binary.path,
                                    "stderr": transport.recentStderr ?? "none"])
            throw failures >= Self.maxConsecutiveRestartFailures ? ClientError.unavailable : error
        }
    }

    // MARK: - Request / response matching

    /// Sends a request and suspends until the matching response id arrives or the timeout fires.
    private func call(method: String, paramsJSON: String, timeout: Duration) async throws -> Data {
        let id = lock.withLock { () -> Int in nextId += 1; return nextId }
        let line = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":\(paramsJSON)}"

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                // Cancellation-aware: if the surrounding task is cancelled, remove and resume the
                // pending continuation with `CancellationError` so it does not orphan (the task group
                // would otherwise await a continuation nobody ever resumes → hang + leak). Exactly
                // one of `handleLine` / timeout / this `onCancel` wins the atomic `removeValue`.
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        self.lock.withLock { self.pendingRequests[id] = continuation }
                        do {
                            try self.transport.send(line)
                        } catch {
                            let stored = self.lock.withLock { self.pendingRequests.removeValue(forKey: id) }
                            stored?.resume(throwing: error)
                        }
                    }
                } onCancel: {
                    let stored = self.lock.withLock { self.pendingRequests.removeValue(forKey: id) }
                    stored?.resume(throwing: CancellationError())
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                let stored = self.lock.withLock { self.pendingRequests.removeValue(forKey: id) }
                stored?.resume(throwing: ClientError.timeout(method: method))
                throw ClientError.timeout(method: method)
            }
            defer { group.cancelAll() }
            let data = try await group.next()!
            // Capture only a landed response — a timeout or cancellation has no body to record.
            onResponse?(method, data)
            return data
        }
    }

    private func startReader(_ stream: AsyncStream<String>) {
        let task = Task { [weak self] in
            for await line in stream {
                self?.handleLine(line)
            }
            self?.handleTransportClosed()
        }
        lock.withLock { readerTask = task }
    }

    /// Routes one stdout line: responses (`id` present) resume the waiting call; unsolicited
    /// notifications (`method`, no `id`) are logged at DEBUG and discarded — never routed to a
    /// continuation (Baseline §8.7, PATTERNS.md §Codex RPC client).
    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Logger.debug("Codex RPC unparseable line", component: .codexAccountAdapter)
            return
        }

        if let id = object["id"] as? Int {
            guard let continuation = lock.withLock({ pendingRequests.removeValue(forKey: id) }) else {
                return  // unknown or already-resolved id
            }
            if let result = object["result"] {
                if let resultData = try? JSONSerialization.data(
                    withJSONObject: result, options: [.fragmentsAllowed]) {
                    continuation.resume(returning: resultData)
                } else {
                    continuation.resume(throwing: ClientError.decoding("result reserialization"))
                }
            } else if let error = object["error"] {
                continuation.resume(throwing: ClientError.rpcError("\(error)"))
            } else {
                continuation.resume(throwing: ClientError.decoding("response missing result and error"))
            }
        } else if let method = object["method"] as? String {
            Logger.debug("Codex RPC notification ignored", component: .codexAccountAdapter,
                         metadata: ["method": method])
        } else {
            Logger.debug("Codex RPC unrecognized frame", component: .codexAccountAdapter)
        }
    }

    /// Process exited: fail every in-flight call so `poll()` surfaces the crash and triggers a
    /// restart on the next call (Baseline §8.7 crash recovery).
    private func handleTransportClosed() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Data, Error>] in
            let all = Array(pendingRequests.values)
            pendingRequests.removeAll()
            started = false
            return all
        }
        for continuation in continuations {
            continuation.resume(throwing: ClientError.transportClosed)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError.decoding("\(error)")
        }
    }
}
