import Foundation

// Decodable shapes for the two Claude OAuth endpoints (Baseline §8.0.2, §8.0.3).
// Only the fields Kvotar normalizes are declared; unknown keys are ignored by
// JSONDecoder. Nothing here is persisted raw (PATTERNS.md §Logger privacy boundary).

/// `GET /api/oauth/usage` (Baseline §8.0.2).
struct ClaudeUsageResponse: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?
    /// Optional: absent on accounts with no pay-as-you-go (Enterprise). Absence suppresses the
    /// §2.4a card entirely (distinct from a present-but-disabled object). A required field here
    /// would fail the whole poll for such accounts (REV-29).
    let extraUsage: ExtraUsageResponse?
    /// Claude Enterprise monthly spend — the canonical quota story on usage-based seats
    /// (Baseline §8.0.4, REV-40). `nil` on Pro/Max. Decoded leniently in `init(from:)`.
    let spend: SpendResponse?
    /// Enterprise-only flag, logged as P1-16 forensics — never branched on (§8.0.4).
    let memberDashboardAvailable: Bool?
    /// The generic limits array (§8.0.2, STEP_134). Carries the same three bars claude.ai's
    /// Settings → Usage page draws — session, weekly all-models, and one **model-scoped** weekly
    /// entry per scoped limit. Only the scoped entries are read: `five_hour`/`seven_day` above
    /// remain the source for the two window rows, so this adds a display, not a migration
    /// (`docs/POLLING.md` §8's `limits[]` migration stays deferred).
    ///
    /// The legacy per-model fields this replaces — `seven_day_opus`, `seven_day_sonnet` — are
    /// **null in every live capture since 2026-08-22** and are deliberately not declared.
    let limits: [LimitEntry]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case extraUsage = "extra_usage"
        case spend
        case memberDashboardAvailable = "member_dashboard_available"
        case limits
    }

    /// `spend` and `member_dashboard_available` decode leniently: an unexpected future shape
    /// degrades the field to nil instead of failing the whole poll — the F4 lesson generalized
    /// (a strict single field once silently killed the entire Codex wham decode; STEP_46).
    /// The window/extra_usage fields keep their existing strict-but-all-optional decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try container.decodeIfPresent(Window.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(Window.self, forKey: .sevenDay)
        extraUsage = try container.decodeIfPresent(ExtraUsageResponse.self, forKey: .extraUsage)
        spend = (try? container.decodeIfPresent(SpendResponse.self, forKey: .spend)) ?? nil
        memberDashboardAvailable =
            (try? container.decodeIfPresent(Bool.self, forKey: .memberDashboardAvailable)) ?? nil
        limits = (try? container.decodeIfPresent([LimitEntry].self, forKey: .limits)) ?? nil
    }

    /// A window with no active session reports `resets_at: null` (live capture 2026-07-06:
    /// `five_hour: { resets_at: null }` all night after inactivity — the null-window shape,
    /// Baseline §8.0.2). Every field is therefore optional; nil maps to "no active window".
    struct Window: Decodable {
        let utilization: Double?
        /// ISO-8601 timestamp string, e.g. "2026-06-15T21:00:00Z"; null when no window is active.
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    /// One entry of the `limits[]` array (§8.0.2, STEP_134). Live capture 2026-08-22:
    ///
    /// ```json
    /// {"group":"weekly","kind":"weekly_scoped","percent":10,"is_active":false,
    ///  "resets_at":"2026-08-28T12:59:59.577548+00:00","severity":"normal",
    ///  "scope":{"model":{"display_name":"Fable","id":null},"surface":null}}
    /// ```
    ///
    /// Every field is optional — this array arrived without announcement and will change again.
    /// `group`/`is_active`/`severity` are declared for the record but read by nothing; the mapping
    /// keys on `kind` alone.
    struct LimitEntry: Decodable {
        let group: String?
        /// `session` / `weekly_all` / `weekly_scoped` — the only discriminator that matters.
        let kind: String?
        /// The server's own whole-percent used figure, round-tripped verbatim (R2 rule). Matches
        /// claude.ai's bar to the digit.
        let percent: Int?
        /// ISO-8601 timestamp string; parsed by the adapter's existing `parseReset`.
        let resetsAt: String?
        let isActive: Bool?
        let severity: String?
        /// Present on `weekly_scoped` only; null on the two unscoped kinds.
        let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case group, kind, percent, severity, scope
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }

        /// What a scoped limit is scoped *to*. `surface` sits unused beside `model` in every
        /// capture — surface-scoped limits are evidently planned — so it is decoded and ignored
        /// rather than assumed away. Only model-scoped entries are rendered (STEP_134).
        struct Scope: Decodable {
            let model: Model?
            let surface: String?
        }

        /// **`id` is `null` in every capture**, so the display string is the only handle a scoped
        /// limit has. Nothing may key on its value — the label is whatever the provider sends, or
        /// the limit is not drawn at all.
        struct Model: Decodable {
            let displayName: String?
            let id: String?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case id
            }
        }
    }

    /// `extra_usage` object. All sub-fields are null in the disabled/no-credits shape
    /// (Baseline §7.1 Case 3) — that is normal, not an error.
    struct ExtraUsageResponse: Decodable {
        let isEnabled: Bool
        let monthlyLimit: Int?
        /// Decoded as a `String`-preserving number so money is parsed as `Decimal`, never a
        /// binary `Double` (Baseline §7.1). See `decimalUsedCredits`.
        let usedCredits: Double?
        let utilization: Double?
        let currency: String?
        let disabledReason: String?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case utilization
            case currency
            case disabledReason = "disabled_reason"
        }
    }

    /// Claude Enterprise `spend` object — money in minor units + exponent (`6916`, exp 2 =
    /// $69.16 — synthetic figures in the shape of a 2026-07-16 capture, Baseline §8.0.4). All-optional (the F4
    /// pattern) so partial/evolving shapes still decode. `cap`/`balance`/`auto_reload`/
    /// `disclaimer` are not declared (ignored); the obfuscated `amber_ladder`/
    /// `omelette_promotional` fields are **never** declared (P2-12).
    struct SpendResponse: Decodable {
        /// A money value: `{amount_minor, currency, exponent}`.
        struct Money: Decodable {
            let amountMinor: Int?
            let currency: String?
            let exponent: Int?

            enum CodingKeys: String, CodingKey {
                case amountMinor = "amount_minor"
                case currency
                case exponent
            }
        }

        let used: Money?
        let limit: Money?
        /// The server's own integer used % — round-tripped verbatim (R2 rule).
        let percent: Int?
        /// Logged-only forensics (P1-16) — `"normal"` is the only value ever captured.
        let severity: String?
        let enabled: Bool?
        let disabledReason: String?
        let canToggle: Bool?
        let canPurchaseCredits: Bool?

        enum CodingKeys: String, CodingKey {
            case used
            case limit
            case percent
            case severity
            case enabled
            case disabledReason = "disabled_reason"
            case canToggle = "can_toggle"
            case canPurchaseCredits = "can_purchase_credits"
        }
    }
}

