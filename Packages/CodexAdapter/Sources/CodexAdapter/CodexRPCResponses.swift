import Foundation

// Decodable shapes for the two Codex app-server RPC result payloads (Baseline §8.1, §8.7).
// Only the fields Step 8 exposes are declared; unknown keys are ignored by JSONDecoder and
// nothing is persisted raw (PATTERNS.md §Logger privacy boundary). Mapping these into a
// `QuotaSnapshot` and applying RPC-vs-wham precedence is Step 9 — not done here.
//
// JSON keys are already camelCase (`planType`, `rateLimitReachedType`, `rateLimitsByLimitId`,
// `requiresOpenaiAuth`), so property names match without custom `CodingKeys`.

/// `account/read` result (Baseline §8.7 confirmed Enterprise shape).
public struct CodexAccountRead: Decodable, Sendable, Equatable {
    public struct Account: Decodable, Sendable, Equatable {
        public let type: String?
        public let email: String?
        /// Raw plan string — never a Swift enum (PATTERNS.md §Naming conventions).
        public let planType: String?
    }

    public let account: Account
    public let requiresOpenaiAuth: Bool?
}

/// `credits` sub-object shared by the RPC and wham shapes (Baseline §8.2; UI Spec §2.4 Codex).
/// D1: `credits` is `null` in every capture, so the populated shape is a working assumption.
/// Lenient by construction — any unexpected shape (scalar, array, missing keys) decodes to a
/// nil `balance` instead of failing the whole poll; worst case the row reads "unavailable".
public struct CodexCredits: Decodable, Sendable, Equatable {
    public let balance: Double?

    private enum CodingKeys: String, CodingKey { case balance }

    public init(balance: Double?) {
        self.balance = balance
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        balance = container.flatMap { (try? $0.decodeIfPresent(Double.self, forKey: .balance)) ?? nil }
    }
}

/// `account/rateLimits/read` result (Baseline §8.7 confirmed Enterprise idle shape).
///
/// `primary`/`secondary` are optional: they are `null` on a healthy idle Enterprise session —
/// treat as "no active tracking this poll" and display `—`, not an error (§8.7). The window
/// subfield keys were unconfirmed until 2026-07-31, when the first populated Codex window this
/// project has ever seen was captured on Free and then Go (spike F1/F3/R17); `Window` stays
/// permissively optional, and the RPC/wham blocked-state shape is D1-gated.
public struct CodexRateLimits: Decodable, Sendable, Equatable {
    public struct Window: Decodable, Sendable, Equatable {
        public let usedPercent: Double?
        /// Window width in **minutes** (`43200` = 30 days on Free/Go). Decoding is by exact
        /// property name — `CodexRPCClient` uses a plain `JSONDecoder`, no key strategy, because
        /// this payload is already camelCase. This field was declared as `windowSeconds` until
        /// STEP_85: a name that matches nothing, so the grain read `nil` on every poll from the
        /// day the file was written, and the unanchored window it would have revealed instead
        /// fired a reset notification on almost every poll (REV-57 §3/§4.1).
        public let windowDurationMins: Int?
        /// Declared but read by nothing — `resetsAt` is preferred. Lenient for that reason
        /// (REV-91).
        public let resetsInSeconds: Int?
        public let resetsAt: Int?

        private enum CodingKeys: String, CodingKey {
            case usedPercent, windowDurationMins, resetsInSeconds, resetsAt
        }

