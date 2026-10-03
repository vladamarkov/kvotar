import Foundation

/// Computes `Est. token value` — never `Cost` (PATTERNS.md §Naming conventions) — from stored
/// local token counts × the bundled pricing table (Baseline §12, §12.1).
///
/// Loading mirrors `LimitsDatabaseAdapter`: a cache-once loader driven by an explicit call,
/// not the initializer. Unlike `limits.json` (bundled inside the `KvotarCore` package),
/// `pricing.json` is bundled into the **app target** (ARCHITECTURE.md §Pricing table), so the
/// bundle to load from is injected and defaults to `.main`.
public actor EstimatedValueEngine {

    /// Est. token value for one tool across the display windows (task line 10; `today` added in
    /// STEP_27 for the Codex credits/spend card, UI Spec §2.4).
    ///
    /// **No `fiveHour` member** *(REV-60 — STEP_90)*. It held a rolling `now − 5h` figure and was
    /// read by nothing: §2.5b's `This window` row renders `LocalAttribution.windowValue`, which
    /// `AttributionEngine` computes over the real reset-anchored window span (REV-49/D-44 — the
    /// tokens ↔ dollars mirror REV-44 §7 requires). A rolling five-hour dollar figure sitting
    /// beside the window-anchored one is exactly the kind of trap REV-60 §5.2 argues against
    /// leaving behind for whoever wires it up next.
    public struct WindowValue: Sendable, Equatable {
        public let weekly: Double
        public let thirtyDay: Double
        /// Local-midnight → now (§2.4 "Est. token value · today"). Defaulted so pre-STEP_27
        /// constructions compile; only the Codex credits card reads it.
        public let today: Double

        public init(weekly: Double, thirtyDay: Double, today: Double = 0) {
            self.weekly = weekly
            self.thirtyDay = thirtyDay
            self.today = today
        }
    }

    /// Rolling horizons by design — unlike the window span, these are not anchored to a reset.
    private static let weeklySeconds: TimeInterval = 604_800
    private static let thirtyDaySeconds: TimeInterval = 2_592_000

    private let store: SQLiteStore
    private let bundle: Bundle
    private var cachedTable: PricingTable?

    public init(store: SQLiteStore, bundle: Bundle = .main) {
        self.store = store
        self.bundle = bundle
    }

    /// Loads and caches `pricing.json`. Idempotent — once cached, later calls are a no-op,
    /// matching `LimitsDatabaseAdapter.loadOnLaunch()`.
    public func loadPricingTable() async {
        guard cachedTable == nil else { return }
        guard let url = bundle.url(forResource: "pricing", withExtension: "json") else {
            Logger.warning("Bundled pricing.json not found", component: .estimatedValueEngine)
            return
        }
        do {
            let data = try Data(contentsOf: url)
            cachedTable = try JSONDecoder().decode(PricingTable.self, from: data)
        } catch {
            Logger.warning("Bundled pricing.json decode failed",
                           component: .estimatedValueEngine, metadata: ["error": "\(error)"])
        }
    }

    /// The loaded table's identity, for the diagnostics bundle's `environment.txt` (STEP_91).
    /// `nil` before `loadPricingTable()` or when the bundled file was missing/undecodable — the
    /// bundle prints "unavailable" rather than inventing a version.
    public func tableStamp() -> (version: String, updated: String)? {
        cachedTable.map { ($0.version, $0.updated) }
    }

    /// Est. token value for `tool`, aggregated across all models observed in each window.
    public func estimatedValue(for tool: Tool) async throws -> WindowValue {
        let now = Date()
        return WindowValue(
            weekly: try await value(for: tool, since: now.addingTimeInterval(-Self.weeklySeconds)),
            thirtyDay: try await value(for: tool, since: now.addingTimeInterval(-Self.thirtyDaySeconds)),
            today: try await value(for: tool, since: Calendar.current.startOfDay(for: now))
        )
    }

    /// Est. token value ($) for `tool` over exactly `[start, end)` — the off-machine estimator's
    /// pricing-weighted local burn numerator (REV-18). Same per-model valuation as the display
    /// windows, just bounded on both sides.
    public func value(for tool: Tool, from start: Date, until end: Date) async throws -> Double {
        try await value(for: tool, since: start, until: end)
    }

    /// Prices an already-fetched set of per-model totals with the loaded table (STEP_109) — the
    /// History window's per-session figure, where the totals come from a session-scoped query.
    /// Same per-model formula as every window figure; nothing new is priced here.
    public func value(for totals: [SQLiteStore.ModelTokenTotals], tool: Tool) -> Double {
        totals.reduce(0.0) { partial, totals in
            partial + Self.value(for: totals, provider: tool.rawValue, table: cachedTable)
        }
    }

    /// Whether `model` is priced at the provider fallback by the loaded table rather than by its
    /// own row — the History recap's `≈` (REV-104 §2.3, STEP_228). The same exact-match rule as
    /// `resolvePricing`, provider agreement included, without its logging or collection side
    /// effects. A `nil` model has no row and takes the fallback. No table prices nothing, so
    /// nothing is approximate: false.
    public func isPricedAtFallback(model: String?, tool: Tool) -> Bool {
        guard let table = cachedTable else { return false }
        guard let model, let row = table.models[model] else { return true }
        return row.provider.map { $0 != tool.rawValue } ?? false
    }

    private func value(for tool: Tool, since start: Date, until end: Date? = nil) async throws -> Double {
        let totals = try await store.tokenTotalsByModel(tool: tool, since: start, until: end)
        return totals.reduce(0.0) { partial, totals in
            partial + Self.value(for: totals, provider: tool.rawValue, table: cachedTable)
        }
    }

    /// Per-event formula, **forked by provider** (Baseline §12, STEP_91). Pure and `static` so it
    /// is directly unit-testable without a live `SQLiteStore`.
    ///
    /// **Claude** — the four columns are disjoint quantities, so each is priced at its own rate and
    /// summed: `input + output + cache_creation + cache_read`. **The cache-write term is tiered**
    /// (STEP_96): Anthropic charges 1.25× input for a 5-minute cache write and 2× for a 1-hour
    /// one, and 84.3% of this corpus's writes are 1-hour, so a single rate understated roughly
    /// $332 of lifetime value. `cacheCreation1hTokens` is a **subset** of `cacheCreationTokens`,
    /// so the 5-minute amount is the remainder — the total is never re-summed and no displayed
    /// count moves. Rows predating migration v17 carry no split, sum in as 0, and therefore price
    /// their whole write at the 5-minute rate exactly as before; those rows are deliberately not
    /// backfilled (user ruling 2026-08-12).
    ///
    /// **Codex** — `cached_input_tokens` is a **subset of** `input_tokens` (REV-62 §3.1), so the
    /// old shared formula charged the whole prompt at the uncached rate and then added $0 for the
    /// same tokens through a null cached rate. Input splits: the uncached remainder is priced at
    /// the input rate and the cached slice at the (much cheaper) cached rate. The cached slice is
    /// read from **both** cache columns (`codexCachedInputTokens`) because the corpus stores that
    /// one quantity under two conventions, and its rate is taken from either cache field for the
    /// same reason — §12.1 writes the same value into both, and an older file may have filled only
    /// one.
    ///
    /// The subtraction is **clamped at zero**: `cached <= input` held in 4,905/4,905 observed
    /// events, but a future provider payload is not bound by that, and a negative uncached count
    /// would silently credit the user.
    static func value(for totals: SQLiteStore.ModelTokenTotals, provider: String, table: PricingTable?) -> Double {
        let pricing = resolvePricing(model: totals.model, provider: provider, table: table)
        let outputCost = Double(totals.outputTokens) * (pricing?.outputPerMtok ?? 0)

        if provider == Tool.codex.rawValue {
            let cached = totals.codexCachedInputTokens
            let uncached = max(0, totals.inputTokens - cached)
            let cachedRate = pricing?.cacheCreationPerMtok ?? pricing?.cacheReadPerMtok ?? 0
            let inputCost = Double(uncached) * (pricing?.inputPerMtok ?? 0)
            let cachedCost = Double(cached) * cachedRate
            return (inputCost + cachedCost + outputCost) / 1_000_000
        }

        let inputCost = Double(totals.inputTokens) * (pricing?.inputPerMtok ?? 0)

        // Claude cache write, split by tier. The `??` chains are a compatibility net, not
        // decoration: a bundled table predating the tier split (the 1.0.2 copies under `dist/`
        // are real) carries only `cache_creation_per_mtok`, which *was* the 5-minute rate — with
        // no fallback every Claude cache write would silently price at $0. A table with a
        // 5-minute rate but no 1-hour one prices both tiers at 5-minute, which is the behaviour
        // this step replaced. Clamped for the same reason the parser clamps: a 1-hour slice above
        // the total would make the 5-minute remainder negative and credit the user.
        let oneHourTokens = min(totals.cacheCreation1hTokens, totals.cacheCreationTokens)
        let fiveMinuteTokens = totals.cacheCreationTokens - oneHourTokens
        let write5mRate = pricing?.cacheWrite5mPerMtok ?? pricing?.cacheCreationPerMtok ?? 0
        let write1hRate = pricing?.cacheWrite1hPerMtok ?? write5mRate
        let cacheCreationCost = Double(fiveMinuteTokens) * write5mRate
            + Double(oneHourTokens) * write1hRate

        let cacheReadCost = Double(totals.cacheReadTokens) * (pricing?.cacheReadPerMtok ?? 0)
        return (inputCost + outputCost + cacheCreationCost + cacheReadCost) / 1_000_000
    }

    /// Exact model-string match; else provider-level fallback (Baseline §12.1).
    ///
    /// **The match must agree on provider** (STEP_91). `pricing.json` carries a `provider` field on
    /// every model row and nothing read it, so a Claude model string arriving on a Codex session
    /// silently took Claude rates — an outcome no log line would have reported, because a match is
    /// not a miss. A row whose provider disagrees is treated as no match at all and falls through
    /// to the provider fallback. Fallback rows carry no `provider` and need no check: the table
    /// keys them by provider already.
    ///
    /// Logs a WARNING only when a known model string failed to match — a `nil` model (session not
    /// yet attributed) silently uses the fallback, since there is no string to have missed — and
    /// **at most once per `(provider, model)` per process** (REV-62 §4.7): the undeduplicated form
    /// fired on every call and consumed 33% of the log lines and 36% of the log bytes in one hour
    /// of runtime, which is how an earlier response to this same signal came to be *silencing* it
    /// (commit `8799fd7`). One line still says everything the flood said.
    static func resolvePricing(model: String?, provider: String, table: PricingTable?) -> ModelPricing? {
        guard let table else { return nil }
        if let model, let exact = table.models[model] {
            if let rowProvider = exact.provider, rowProvider != provider {
                if PricingWarningLog.shared.shouldWarn(provider: provider, model: model + " (provider mismatch)") {
                    Logger.warning("Pricing row provider does not match request; using provider fallback",
                                   component: .estimatedValueEngine,
                                   metadata: ["model": model, "provider": provider,
                                              "row_provider": rowProvider])
                }
            } else {
                return exact
            }
        }
        if let model {
            UnpricedModelCollector.shared.record(provider: provider, model: model)
        }
        guard let fallback = table.fallback[provider] else { return nil }
        if let model, PricingWarningLog.shared.shouldWarn(provider: provider, model: model) {
            Logger.warning("Model not found in pricing table; using provider fallback",
                           component: .estimatedValueEngine,
                           metadata: ["model": model, "provider": provider])
        }
        return fallback
    }
}

