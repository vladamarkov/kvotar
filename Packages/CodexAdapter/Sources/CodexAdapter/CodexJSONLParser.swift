import Foundation
import KvotarCore

/// Pure, side-effect-free parser for Codex JSONL session logs (Baseline §8.4, task Step 11).
///
/// Split into two entry points because Codex carries origination only on line 1 of each file
/// (`session_meta`), not on every event, unlike Claude where every `assistant` line is
/// self-contained. The adapter reads line 1 once per file via `parseSessionMeta`, caches the
/// result, and passes it into `parseTokenEvents` for every subsequent batch from that file.
///
/// Only metadata is read; prompt/code content fields are never decoded (§8.4 confirmed field set).
struct CodexJSONLParser {

    static let surfaceUnknown = CodexSurface.unknownLabel

    /// Vocabulary is `ClaudeJSONLParser.surfaceBucket`'s, reused deliberately (REV-63 / UI Spec
    /// D-65) — the two tabs must read alike, so this is not a Codex-specific form. It cannot be
    /// shared by import: adapters depend on Core only (ARCHITECTURE.md), never on each other.
    static let surfaceSubagentUnknown = "Subagent · Unknown"

    /// A `token_count` event stamped within this many seconds of a fork-marked `session_meta`
    /// line is inherited history, not this thread's work (STEP_103). Codex Desktop's fork
    /// replays the parent's whole history into the fork's file within milliseconds of the
    /// `session_meta` line (observed spread: 3 ms), while the nearest genuine turn lands 10 s
    /// out — 2 s sits an order of magnitude from both edges.
    static let forkedHistoryWindow: TimeInterval = 2

    /// Reports a line that could not be **decoded** (§17.1 `parse_anomalies`, STEP_72). Nil unless
    /// diagnostics are wired, so every existing test constructs the parser exactly as before.
    var onAnomaly: ((ParseAnomaly) -> Void)?

    init(onAnomaly: ((ParseAnomaly) -> Void)? = nil) {
        self.onAnomaly = onAnomaly
    }

    /// Parses the first line of a Codex JSONL file. Returns `nil` when the line isn't a
    /// `session_meta` event or lacks `payload.originator` (malformed first line — adapter falls
    /// back to the `Unknown` bucket rather than throwing).
    ///
    /// `forkMarkerAt` is non-nil only when the line carries a fork marker — `forked_from_id` or
    /// `parent_thread_id` (STEP_103) — *and* its own timestamp parses; it anchors the
    /// `forkedHistoryWindow` drop rule in `parseTokenEvents`. A marker whose timestamp does not
    /// parse yields `nil` (no anchor ⇒ no drops), and neither field's shape can cost the file
    /// its originator: both decode leniently, like `source` (REV-63).
    func parseSessionMeta(_ data: Data)
        -> (originator: String, surfaceBucket: String, forkMarkerAt: Date?)? {
        guard let raw = try? JSONDecoder().decode(RawEvent.self, from: data),
              raw.type == "session_meta",
              let originator = raw.payload?.originator, !originator.isEmpty else { return nil }
        let bucket = Self.surfaceBucket(originator: originator, source: raw.payload?.source,
                                        threadSource: raw.payload?.threadSource,
                                        agentNickname: raw.payload?.agentNickname,
                                        parentThreadId: raw.payload?.parentThreadId)
        let hasForkMarker = raw.payload?.forkedFromId != nil || raw.payload?.parentThreadId != nil
        let forkMarkerAt = hasForkMarker
            ? raw.timestamp.flatMap(Self.parseISOTimestamp) : nil
        return (originator, bucket, forkMarkerAt)
    }

    /// One parsed blob: its token events plus the per-file carry values the adapter keeps
    /// across debounced flushes and backfill chunks (STEP_93 model, STEP_94 cumulative total).
    struct ParsedTokenBatch {
        let events: [TokenEvent]
        /// Model from the last `turn_context` line in this blob; `nil` when the blob had none.
        let lastTurnContextModel: String?
        /// Highest cumulative `total_token_usage.total_tokens` seen in this blob; `nil` when no
        /// event carried one (older file shapes). Feeds the next call's `carriedCumulativeTotal`.
        let lastCumulativeTotal: Int?
    }

