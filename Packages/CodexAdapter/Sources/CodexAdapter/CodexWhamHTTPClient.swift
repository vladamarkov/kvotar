import Foundation
import KvotarCore

/// Live `CodexWhamClient` conformance: direct `GET https://chatgpt.com/backend-api/wham/usage`
/// (Baseline §8.2, §5.2; task Step 10).
///
/// Auth is a passive read of `~/.codex/auth.json` via the injected `CodexTokenProvider` —
/// `tokens.access_token` as `Authorization: Bearer`, `tokens.account_id` as `ChatGPT-Account-Id`
/// when present. Never refreshes or writes `auth.json` (CLAUDE.md absolute rules).
///
/// `struct` — holds no mutable state between calls, matching `CodexRPCResponses`'s stateless
/// normalization style; state (health, identity caching) lives in `CodexAccountAdapter`.
public struct CodexWhamHTTPClient: CodexWhamClient {

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let fetcher: CodexHTTPFetcher
    private let tokenProvider: CodexTokenProvider

    public init(
        fetcher: CodexHTTPFetcher = CodexURLSessionFetcher(),
        tokenProvider: CodexTokenProvider = CodexAuthFileReader()
    ) {
        self.fetcher = fetcher
        self.tokenProvider = tokenProvider
    }

    public func fetchUsage() async throws -> CodexWhamResult {
        // `nil` means the file is genuinely absent → setup required. A read that could not be
        // attempted throws `credentialUnreadable` from the provider and propagates straight
        // through here, so it never reaches `DetectionStatus.classify` as "never set up"
        // (STEP_117 / REV-71 §3.2).
        guard let credential = try tokenProvider.credential() else {
            Logger.warning("Codex auth.json token unavailable — entering setup-required mode",
                           component: .codexAccountAdapter)
            throw AccountAdapterError.setupRequired
        }

        var headers = ["Authorization": "Bearer \(credential.accessToken)"]
        if let accountId = credential.accountId {
            headers["ChatGPT-Account-Id"] = accountId
        }

        let (data, response) = try await fetcher.get(Self.usageURL, headers: headers)
        try checkStatus(response, data: data, token: credential.accessToken)

        let usage: CodexWhamUsage
        do {
            usage = try CodexWhamUsage.decode(from: data)
        } catch {
            throw AccountAdapterError.decoding("\(error)")
        }

        return CodexWhamResult(usage: usage, headers: Self.parseRateLimitHeaders(response))
    }

    // MARK: - Status handling (Baseline §8.2, §9.3 — mirrors ClaudeAccountAdapter)

    private func checkStatus(_ response: HTTPURLResponse, data: Data, token: String) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401, 403:
            Logger.warning("Codex wham/usage rejected token",
                           component: .codexAccountAdapter,
                           metadata: ["status": "\(response.statusCode)"])
            throw AccountAdapterError.reauthRequired
        case 429:
            let rawRetryAfter = Self.retryAfterSeconds(response)
            let retryAfter = rawRetryAfter ?? 120
            Logger.warning("Codex wham/usage poll 429", component: .codexAccountAdapter,
                           metadata: ["retry_after": "\(retryAfter)s"])
            let details = RateLimit429Details(
                statusCode: 429,
                headers: Self.forensicHeaders(response),
                body: Self.redactedBody(data, token: token),
                category: Self.classify429(rawRetryAfter: rawRetryAfter))
            throw AccountAdapterError.rateLimited(retryAfter: retryAfter, details: details)
        default:
            Logger.warning("Codex wham/usage unexpected status",
                           component: .codexAccountAdapter,
                           metadata: ["status": "\(response.statusCode)"])
            throw AccountAdapterError.httpStatus(response.statusCode)
        }
    }

    // MARK: - Header parsing (Baseline §9.2) — header names unconfirmed on this endpoint; tolerant.

    private static func parseRateLimitHeaders(_ response: HTTPURLResponse) -> CodexRateLimitHeaders {
        let limit = intHeader(response, "X-RateLimit-Limit")
        let remaining = intHeader(response, "X-RateLimit-Remaining")
        let reset = intHeader(response, "X-RateLimit-Reset").map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        return CodexRateLimitHeaders(limit: limit, remaining: remaining, reset: reset)
    }

    private static func retryAfterSeconds(_ response: HTTPURLResponse) -> Int? {
        intHeader(response, "Retry-After")
    }

    private static func intHeader(_ response: HTTPURLResponse, _ name: String) -> Int? {
        guard let value = response.value(forHTTPHeaderField: name) else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - 429 forensic capture (§9.5 — R31-4; mirrors ClaudeAccountAdapter)

    private static let maxForensicBodyChars = 4096

    /// Response headers for the forensic row (§9.5), verbatim except any `Authorization` /
    /// `ChatGPT-Account-Id` credential keys (defensively dropped — §10.6).
    private static func forensicHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            let name = String(describing: key)
            if name.caseInsensitiveCompare("Authorization") == .orderedSame { continue }
            if name.caseInsensitiveCompare("ChatGPT-Account-Id") == .orderedSame { continue }
            out[name] = String(describing: value)
        }
        return out
    }

    /// Redacts the known bearer token and caps length before storage (§10.6). Never write the token.
    private static func redactedBody(_ data: Data, token: String) -> String? {
        guard !data.isEmpty, var body = String(data: data, encoding: .utf8) else { return nil }
        if !token.isEmpty { body = body.replacingOccurrences(of: token, with: "<redacted>") }
        if body.count > maxForensicBodyChars {
            body = String(body.prefix(maxForensicBodyChars)) + "…[truncated]"
        }
        return body
    }

    /// §9.5 `category`, analysis-only (nothing branches on it): absent → unknown; ≤ floor →
    /// transient; else → rate_pressure.
    private static func classify429(rawRetryAfter: Int?) -> String {
        guard let ra = rawRetryAfter else { return "unknown" }
        return TimeInterval(ra) <= PollBackoffPolicy.retryAfterFloor ? "transient" : "rate_pressure"
    }
}
