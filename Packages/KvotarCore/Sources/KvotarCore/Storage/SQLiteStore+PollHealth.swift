import Foundation
import GRDB

/// Endpoint named in a `poll_health_events` row (§9.5 `poll_health_events.endpoint`).
/// Raw values are the exact column strings from the migration. `.rpc` is currently reserved:
/// a Codex RPC 429 falls through to wham inside `CodexAccountAdapter` (§9.3) and only a wham
/// 429 surfaces to the poll driver, so no `"rpc"` row can be written yet.
///
/// **Two vocabularies, mapped rather than merged** (STEP_75). This table has always named the
/// Claude quota endpoint `oauth_usage` and the Codex one `wham_usage`; the diagnostics seam that
/// feeds the standing-rejection detector speaks `DiagnosticsEndpoint`'s `claude_usage` /
/// `claude_profile` / `claude_prepaid` / `codex_wham_usage`. The historical raw values are
/// **deliberately left alone** — 46 rows in the field already carry `oauth_usage`, and renaming a
/// column value to tidy an enum would orphan them. The two new cases below therefore adopt the
/// diagnostics spelling while the old two keep theirs, and `init(diagnosticsEndpoint:)` is the
/// single crossing point. The inconsistency is recorded here on purpose rather than lived with
/// silently.
public enum PollHealthEndpoint: String, Sendable {
    case oauthUsage = "oauth_usage"
    case rpc
    case whamUsage = "wham_usage"
    case claudeProfile = "claude_profile"
    case claudePrepaid = "claude_prepaid"

    /// Translates a `DiagnosticsEndpoint` name into this table's vocabulary. Nil for a name with
    /// no health-table equivalent (`claude_other`, a raw JSON-RPC method) — the caller logs the
    /// condition regardless and simply writes no row, rather than inventing a column value for an
    /// endpoint the app never calls.
    public init?(diagnosticsEndpoint name: String) {
        switch name {
        case DiagnosticsEndpoint.claudeUsage: self = .oauthUsage
        case DiagnosticsEndpoint.claudeProfile: self = .claudeProfile
        case DiagnosticsEndpoint.claudePrepaid: self = .claudePrepaid
        case DiagnosticsEndpoint.codexWhamUsage: self = .whamUsage
        default: return nil
        }
    }
}

/// The two ends of a standing-rejection episode (§9.5 `category`, STEP_75). Sharing a prefix keeps
/// `category LIKE 'endpoint_rejected%'` finding the pair, while the distinct values mean a reader
/// never has to infer which row is which from the counts alone.
public enum EndpointRejectionPhase: String, Sendable {
    case opened = "endpoint_rejected"
    case cleared = "endpoint_rejected_cleared"
}

// Writer for `poll_health_events` — Kvotar-caused throttling only, never user quota 429s
// (§9.1: the two categories must not share storage). Called by the poll driver on every
// surfaced poll 429; read back only for debugging/dogfood (7-day retention, §17.2).
extension SQLiteStore {

