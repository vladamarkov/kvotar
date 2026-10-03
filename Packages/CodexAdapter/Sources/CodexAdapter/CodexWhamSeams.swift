import Foundation
import KvotarCore

/// Direct `wham/usage` fallback surface consumed by `CodexAccountAdapter` when RPC fails or 429s
/// (Baseline §8.2, §8.3; ARCHITECTURE.md §Data source map). Injected as a protocol so the adapter
/// can be unit-tested with a scripted fake; `CodexWhamHTTPClient` is the live conformance (task
/// Step 10) — passive `~/.codex/auth.json` read, `ChatGPT-Account-Id` header, never-refresh.
///
/// Conformances signal auth failure by throwing `AccountAdapterError.reauthRequired` (401/403,
/// §8.2) so the adapter can map health without inspecting HTTP internals.
public protocol CodexWhamClient: Sendable {
    /// Performs one `wham/usage` fetch and returns the decoded response plus the rate-limit
    /// headers observed on that response (Baseline §9.2 — proactive-slowdown / poll-429 tracking).
    func fetchUsage() async throws -> CodexWhamResult
}

/// Rate-limit headers captured on a `wham/usage` response (Baseline §9.2). Field names mirror the
/// generic `X-RateLimit-*` / `Retry-After` convention used elsewhere in the app; the exact header
/// names on this endpoint are unconfirmed (never captured) — parsing is tolerant of absence.
public struct CodexRateLimitHeaders: Sendable, Equatable {
    public let limit: Int?
    public let remaining: Int?
    public let reset: Date?

    public init(limit: Int? = nil, remaining: Int? = nil, reset: Date? = nil) {
        self.limit = limit
        self.remaining = remaining
        self.reset = reset
    }

    public static let empty = CodexRateLimitHeaders()
}

/// One `wham/usage` fetch result: the decoded quota body plus the rate-limit headers observed on
/// the same response.
public struct CodexWhamResult: Sendable, Equatable {
    public let usage: CodexWhamUsage
    public let headers: CodexRateLimitHeaders

    public init(usage: CodexWhamUsage, headers: CodexRateLimitHeaders = .empty) {
        self.usage = usage
        self.headers = headers
    }
}