    /// Parses a full JSONL blob (one JSON object per line) into `TokenEvent`s, using the
    /// `sessionId`/`surfaceBucket`/`originator` already resolved for the file this batch came
    /// from. Blank lines and irrelevant events are skipped; malformed lines and events with no
    /// usable token data are ignored rather than throwing.
    ///
    /// **The per-event model comes from `turn_context` lines** (STEP_93, REV-62 §4.3 — the old
    /// claim that the model is absent from Codex JSONL was wrong). A `turn_context` line is
    /// identified by its **top-level** `type == "turn_context"` — unlike `token_count`, which
    /// lives at `payload.type` — and carries `payload.model` (e.g. `"gpt-5.5"`). Each
    /// `token_count` event takes the most recent `turn_context` model above it: within this blob,
    /// else `carriedModel` (the adapter's cache from earlier reads of the same file), else
    /// `sessionModel` — the `state_5.sqlite` → `threads.model` value (§8.5), which remains the
    /// only source for files predating `turn_context` and is now the fallback, not the primary.
    /// The filter must decode, never substring-scan: chat lines *mention* "turn_context" in
    /// content (observed on real data).
    ///
    /// `sessionModel`/`project` come from `CodexSQLiteMetadataReader` (task Step 12, §8.5);
    /// `nil` when the SQLite lookup hasn't resolved them yet.
    ///
    /// **Re-emitted turns are dropped here** (STEP_94 (a), REV-62 §4.1): OpenAI writes the same
    /// turn into the log again with a different timestamp, which defeats the timestamp-bearing
    /// dedup key (0 of 192 corpus re-emissions collapsed; +4.4% input, +5.9% output). The
    /// identity that works is the provider's own accounting — any `token_count` event whose
    /// cumulative `total_token_usage.total_tokens` has not advanced past the previous event's is
    /// a re-record of work already counted, and is dropped with a `parse_anomalies` record so
    /// the rate stays visible rather than becoming invisible good news. `carriedCumulativeTotal`
    /// is the adapter's per-file carry from earlier reads of the same file; events with no
    /// cumulative field (older shapes) are exempt from the rule, never dropped by it.
    ///
    /// **A counter that goes backwards is a reset, not a re-emission** (STEP_167, REV-87 /
    /// D-111, 2026-09-07): Codex Desktop resumed a thread with its cumulative rebuilt at
    /// 19,776,834 against a carry of 26,977,258, and the rule above dropped all 15 of that
    /// morning's turns — the Codex tab read "All local surfaces idle · Elsewhere ≈6%" while every
    /// token was local. The discriminator is the event's own `last_token_usage.total_tokens`: a
    /// re-record can fall at most one turn below the carry; a rebuilt counter falls by many. So
    /// `previous − cumulative > lastTurn` **accepts** the event, rebases the carry on it, and
    /// records a `parse_anomalies` row with its own fixed text. Fails soft: a re-record of an
    /// *older* turn would be counted once more (the pre-STEP_94 behaviour), and the next genuine
    /// turn resumes normally above the rebased carry.
    ///
    /// **Inherited forked-thread history is dropped here too** (STEP_103): Codex Desktop's fork
    /// replays the parent thread's whole history into the fork's file — every `token_count`
    /// line rewritten under the fork's basename and timestamp, so the dedup key sees all-new
    /// identities and the parent's turns are counted twice (78 rows / ~6.71 M tokens on the
    /// dogfood corpus; 95% of the `Subagent · Fermat` surface figure was the parent's Desktop
    /// work). In a file whose `session_meta` carries a fork marker (`forkMarkerAt` non-nil), a
    /// `token_count` event stamped within `forkedHistoryWindow` of that line is inherited
    /// history: dropped before it can advance the cumulative carry, one `parse_anomalies`
    /// record each. Both marker *and* window are load-bearing — the marker holds the blast
    /// radius to fork-marked files, and the window spares a genuine subagent thread that
    /// carries `parent_thread_id` but inherits nothing (its first turn lands 16 s out). An
    /// event with no parseable timestamp is exempt, never dropped. **Accepted gap (user ruling
    /// 2026-08-13):** a fork whose parent was never ingested loses those turns — inherited
    /// history is another thread's work, and this app records a turn once, in the thread that
    /// ran it; a parent-lineage lookup at ingest would buy a case never observed at the price
    /// of a stateful parser.
    func parseTokenEvents(
        _ data: Data,
        sessionId: String,
        surfaceBucket: String,
        originator: String?,
        sessionModel: String? = nil,
        carriedModel: String? = nil,
        carriedCumulativeTotal: Int? = nil,
        forkMarkerAt: Date? = nil,
        project: String? = nil,
        recordedAt: Date = Date(),
        sourceFile: String? = nil
    ) -> ParsedTokenBatch {
        guard let text = String(data: data, encoding: .utf8) else {
            return ParsedTokenBatch(events: [], lastTurnContextModel: nil,
                                    lastCumulativeTotal: nil)
        }
        var events: [TokenEvent] = []
        var turnContextModel: String? = nil
        var cumulativeTotal = carriedCumulativeTotal
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            guard let raw = decodeLine(lineData, sourceFile: sourceFile) else { continue }
            if raw.type == "turn_context" {
                if let model = raw.payload?.model, !model.isEmpty {
                    turnContextModel = model
                }
                continue
            }
            if raw.payload?.type == "token_count", let forkMarkerAt,
               let eventAt = raw.timestamp.flatMap(Self.parseISOTimestamp),
               eventAt.timeIntervalSince(forkMarkerAt) <= Self.forkedHistoryWindow {
                // Before the cumulative carry on purpose: the replayed block carries the
                // parent's cumulative ladder, and it must not become the baseline the first
                // genuine turn is judged against.
                if let onAnomaly, let sourceFile {
                    onAnomaly(ParseAnomaly(
                        tool: .codex, sourceFile: sourceFile, lineNumber: nil,
                        error: "inherited forked-thread history dropped: token_count within fork window of session_meta",
                        fieldNames: ParseAnomaly.fieldNames(of: lineData)))
                }
                continue
            }
            if raw.payload?.type == "token_count",
               let cumulative = raw.payload?.info?.totalTokenUsage?.totalTokens {
                if let previous = cumulativeTotal, cumulative <= previous {
                    // A re-record repeats the turn just counted, so it can sit at most one
                    // turn's worth below the carry (observed: exactly equal). A counter that
                    // fell further than this event's own turn was rebuilt by Codex (STEP_167 —
                    // a resumed Desktop thread restarted 7.2 M below its own high-water mark and
                    // every genuine turn for the morning was dropped as "already counted").
                    // That is a reset: accept the event and rebase the carry on it.
                    let lastTurn = raw.payload?.info?.lastTokenUsage?.totalTokens ?? 0
                    let isReset = previous - cumulative > lastTurn
                    if let onAnomaly, let sourceFile {
                        onAnomaly(ParseAnomaly(
                            tool: .codex, sourceFile: sourceFile, lineNumber: nil,
                            error: isReset
                                ? "cumulative counter reset: carry rebased"
                                : "re-emitted turn dropped: cumulative total_token_usage not advanced",
                            fieldNames: ParseAnomaly.fieldNames(of: lineData)))
                    }
                    if !isReset { continue }
                }
                cumulativeTotal = cumulative
            }
            if let event = tokenEvent(
                from: raw, sessionId: sessionId, surfaceBucket: surfaceBucket,
                originator: originator,
                model: turnContextModel ?? carriedModel ?? sessionModel,
                project: project, recordedAt: recordedAt
            ) {
                events.append(event)
            }
        }
        // `cumulativeTotal` starts from the carry and never regresses, so returning it
        // unconditionally lets the adapter assign it straight back to its per-file cache.
        return ParsedTokenBatch(events: events, lastTurnContextModel: turnContextModel,
                                lastCumulativeTotal: cumulativeTotal)
    }

    /// Decodes one JSONL line into the raw metadata shape. Only a **decode failure** is an
    /// anomaly — type filtering happens in the caller and fires on every other event in the
    /// rollout file, so reporting it would write millions of rows and drown the real signal.
    private func decodeLine(_ data: Data, sourceFile: String?) -> RawEvent? {
        guard let raw = try? JSONDecoder().decode(RawEvent.self, from: data) else {
            if let onAnomaly, let sourceFile {
                onAnomaly(ParseAnomaly(
                    tool: .codex, sourceFile: sourceFile, lineNumber: nil,
                    error: "RawEvent decode failed",
                    fieldNames: ParseAnomaly.fieldNames(of: data)))
            }
            return nil
        }
        return raw
    }

    /// Builds a `TokenEvent` from a decoded line, or `nil` when the event isn't
    /// `payload.type == "token_count"` (top-level `type` — `event_msg`/`response_item` — is not
    /// used for filtering, §8.4), or lacks the token/total-tokens data needed to key a dedup
    /// entry (the "null-info token event" case).
    private func tokenEvent(
        from raw: RawEvent,
        sessionId: String,
        surfaceBucket: String,
        originator: String?,
        model: String?,
        project: String?,
        recordedAt: Date
    ) -> TokenEvent? {
        guard raw.payload?.type == "token_count" else { return nil }
        guard let usage = raw.payload?.info?.lastTokenUsage,
              let totalTokens = usage.totalTokens else { return nil }

        // Dedup key: file basename + event timestamp + total tokens (task checklist literal
        // format). The exact JSON path for "timestamp" is unconfirmed by any spike — assumed to
        // be a top-level string alongside `type`/`payload`. Kept as an opaque string in the key
        // so the assumption can't crash parsing if the format differs; absence just widens the
        // dedup key rather than dropping the event.
        let dedupKey = "\(sessionId)_\(raw.timestamp ?? "")_\(totalTokens)"

        // Timestamp honesty (REV-20): stamp the line's own event time when it parses as ISO8601,
        // else fall back to parse time — a catch-up read of backlogged lines must not register
        // as a fake "now" spike in the 2-min rate windows. Lenient: the timestamp path is
        // spike-unconfirmed, so a differing format only means the fallback, never a lost event.
        let eventAt = raw.timestamp.flatMap(Self.parseISOTimestamp) ?? recordedAt

        return TokenEvent(
            tool: .codex,
            sessionId: sessionId,
            project: project,
            model: model,
            surfaceBucket: surfaceBucket,
            slug: nil,
            startedAt: eventAt,
            inputTokens: usage.inputTokens ?? 0,
            // `reasoning_output_tokens` is a **subset of** `output_tokens`, not a sibling of it —
            // measured `reasoning <= output` in 4,905/4,905 corpus events, `reasoning > output` in
            // zero (REV-62 §3.2, Baseline §8.4). Adding the two charged and displayed the same
            // tokens twice, and OpenAI bills reasoning as output exactly once. The decode of
            // `reasoningOutputTokens` stays — it is real data, it costs nothing, and its presence
            // here is the note to the next reader that leaving it out is deliberate (STEP_91).
            outputTokens: usage.outputTokens ?? 0,
            cacheCreationTokens: usage.cachedInputTokens ?? 0,
            cacheReadTokens: 0,
            recordedAt: eventAt,
            dedupKey: dedupKey,
            originator: originator
        )
    }

    /// Codex JSONL timestamps observed as ISO8601; fractional and plain forms both accepted.
    private static func parseISOTimestamp(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    /// Quota-429 detector (Baseline §9.4, STEP_26). WORKING ASSUMPTION — Codex blocked-state
    /// JSONL shapes are not captured (D1): the assumed shape is an error event
    /// (`payload.type == "error"`, or top-level `type == "error"`) whose raw text mentions a
    /// usage/rate limit or a 429/529 status. The marker scan runs on the raw line so message
    /// content is never decoded (§8.4 confirmed field set / §10.6 privacy boundary). Isolated
    /// here so the shape can be corrected in one place once a real capture lands.
    func detectQuota429(_ data: Data, sourceFile: String,
                        recordedAt: Date = Date()) -> [Quota429Observation] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var observations: [Quota429Observation] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            guard let raw = try? JSONDecoder().decode(RawEvent.self, from: lineData),
                  raw.payload?.type == "error" || raw.type == "error",
                  Quota429Observation.lineContainsQuotaLimitMarker(trimmed) else { continue }
            observations.append(Quota429Observation(sourceFile: sourceFile, observedAt: recordedAt))
        }
        return observations
    }

    /// Surface bucket rule (PATTERNS.md §Originator → surface bucket mapping, Baseline §8.4 as
    /// amended by REV-63). Any originator the table does not name falls through to `Unknown` —
    /// bucket and monitor, no special-casing.
    ///
    /// **`thread_source` is read first** (STEP_100, resolving P2-4). A subagent-spawned thread
    /// writes a nested object where `source` is normally a string, so the lenient `String?` decode
    /// yields `nil` and the pair `("Codex Desktop", nil)` used to miss every case and land on
    /// `Unknown`. `thread_source` answers that question directly, **without classifying the nested
    /// object at all**, so the lenient decode stays exactly as it was and keeps doing its own job
    /// (never losing a good `originator` to an unexpected `source` shape).
    ///
    /// **But the tag alone does not make a helper** (REV-76 / D-95, 2026-08-22). Codex writes
    /// `thread_source: "subagent"` on **top-level threads too**, and on the dogfood corpus those
    /// are the biggest spenders: `Subagent · Unknown` held 502.6M tokens against 785.7M for
    /// `Desktop`, every genuinely-nicknamed helper together 35.9M — and inside it sat the thread
    /// that is the literal `parent_thread_id` of six named helpers, bucketed as a sibling of its
    /// own children. A census of all 181 corpus files (40 subagent-tagged) splits with **zero
    /// overlap across two Codex versions**: 32 files carry neither parent id nor nickname, 8 carry
    /// both. **The discriminator is `parent_thread_id`, not the nickname** — a nickname never
    /// appears without a parent, a parent never without a nickname. So a `subagent` tag with no
    /// parent id falls through to the `(originator, source)` table, i.e. to its real surface.
    ///
    /// The nickname-less-but-parented row is **kept deliberately**: a future shape could spawn a
    /// helper without naming it, and `Subagent · Unknown` is the honest label there. What it stops
    /// being is where main threads go. **Fails soft** — a genuine helper emitted without a parent
    /// id lands in the main-thread share, which is the answer given today anyway; the rule can
    /// under-count helpers, never invent a phantom.
    static func surfaceBucket(originator: String, source: String?,
                              threadSource: String?, agentNickname: String?,
                              parentThreadId: String?) -> String {
        if threadSource == "subagent", let parent = parentThreadId, !parent.isEmpty {
            guard let nickname = agentNickname, !nickname.isEmpty else { return surfaceSubagentUnknown }
            return "Subagent · \(nickname)"
        }
        // The originator table itself lives in `KvotarCore.CodexSurface` since STEP_197 — the
        // daily local report resolves a helper session's stored originator at read time and
        // cannot import this package, and two copies of this table drift (STEP_192). The
        // helper rule above stays here: it reads thread fields Core never sees.
        return CodexSurface.bucket(originator: originator, source: source)
    }
}

