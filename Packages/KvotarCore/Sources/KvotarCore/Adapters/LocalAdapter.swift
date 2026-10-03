import Foundation

/// Local JSONL adapter contract (ARCHITECTURE.md §Adapter protocols).
///
/// A local adapter watches a tool's on-disk JSONL session logs and emits normalized
/// `TokenEvent`s as new token usage appears. Like `AccountAdapter`, it is a pure reporter:
/// it never owns persistence and never writes to `SQLiteStore` (PATTERNS.md §Actor usage).
/// `AttributionEngine` consumes `tokenEvents` and calls `SQLiteStore.writeTokenEvents(_:)`.
public protocol LocalAdapter: Sendable {
    /// Begins directory + per-file watching. Idempotent — a second call while watching is a no-op.
    func startWatching() async

    /// Cancels all watchers and pending debounce work.
    func stopWatching() async

    /// Stream of normalized token events — one batch per debounced flush (PATTERNS.md §JSONL
    /// watching), so the consumer can persist each flush in a single transaction (STEP_26).
    var tokenEvents: AsyncStream<[TokenEvent]> { get }

    /// Stream of "meaningful JSONL delta" signals — the StateEngine's Trigger 2 (Baseline §13.1).
    /// Emitted at most once per debounced flush, only when a tracked signal fired.
    var deltaSignals: AsyncStream<LocalDeltaSignal> { get }

    /// Flush times for watched files that gained completed lines — token-bearing or not (STEP_170).
    ///
    /// A growing rollout file is evidence that a local surface is **alive**, and nothing more.
    /// Codex writes a turn's `token_count` twenty to thirty minutes after the work starts, so the
    /// token stream alone reads a busy machine as idle: on 2026-09-03 the tester's editor-extension
    /// file was appended 35 times with `events=0` while their account climbed 3 % → 95 %, and the
    /// Elsewhere notification fired three times at a machine that was working the whole morning.
    ///
    /// It is **never** evidence of an amount. This carries no tokens, so it must not reach
    /// `ingest`, the burn tiers, the JSONL tripwire, or the STEP_77 turn-boundary hook — only the
    /// liveness timestamp the idle tests read.
    var localWrites: AsyncStream<Date> { get }
}

/// One normalized token-usage record parsed from a single JSONL event.
///
/// Maps onto the `local_sessions` + `local_usage_events` columns (§17.1). Session-scoped
/// metadata (`project`, `model`, `surfaceBucket`, `slug`, `startedAt`) is carried on every
/// event so the persistence layer can upsert the session row from any event in the batch.
public struct TokenEvent: Sendable, Equatable {
    public let tool: Tool
    public let sessionId: String

    // MARK: Session metadata (→ local_sessions)
    /// Project display source — Claude `cwd` (Baseline §7.2).
    public let project: String?
    /// Model string — Claude `message.model` (Baseline §7.2, §12.1).
    public let model: String?
    /// Surface bucket — `Claude Code` / `Subagent · <agent>` / `Subagent · Unknown` (§7.2).
    public let surfaceBucket: String
    /// Human-readable session name — Claude `slug` (Baseline §7.2).
    public let slug: String?
    /// Earliest observed event time for the session, if known.
    public let startedAt: Date?

    // MARK: Token deltas (→ local_usage_events)
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    /// The 1-hour slice of `cacheCreationTokens`, or `nil` when the source line does not break
    /// the cache write down by tier (STEP_96, Baseline §7.2/§12.1). Anthropic charges 1.25x
    /// input for a 5-minute cache write and 2x for a 1-hour one; the 5-minute amount is
    /// `cacheCreationTokens - cacheCreation1hTokens`.
    ///
    /// A **subset**, never a sibling: adding it to a displayed token count double-counts those
    /// tokens. Only the est-value math reads it. Codex leaves it `nil` — OpenAI publishes no
    /// cache-write charge at all, and that tool's `cacheCreationTokens` holds cached *input*
    /// under one of two storage conventions (§8.4), not a write.
    public let cacheCreation1hTokens: Int?
    public let cacheReadTokens: Int

    /// Time this event was recorded/observed.
    public let recordedAt: Date

