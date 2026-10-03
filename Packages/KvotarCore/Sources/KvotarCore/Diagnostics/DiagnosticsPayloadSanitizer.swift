import Foundation

/// Safety boundary applied before any extended provider response reaches persistent storage.
/// Unknown endpoints and non-JSON bodies are rejected; forbidden content-bearing fields are kept
/// only as names with a redaction marker so shape diagnosis remains possible without the content.
public enum DiagnosticsPayloadSanitizer {
    private static let allowedEndpoints: Set<String> = [
        DiagnosticsEndpoint.claudeUsage,
        DiagnosticsEndpoint.claudeProfile,
        DiagnosticsEndpoint.claudePrepaid,
        DiagnosticsEndpoint.codexWhamUsage,
        "account/read",
        "account/rateLimits/read",
    ]

    /// Public since STEP_133 so a file that does **not** cross this boundary can still check its
    /// own key names against it (`ExplanationSnapshot`). A hand-copied list in a test drifts from
    /// the one that does the redacting; this cannot.
    ///
    /// Identity fields too (2026-08-31): the log redacts the account email, but the captured
    /// bodies kept `email`, `full_name` and `display_name` verbatim — a tester's bundle carried two
    /// addresses hundreds of times. Bare `name` stays allowed (`model_name`, plan names).
    ///
    /// And `uuid` (STEP_171, 2026-09-08): that same amendment left the Claude profile's
    /// `account.uuid`, `organization.uuid` and `application.uuid` in the clear, and a bundle is
    /// mailed by a tester — an organisation UUID is an identifier, not a shape. All three are
    /// scalar strings, so redacting them leaves the `PayloadShape` fingerprint untouched and the
    /// provider-drift tripwire intact. **Do not reach for `organization` or `application`
    /// instead:** those name object-valued keys, and a forbidden key's whole value is replaced
    /// before the walk recurses, so they would collapse the subtree to one scalar, change the
    /// shape hash, and destroy `organization.rate_limit_tier` / `organization_type` / `seat_tier`,
    /// which `ClaudeAccountAdapter` reads for plan and enterprise detection. Codex's identity keys
    /// are `user_id` and `account_id`; this fragment deliberately does not reach them.
    public static let forbiddenKeyFragments = [
        "access_token", "accesstoken", "refresh_token", "refreshtoken", "authorization",
        "bearer", "secret", "prompt", "transcript", "tool_output", "tooloutput", "code",
        "message_content", "content", "email", "full_name", "display_name", "uuid",
    ]

    public static func sanitize(endpoint: String, body: Data) -> Data? {
        guard allowedEndpoints.contains(endpoint),
              let object = try? JSONSerialization.jsonObject(with: body),
              JSONSerialization.isValidJSONObject(object) else { return nil }
        let sanitized = sanitizeValue(object, key: nil)
        return try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys])
    }

    private static func sanitizeValue(_ value: Any, key: String?) -> Any {
        if let key, isForbidden(key) { return "<redacted>" }
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (childKey, child) in dictionary {
                result[childKey] = sanitizeValue(child, key: childKey)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { sanitizeValue($0, key: key) }
        }
        if let string = value as? String,
           string.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("bearer ") {
            return "<redacted>"
        }
        return value
    }

    private static func isForbidden(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return forbiddenKeyFragments.contains { normalized.contains($0) }
    }
}
