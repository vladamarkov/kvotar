import Foundation

/// One coloured share of a surface split (Codex Desktop / CLI / IDE extension).
public struct SurfaceShare: Sendable, Equatable {
    public let label: String
    public let fraction: Double   // 0...1 of window tokens
    /// Newest token event in this bucket within the window (STEP_192) — what
    /// `SurfaceWorkSplit.activeSurfaces` reads. `nil` (no event, or a caller that never
    /// measured one) is never active.
    public let lastEventAt: Date?
    public init(label: String, fraction: Double, lastEventAt: Date? = nil) {
        self.label = label
        self.fraction = fraction
        self.lastEventAt = lastEventAt
    }
}

/// Local-JSONL-derived data for one tool's popover Local-session section (UI Spec §2.5/§2.6).
/// Raw, formatting-free values — `DisplayFormatter` turns these into labelled rows/bars. Fields
/// are optional/empty when the underlying data isn't available — never fabricated.
public struct LocalAttribution: Sendable, Equatable {
    public let project: String?
    public let model: String?
    public let surfaceBucket: String?
    public let subagentCount: Int
    public let cacheHitRatio: Double?          // nil when no cached+input tokens this window
    public let estValue: EstimatedValueEngine.WindowValue
    public let surfaceShares: [SurfaceShare]   // window token split by surface bucket
    public let tokensPerMinute: Double?        // recent local token rate, nil when idle
    public let lastActivityAt: Date?           // most recent local JSONL event (§15.1 tie-break)
    // REV-44 §2.5a/§2.5b (Claude two-section local card). All three are scoped to the same
    // reset-anchored `windowStart` as `cacheHitRatio`/`surfaceShares` (not the rolling `estValue`):
    public let sessionCount: Int               // distinct local sessions active in the window
    public let modelTotals: [SQLiteStore.ModelTokenTotals]  // per-model token totals this window
    public let windowValue: Double             // reset-anchored this-window est. dollars (§2.5b)
    /// When this attribution was computed (STEP_177). `tokensPerMinute` is a 2-minute in-memory
    /// rate measured at this instant; a re-render minutes later must not present it as current.
    /// `nil` on fixtures that predate the stamp — read as "age unknown", never as fresh.
    public let computedAt: Date?

    public init(project: String?, model: String?, surfaceBucket: String?, subagentCount: Int,
                cacheHitRatio: Double?, estValue: EstimatedValueEngine.WindowValue,
                surfaceShares: [SurfaceShare], tokensPerMinute: Double?,
                lastActivityAt: Date? = nil, sessionCount: Int = 0,
                modelTotals: [SQLiteStore.ModelTokenTotals] = [], windowValue: Double = 0,
                computedAt: Date? = nil) {
        self.computedAt = computedAt
        self.project = project
        self.model = model
        self.surfaceBucket = surfaceBucket
        self.subagentCount = subagentCount
        self.cacheHitRatio = cacheHitRatio
        self.estValue = estValue
        self.surfaceShares = surfaceShares
        self.tokensPerMinute = tokensPerMinute
        self.lastActivityAt = lastActivityAt
        self.sessionCount = sessionCount
        self.modelTotals = modelTotals
        self.windowValue = windowValue
    }

    /// Idle gap for "is the local session alive?" (REV-23). Claude Code writes a JSONL usage line
    /// only when an assistant *turn completes*, so a long turn / build / thinking spell writes
    /// nothing for its duration. Liveness is therefore measured by the recency of the last event,
    /// not by a token rate over a short window — otherwise any turn longer than the window reads as
    /// "idle" mid-work. Tunable during dogfood.
    public static let idleGap: TimeInterval = 480   // 8 minutes

    /// True when local JSONL activity is recent enough to consider the session live (REV-23).
    /// A `nil` timestamp (no local event observed) reads as idle. `lastActivityAt` is set on *every*
    /// parsed event, including cache-only turns, so cache-heavy light-output work still counts.
    public static func isActive(lastActivityAt: Date?, now: Date) -> Bool {
        guard let lastActivityAt else { return false }
        return now.timeIntervalSince(lastActivityAt) < idleGap
    }

