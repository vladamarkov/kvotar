import Foundation
import KvotarCore

/// Pure, side-effect-free parser for Claude Code JSONL session logs (Baseline §7.2).
///
/// Kept separate from the file watcher so parsing, token-path extraction, subagent bucketing,
/// and deduplication are unit-testable from static fixtures (PATTERNS.md §Testing — fixture-driven).
/// Only metadata is read; prompt/code content fields are never decoded (§7.2 ignore list).
struct ClaudeJSONLParser {

    static let surfaceMainAgent = SurfaceWorkSplit.claudeMainAgent
    static let surfaceSubagentUnknown = "Subagent · Unknown"

    /// Reports a line that could not be **decoded** (§17.1 `parse_anomalies`, STEP_72). Nil unless
    /// diagnostics are wired, so every existing test constructs the parser exactly as before.
    var onAnomaly: ((ParseAnomaly) -> Void)?

    init(onAnomaly: ((ParseAnomaly) -> Void)? = nil) {
        self.onAnomaly = onAnomaly
    }

    /// Parses a full JSONL blob (one JSON object per line). Blank lines and non-`assistant`
    /// events are skipped; malformed lines are ignored rather than throwing.
    ///
    /// `sourceFile` is carried only so an undecodable line can be reported with its origin; it does
    /// not affect parsing. **Line numbers are deliberately not reported**: this blob is an appended
    /// chunk, not the whole file, so any index here would be chunk-relative — a number that looks
    /// absolute and is not is worse in a bundle than an honest NULL.
    func parse(_ data: Data, recordedAt: Date = Date(), sourceFile: String? = nil) -> [TokenEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var events: [TokenEvent] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            if let event = parseLine(lineData, recordedAt: recordedAt, sourceFile: sourceFile) {
                events.append(event)
            }
        }
        return events
    }

    /// Parses a single JSONL line into a `TokenEvent`, or `nil` when the event is not an
    /// `assistant` event, is malformed, or lacks the identifiers needed to key it.
    func parseLine(_ data: Data, recordedAt: Date = Date(),
                   sourceFile: String? = nil) -> TokenEvent? {
        // Only a **decode failure** is an anomaly. The `type != "assistant"` return below is
        // ordinary filtering — it fires on every user message, tool result and summary line in the
        // transcript, so reporting it would write millions of rows and drown the real signal.
        guard let raw = try? JSONDecoder().decode(RawEvent.self, from: data) else {
            if let onAnomaly, let sourceFile {
                onAnomaly(ParseAnomaly(
                    tool: .claude, sourceFile: sourceFile, lineNumber: nil,
                    error: "RawEvent decode failed",
                    fieldNames: ParseAnomaly.fieldNames(of: data)))
            }
            return nil
        }
        guard raw.type == "assistant" else { return nil }
        guard let sessionId = raw.sessionId else { return nil }

        // Deduplication key: (message.id, requestId) — the identity of one billed message,
        // with the session id deliberately left out (STEP_94, REV-62 §4.1 (c)): resuming or
        // forking a session rewrites the copied lines under the *new* session id, so a
        // session-scoped key stored every copied message again (67 corpus pairs, +7.2M tokens).
        // `message.id` is present on every assistant line in the corpus (verified 2026-08-12,
        // 18,788/18,788); `requestId` is absent on a handful, hence the msg-only form. The bare
        // `requestId` is carried as `legacyDedupKey` so the store's guards also match rows
        // written under the pre-STEP_94 format (see `TokenEvent.legacyDedupKey`).
        let dedupKey: String
        var legacyDedupKey: String? = nil
        let messageId = raw.message?.id ?? ""
        let requestId = raw.requestId ?? ""
        if !messageId.isEmpty, !requestId.isEmpty {
            dedupKey = "\(messageId)_\(requestId)"
            legacyDedupKey = requestId
        } else if !messageId.isEmpty {
            dedupKey = "msg:\(messageId)"      // same form as before STEP_94 — no legacy twin
        } else if !requestId.isEmpty {
            dedupKey = requestId               // same form as before STEP_94 — no legacy twin
        } else {
            return nil
        }

        let usage = raw.message?.usage
        let surfaceBucket = Self.surfaceBucket(
            isSidechain: raw.isSidechain ?? false,
            attributionAgent: raw.attributionAgent
        )

        // Timestamp honesty (REV-20): stamp the line's own event time, not parse time — a
        // catch-up read of backlogged lines must land at its true instants, or the burst
        // registers as a fake "now" spike in every 2-min rate window. Fallback: parse time.
        let eventAt = raw.timestamp.flatMap(Self.parseISOTimestamp) ?? recordedAt

        return TokenEvent(
            tool: .claude,
            sessionId: sessionId,
            project: raw.cwd,
            model: raw.message?.model,
            surfaceBucket: surfaceBucket,
            slug: raw.slug,
            startedAt: eventAt,
            inputTokens: usage?.inputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0,
            cacheCreationTokens: usage?.resolvedCacheCreation ?? 0,
            cacheCreation1hTokens: usage?.resolvedCacheCreation1h,
            cacheReadTokens: usage?.cacheReadInputTokens ?? 0,
            recordedAt: eventAt,
            dedupKey: dedupKey,
            legacyDedupKey: legacyDedupKey
        )
    }

    /// Quota-429 detector (Baseline §9.4, STEP_26). WORKING ASSUMPTION — Claude Code JSONL
    /// 429/529 error-line shapes are not captured by any spike (D1-adjacent caveat): the assumed
    /// shape is a line flagged `isApiErrorMessage: true` whose raw text mentions a usage/rate
    /// limit or a 429/529 status. The marker scan runs on the raw line so message content is
    /// never decoded (§7.2 ignore list / §10.6 privacy boundary). Isolated here so the shape can
    /// be corrected in one place once a real capture lands.
    func detectQuota429(_ data: Data, sourceFile: String,
                        recordedAt: Date = Date()) -> [Quota429Observation] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var observations: [Quota429Observation] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            guard let probe = try? JSONDecoder().decode(RawErrorProbe.self, from: lineData),
                  probe.isApiErrorMessage == true,
                  Quota429Observation.lineContainsQuotaLimitMarker(trimmed) else { continue }
            let observedAt = probe.timestamp.flatMap(Self.parseISOTimestamp) ?? recordedAt
            observations.append(Quota429Observation(sourceFile: sourceFile, observedAt: observedAt))
        }
        return observations
    }

    /// Claude JSONL timestamps are ISO8601 with fractional seconds; plain ISO8601 accepted too.
    private static func parseISOTimestamp(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    /// Surface bucket rule (Baseline §7.2, PATTERNS.md §Naming): main agent, named subagent,
    /// or unnamed subagent.
    static func surfaceBucket(isSidechain: Bool, attributionAgent: String?) -> String {
        guard isSidechain else { return surfaceMainAgent }
        if let agent = attributionAgent, !agent.isEmpty {
            return "Subagent · \(agent)"
        }
        return surfaceSubagentUnknown
    }
}