    /// Appends one poll-429 event (§9.5 columns). Timestamps written as Int unix seconds
    /// (PATTERNS.md §SQLite rule). The forensic parameters (§9.5 — R31-4) are all optional and
    /// nullable at the column level; the last-good `*` context is copied here at write time (not
    /// joined) because `poll_snapshots` retains only 2h. Response headers and bodies are never
    /// persisted; only the derived category and normalized context cross this boundary.
    public func writePollHealthEvent(
        tool: Tool,
        endpoint: PollHealthEndpoint,
        retryAfterSeconds: Int,
        consecutiveCount: Int,
        baseIntervalAtTime: Int,
        details: RateLimit429Details? = nil,
        lastPrimaryUsedPct: Double? = nil,
        lastSecondaryUsedPct: Double? = nil,
        lastPrimaryResetsAt: Date? = nil,
        lastExtraUsageEnabled: Bool? = nil,
        nullWindowSource: NullWindowSource? = nil,
        at now: Date = Date()
    ) throws {
        do {
            try withPool { pool in
                try pool.write { db in
                    try db.execute(sql: """
                        INSERT INTO poll_health_events (
                            tool, endpoint, timestamp,
                            retry_after_seconds, consecutive_count, base_interval_at_time,
                            response_headers_json, response_body, category,
                            last_primary_used_pct, last_secondary_used_pct, last_primary_resets_at,
                            last_extra_usage_enabled, null_window_source
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            tool.rawValue,
                            endpoint.rawValue,
                            Int(now.timeIntervalSince1970),
                            retryAfterSeconds,
                            consecutiveCount,
                            baseIntervalAtTime,
                            nil,
                            nil,
                            details?.category,
                            lastPrimaryUsedPct,
                            lastSecondaryUsedPct,
                            lastPrimaryResetsAt.map { Int($0.timeIntervalSince1970) },
                            lastExtraUsageEnabled.map { $0 ? 1 : 0 },
                            nullWindowSource?.rawValue,
                        ])
                }
            }
        } catch {
            Logger.error("Poll health write failed", component: .sqliteStore,
                         metadata: ["tool": tool.rawValue, "error": "\(error)"])
            throw error
        }
    }

    /// Appends one **credential-expired** health row (§9.1/§9.5 — REV-41, STEP_48): category
    /// `credential_expired`, and `retry_after_seconds` **NULL** in both subcases. The pre-poll
    /// gate sends no request (`details == nil`) so headers/body are null too; a belt-and-braces
    /// reclassified 429 may carry transient details, but none of its headers/body are persisted.
    /// Recording its countdown in the rate-signal column would falsely read as a backoff
    /// instruction. This class never touches
    /// the 429 ladder, so `consecutiveCount`/`baseIntervalAtTime` are the current *unchanged*
    /// ladder state, recorded for forensics only. The last-good `*` context is copied here at
    /// write time (§9.5 — poll_snapshots retains only 2h). `retry_after_seconds` is nullable since
    /// migration v8.
    public func writeCredentialExpiredEvent(
        tool: Tool,
        endpoint: PollHealthEndpoint,
        consecutiveCount: Int,
        baseIntervalAtTime: Int,
        details: RateLimit429Details? = nil,
        lastPrimaryUsedPct: Double? = nil,
        lastSecondaryUsedPct: Double? = nil,
        lastPrimaryResetsAt: Date? = nil,
        lastExtraUsageEnabled: Bool? = nil,
        nullWindowSource: NullWindowSource? = nil,
        at now: Date = Date()
    ) throws {
        do {
            try withPool { pool in
                try pool.write { db in
                    try db.execute(sql: """
                        INSERT INTO poll_health_events (
                            tool, endpoint, timestamp,
                            retry_after_seconds, consecutive_count, base_interval_at_time,
                            response_headers_json, response_body, category,
                            last_primary_used_pct, last_secondary_used_pct, last_primary_resets_at,
                            last_extra_usage_enabled, null_window_source
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            tool.rawValue,
                            endpoint.rawValue,
                            Int(now.timeIntervalSince1970),
                            nil,                              // retry_after_seconds — NULL (§9.5, v8)
                            consecutiveCount,
                            baseIntervalAtTime,
                            nil,
                            nil,
                            "credential_expired",             // category (§9.5, REV-41)
                            lastPrimaryUsedPct,
                            lastSecondaryUsedPct,
                            lastPrimaryResetsAt.map { Int($0.timeIntervalSince1970) },
                            lastExtraUsageEnabled.map { $0 ? 1 : 0 },
                            nullWindowSource?.rawValue,
                        ])
                }
            }
        } catch {
            Logger.error("Credential-expired health write failed", component: .sqliteStore,
                         metadata: ["tool": tool.rawValue, "error": "\(error)"])
            throw error
        }
    }

    /// Appends one **standing endpoint rejection** health row (§9.5 — STEP_75): category
    /// `endpoint_rejected` when a secondary endpoint has refused three requests in a row, and
    /// `endpoint_rejected_cleared` when a 2xx ends the episode, so the pair carries a duration.
    /// **Two rows per episode, never one per occurrence** — the 2026-07-15 field episode was 57
    /// identical 403s over 25 hours, logged at INFO with nothing escalating anywhere, and a table
    /// whose value is "a non-trivial count is the finding" is destroyed by 57 identical rows.
    ///
    /// Column choices, all inside the existing schema (**no migration**): `retry_after_seconds` is
    /// NULL because the server issued no backoff instruction and recording one would read as an
    /// instruction we invented (nullable since v8); `base_interval_at_time` is 0 because this class
    /// never touches the §9.3 ladder — it is not a cadence signal. `responseBody` is retained as a
    /// source-compatibility parameter but is deliberately never stored. The
    /// rejecting HTTP status lives in the accompanying log line: this table has no column for it,
    /// and adding one is a migration this step deliberately does not make.
    public func writeEndpointRejectionEvent(
        tool: Tool,
        endpoint: PollHealthEndpoint,
        phase: EndpointRejectionPhase,
        consecutiveCount: Int,
        responseBody: String? = nil,
        at now: Date = Date()
    ) throws {
        do {
            try withPool { pool in
                try pool.write { db in
                    try db.execute(sql: """
                        INSERT INTO poll_health_events (
                            tool, endpoint, timestamp,
                            retry_after_seconds, consecutive_count, base_interval_at_time,
                            response_headers_json, response_body, category
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            tool.rawValue,
                            endpoint.rawValue,
                            Int(now.timeIntervalSince1970),
                            nil,                              // retry_after_seconds — NULL (§9.5, v8)
                            consecutiveCount,
                            0,                                // base_interval_at_time — no ladder
                            nil,                              // response_headers_json
                            nil,
                            phase.rawValue,                   // category (§9.5, STEP_75)
                        ])
                }
            }
        } catch {
            Logger.error("Endpoint-rejection health write failed", component: .sqliteStore,
                         metadata: ["tool": tool.rawValue, "endpoint": endpoint.rawValue,
                                    "error": "\(error)"])
            throw error
        }
    }
}