        /// The three numbers the display is built from stay strict; the unread one degrades.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try container.decodeIfPresent(Double.self, forKey: .usedPercent)
            windowDurationMins = try container.decodeIfPresent(Int.self, forKey: .windowDurationMins)
            resetsAt = try container.decodeIfPresent(Int.self, forKey: .resetsAt)
            resetsInSeconds =
                (try? container.decodeIfPresent(Int.self, forKey: .resetsInSeconds)) ?? nil
        }
    }

    /// `rateLimits.individualLimit` — the per-user monthly credit limit (Baseline §8.2, REV-38).
    /// Additive nullable field on `read` responses; `null` = no monthly limit configured. Keys are
    /// camelCase like the rest of the RPC payload, and the key set differs from the wham twin
    /// (`resetsAt` here vs `reset_at`/`reset_after_seconds`/percent pair there) — hence a separate
    /// struct. `limit`/`used` are **strings**; parsed defensively at normalization. Poll `read`
    /// only — sparse `updated` notifications are never consumed (PR #24812 merge-bug class).
    public struct IndividualLimit: Decodable, Sendable, Equatable {
        public let limit: String?
        public let used: String?
        public let remainingPercent: Int?
        /// Unix seconds — start of the next calendar month UTC (§8.2).
        public let resetsAt: Int?
        public let source: String?
    }

    public struct Limits: Decodable, Sendable, Equatable {
        public let limitId: String?
        public let limitName: String?
        public let primary: Window?
        public let secondary: Window?
        /// Raw plan string — never a Swift enum (PATTERNS.md §Naming conventions).
        public let planType: String?
        /// Normalized to the string form whichever shape arrives — see `CodexWhamUsage`'s twin
        /// and REV-91. On **this** transport the field is load-bearing (`normalize(rpc:)` reads
        /// its nil-ness as the over-quota signal when windows are present), which is exactly why
        /// it may not throw: a shape change here would take the primary transport down.
        public let rateLimitReachedType: String?
        /// The RPC **does** carry this (STEP_98) — present on all 1,469 retained
        /// `account/rateLimits/read` bodies back to 2026-07-24, sitting beside
        /// `rateLimitReachedType`. It was previously not declared here at all, so `normalize`
        /// hardcoded `nil` and `.spendControl` was unreachable on the primary transport.
        public let spendControlReached: Bool?
        /// `null` in the only capture (D1) — feeds the §2.4 Credit balance row when it populates.
        public let credits: CodexCredits?
        /// `null` unless an admin-set monthly limit exists (REV-38, STEP_43).
        public let individualLimit: IndividualLimit?

        private enum CodingKeys: String, CodingKey {
            case limitId, limitName, primary, secondary, planType, rateLimitReachedType
            case spendControlReached, credits, individualLimit
        }

        /// This struct had no custom decoder until REV-91, which made it *more* exposed than its
        /// wham twin: every field was strict, so any one of them could discard a poll on the
        /// **primary** transport. Same rule as wham — the windows stay strict because a wrong
        /// number is worse than no number; everything else degrades to nil.
        ///
        /// The two transports are already known to disagree on `rateLimitReachedType`: the
        /// 2026-07-31 spike caught RPC returning the bare string minutes apart from a wham
        /// response, and 2026-09-08 caught wham returning the object. Neither may throw.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            primary = try container.decodeIfPresent(Window.self, forKey: .primary)
            secondary = try container.decodeIfPresent(Window.self, forKey: .secondary)
            limitId = (try? container.decodeIfPresent(String.self, forKey: .limitId)) ?? nil
            limitName = (try? container.decodeIfPresent(String.self, forKey: .limitName)) ?? nil
            planType = (try? container.decodeIfPresent(String.self, forKey: .planType)) ?? nil
            rateLimitReachedType = Self.decodeReachedType(from: container)
            spendControlReached =
                (try? container.decodeIfPresent(Bool.self, forKey: .spendControlReached)) ?? nil
            credits = (try? container.decodeIfPresent(CodexCredits.self, forKey: .credits)) ?? nil
            individualLimit =
                (try? container.decodeIfPresent(IndividualLimit.self, forKey: .individualLimit)) ?? nil
        }

        /// The same key read twice as two shapes, mirroring `CodexWhamUsage.decodeReachedType`.
        /// Cannot throw.
        private static func decodeReachedType(
            from container: KeyedDecodingContainer<CodingKeys>
        ) -> String? {
            if let scalar = try? container.decodeIfPresent(String.self, forKey: .rateLimitReachedType) {
                return scalar
            }
            return (try? container.decode(CodexWhamUsage.ReachedType.self,
                                          forKey: .rateLimitReachedType))?.type
        }
    }

    public let rateLimits: Limits
    /// Per-limit breakdown keyed by limit id. Present on Enterprise; optional for other plans.
    /// Feeds the §2.7 additional-limits section only — a secondary display, so an unexpected
    /// shape here degrades the section rather than the poll (REV-91).
    public let rateLimitsByLimitId: [String: Limits]?

    private enum CodingKeys: String, CodingKey { case rateLimits, rateLimitsByLimitId }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimits = try container.decode(Limits.self, forKey: .rateLimits)
        rateLimitsByLimitId =
            (try? container.decodeIfPresent([String: Limits].self, forKey: .rateLimitsByLimitId)) ?? nil
    }
}