// MARK: - Raw JSONL shapes (metadata only — §7.2 ignore list omits content/diagnostics/etc.)

private struct RawEvent: Decodable {
    let type: String?
    let sessionId: String?
    let cwd: String?
    let slug: String?
    let requestId: String?
    let isSidechain: Bool?
    let attributionAgent: String?
    /// Per-line event time (ISO8601, fractional seconds) — the honest `recordedAt` (REV-20).
    let timestamp: String?
    let message: RawMessage?
}

/// Minimal decode for the quota-429 detector — error flag + event time only (see
/// `detectQuota429`; the marker test runs on the raw line, never on decoded content).
private struct RawErrorProbe: Decodable {
    let isApiErrorMessage: Bool?
    let timestamp: String?
}

private struct RawMessage: Decodable {
    let id: String?
    let model: String?
    let usage: RawUsage?
}

private struct RawUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreation: RawCacheCreation?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreation = "cache_creation"
    }

    /// Cache creation total: flat field when present, else sum of the two tiers, else 0 (§7.2).
    var resolvedCacheCreation: Int {
        if let flat = cacheCreationInputTokens { return flat }
        if let tiers = cacheCreation {
            return (tiers.ephemeral1hInputTokens ?? 0) + (tiers.ephemeral5mInputTokens ?? 0)
        }
        return 0
    }

    /// The **1-hour slice** of the cache write, or `nil` when the line does not break the write
    /// down by tier (STEP_96, §7.2). Anthropic charges 1.25x input for a 5-minute cache write
    /// and 2x for a 1-hour one, and 84.3% of this corpus's writes are 1-hour — so summing the
    /// tiers away, as `resolvedCacheCreation` alone did, discarded the larger of the two prices
    /// before it could reach storage (REV-62 §4.4).
    ///
    /// A subset of `resolvedCacheCreation`, which is unchanged and still the total. Three cases:
    /// no `cache_creation` object → `nil` (split unknown ⇒ priced at 5-minute, today's
    /// behaviour); object present without the 1-hour field → an explicit `0` (none of it was
    /// 1-hour); object present with it → the value, clamped to the total.
    ///
    /// The clamp mirrors STEP_91's clamp on the Codex uncached remainder. The flat field equalled
    /// the tier sum on all 20,481 corpus lines, but a future payload is not bound by that, and a
    /// 1-hour value above the total would make the 5-minute remainder negative — silently
    /// crediting the user instead of charging them.
    var resolvedCacheCreation1h: Int? {
        guard let tiers = cacheCreation else { return nil }
        return min(tiers.ephemeral1hInputTokens ?? 0, resolvedCacheCreation)
    }
}

private struct RawCacheCreation: Decodable {
    let ephemeral1hInputTokens: Int?
    let ephemeral5mInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
        case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
    }
}
