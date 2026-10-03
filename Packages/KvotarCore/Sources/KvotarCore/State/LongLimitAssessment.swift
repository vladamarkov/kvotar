import Foundation

/// How a **long limit** — a secondary (weekly) window or a monthly pool — is doing against both
/// its ceiling and its calendar (Baseline §11.3 / §13, REV-96 §2.2 — STEP_194).
///
/// One assessment, three readers. `StateEngine` ranks it (5b Limit nearly spent, 10 Limit ahead
/// of pace), `DisplayFormatter` writes the strip, the row suffix and the hover card from it, and
/// `NotificationEngine` fires event 9 off it. The §19 discipline: state and display read one
/// derivation, never two that can drift.
///
/// **Why the long limits needed this at all.** Until now the only thing the app knew about a
/// weekly was `used ≥ 85 %` (rank 10 Weekly-elevated, a placeholder since v4.6), so 85 % with five
/// days left and 85 % with three hours left rendered identically — and a weekly at 100 % rendered
/// *amber*, with no notification, unless the provider happened to raise its block flag. The
/// tester's Codex weekly sat spent for three days under that rule.
public struct LongLimitAssessment: Sendable, Equatable {

    /// The four tiers (REV-96 §2.2). Ordered so a worse tier compares greater — the selection
    /// rule is "worst tier wins", and `Comparable` is what makes that one `max(by:)`.
    public enum Tier: Int, Sendable, Equatable, Comparable, CaseIterable {
        /// None of the below.
        case onPace = 0
        /// Past the floor **and** ahead of the calendar, outside the window's opening grace.
        /// Amber, display-only — it never notifies.
        case aheadOfPace = 1
        /// At or past the nearly-spent line, whatever the pace. Red; fires event 9 once per
        /// limit instance.
        case nearlySpent = 2
        /// At or past the ceiling, or the provider says so. Red; this is rank 2/3's block, and
        /// its banner is capped per `BlockEpisode`, not here.
        case spent = 3

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Which limit this describes. Reuses `BlockEpisode.Limit` deliberately — one vocabulary for
    /// "which limit" across the assessment, the block episode and both `settings` key families,
    /// so a stored key can never name a limit the assessment cannot.
    public let limit: BlockEpisode.Limit
    public let tier: Tier
    /// Utilization, raw and uncapped.
    public let usedPct: Double
    /// How much of the limit's *calendar* has gone — the §11.3 pace clock pointed at this limit.
    /// Unclamped, like `QuotaSnapshot.paceElapsedPct`; callers that display it clamp.
    public let elapsedPct: Double
    /// When the limit lets go. A limit with no reset yields no assessment at all, so this is
    /// never absent.
    public let resetsAt: Date
    /// The limit's period in seconds — the weekly's reported width (or the 7-day fallback), the
    /// monthly's own calendar cycle. Drives `day N of M` and the strip's `for N days`.
    public let periodSeconds: Int
    /// Monthly meters only: the native amounts and their unit, carried so the notification body
    /// can say `5.46 EUR of the 70.00 EUR limit left` without a second lookup. `nil` on a
    /// percentage window, which has no amounts.
    public let usedAmount: Double?
    public let limitAmount: Double?
    public let unit: QuotaUnit?

    public init(limit: BlockEpisode.Limit, tier: Tier, usedPct: Double, elapsedPct: Double,
                resetsAt: Date, periodSeconds: Int, usedAmount: Double? = nil,
                limitAmount: Double? = nil, unit: QuotaUnit? = nil) {
        self.limit = limit
        self.tier = tier
        self.usedPct = usedPct
        self.elapsedPct = elapsedPct
        self.resetsAt = resetsAt
        self.periodSeconds = periodSeconds
        self.usedAmount = usedAmount
        self.limitAmount = limitAmount
        self.unit = unit
    }

    /// `100 − used`, floored at 0 (REV-77 / D-97 — every displayed percent is what is left).
    public var remainingPct: Double { max(0, 100 - usedPct) }

    /// Whether this limit deserves a surface of its own: amber or worse.
    public var isElevated: Bool { tier >= .aheadOfPace }

    // MARK: Event 9's key (§3.5)

    /// The `settings` row event 9 dedupes on — one per limit **instance**, so a new week fires
    /// again and the same week never fires twice. The limit is in the key, so the value is the
    /// reset alone (unlike `BlockEpisode`, whose one row has to say which limit it is about).
    public static func nearlySpentSettingsKey(tool: Tool, limit: BlockEpisode.Limit) -> String {
        "nearly_spent.\(tool.rawValue).\(limit.rawValue)"
    }

    /// The stored value: the reset, as unix seconds.
    public var nearlySpentStoredValue: String { String(Int(resetsAt.timeIntervalSince1970)) }

    /// Whether a stored value describes **this** instance. Compared through the one Core reset
    /// tolerance, never as a string — the provider wobbles `resets_at` by a second between polls
    /// (the tester's weekly reported `06:55:26` and `06:55:27` inside one block), and on a string
    /// match that wobble reads as a new week and fires a second banner.
    public func matchesNearlySpent(storedValue: String?) -> Bool {
        guard let storedValue, let epoch = TimeInterval(storedValue) else { return false }
        return QuotaSnapshot.isSameResetInstant(epoch, resetsAt)
    }
}
