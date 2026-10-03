import Foundation

// Decodable shape for the direct `wham/usage` fallback response (Baseline §8.2 confirmed
// Enterprise capture). Only the fields Step 9 normalizes are declared; unknown keys are ignored
// and nothing is persisted raw (PATTERNS.md §Logger privacy boundary).
//
// The endpoint uses snake_case keys (`plan_type`, `rate_limit`, `used_percent`, `reset_at`, …),
// unlike the camelCase RPC results — decode via `CodexWhamUsage.decode(from:)`, which applies
// `.convertFromSnakeCase` so both the live client (Step 10) and tests share one decode path.
//
// `rate_limit` is nullable: it is `null` on a healthy idle session (§8.3) — that is the §13
// Null-window state (display `—`, no warning), not an error. The blocked-state shape
// (`limit_reached: true` + populated windows) was a D1 working assumption until 2026-09-08,
// when the owner's Plus account ran out and the first real blocked payload was captured
// (REV-91): the assumption held, and the capture also carried `rate_limit_reached_type` as an
// **object** where every prior capture had a string or null.
//
// **The decoding rule this file now follows (REV-91).** Strict decoding is reserved for fields
// the app actually reads and acts on — `rate_limit`, its `limit_reached`, and the window
// numbers. Everything else decodes leniently: an unexpected shape degrades that one field to
// nil and the poll still lands. The reason is not tidiness. `rate_limit_reached_type` had zero
// consumers on this transport (`normalize(wham:)` derives over-quota from `limit_reached`), yet
// its shape change discarded every poll for 50 minutes — and it did so at the exact moment the
// user hit their limit, because the field is null until then. A declared-but-unread field that
// can fail the whole decode is a tripwire aimed at the worst possible minute.

/// `GET chatgpt.com/backend-api/wham/usage` result (Baseline §8.2).
public struct CodexWhamUsage: Decodable, Sendable, Equatable {

    public struct Window: Decodable, Sendable, Equatable {
        public let usedPercent: Double?
        /// Window width in **seconds** (`2592000` = 30 days on Free/Go). Decoded correctly since
        /// it was declared, but read by nothing until STEP_85 — see the RPC twin's
        /// `windowDurationMins` for what that cost (REV-57 §4.1).
        public let limitWindowSeconds: Int?
        /// Declared but read by nothing — `resetAt` is preferred for countdown accuracy. Lenient
        /// for that reason (REV-91).
        public let resetAfterSeconds: Int?
        /// Unix seconds — preferred over `resetAfterSeconds` for countdown accuracy (§8.2).
        public let resetAt: Int?

        private enum CodingKeys: String, CodingKey {
            case usedPercent, limitWindowSeconds, resetAfterSeconds, resetAt
        }

