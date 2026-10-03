import Foundation

/// Provides fallback quota ceilings when live account quota (OAuth / RPC / wham) is
/// unavailable (ARCHITECTURE.md §Data source map; Baseline §6, §9).
///
/// Load order (`loadOnLaunch`):
///  1. Remote CDN JSON — **stubbed for Pre-Alpha** (P1-2: GitHub raw later). Always nil.
///  2. Bundled `Resources/limits.json` seed — community-observed values.
///  3. Hardcoded conservative prior — last resort if the bundled seed is missing/corrupt.
///
/// Cache strategy: loaded once in memory; refresh happens on app launch only.
/// Boundary: this adapter serves fallback capacities only. It does not read `SQLiteStore`.
/// The self-learning personal ceiling (§9.4) is resolved by the pure `resolveCeiling`
/// helper below, which `ForecastEngine` feeds with `quota_limit_events` observations.
///
/// An actor because the cached seed is mutable state now shared across isolation domains —
/// `ForecastEngine` reads ceilings for the Inferred-runway tier while the app lifecycle
/// drives `loadOnLaunch` (PATTERNS.md §Actor usage).
public actor LimitsDatabaseAdapter {

    /// Source that produced the currently cached seed.
    public enum Source: String, Sendable {
        case remote
        case bundled
        case hardcodedPrior
    }

    private let remoteURL: URL?
    private let bundle: Bundle

    private var cachedSeed: LimitsSeed?
    private var cachedSource: Source?

    /// - Parameters:
    ///   - remoteURL: Optional remote limits DB URL. Present for structure only in Pre-Alpha;
    ///     the remote fetch is stubbed and never performed.
    ///   - bundle: Bundle to load the seed resource from. Defaults to the module bundle.
    ///     (`Bundle.module` cannot be a default argument value, so nil resolves to it here.)
    public init(remoteURL: URL? = nil, bundle: Bundle? = nil) {
        self.remoteURL = remoteURL
        self.bundle = bundle ?? .module
    }

    /// Loads and caches community limits. Idempotent: once a seed is cached, subsequent
    /// calls return immediately without re-loading (refresh on launch only).
    public func loadOnLaunch() async {
        guard cachedSeed == nil else { return }

        if let remote = await fetchRemote() {
            cache(remote, from: .remote)
            return
        }

        if let bundled = loadBundledSeed() {
            cache(bundled, from: .bundled)
            return
        }

        cache(Self.hardcodedPrior, from: .hardcodedPrior)
    }

    /// The source of the currently cached seed, or nil before `loadOnLaunch`.
    public var source: Source? { cachedSource }

    /// Fallback ceiling for a tool/plan/window. Returns a `.community` tier value when the
    /// cached seed contains it, otherwise the `.hardcodedPrior` tier. Callers must have
    /// invoked `loadOnLaunch` first; if not, the hardcoded prior is used.
    public func ceiling(tool: Tool, planType: String, window: WindowType) -> QuotaCeiling {
        // A value found in the cached seed carries the community tier only when the cache
        // came from the seed (remote/bundled). If the cache is the hardcoded prior, any hit
        // is still the hardcoded-prior tier.
        if let seed = cachedSeed,
           let planCeilings = seed.tools[tool.rawValue]?[planType] {
            let tier: ConfidenceTier = cachedSource == .hardcodedPrior ? .hardcodedPrior : .community
            return QuotaCeiling(utilizationPct: planCeilings.ceiling(for: window), tier: tier)
        }
        let prior = Self.hardcodedPrior.tools[tool.rawValue]?[planType]
            ?? Self.hardcodedWindowCeilings
        return QuotaCeiling(utilizationPct: prior.ceiling(for: window), tier: .hardcodedPrior)
    }

    /// Below this utilization%, a "quota limit" observation cannot be a window exhaustion and is
    /// **not recorded** as a ceiling observation (§9.4; REV-54 §6). The §9.4 detector is a working
    /// assumption — it marks any rate-limit-shaped error line, so a server-overload 429 or a
    /// non-quota limit is recorded as an exhaustion — and `resolveCeiling` takes the *minimum* of a
    /// **permanent** table, so without this floor one bad reading beats every good one forever.
    /// Live evidence: observations of `100, 100, 5, 7, 97, 97, 99, 100` learned a 5.0% ceiling.
    ///
    /// The value is bounded by observed data, not theory — bad readings clustered at 5/7%, real
    /// ones at 97–100%; 50 is the round number furthest from both clusters. A genuinely low plan
    /// ceiling would be discarded; the write path logs every discard so it stays recoverable.
    /// **Dogfood-tunable — P1-21.** (The `v11_quota_ceiling_floor` cleanup deliberately does *not*
    /// read this constant: see the migration comment.)
    public static let quotaCeilingObservationFloorPct: Double = 50.0

    /// Resolves the effective ceiling for a window per §9.4: prefer the user's personal
    /// observed ceiling once at least 3 observations exist, otherwise the community prior.
    ///
    /// Pure — no I/O. `personalObservations` are the utilization percentages recorded in
    /// `quota_limit_events` for the relevant tool/window/plan; the personal ceiling is the
    /// lowest utilization% at which a quota 429 was observed.
    ///
    /// **The min-rule is safe only because the write path applies
    /// `quotaCeilingObservationFloorPct`** (STEP_80) — taking the minimum of untrusted inputs is
    /// what let a single 5% reading pin this account's ceiling. Do not decouple the two: relaxing
    /// or removing the floor re-opens the defect here, not at the write site.
    public static func resolveCeiling(
        personalObservations: [Double],
        communityCeiling: Double
    ) -> Double {
        guard personalObservations.count >= 3, let lowest = personalObservations.min() else {
            return communityCeiling
        }
        return lowest
    }

    // MARK: - Loading internals

    /// Pre-Alpha remote fetch stub. Structure only; never performs a network request.
    private func fetchRemote() async -> LimitsSeed? {
        Logger.info("Remote limits fetch not configured; using bundled seed",
                    component: .limitsDatabaseAdapter,
                    metadata: ["remote": remoteURL?.absoluteString ?? "nil"])
        return nil
    }

    private func loadBundledSeed() -> LimitsSeed? {
        guard let url = bundle.url(forResource: "limits", withExtension: "json") else {
            Logger.warning("Bundled limits.json not found", component: .limitsDatabaseAdapter)
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(LimitsSeed.self, from: data)
        } catch {
            Logger.warning("Bundled limits.json decode failed",
                           component: .limitsDatabaseAdapter,
                           metadata: ["error": "\(error)"])
            return nil
        }
    }

    private func cache(_ seed: LimitsSeed, from source: Source) {
        cachedSeed = seed
        cachedSource = source
        Logger.info("Limits database loaded", component: .limitsDatabaseAdapter,
                    metadata: [
                        "source": source.rawValue,
                        "version": "\(seed.version)",
                        "tools": "\(seed.tools.count)",
                    ])
    }

    // MARK: - Hardcoded conservative prior

    /// Conservative per-window ceilings used when tool/plan is absent from the seed.
    static let hardcodedWindowCeilings = LimitsSeed.WindowCeilings(fiveHour: 100, weekly: 100)

    /// Last-resort seed used when the bundled resource is missing or corrupt.
    static let hardcodedPrior = LimitsSeed(
        version: 0,
        tools: [
            "claude": ["max": hardcodedWindowCeilings, "pro": hardcodedWindowCeilings],
            "codex": ["pro": hardcodedWindowCeilings, "plus": hardcodedWindowCeilings],
        ]
    )
}