/// Per-`(provider, model)` WARNING deduplication for `EstimatedValueEngine` — the behaviour
/// `PATTERNS.md` has documented as this engine's since STEP_13 and which the code did not have
/// until STEP_91.
///
/// A lock rather than an actor, for the same reason `Logger` uses a serial queue and
/// `CodexRPCClient` uses an `NSLock` (PATTERNS.md §Actor usage): the callers are `static` pure
/// functions on a hot path and must not become `await` points just to record that they have
/// already complained once.
final class PricingWarningLog: @unchecked Sendable {
    static let shared = PricingWarningLog()

    private let lock = NSLock()
    private var seen: Set<String> = []

    /// True the first time this `(provider, model)` pair is seen in this process, false forever
    /// after. Deliberately unbounded: the key space is the set of model strings the user actually
    /// runs, which is a handful, and a cap would let the flood back in.
    func shouldWarn(provider: String, model: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.insert("\(provider)|\(model)").inserted
    }

    /// Test seam only — the singleton would otherwise leak state between cases in one process.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        seen.removeAll()
    }
}


/// Accumulates the `(provider, model)` pairs `resolvePricing` priced at the provider fallback,
/// for the durable `unpriced_models` table (§17.1 — REV-62 §5.3, STEP_92). The log line above
/// says it once per process; this is the record that survives the process.
///
/// Same construction as `PricingWarningLog`, for the same reason: the recording site is a
/// `static` pure function on a hot path and must not become an `await` point, so the collector
/// buffers under an `NSLock` and `PollCoordinator` drains it into `SQLiteStore` once per poll
/// cycle — one write per cycle, zero in the steady state where the drain comes back empty.
public final class UnpricedModelCollector: @unchecked Sendable {
    public static let shared = UnpricedModelCollector()

