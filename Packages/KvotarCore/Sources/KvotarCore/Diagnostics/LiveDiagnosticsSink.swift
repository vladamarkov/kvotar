import Foundation

/// The production `DiagnosticsSink`: gates on the live capture flag, then hands the write to the
/// store on a detached `Task` (§10.7a, REV-52 / STEP_72).
///
/// Fire-and-forget by design. The decorators calling this sit on the poll path, so a slow or failed
/// diagnostic write must cost the poll nothing — a dropped evidence row is acceptable, a delayed
/// quota reading is not. `SQLiteStore` already logs its own failures at WARN.
public struct LiveDiagnosticsSink: DiagnosticsSink {

    private let store: SQLiteStore
    private let anomalyBudget: AnomalyBudget
    private let rejectionTracker: EndpointRejectionTracker

    /// - Parameter maxAnomaliesPerFile: per-file cap for this process. One corrupt or truncated
    ///   JSONL file would otherwise append a row per line on every rescan — thousands of rows
    ///   saying the same thing, in a table whose value is that a non-trivial count *is* the finding.
    public init(store: SQLiteStore, maxAnomaliesPerFile: Int = 20) {
        self.store = store
        self.anomalyBudget = AnomalyBudget(limit: maxAnomaliesPerFile)
        self.rejectionTracker = EndpointRejectionTracker()
    }

    public func capture(tool: Tool, endpoint: String, body: Data, httpStatus: Int?) {
        // **Above** the capture gate, deliberately (STEP_75). Payload capture stays beta-gated, but
        // a standing rejection has to be detectable on the **release** channel too: the tester who
        // needs the signal is exactly the one running with capture off. This placement is the whole
        // always-on decision.
        detectStandingRejection(tool: tool, endpoint: endpoint, body: body, httpStatus: httpStatus)

        guard DiagnosticsCapture.isEnabled else { return }
        let store = self.store
        Task.detached(priority: .utility) {
            try? await store.writeRawPayload(
                tool: tool, endpoint: endpoint, body: body, httpStatus: httpStatus)
        }
    }

    public func recordAnomaly(_ anomaly: ParseAnomaly) {
        guard DiagnosticsCapture.isEnabled else { return }
        guard anomalyBudget.admit(anomaly.sourceFile) else { return }
        let store = self.store
        Task.detached(priority: .utility) {
            try? await store.writeParseAnomaly(anomaly)
        }
    }

    // MARK: - Standing endpoint rejection (§9.5 — STEP_75)

    /// Escalates an endpoint that has rejected us three times running, and records the moment it
    /// recovers. Two rows per episode, never one per occurrence — the 2026-07-15 field episode was
    /// 57 identical 403s logged at INFO with nothing escalating anywhere.
    private func detectStandingRejection(tool: Tool, endpoint: String, body: Data, httpStatus: Int?) {
        guard let outcome = rejectionTracker.record(
            tool: tool, endpoint: endpoint, httpStatus: httpStatus) else { return }

        // The log line carries the status; `poll_health_events` has no column for it and this step
        // adds no migration. Logged before the mapping below so an unmapped endpoint still shouts.
        switch outcome {
        case .opened(let status, let count):
            Logger.warning("Endpoint rejecting every request — standing condition",
                           component: .pollEngine,
                           metadata: ["tool": tool.rawValue, "endpoint": endpoint,
                                      "status": "\(status)", "consecutive": "\(count)"])
        case .cleared(let status, let count):
            Logger.info("Endpoint recovered after a standing rejection",
                        component: .pollEngine,
                        metadata: ["tool": tool.rawValue, "endpoint": endpoint,
                                   "status": "\(status)", "occurrences": "\(count)"])
        }

        // Two vocabularies meet here (see `PollHealthEndpoint`). An endpoint with no health-table
        // name — `claude_other`, a raw RPC method — keeps the log line above and writes no row,
        // rather than inventing a column value for an endpoint the app never calls.
        guard let healthEndpoint = PollHealthEndpoint(diagnosticsEndpoint: endpoint) else { return }

        let phase: EndpointRejectionPhase
        let count: Int
        switch outcome {
        case .opened(_, let openCount):
            phase = .opened
            count = openCount
        case .cleared(_, let total):
            phase = .cleared
            count = total
        }

        let store = self.store
        Task.detached(priority: .utility) {
            try? await store.writeEndpointRejectionEvent(
                tool: tool, endpoint: healthEndpoint, phase: phase,
                consecutiveCount: count, responseBody: nil)
        }
    }
}

/// What one observed response means to the standing-rejection detector.
enum EndpointRejectionOutcome: Equatable {
    /// The threshold was just crossed. `status` is the repeating rejection, `count` the run length.
    case opened(status: Int, count: Int)
    /// A 2xx ended an open episode. `count` is every rejection it contained.
    case cleared(status: Int, count: Int)
}