// MARK: - Raw JSONL shapes (metadata only — §8.4 confirmed field set)

private struct RawEvent: Decodable {
    let type: String?
    /// Top-level event timestamp — path unconfirmed by any spike; see `parseTokenLine` note.
    let timestamp: String?
    let payload: RawPayload?
}

private struct RawPayload: Decodable {
    /// `"token_count"` on token events; absent on `session_meta` (its own line is identified by
    /// the top-level `type`, not a payload-level one).
    let type: String?
    /// `session_meta` only.
    let originator: String?
    /// `session_meta` only. Usually a plain string (`"vscode"`/`"desktop"`/`"cli"`), but confirmed
    /// on real data (2026-07-03) to sometimes be a nested object for subagent-generated
    /// `session_meta` lines (e.g. `{"subagent":{"other":"guardian"}}` — this was P2-4, resolved by
    /// `threadSource` below rather than by classifying this field). Decoded
    /// leniently in `init(from:)` below so an unexpected shape only drops `source`, not the whole
    /// event — a plain `String?` here would throw and silently lose a perfectly good `originator`.
    let source: String?
    /// `token_count` only.
    let info: RawInfo?
    /// `turn_context` only (top-level `type == "turn_context"`) — the per-turn model string,
    /// e.g. `"gpt-5.5"` (STEP_93, REV-62 §4.3). Decoded leniently: a non-string shape only
    /// drops the model, never the line.
    let model: String?
    /// `session_meta` only — `"user"` or `"subagent"` (REV-63, added by Codex after the
    /// 2026-07-03 observation above). This is what makes the nested `source` shape irrelevant to
    /// bucketing: it states the answer outright. Absent on files written before Codex added it,
    /// which is why absence falls through to the originator table rather than meaning `user`.
    let threadSource: String?
    /// `session_meta` only, and only on the nested `source` variant — the subagent's display name
    /// (`source.subagent.thread_spawn.agent_nickname`, e.g. `"Fermat"`). `nil` for a plain-string
    /// `source` and for the `{"subagent":{"other":…}}` variant, both of which carry no name.
    let agentNickname: String?
    /// `session_meta` only — the fork markers (STEP_103). `forked_from_id` marks an explicit
    /// fork; `parent_thread_id` is the marker's second form, present on subagent-spawned
    /// threads too (which is why the marker alone never triggers a drop — the
    /// `forkedHistoryWindow` does). Both decoded leniently: an unexpected shape must not cost
    /// the file its originator (REV-63's `source` lesson).
    ///
    /// `parent_thread_id` has a **second reader** since REV-76 / D-95: it is also the
    /// helper/top-level discriminator in `surfaceBucket`. The two uses do not interact — one
    /// decides whether a file's early events are inherited history, the other decides the file's
    /// label — and neither needed a new decode.
    let forkedFromId: String?
    let parentThreadId: String?