    /// Convenience for the UI: whether this attribution's session is live (REV-23).
    public func isActive(now: Date = Date()) -> Bool {
        Self.isActive(lastActivityAt: lastActivityAt, now: now)
    }

    /// True only when local idleness can be *confirmed* for off-machine attribution (REV-23):
    /// activity was observed this run (`lastActivityAt != nil`) and the most recent event is now
    /// older than `idleGap`. A `nil` timestamp is "cannot confirm" — never observed — and is
    /// deliberately NOT idle, so off-machine stays dormant until local activity has been seen at
    /// least once (preserves the pre-REV-23 nil-guard: `nil` local metric ⇒ don't fire off-machine).
    /// This is stricter than `!isActive`, which treats `nil` as idle.
    public static func isConfirmedIdle(lastActivityAt: Date?, now: Date) -> Bool {
        guard let lastActivityAt else { return false }
        return now.timeIntervalSince(lastActivityAt) >= idleGap
    }
}

/// Consumes the local JSONL `TokenEvent` streams, persists them, and derives the per-tool
/// `LocalAttribution` the popover renders (Step 22; the long-referenced "future AttributionEngine").
///
/// It owns the two `LocalAdapter`s and the `EstimatedValueEngine`. A consumer `Task` per adapter
/// drains `tokenEvents`, persisting each via `SQLiteStore.writeTokenEvents` (the store accumulates
/// across launches, so windowed est-value grows toward reality; dedup makes re-observation safe)
/// and updating in-memory rolling state (recent token rate, active subagent buckets) that isn't
/// reconstructable from the per-session store rows.
public actor AttributionEngine {

    private let store: SQLiteStore
    private let valueEngine: EstimatedValueEngine
    private let adapters: [Tool: any LocalAdapter]
    private var consumerTasks: [Task<Void, Never>] = []
    private var started = false

    /// Rolling `(observedAt, tokens)` per tool for the tok/min estimate; pruned to `rateWindow`.
    private var recentTokens: [Tool: [(at: Date, tokens: Int)]] = [:]
    /// Active subagent buckets → last-seen time, per tool; pruned to the 5-hour window.
    private var subagentSeen: [Tool: [String: Date]] = [:]
    /// Most recent local JSONL event per tool — the §15.1 default-tab tie-break input and the
    /// §3.3 null-window attribution fallback ("most recent JSONL activity timestamp").
    private var lastEventAt: [Tool: Date] = [:]
    /// Most recent local *write* per tool — a watched file gained completed lines, whether or not
    /// any of them carried token accounting (STEP_170). Evidence a surface is alive, never of an
    /// amount, so it feeds the liveness timestamp below and nothing else: no token row, no
    /// `recentTokens` sample, no burn tier, no `onActivity` notice. In-memory and since-launch —
    /// after a relaunch the watcher seeds offsets to EOF and the first append re-seeds this.
    private var lastWriteAt: [Tool: Date] = [:]
    /// Push notice that a flush landed, set by the owner (STEP_77). The poll driver needs to see
    /// *every* turn to place a turn-boundary alignment poll, and `LocalAdapter.deltaSignals` — its
    /// only other local input — deliberately yields nothing for an ordinary turn (§13.1: it
    /// carries meaningful deltas, and its "seen buckets" sets are cumulative). `tokenEvents` has a
    /// single consumer by construction, so the notice is a hook rather than a second stream.
    private var onActivity: (@Sendable (Tool, Date) -> Void)?

    /// Last-resort span when **no** window start could be supplied — null windows and cold start,
    /// where no width is known either. **Not a window length** (REV-60): it is a floor for an
    /// unknown window, so a future reader must not "fix" it into the defect that step removed.
    private static let fallbackWindowSeconds: TimeInterval = 18_000
    /// How long a subagent bucket stays counted as active after its last event. A genuinely
    /// rolling liveness horizon, unrelated to any quota window's width.
    private static let subagentActiveWindow: TimeInterval = 18_000
    public static let rateWindow: TimeInterval = 120   // tok/min sampled over the last 2 minutes

    public init(store: SQLiteStore, claude: any LocalAdapter, codex: any LocalAdapter,
                bundle: Bundle = .main) {
        self.store = store
        self.valueEngine = EstimatedValueEngine(store: store, bundle: bundle)
        self.adapters = [.claude: claude, .codex: codex]
    }

    /// Registers the STEP_77 activity notice. Called once by the composition root with the tool
    /// and the newest event timestamp in each flush; nothing in Core reads it.
    public func setActivityObserver(_ observer: @escaping @Sendable (Tool, Date) -> Void) {
        onActivity = observer
    }

    /// Loads pricing, starts both watchers, and begins draining their event streams. Idempotent.
    public func start() async {
        guard !started else { return }
        started = true
        await valueEngine.loadPricingTable()
        for (tool, adapter) in adapters {
            await adapter.startWatching()
            let stream = adapter.tokenEvents
            consumerTasks.append(Task { [weak self] in
                for await batch in stream {
                    await self?.ingest(batch, tool: tool)
                }
            })
            // STEP_170: liveness from file growth. Deliberately its own consumer rather than a
            // branch inside `ingest` — that path persists rows and fires the STEP_77 turn-boundary
            // hook, and a token-less append is neither a turn nor a token.
            let writes = adapter.localWrites
            consumerTasks.append(Task { [weak self] in
                for await at in writes {
                    await self?.noteLocalWrite(tool: tool, at: at)
                }
            })
        }
        Logger.info("Attribution engine started", component: .attributionEngine)
    }

    /// Cancels the consumer tasks and stops the watchers.
    public func stop() async {
        for task in consumerTasks { task.cancel() }
        consumerTasks.removeAll()
        for adapter in adapters.values { await adapter.stopWatching() }
        started = false
    }

    // MARK: - Liveness

    /// Records that a watched file for `tool` gained completed lines at `at` (STEP_170).
    ///
    /// Monotone: a rescan re-draining an already-seen file cannot walk the timestamp backwards.
    /// Nothing else is touched — the caller's whole contract is "a local surface is alive".
    private func noteLocalWrite(tool: Tool, at: Date) {
        if at > (lastWriteAt[tool] ?? .distantPast) { lastWriteAt[tool] = at }
    }

    // MARK: - Ingest

    /// Persists one adapter flush in a single transaction (`writeTokenEvents` takes the whole
    /// batch — STEP_26, one transaction per flush) and updates the in-memory rolling state.
    private func ingest(_ events: [TokenEvent], tool: Tool) async {
        guard !events.isEmpty else { return }
        do {
            try await store.writeTokenEvents(events)
        } catch {
            Logger.error("Attribution persist failed", component: .attributionEngine,
                         metadata: ["tool": tool.rawValue, "error": "\(error)",
                                    "events": "\(events.count)"])
        }

        var tokens = recentTokens[tool] ?? []
        for event in events {
            tokens.append((at: event.recordedAt, tokens: event.inputTokens + event.outputTokens))
            if event.surfaceBucket.hasPrefix("Subagent") {
                subagentSeen[tool, default: [:]][event.surfaceBucket] = event.recordedAt
            }
            if event.recordedAt > (lastEventAt[tool] ?? .distantPast) {
                lastEventAt[tool] = event.recordedAt
            }
        }
        let rateCutoff = Date().addingTimeInterval(-Self.rateWindow)
        tokens.removeAll { $0.at < rateCutoff }
        recentTokens[tool] = tokens
        // STEP_77: the newest event in *this* flush, not `lastEventAt[tool]` — a re-read of an
        // older file must not read as a fresh turn boundary.
        if let newest = events.map(\.recordedAt).max() { onActivity?(tool, newest) }
    }

    // MARK: - Query

    /// The current `LocalAttribution` for `tool`, or `nil` when there is no recent session and no
    /// stored token value at all (so the popover simply hides the Local-session section).
    ///
    /// `windowStart` is the real quota-window start (UI Spec §3.3: Claude `resets_at − 18000s`;
    /// Codex from RPC/wham reset fields) supplied by the poll side. When nil (null windows or no
    /// successful poll yet), fall back per §3.3 to the most recent session's start timestamp,
    /// else the sliding `now − 5h` as the last resort.
    public func attribution(for tool: Tool, windowStart: Date? = nil,
                            now: Date = Date()) async -> LocalAttribution? {
        var resolvedStart = windowStart
        if resolvedStart == nil {
            resolvedStart = (try? await store.mostRecentSessionStart(tool: tool)) ?? nil
        }
        let windowStart = resolvedStart ?? now.addingTimeInterval(-Self.fallbackWindowSeconds)
        let session = (try? await store.currentSession(tool: tool, since: windowStart)) ?? nil
        let estValue = (try? await valueEngine.estimatedValue(for: tool))
            ?? EstimatedValueEngine.WindowValue(weekly: 0, thirtyDay: 0)
        let shares = await surfaceShares(tool: tool, windowStart: windowStart)
        // REV-44 §2.5a/§2.5b: per-model token totals (also the cache-hit input, so fetched once) and
        // the reset-anchored this-window est-value — both scoped to the same `windowStart`.
        let modelTotals = (try? await store.tokenTotalsByModel(tool: tool, since: windowStart)) ?? []
        let windowValue = (try? await valueEngine.value(for: tool, from: windowStart, until: now)) ?? 0
        let sessionCount = (try? await store.sessionCount(tool: tool, since: windowStart)) ?? 0

        // Nothing local to show.
        if session == nil, estValue.thirtyDay == 0, shares.isEmpty { return nil }

        // Liveness gap survives a restart (REV-30): after launch `lastEventAt` is nil until the
        // first post-launch flush (offsets are seeded to EOF), so a restart mid-session would read
        // "Claude Code idle" until the first successful poll. Seed from the persisted most-recent
        // event so the very first render (launch restore) reflects real recent activity. The
        // in-memory `lastEventAt` — the since-launch detection / §15.1 tie-break signal exposed by
        // `lastActivityAt(for:)` — is deliberately left untouched; only the burn-card liveness
        // timestamp on `LocalAttribution` is seeded.
        // STEP_170 adds the third term: a watched file that gained completed lines is a live
        // surface even when none of them carried token accounting. Codex writes a turn's
        // `token_count` twenty to thirty minutes late, so without it a working machine reads idle.
        let storedLastEventAt = (try? await store.mostRecentEventAt(tool: tool)) ?? nil
        let liveness = [lastEventAt[tool], storedLastEventAt, lastWriteAt[tool]]
            .compactMap { $0 }.max()

        return LocalAttribution(
            project: session?.project,
            model: session?.model,
            surfaceBucket: session?.surfaceBucket,
            subagentCount: subagentCount(tool: tool, now: now),
            cacheHitRatio: CacheHit.ratio(tool: tool, totals: modelTotals),
            estValue: estValue,
            surfaceShares: shares,
            tokensPerMinute: tokensPerMinute(tool: tool, now: now),
            lastActivityAt: liveness,
            sessionCount: sessionCount,
            modelTotals: modelTotals,
            windowValue: windowValue,
            computedAt: now
        )
    }

    /// Most recent local JSONL event time for `tool` — the §15.1 default-tab middle tie-break
    /// input. `nil` when no local activity has been observed this run.
    public func lastActivityAt(for tool: Tool) -> Date? {
        lastEventAt[tool]
    }

    private func surfaceShares(tool: Tool, windowStart: Date) async -> [SurfaceShare] {
        guard let totals = try? await store.tokenTotalsBySurface(tool: tool, since: windowStart) else { return [] }
        let sum = totals.reduce(0) { $0 + $1.totalTokens }
        guard sum > 0 else { return [] }
        return totals
            .filter { $0.totalTokens > 0 }
            .sorted { $0.totalTokens > $1.totalTokens }
            .map { SurfaceShare(label: $0.surfaceBucket, fraction: Double($0.totalTokens) / Double(sum),
                                lastEventAt: $0.lastEventAt) }
    }

    private func subagentCount(tool: Tool, now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-Self.subagentActiveWindow)
        return (subagentSeen[tool] ?? [:]).values.filter { $0 >= cutoff }.count
    }

    /// Pricing-valued local burn ($/min) over exactly `[start, end)` — the off-machine
    /// estimator's span-aligned `L` input (REV-18). Pass-through to the owned
    /// `EstimatedValueEngine` so `PollCoordinator` keeps a single attribution dependency.
    /// `nil` on an empty span or a store read failure — the estimator reads nil as "local
    /// idle", so a (rare, local-SQLite) read failure can over-attribute one poll's burn to
    /// off-machine; accepted for an "est." row over plumbing an unknown-vs-idle distinction.
    public func localValuePerMin(for tool: Tool, from start: Date, until end: Date) async -> Double? {
        let minutes = end.timeIntervalSince(start) / 60
        guard minutes > 0 else { return nil }
        guard let value = try? await valueEngine.value(for: tool, from: start, until: end) else {
            return nil
        }
        return value / minutes
    }

    /// The loaded pricing table's `version` / `updated`, for the diagnostics bundle (STEP_91).
    /// Pass-through to the owned `EstimatedValueEngine` so callers keep a single attribution
    /// dependency, exactly as `localValuePerMin` does.
    /// The History window's payload (STEP_109), computed over this engine's own pricing engine so
    /// there is exactly one pricing path — a second `EstimatedValueEngine` could load a different
    /// table and let the window and the popover disagree about a dollar.
    public func historyReport(now: Date = Date()) async -> HistoryReport {
        await HistoryReportReader(store: store, valueEngine: valueEngine).report(now: now)
    }

    public func pricingTableStamp() async -> (version: String, updated: String)? {
        await valueEngine.tableStamp()
    }

    /// Today's local report for `tool` (STEP_177 — REV-92 / Baseline §15.2): the bounded
    /// `[startOfDay(now), now)` read, grouped project × per-event model, priced through this
    /// engine's own pricing engine — the same one-pricing-path argument as `historyReport`.
    /// **Throws** on a store failure so the caller can keep its last good report and say so,
    /// rather than rendering a failed read as "no local activity observed today".
    public func dailyReport(for tool: Tool, now: Date = Date(),
                            calendar: Calendar = .current) async throws -> DailyLocalReport {
        try await DailyLocalReportReader(store: store, valueEngine: valueEngine)
            .report(tool: tool, now: now, calendar: calendar)
    }

    /// Local tokens attributed on this machine over the last 2 minutes — the Off-machine idle-floor
    /// input (§13 rule 7). 0 when nothing local is happening (a confirmed-idle reading, not "unknown").
    public func localTokensLast2Min(for tool: Tool, now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Self.rateWindow)
        return (recentTokens[tool] ?? []).filter { $0.at >= cutoff }.reduce(0) { $0 + $1.tokens }
    }

    private func tokensPerMinute(tool: Tool, now: Date) -> Double? {
        let cutoff = now.addingTimeInterval(-Self.rateWindow)
        let recent = (recentTokens[tool] ?? []).filter { $0.at >= cutoff }
        guard !recent.isEmpty else { return nil }
        let total = recent.reduce(0) { $0 + $1.tokens }
        return Double(total) / (Self.rateWindow / 60)
    }
}