    /// Deduplication key. Claude: `"<message.id>_<requestId>"`, falling back to `"msg:<id>"`
    /// when `requestId` is absent (Baseline §7.2, STEP_94 — the session id is deliberately no
    /// part of the identity: a resumed/forked session rewrites copied lines under a new session
    /// id, so the same billed message legitimately appears in two files). Codex:
    /// `"<file basename>_<timestamp>_<total_tokens>"` (§8.4). Still part of the
    /// `local_usage_events` composite primary key, but the store's duplicate guard checks it
    /// under **any** session id.
    public let dedupKey: String

    /// The key this event would have carried before STEP_94 changed the Claude format (the bare
    /// `requestId`), or `nil` when the two formats coincide. Rows written before the change keep
    /// their old keys forever — the corpus is permanent and the one-shot sweeps only reach files
    /// touched within their 90-day horizon — so every duplicate guard must match either form.
    /// Never stored; new inserts always store `dedupKey`.
    public let legacyDedupKey: String?

    /// Raw originator string — `local_sessions.originator` (§17.1). Claude has no equivalent
    /// concept and leaves this `nil`; Codex sets it from the JSONL `session_meta` first line
    /// (§8.4).
    public let originator: String?

    /// The model this event's tokens may be attributed to: `model`, unless the event carries no
    /// usage at all (all four token columns zero), in which case `nil` (STEP_93 task 3). Claude
    /// Code writes a zero-token placeholder line — model string `<synthetic>` — for a turn that
    /// died before reaching the API, and one such line landing last in a file renamed the whole
    /// session (REV-62 §4.3). A zero-usage event has nothing to price, so it asserts no model:
    /// not on the session row it upserts, not in its own `local_usage_events.model` column.
    public var attributableModel: String? {
        let usage = inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
        return usage > 0 ? model : nil
    }

    public init(
        tool: Tool,
        sessionId: String,
        project: String? = nil,
        model: String? = nil,
        surfaceBucket: String,
        slug: String? = nil,
        startedAt: Date? = nil,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheCreation1hTokens: Int? = nil,
        cacheReadTokens: Int,
        recordedAt: Date,
        dedupKey: String,
        legacyDedupKey: String? = nil,
        originator: String? = nil
    ) {
        self.tool = tool
        self.sessionId = sessionId
        self.project = project
        self.model = model
        self.surfaceBucket = surfaceBucket
        self.slug = slug
        self.startedAt = startedAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.cacheReadTokens = cacheReadTokens
        self.recordedAt = recordedAt
        self.dedupKey = dedupKey
        self.legacyDedupKey = legacyDedupKey
        self.originator = originator
    }
}

/// A "meaningful JSONL delta" signal for the StateEngine re-evaluation trigger (Baseline §13.1).
///
/// All four §13.1 signal kinds are computed as of STEP_26: subagent-count change, surface-bucket
/// change, burn-rate tier crossing (`BurnTierTracker`, provisional local thresholds), and
/// quota-429 observation (working-assumption JSONL shapes — see the parsers' detectors).
public struct LocalDeltaSignal: Sendable, Equatable {
    public let tool: Tool
    /// True when the set of active subagent buckets changed size since the previous flush.
    public let subagentCountChanged: Bool
    /// True when the set of surface buckets observed changed since the previous flush.
    public let surfaceBucketChanged: Bool
    /// True when the local token rate crossed a burn tier boundary since the previous flush
    /// (none→low, low→mid, mid→high, or reverse — Baseline §13.1).
    public let burnTierCrossed: Bool
    /// Quota 429/529 events observed in the flushed JSONL lines (user session hit its ceiling —
    /// never Kvotar's own poll 429s, Baseline §9.1). Feeds `quota_limit_events` (§9.4).
    public let quota429Observations: [Quota429Observation]

    public init(tool: Tool, subagentCountChanged: Bool, surfaceBucketChanged: Bool,
                burnTierCrossed: Bool = false, quota429Observations: [Quota429Observation] = []) {
        self.tool = tool
        self.subagentCountChanged = subagentCountChanged
        self.surfaceBucketChanged = surfaceBucketChanged
        self.burnTierCrossed = burnTierCrossed
        self.quota429Observations = quota429Observations
    }