/// `GET /api/oauth/profile` with `anthropic-beta: oauth-2025-04-20` (Baseline §8.0.3).
struct ClaudeProfileResponse: Decodable {
    let account: Account
    let organization: Organization?

    struct Account: Decodable {
        let email: String?
        /// Authoritative plan-tier booleans — map deterministically to the limits-DB plan keys.
        let hasClaudePro: Bool?
        let hasClaudeMax: Bool?

        enum CodingKeys: String, CodingKey {
            case email
            case hasClaudePro = "has_claude_pro"
            case hasClaudeMax = "has_claude_max"
        }
    }

    struct Organization: Decodable {
        /// Org UUID — the `<org_id>` path component of the `/prepaid/credits` call (REV-29,
        /// live-confirmed 2026-07-10). Cached once per token, never persisted.
        let uuid: String?
        /// Raw tier string, used only if the account booleans are absent.
        let rateLimitTier: String?
        /// Enterprise identity signal 1: `"claude_enterprise"` (REV-40, §8.0.3 amendment).
        /// Optional — absent on Pro/Max payloads.
        let organizationType: String?
        /// Enterprise identity signal 2: `"enterprise_usage_based"`. Optional — absent on
        /// Pro/Max payloads.
        let seatTier: String?

        enum CodingKeys: String, CodingKey {
            case uuid
            case rateLimitTier = "rate_limit_tier"
            case organizationType = "organization_type"
            case seatTier = "seat_tier"
        }
    }
}

/// `GET /api/oauth/organizations/<org_id>/prepaid/credits` — the second OAuth call (REV-29,
/// Baseline §7.1). Live shape captured 2026-07-10: `amount` is minor units (cents),
/// `auto_reload_settings` is null when auto-reload is off. Display-only; never blocks the poll.
struct PrepaidCreditsResponse: Decodable {
    let amount: Int?
    let autoReloadSettings: AutoReloadSettings?
    /// Display-only (STEP_219), so it degrades to nil on any unexpected shape rather than
    /// costing the wallet its balance (the REV-91 rule: only what the app acts on may fail).
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case amount
        case autoReloadSettings = "auto_reload_settings"
        case currency
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Int.self, forKey: .amount)
        autoReloadSettings = try c.decodeIfPresent(AutoReloadSettings.self,
                                                   forKey: .autoReloadSettings)
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
    }

    /// Opaque presence marker — a non-null object means auto-reload is on. Its populated field
    /// shape is unconfirmed (only ever observed null; Baseline §20 P2-8 +a), so nothing inside
    /// is decoded: presence alone drives the display-only auto-reload row (§2.4a.5).
    struct AutoReloadSettings: Decodable {}
}

/// Local fallback `~/.claude.json` → `oauthAccount.emailAddress` (Baseline §8.0.3).
struct ClaudeLocalConfig: Decodable {
    let oauthAccount: OAuthAccount?
    struct OAuthAccount: Decodable {
        let emailAddress: String?
    }
}
