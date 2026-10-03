import Foundation

/// Quota window a ceiling applies to. Raw values match the `quota_limit_events.window_type`
/// column ("five_hour" | "weekly", §9.5) so the two representations never diverge.
public enum WindowType: String, Sendable, CaseIterable, Codable {
    case fiveHour = "five_hour"
    case weekly
}

/// Confidence tier of a resolved ceiling (ARCHITECTURE.md §Data source map).
/// `community` = observed value from the seed/remote limits DB.
/// `hardcodedPrior` = conservative Swift fallback when no seed value exists.
public enum ConfidenceTier: String, Sendable, Codable {
    case community
    case hardcodedPrior
}

/// A fallback quota ceiling for one tool/plan/window, expressed as a utilization percentage.
/// Used only when OAuth / RPC / wham live quota is unavailable (§6, §9).
public struct QuotaCeiling: Sendable, Equatable {
    /// Utilization percentage at which the window is considered exhausted (0–100).
    public let utilizationPct: Double
    public let tier: ConfidenceTier

    public init(utilizationPct: Double, tier: ConfidenceTier) {
        self.utilizationPct = utilizationPct
        self.tier = tier
    }
}

/// `Codable` root matching `Resources/limits.json`. The same shape is used for the
/// (Pre-Alpha stubbed) remote CDN file so both paths decode with identical code.
///
/// `plan_type` keys are raw `String`s, never a Swift enum (PATTERNS.md §Naming conventions).
public struct LimitsSeed: Sendable, Codable, Equatable {
    /// Monotonic version for future remote-vs-bundled diffing.
    public let version: Int
    /// tool ("claude" | "codex") → plan_type → window ceilings.
    public let tools: [String: [String: WindowCeilings]]

    public init(version: Int, tools: [String: [String: WindowCeilings]]) {
        self.version = version
        self.tools = tools
    }

    /// Per-plan window ceilings as raw utilization percentages.
    public struct WindowCeilings: Sendable, Codable, Equatable {
        public let fiveHour: Double
        public let weekly: Double

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case weekly
        }

        public init(fiveHour: Double, weekly: Double) {
            self.fiveHour = fiveHour
            self.weekly = weekly
        }

        public func ceiling(for window: WindowType) -> Double {
            switch window {
            case .fiveHour: return fiveHour
            case .weekly: return weekly
            }
        }
    }
}
