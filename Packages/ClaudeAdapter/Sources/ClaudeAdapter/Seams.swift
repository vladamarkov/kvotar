import Foundation

/// The Claude OAuth credential read from the Keychain (Baseline §8.0.1). Carries the access
/// token plus the raw `subscriptionType` used as a secondary source for the account plan tier.
public struct ClaudeCredential: Sendable, Equatable {
    public let accessToken: String
    /// Raw `claudeAiOauth.subscriptionType` string, if present. Normalized to a limits-DB plan
    /// key (`"max"`/`"pro"`) by the adapter; used only when the profile endpoint is unavailable.
    public let subscriptionType: String?
    /// `claudeAiOauth.expiresAt` — the access token's expiry, **epoch milliseconds** (§8.0.1,
    /// REV-41). `nil` when absent/unparseable, in which case the STEP_48 expiry gate is a no-op
    /// (the adapter behaves exactly as before). Compared against `now` by `ClaudeAccountAdapter`'s
    /// pre-poll gate; the token has an observed ~8-hour lifetime and is refreshed only when Claude
    /// Code runs, so an idle-overnight Mac wakes with it expired.
    public let expiresAt: Double?

    public init(accessToken: String, subscriptionType: String? = nil, expiresAt: Double? = nil) {
        self.accessToken = accessToken
        self.subscriptionType = subscriptionType
        self.expiresAt = expiresAt
    }
}

/// Supplies the current Claude OAuth credential. Injected so tests can feed a fixed value
/// (or nil) without touching the Keychain (PATTERNS.md §Testing — inject mock conformances).
///
/// Read-only posture: an implementation must never write or refresh credentials (§5.1, §8.0.1).
public protocol ClaudeTokenProvider: Sendable {
    /// Returns the current credential, or `nil` when it is inaccessible (e.g. Keychain locked).
    /// Must fail silently — never present an auth dialog.
    func credential() throws -> ClaudeCredential?
}

/// Minimal HTTP GET seam over the two Claude OAuth endpoints. Injected so tests can return
/// fixture bodies with chosen status codes and headers, with no real network (no URLProtocol
/// swizzling — PATTERNS.md §Testing).
public protocol HTTPFetcher: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse)
}