    /// Whether any tracked signal fired — the debounced trigger condition.
    public var isMeaningful: Bool {
        subagentCountChanged || surfaceBucketChanged || burnTierCrossed
            || !quota429Observations.isEmpty
    }
}

/// One user-session quota 429/529 observed in JSONL (Baseline §9.4). Carried on
/// `LocalDeltaSignal`; the consumer joins it with poll-side context (utilization%, plan_type)
/// to write a `quota_limit_events` row — the adapter itself never touches the store.
public struct Quota429Observation: Sendable, Equatable {
    /// JSONL file basename the event was observed in (→ `quota_limit_events.source_file`).
    public let sourceFile: String
    /// When the event was observed (falls back to read time when the line carries no timestamp).
    public let observedAt: Date

    public init(sourceFile: String, observedAt: Date) {
        self.sourceFile = sourceFile
        self.observedAt = observedAt
    }

    /// Shared marker test for the parsers' quota-429 detectors (WORKING ASSUMPTION — no real
    /// 429/529 JSONL capture exists yet, D1-adjacent). Callers first gate on their tool's
    /// error-line shape; this only asks "does this error line look like a quota/rate limit?".
    /// Scans the raw line so message content is never decoded (§10.6 privacy boundary).
    public static func lineContainsQuotaLimitMarker(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.contains("usage limit") || lowered.contains("rate limit")
            || lowered.contains("limit reached") || lowered.contains("rate_limit")
            || lowered.contains("usage_limit") || lowered.contains("429")
            || lowered.contains("529")
    }
}

/// Local burn intensity tier (UI Spec §5 grammar: none/low/mid/high). Only tier *crossings*
/// are meaningful (§13.1) — the tier itself is not displayed from here.
public enum LocalBurnTier: Int, Sendable, Comparable {
    case none = 0, low, mid, high

    public static func < (lhs: LocalBurnTier, rhs: LocalBurnTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Rolling-window tracker that detects local burn-tier crossings for the §13.1 delta signal.
///
/// Thresholds are **provisional fixed tokens/min** — the UI Spec §5 tiers are plan-relative
/// %/min, but the adapter has no plan context and Anthropic exposes no window token budget to
/// convert against. Since the signal only triggers a state re-evaluation (never display),
/// fixed local boundaries are proportionate; tune during dogfooding (§5: "starting points
/// only"). Same provisional-threshold precedent as `OffMachineEstimator`.
public struct BurnTierTracker: Sendable {
    /// Tokens/min boundaries over the rolling window:
    /// none < 100 · low 100–1k · mid 1k–3k · high ≥ 3k. Mirrors the §5 %/min tier shape
    /// (low 0.1–1, mid 1–3, high >3) at a provisional ~1k tokens per 1% scale.
    static let lowFloorTokPerMin = 100.0
    static let midFloorTokPerMin = 1_000.0
    static let highFloorTokPerMin = 3_000.0
    /// Rolling window — matches the 2-min rate window used across the burn inputs.
    static let window: TimeInterval = 120

    private var samples: [(at: Date, tokens: Int)] = []
    private var lastTier: LocalBurnTier = .none

    public init() {}

    /// Records a flush's token total and reports whether the tier boundary was crossed
    /// (in either direction) relative to the previous flush.
    public mutating func record(tokens: Int, at now: Date = Date()) -> Bool {
        samples.append((at: now, tokens: tokens))
        let cutoff = now.addingTimeInterval(-Self.window)
        samples.removeAll { $0.at < cutoff }
        let total = samples.reduce(0) { $0 + $1.tokens }
        let perMin = Double(total) / (Self.window / 60)
        let tier: LocalBurnTier
        switch perMin {
        case ..<Self.lowFloorTokPerMin: tier = .none
        case ..<Self.midFloorTokPerMin: tier = .low
        case ..<Self.highFloorTokPerMin: tier = .mid
        default: tier = .high
        }
        defer { lastTier = tier }
        return tier != lastTier
    }
}