    private enum CodingKeys: String, CodingKey {
        case type, originator, source, info, model
        case threadSource = "thread_source"
        case forkedFromId = "forked_from_id"
        case parentThreadId = "parent_thread_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        originator = try container.decodeIfPresent(String.self, forKey: .originator)
        source = try? container.decodeIfPresent(String.self, forKey: .source)
        info = try container.decodeIfPresent(RawInfo.self, forKey: .info)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        threadSource = try? container.decodeIfPresent(String.self, forKey: .threadSource)
        forkedFromId = try? container.decodeIfPresent(String.self, forKey: .forkedFromId)
        parentThreadId = try? container.decodeIfPresent(String.self, forKey: .parentThreadId)
        // The **same** `source` key, read a second time as the nested shape. A plain-string
        // `source` simply fails this decode and leaves the nickname nil, which is correct —
        // `decode` rather than `decodeIfPresent` so an absent key is one optional, not two.
        agentNickname = (try? container.decode(RawSubagentSource.self, forKey: .source))?
            .subagent?.threadSpawn?.agentNickname
    }
}

/// The nested `source` variant a subagent-spawned `session_meta` writes, e.g.
/// `{"subagent":{"thread_spawn":{"parent_thread_id":…,"depth":1,"agent_nickname":"Fermat"}}}`.
/// Only the nickname is decoded — `parent_thread_id`, `depth` and `agent_role` are outside the
/// §8.4 confirmed field set and nothing reads them. The older `{"subagent":{"other":"guardian"}}`
/// variant (2026-07-03) has no `thread_spawn`, so it lands on `nil` without a special case.
private struct RawSubagentSource: Decodable {
    struct Subagent: Decodable {
        struct ThreadSpawn: Decodable {
            let agentNickname: String?

            enum CodingKeys: String, CodingKey {
                case agentNickname = "agent_nickname"
            }
        }
        let threadSpawn: ThreadSpawn?

        enum CodingKeys: String, CodingKey {
            case threadSpawn = "thread_spawn"
        }
    }
    let subagent: Subagent?
}

private struct RawInfo: Decodable {
    let lastTokenUsage: RawTokenUsage?
    /// Session-cumulative totals — the provider's own running account of the session. Only
    /// `total_tokens` is consumed (the STEP_94 re-emission identity); the per-turn numbers the
    /// app stores keep coming from `last_token_usage`.
    let totalTokenUsage: RawTokenUsage?

    enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
        case totalTokenUsage = "total_token_usage"
    }
}

private struct RawTokenUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedInputTokens: Int?
    let reasoningOutputTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}