    /// Fallback "model" strings that are not models, observed but never recorded — without this
    /// the table's first row would tell its first reader to price something that does not exist
    /// (REV-62 §5.4). `<synthetic>` is Claude Code's zero-token placeholder for a turn that died
    /// before reaching the API; `codex-auto-review` is Codex's internal command-approval
    /// reviewer, not an API model. A `nil` model never reaches the collector — there is no
    /// string to record.
    static let knownNonModels: Set<String> = ["<synthetic>", "codex-auto-review"]

    private struct Key: Hashable {
        let provider: String
        let model: String
    }

    private struct Span {
        var firstSeen: Int
        var lastSeen: Int
        var count: Int
    }

    private let lock = NSLock()
    private var pending: [Key: Span] = [:]

    func record(provider: String, model: String, at now: Date = Date()) {
        guard !Self.knownNonModels.contains(model) else { return }
        let instant = Int(now.timeIntervalSince1970)
        lock.lock()
        defer { lock.unlock() }
        let key = Key(provider: provider, model: model)
        if var span = pending[key] {
            span.firstSeen = min(span.firstSeen, instant)
            span.lastSeen = max(span.lastSeen, instant)
            span.count += 1
            pending[key] = span
        } else {
            pending[key] = Span(firstSeen: instant, lastSeen: instant, count: 1)
        }
    }

    /// Returns everything recorded since the last drain and clears the buffer. On a failed
    /// upsert the caller may simply drop the batch — the next fallback re-records the pair,
    /// and the table's span/count are observations, not an audit.
    public func drain() -> [UnpricedModelObservation] {
        lock.lock()
        defer { lock.unlock() }
        let drained = pending.map { key, span in
            UnpricedModelObservation(
                provider: key.provider, model: key.model,
                firstSeenAt: span.firstSeen, lastSeenAt: span.lastSeen,
                observationCount: span.count)
        }
        pending.removeAll()
        return drained
    }

    /// Test seam only — the singleton would otherwise leak state between cases in one process.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
    }
}