/// Detects an endpoint that rejects us *every single time* (§9.5 — STEP_75).
///
/// Not an actor, for the same reason as `AnomalyBudget`: it is called from `capture`, a synchronous
/// non-awaiting path on the poll route. The decision is kept here, free of I/O — the `SQLiteStore`
/// write lives in the sink — so the episode logic is testable without a database or an async hop
/// (the `PollBackoffPolicy` split, applied to a much smaller policy).
final class EndpointRejectionTracker: @unchecked Sendable {

    /// One rejection is ordinary transient noise; three consecutive is a standing condition. At the
    /// prepaid endpoint's 15-minute `prepaidMinInterval` that is 30–60 minutes to detection —
    /// against the week the 2026-07-15 episode actually took.
    static let defaultThreshold = 3

    private struct Key: Hashable {
        let tool: Tool
        let endpoint: String
    }

    private struct Run {
        var status: Int
        var count: Int
        var isOpen: Bool
    }

    private let threshold: Int
    private let lock = NSLock()
    private var runs: [Key: Run] = [:]

    init(threshold: Int = EndpointRejectionTracker.defaultThreshold) {
        self.threshold = threshold
    }

    /// Returns non-nil only at the two instants worth recording: the episode opening, and the 2xx
    /// that ends it. Everything in between — including occurrences 4…n of the same rejection —
    /// returns nil, which is what keeps a 25-hour episode to two rows instead of 57.
    ///
    /// Runs are keyed per `(tool, endpoint)`, so a healthy quota endpoint polling alongside a
    /// broken secondary one never re-arms it.
    func record(tool: Tool, endpoint: String, httpStatus: Int?) -> EndpointRejectionOutcome? {
        // The Codex RPC seam reports `httpStatus: nil` — a JSON-RPC error is not an HTTP status,
        // and there is nothing here to classify.
        guard let status = httpStatus else { return nil }

        let key = Key(tool: tool, endpoint: endpoint)
        lock.lock()
        defer { lock.unlock() }

        if (200...299).contains(status) {
            guard let run = runs.removeValue(forKey: key), run.isOpen else { return nil }
            return .cleared(status: status, count: run.count)
        }

        // A status another mechanism already owns is not evidence in either direction: it must
        // neither open an episode nor close one.
        guard !Self.isOwnedElsewhere(status: status, endpoint: endpoint) else { return nil }

        var run = runs[key] ?? Run(status: status, count: 0, isOpen: false)
        // A *different* rejection is a different condition — start its own run rather than letting
        // unrelated failures accumulate into a false standing signal.
        if run.status != status { run = Run(status: status, count: 0, isOpen: false) }
        run.count += 1
        let opening = !run.isOpen && run.count >= threshold
        if opening { run.isOpen = true }
        runs[key] = run

        return opening ? .opened(status: status, count: run.count) : nil
    }

    /// The exclusion list (§9.1 taxonomy discipline — never double-report a condition another
    /// mechanism owns and already surfaces).
    ///
    /// - `429`, anywhere: the §9.3 rate-limit ladder owns it, and records it as `transient` /
    ///   `rate_pressure` in this very table.
    /// - `401`/`403` on a **quota** endpoint: the re-auth path owns it — `checkUsageStatus` /
    ///   `CodexWhamHTTPClient.checkStatus` set `AdapterHealth.reauthRequired`, which reaches the
    ///   display, so the condition is already visible. Both handlers treat 401 and 403 identically,
    ///   so excluding one without the other would leave an asymmetric hole. (STEP_75's task file
    ///   attributed this to STEP_48's credential-expiry gate; that gate is *pre-poll* and sends no
    ///   request, so the sink never sees it, and its 429 reclassification never produces a 401.)
    ///
    /// Everything else — a 403 on a secondary endpoint, a 404, a 5xx — is nobody's, which is
    /// precisely the silence this detector exists to break.
    static func isOwnedElsewhere(status: Int, endpoint: String) -> Bool {
        if status == 429 { return true }
        if status == 401 || status == 403 { return quotaEndpoints.contains(endpoint) }
        return false
    }

    private static let quotaEndpoints: Set<String> = [
        DiagnosticsEndpoint.claudeUsage,
        DiagnosticsEndpoint.codexWhamUsage,
    ]
}

/// Per-file, per-process anomaly cap. Not an actor — `recordAnomaly` is called from the parsers'
/// synchronous decode path and must not await.
private final class AnomalyBudget: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    init(limit: Int) { self.limit = limit }

    /// True while the file is under budget. Logs once, at the moment the cap trips, so a silent
    /// stop is never mistaken for "the file went quiet".
    func admit(_ file: String) -> Bool {
        lock.lock()
        let seen = counts[file, default: 0]
        counts[file] = seen + 1
        lock.unlock()

        if seen == limit {
            Logger.warning("Parse-anomaly cap reached for file — further rows suppressed",
                           component: .sqliteStore,
                           metadata: ["file": (file as NSString).lastPathComponent,
                                      "limit": "\(limit)"])
        }
        return seen < limit
    }
}