        /// The three numbers the display is built from stay strict — a wrong percentage or reset
        /// time is worse than none. `resetAfterSeconds` is unread, so it degrades (REV-91).
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try container.decodeIfPresent(Double.self, forKey: .usedPercent)
            limitWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .limitWindowSeconds)
            resetAt = try container.decodeIfPresent(Int.self, forKey: .resetAt)
            resetAfterSeconds =
                (try? container.decodeIfPresent(Int.self, forKey: .resetAfterSeconds)) ?? nil
        }
    }

    public struct RateLimit: Decodable, Sendable, Equatable {
        /// Declared but read by nothing — over-quota comes from `limitReached`. Lenient (REV-91).
        public let allowed: Bool?
        /// Over-quota trigger — confirmed by the 2026-09-08 blocked capture (§8.2, REV-91).
        public let limitReached: Bool?
        public let primaryWindow: Window?
        public let secondaryWindow: Window?

        private enum CodingKeys: String, CodingKey {
            case allowed, limitReached, primaryWindow, secondaryWindow
        }

        /// `limitReached` and the two windows are what the app acts on, so they stay strict.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limitReached = try container.decodeIfPresent(Bool.self, forKey: .limitReached)
            primaryWindow = try container.decodeIfPresent(Window.self, forKey: .primaryWindow)
            secondaryWindow = try container.decodeIfPresent(Window.self, forKey: .secondaryWindow)
            allowed = (try? container.decodeIfPresent(Bool.self, forKey: .allowed)) ?? nil
        }
    }

    /// The object form of `rate_limit_reached_type`, first seen 2026-09-08 on an exhausted Plus
    /// account: `{"type": "rate_limit_reached", "details": "default"}`. Older captures carry a
    /// bare string in the same key, and a healthy account carries `null` — so this key is a
    /// one-of, and `CodexWhamUsage` reads it as one (REV-91).
    public struct ReachedType: Decodable, Sendable, Equatable {
        public let type: String?
        public let details: String?
    }

    /// `spend_control.individual_limit` — the per-user monthly credit limit on a workspace-wide
    /// pool (§8.2, REV-38; live-confirmed 2026-07-15/16). `null` = no monthly limit configured.
    /// `limit`/`used`/`remaining` are **strings** (`"5000"`, `"2376.905242651701"`); the
    /// percents are numbers. All-optional so null / object / absent all decode — the historical
    /// `Int?` declaration never matched a real payload and silently killed the entire wham
    /// decode on any limit-configured account (F4).
    public struct IndividualLimit: Decodable, Sendable, Equatable {
        public let limit: String?
        public let used: String?
        public let remaining: String?
        public let usedPercent: Int?
        public let remainingPercent: Int?
        public let resetAfterSeconds: Int?
        /// Unix seconds — start of the next calendar month UTC (§8.2).
        public let resetAt: Int?
        /// e.g. `"group_based_spend_controls"` — control metadata, never displayed.
        public let source: String?
    }

    public struct SpendControl: Decodable, Sendable, Equatable {
        /// Drives the Spend control notification on transition to true (§8.2).
        public let reached: Bool?
        public let individualLimit: IndividualLimit?

        private enum CodingKeys: String, CodingKey { case reached, individualLimit }

        public init(reached: Bool?, individualLimit: IndividualLimit?) {
            self.reached = reached
            self.individualLimit = individualLimit
        }

        /// `individual_limit` decodes leniently (like `credits`/`additional_rate_limits` on the
        /// parent): an unexpected future shape degrades this field to nil instead of failing the
        /// whole poll — F4 existed precisely because this one field could. `reached` stays strict.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            reached = try container.decodeIfPresent(Bool.self, forKey: .reached)
            individualLimit =
                (try? container.decodeIfPresent(IndividualLimit.self, forKey: .individualLimit)) ?? nil
        }
    }

    public struct ResetCredits: Decodable, Sendable, Equatable {
        /// Banked resets; stored in `poll_snapshots`, display deferred to Alpha A18 (§8.2).
        public let availableCount: Int?
    }

    /// One `additional_rate_limits[]` entry — a per-model allowance (UI Spec §2.7 → §REV92).
    ///
    /// **Captured 2026-09-10 (STEP_176, `docs/evidence/REV92/codex_wham_usage_2026-09-10.json`)**
    /// — the D1 working assumption ("field names mirror the top-level shape") was wrong in every
    /// particular: the entry has **no** `limit_id`, no flat `used_percent`/`reset_at`, and no
    /// top-level `primary_window`. It carries `limit_name`, `metered_feature` (the allowance key —
    /// `codex_bengalfox` for Spark, the same string RPC uses as its `rateLimitsByLimitId` key),
    /// a nested **`rate_limit`** object identical to the top-level one (`allowed`,
    /// `limit_reached`, `primary_window`, `secondary_window`), and `normal_model_slug`.
    ///
    /// The three pre-capture fields are kept, lenient, so a payload shaped like the old guess still
    /// yields a name and a percent rather than nothing; the nested object wins where both exist.
    /// Every field degrades to nil on a surprise — this array is decoded leniently by the parent
    /// (REV-91), and one odd entry must not blank every model limit on the popover.
    public struct AdditionalLimit: Decodable, Sendable, Equatable {
        public let limitId: String?
        public let limitName: String?
        /// The allowance key — `codex_bengalfox`. Used as the normalized `id`.
        public let meteredFeature: String?
        /// The allowance's own windows, nested exactly like the account's `rate_limit`.
        public let rateLimit: RateLimit?
        /// `null` in the capture; kept as evidence, read by nothing.
        public let normalModelSlug: String?
        // Pre-capture working-assumption fields — never observed, kept lenient as a fallback.
        public let usedPercent: Double?
        public let resetAt: Int?
        public let primaryWindow: Window?

        private enum CodingKeys: String, CodingKey {
            case limitId, limitName, meteredFeature, rateLimit, normalModelSlug
            case usedPercent, resetAt, primaryWindow
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            limitId = (try? c.decodeIfPresent(String.self, forKey: .limitId)) ?? nil
            limitName = (try? c.decodeIfPresent(String.self, forKey: .limitName)) ?? nil
            meteredFeature = (try? c.decodeIfPresent(String.self, forKey: .meteredFeature)) ?? nil
            rateLimit = (try? c.decodeIfPresent(RateLimit.self, forKey: .rateLimit)) ?? nil
            normalModelSlug = (try? c.decodeIfPresent(String.self, forKey: .normalModelSlug)) ?? nil
            usedPercent = (try? c.decodeIfPresent(Double.self, forKey: .usedPercent)) ?? nil
            resetAt = (try? c.decodeIfPresent(Int.self, forKey: .resetAt)) ?? nil
            primaryWindow = (try? c.decodeIfPresent(Window.self, forKey: .primaryWindow)) ?? nil
        }

        public init(limitId: String? = nil, limitName: String?, meteredFeature: String? = nil,
                    rateLimit: RateLimit? = nil, normalModelSlug: String? = nil,
                    usedPercent: Double? = nil, resetAt: Int? = nil, primaryWindow: Window? = nil) {
            self.limitId = limitId
            self.limitName = limitName
            self.meteredFeature = meteredFeature
            self.rateLimit = rateLimit
            self.normalModelSlug = normalModelSlug
            self.usedPercent = usedPercent
            self.resetAt = resetAt
            self.primaryWindow = primaryWindow
        }
    }

    public let email: String?
    /// Raw plan string — never a Swift enum (PATTERNS.md §Naming conventions).
    public let planType: String?
    /// `null` in healthy idle → §13 Null-window state (§8.3).
    public let rateLimit: RateLimit?
    public let spendControl: SpendControl?
    /// Normalized to the **string** form regardless of which shape the response used: a bare
    /// string decodes as itself, the object form contributes its `type`, `null`/absent is nil.
    /// Nothing on this transport reads it — `normalize(wham:)` uses `rateLimit.limitReached` —
    /// so it is kept only as evidence, and it must never fail a poll again (REV-91).
    public let rateLimitReachedType: String?
    public let rateLimitResetCredits: ResetCredits?
    /// `null` in every capture (D1) — feeds the §2.4 Credit balance row when it populates.
    public let credits: CodexCredits?
    /// Per-model allowances. `null` on every capture before 2026-09-10; populated with Spark on
    /// the owner's Pro account since (STEP_176) — see `AdditionalLimit`.
    public let additionalRateLimits: [AdditionalLimit]?

    private enum CodingKeys: String, CodingKey {
        case email, planType, rateLimit, spendControl, rateLimitReachedType, rateLimitResetCredits
        case credits, additionalRateLimits
    }

    /// Custom decode so that only `rate_limit` — the one field the app acts on — can fail a
    /// poll. Every other key degrades to nil on an unexpected shape (REV-91; the rule is stated
    /// in full at the top of this file, and F4 / the 2026-09-08 outage are why it exists).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimit = try container.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
        email = (try? container.decodeIfPresent(String.self, forKey: .email)) ?? nil
        planType = (try? container.decodeIfPresent(String.self, forKey: .planType)) ?? nil
        spendControl = (try? container.decodeIfPresent(SpendControl.self, forKey: .spendControl)) ?? nil
        rateLimitReachedType = Self.decodeReachedType(from: container)
        rateLimitResetCredits = (try? container.decodeIfPresent(ResetCredits.self, forKey: .rateLimitResetCredits)) ?? nil
        credits = (try? container.decodeIfPresent(CodexCredits.self, forKey: .credits)) ?? nil
        additionalRateLimits = (try? container.decodeIfPresent([AdditionalLimit].self, forKey: .additionalRateLimits)) ?? nil
    }

    /// Reads the **same** `rate_limit_reached_type` key twice, as two different shapes — the
    /// technique `CodexJSONLParser`'s `source`/`agentNickname` pair already uses for a key that
    /// is a string on one payload and an object on another. A string wins; otherwise the object
    /// form contributes its `type`; anything else is nil. This function cannot throw, which is
    /// the point of it.
    private static func decodeReachedType(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> String? {
        // `decodeIfPresent` returns nil for an explicit `null`, so a healthy response settles
        // here without ever attempting the object read.
        if let scalar = try? container.decodeIfPresent(String.self, forKey: .rateLimitReachedType) {
            return scalar
        }
        return (try? container.decode(ReachedType.self, forKey: .rateLimitReachedType))?.type
    }

    /// Shared decode path — applies `.convertFromSnakeCase` for the endpoint's snake_case keys.
    public static func decode(from data: Data) throws -> CodexWhamUsage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CodexWhamUsage.self, from: data)
    }
}
