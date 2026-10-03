import KvotarCore
import Foundation

/// `CodexHTTPFetcher` decorator recording each wham/usage response into diagnostics capture
/// (§10.7a, REV-52 / STEP_72), then returning it untouched.
///
/// Twin of `ClaudeAdapter.CapturingHTTPFetcher`, duplicated rather than shared because
/// `CodexAdapter` cannot import `ClaudeAdapter` (ARCHITECTURE.md §SPM package dependency graph) —
/// the same reason `CodexHTTPFetcher` itself duplicates `HTTPFetcher`.
///
/// **Requests are never captured** — the bearer token rides in a request header.
public struct CapturingCodexHTTPFetcher: CodexHTTPFetcher {

    private let wrapped: CodexHTTPFetcher
    private let sink: DiagnosticsSink

    public init(wrapping wrapped: CodexHTTPFetcher, sink: DiagnosticsSink) {
        self.wrapped = wrapped
        self.sink = sink
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await wrapped.get(url, headers: headers)
        sink.capture(tool: .codex,
                     endpoint: DiagnosticsEndpoint.codexWhamUsage,
                     body: data,
                     httpStatus: response.statusCode)
        return (data, response)
    }
}
