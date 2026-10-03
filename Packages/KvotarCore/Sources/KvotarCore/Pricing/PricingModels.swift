import Foundation

/// `Codable` root matching `Resources/pricing.json` (Baseline §12.1).
///
/// Unlike `limits.json`, this file is bundled into the **app target** (`Kvotar.app/Contents/
/// Resources/pricing.json`), not the `KvotarCore` package — see `EstimatedValueEngine`.
public struct PricingTable: Sendable, Codable, Equatable {
    /// Monotonic version, enables future remote-fetch conflict resolution.
    public let version: String
    public let updated: String
    /// Exact model string (Claude `message.model`; Codex `state_5.sqlite.threads.model`) → rates.
    public let models: [String: ModelPricing]
    /// Provider ("claude" | "codex") → rates, used when a model string is not in `models`.
    public let fallback: [String: ModelPricing]

    public init(version: String, updated: String, models: [String: ModelPricing], fallback: [String: ModelPricing]) {
        self.version = version
        self.updated = updated
        self.models = models
        self.fallback = fallback
    }

    /// Whole days since the table's `updated` stamp, or nil when the stamp does not parse as
    /// `yyyy-MM-dd`. Feeds the staleness assertion (REV-62 §5.3 mechanism 3 / STEP_92): neither
    /// provider publishes an effective date on its rate card, so a rate whose value silently
    /// changed is undetectable from its own source — the honest mitigation is to assert the
    /// table's own age and force a human re-check on a schedule. The Sonnet 5 rate sat five
    /// weeks stale with a 2× error on the card because nothing did this.
    public func ageInDays(asOf now: Date = Date()) -> Int? {
        var parser = DateComponents()
        let parts = updated.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        parser.year = parts[0]
        parser.month = parts[1]
        parser.day = parts[2]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let stamp = calendar.date(from: parser) else { return nil }
        // `Calendar.date(from:)` silently normalises overflowing components ("2026-13-40" becomes
        // a real date in February 2027), and a corrupt stamp must read as unparseable, never as
        // some other day's age — so require the round trip to reproduce the input exactly.
        let echo = calendar.dateComponents([.year, .month, .day], from: stamp)
        guard echo.year == parser.year, echo.month == parser.month, echo.day == parser.day else {
            return nil
        }
        return calendar.dateComponents([.day], from: stamp, to: now).day
    }

    /// The re-check schedule the suite enforces against the shipped file.
    public static let stalenessLimitDays = 90
}

/// Per-million-token rates for one model or provider fallback. Null fields are treated as
/// zero cost for that token type (Baseline §12.1).
///
/// **There is no `reasoning_per_mtok`** *(deleted STEP_91)*. It sat in every row and nothing ever
/// multiplied it: `EstimatedValueEngine.value` has four terms, not five. Both providers bill
/// reasoning as output tokens once — Codex's `reasoning_output_tokens` is a subset of
/// `output_tokens` (Baseline §8.4) — so wiring the field up would have double-charged reasoning at
/// exactly 2×. Its presence read as though reasoning were separately priced, which is the trap;
/// the field is removed rather than populated.
///
/// **Cache writes are tiered on Claude and absent on Codex** *(STEP_96)*. Anthropic charges
/// 1.25× input for a 5-minute cache write and 2× for a 1-hour one, so Claude rows carry
/// `cache_write_5m_per_mtok` / `cache_write_1h_per_mtok` and **no** `cache_creation_per_mtok` —
/// a single field at 1.25× under-charged 84.3% of this corpus's writes. Codex rows are the
/// mirror image: OpenAI publishes no cache-write charge at all, so they carry neither tier
/// field, and their `cache_creation_per_mtok` is not a write price — it is the one cached-input
/// rate, held in both cache fields because the app's storage has two conventions for that same
/// quantity (Baseline §8.4). `cache_creation_per_mtok` is still read on Claude as the 5-minute
/// rate when an older bundled table predates the tier split.
public struct ModelPricing: Sendable, Codable, Equatable {
    public let provider: String?
    public let inputPerMtok: Double?
    public let outputPerMtok: Double?
    public let cacheCreationPerMtok: Double?
    /// Claude 5-minute cache write, 1.25× input (STEP_96). Nil on Codex rows.
    public let cacheWrite5mPerMtok: Double?
    /// Claude 1-hour cache write, 2× input (STEP_96). Nil on Codex rows.
    public let cacheWrite1hPerMtok: Double?
    public let cacheReadPerMtok: Double?
    public let currency: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case inputPerMtok = "input_per_mtok"
        case outputPerMtok = "output_per_mtok"
        case cacheCreationPerMtok = "cache_creation_per_mtok"
        case cacheWrite5mPerMtok = "cache_write_5m_per_mtok"
        case cacheWrite1hPerMtok = "cache_write_1h_per_mtok"
        case cacheReadPerMtok = "cache_read_per_mtok"
        case currency
    }

    public init(
        provider: String? = nil,
        inputPerMtok: Double? = nil,
        outputPerMtok: Double? = nil,
        cacheCreationPerMtok: Double? = nil,
        cacheWrite5mPerMtok: Double? = nil,
        cacheWrite1hPerMtok: Double? = nil,
        cacheReadPerMtok: Double? = nil,
        currency: String? = nil
    ) {
        self.provider = provider
        self.inputPerMtok = inputPerMtok
        self.outputPerMtok = outputPerMtok
        self.cacheCreationPerMtok = cacheCreationPerMtok
        self.cacheWrite5mPerMtok = cacheWrite5mPerMtok
        self.cacheWrite1hPerMtok = cacheWrite1hPerMtok
        self.cacheReadPerMtok = cacheReadPerMtok
        self.currency = currency
    }
}
