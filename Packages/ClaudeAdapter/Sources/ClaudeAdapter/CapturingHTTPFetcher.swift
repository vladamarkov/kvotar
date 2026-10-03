import KvotarCore
import Foundation

/// `HTTPFetcher` decorator that records each response into diagnostics capture (§10.7a, REV-52 /
/// STEP_72), then returns it untouched.
///
/// A decorator rather than call-site edits in `ClaudeAccountAdapter`, for three reasons: all three
/// Claude OAuth calls (usage, profile, prepaid) go through `fetcher.get`, so one wrapper covers the
/// set; the adapter's own test suite stays **unmodified**, which is this step's regression
/// assertion; and the privacy boundary (§10.6) ends up in one reviewable place instead of three.
///
/// **Requests are never captured** — the bearer token rides in a request header, and no capture path
/// in this app touches credential material in either direction.
public struct CapturingHTTPFetcher: HTTPFetcher {

    private let wrapped: HTTPFetcher
    private let sink: DiagnosticsSink

    public init(wrapping wrapped: HTTPFetcher, sink: DiagnosticsSink) {
        self.wrapped = wrapped
        self.sink = sink
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await wrapped.get(url, headers: headers)
        // Errors are captured too: a 4xx body is often *more* informative about an unfamiliar
        // account shape than a healthy one. A throwing call captures nothing — there is no body.
        sink.capture(tool: .claude,
                     endpoint: DiagnosticsEndpoint.claudeEndpoint(for: url),
                     body: data,
                     httpStatus: response.statusCode)
        return (data, response)
    }
}
