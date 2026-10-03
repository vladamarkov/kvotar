import Foundation

/// Account-quota adapter contract (ARCHITECTURE.md §Adapter protocols).
///
/// Adapters return values — they never publish, hold a poll timer, or write to
/// `SQLiteStore` (PATTERNS.md §Async model, §Actor usage). `PollEngine` owns cadence
/// and persistence; the adapter's job ends at parsing and reporting.
public protocol AccountAdapter: Sendable {
    /// Performs one account-quota fetch and returns the normalized snapshot.
    func fetchQuotaSnapshot() async throws -> QuotaSnapshot

    /// The adapter's last-known health, used by the UI/engines to decide fallbacks
    /// (setup prompt, re-auth, cached-state freeze). Updated as a side effect of fetches.
    var health: AdapterHealth { get async }

    /// True when the credential on disk is a different, usable token than the one the last
    /// request carried (§9.3, STEP_168). Consulted by the poll driver while a server-advertised
    /// cooldown is pending — a rotation is the one sanctioned reason to probe before the
    /// deadline. Must be read-only and local (no request, no dialog). Default: never.
    func credentialChanged() async -> Bool
}

public extension AccountAdapter {
    func credentialChanged() async -> Bool { false }
}

/// Adapter health after the most recent fetch attempt (ARCHITECTURE.md §Data source map,
/// Baseline §8.0.1, §9.3). Drives fallback behaviour without exposing polling internals.
public enum AdapterHealth: Sendable, Equatable {
    /// Last fetch succeeded.
    case healthy
    /// Credential/OAuth unavailable (e.g. Keychain inaccessible) — fall back to JSONL-only
    /// mode and show the setup prompt (Baseline §8.0.1). Never surfaced as an error dialog.
    case setupRequired
    /// Token rejected (401/403) — ask the user to re-authenticate; never refresh ourselves.
    case reauthRequired
    /// Poll 429 — Kvotar's own polling was throttled. `retryAfter` is the exact number of
    /// seconds to wait (Baseline §9.3, default 120 applied by caller if the header was absent).
    case rateLimited(retryAfter: Int)
    /// The Claude OAuth access token is past its `expiresAt` (Baseline §8.0.1/§9.1 — REV-41,
    /// STEP_48). A credential-shaped condition, **not** rate pressure: the server answers an
    /// expired token with `429 rate_limit_error` + a countdown `Retry-After`, so it must never
    /// feed the 429 ladder or the persisted base. Recovery is automatic once Claude Code refreshes
    /// the credential (zero-network — the gate re-reads the Keychain each tick). Rendered
    /// generically until STEP_49 adds the D-38 "sign-in expired" copy.
    case credentialExpired
    /// No successful fetch yet, or a transient failure that is none of the above.
    case unknown
}

/// Errors thrown by `AccountAdapter.fetchQuotaSnapshot()`.
public enum AccountAdapterError: Error, Equatable {
    /// No usable credential — adapter enters `.setupRequired`; caller drops to JSONL-only mode.
    ///
    /// **This is the "it is not there" error, and only that** (REV-71 §3.2). `DetectionStatus`
    /// reads it as *never set up*, so nothing may throw it for a credential that could not be
    /// *reached* — see `credentialUnreadable`.
    case setupRequired
    /// The credential could not be **read**: the subprocess would not start, the file would not
    /// open. Distinct from `setupRequired`, which means the credential genuinely is not there.
    ///
    /// **Why the distinction is load-bearing (REV-71 §2.5, the finding with the longest reach).**
    /// On 2026-08-17 the process ran out of file descriptors, so `/usr/bin/security` could not be
    /// launched and `~/.codex/auth.json` could not be opened. Both failures returned the same
    /// "no credential" answer as a machine that had never signed in, and — because the same
    /// exhaustion had also stopped the JSONL watchers — `hasLocalActivity` was false too. Both of
    /// `DetectionStatus.classify`'s inputs were wrong *for the same reason*, which is the one
    /// correlation that rule cannot see, and the user was shown a first-run welcome on a machine
    /// where both tools were signed in.
    ///
    /// `classify` is unchanged and needs no knowledge of this case: it returns `.idle` for
    /// everything that is not `setupRequired`, so this routes itself to the existing
    /// detected-but-unreachable path. Adapters map it to `AdapterHealth.unknown`, which forks no
    /// display state — a failure to look is reported as a failure, not as a new user-facing mode.
    /// The payload is a short diagnostic reason for the log line; nothing branches on it.
    case credentialUnreadable(String)
    /// Token rejected (401/403) — adapter enters `.reauthRequired`.
    case reauthRequired
    /// Poll 429 — adapter enters `.rateLimited`. `retryAfter` seconds already resolved. `details`
    /// carries the forensic capture (§9.5 — R31-4) for the `poll_health_events` row; `nil` when
    /// the throttle surfaced without a captured response (e.g. a Codex path that only knows
    /// `retryAfter`). Nothing branches on it — capture only.
    case rateLimited(retryAfter: Int, details: RateLimit429Details?)
    /// The credential is past its `expiresAt` (Baseline §8.0.1/§9.1 — REV-41, STEP_48). Thrown by
    /// the pre-poll gate (no request sent — `details == nil`) or by the belt-and-braces 429
    /// reclassification (a countdown 429 within skew tolerance of expiry — `details` carries the
    /// captured headers/body, `category == "credential_expired"`). The coordinator routes it away
    /// from the ladder: it never advances the consecutive count nor mutates the base (§9.2 rule 6).
    case credentialExpired(details: RateLimit429Details?)
    /// Non-2xx that is neither 401/403 nor 429.
    case httpStatus(Int)
    /// Response body could not be decoded into the expected shape.
    case decoding(String)
}

/// Makes the error legible in a log line (REV-91).
///
/// Without this, `Logger.metadata(for:)` bridges the enum to `NSError` and prints
/// `error="The operation couldn't be completed. (KvotarCore.AccountAdapterError error 4.)"`.
/// Two things are wrong with that. The associated value — the only part that says *which* field
/// failed — is dropped, so the 2026-09-08 Codex decode outage took an hour to diagnose from a
/// log that had recorded it 22 times. And the ordinal is **not** the declaration order: Swift's
/// bridge numbers multi-payload enum cases by layout, so `decoding` is 4 while `credentialExpired`
/// is 2, and any reordering of the cases above silently renumbers them. A named case is stable.
///
/// **Privacy (PATTERNS.md §Logger privacy boundary, Baseline §10.6).** Every payload interpolated
/// here is already a diagnostic string the thrower composed — a `DecodingError` description
/// (type and `codingPath`, i.e. field *names*) or a short reason. Response bodies, tokens and
/// prompt content never reach an associated value, and must not be added to one. `RateLimit429Details`
/// does carry a redacted body, which is why the two cases holding it print only their category.
extension AccountAdapterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .setupRequired:
            return "setup_required"
        case .credentialUnreadable(let reason):
            return "credential_unreadable: \(reason)"
        case .reauthRequired:
            return "reauth_required"
        case .rateLimited(let retryAfter, let details):
            return "rate_limited: retry_after=\(retryAfter)s category=\(details?.category ?? "n/a")"
        case .credentialExpired(let details):
            return "credential_expired: category=\(details?.category ?? "none")"
        case .httpStatus(let code):
            return "http_status: \(code)"
        case .decoding(let reason):
            return "decoding: \(reason)"
        }
    }
}

/// Transient details for classifying a poll 429. Response headers and body never cross the storage
/// boundary. `category` is recorded for analysis only; no code path branches on it.
public struct RateLimit429Details: Sendable, Equatable {
    /// The HTTP status (always 429 today; kept explicit for the record).
    public let statusCode: Int
    /// Full response header set, verbatim except any `Authorization` key (defensively dropped).
    public let headers: [String: String]
    /// Response body, redacted (§10.6) and length-capped. `nil` if the body was empty/absent.
    public let body: String?
    /// `transient` (Retry-After ≤ floor) / `rate_pressure` (present, larger) / `unknown` (absent).
    public let category: String

    public init(statusCode: Int, headers: [String: String], body: String?, category: String) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.category = category
    }
}

/// Origin of a null primary quota window (Baseline §9.5 — R31-4, bears on D1): did the endpoint
/// itself report no active window (`provider`), or did our own normalization drop the window
/// (`normalized`)? Recorded on the forensic 429 row to disambiguate the D-26 null-window question.
public enum NullWindowSource: String, Sendable, Equatable {
    case provider
    case normalized
}

/// Pre-content classification for a tool that has not yet produced a successful poll — the
/// first-run-vs-idle distinction (Baseline §13.3, UI Spec Part 3 §3). Two of the three §13.3
/// states resolve here (`loading` is the still-awaiting-first-poll case handled before a failure).
public enum DetectionStatus: Sendable, Equatable {
    /// Never detected — no credential AND no local JSONL activity. Show first-run onboarding.
    case firstRun
    /// Detected but unreachable / idle (credential present, or local activity seen). Idle card.
    case idle

    /// Classifies a failed first poll: a `setupRequired` error with no observed local JSONL
    /// activity means the tool was never detected (first-run); anything else means it is detected
    /// but currently idle/unreachable. The single rule the App layer applies on a pre-success
    /// failure (STEP_30) — pure so it is unit-testable per tool.
    ///
    /// **The rule is unchanged by STEP_117; what changed is what reaches it** (REV-71 §3.2). A
    /// credential read that fails at the I/O layer now throws
    /// `AccountAdapterError.credentialUnreadable` rather than `setupRequired`, so it lands on the
    /// `.idle` branch below even with no local activity — see `DetectionStatusTests`.
    public static func classify(error: Error, hasLocalActivity: Bool) -> DetectionStatus {
        if case AccountAdapterError.setupRequired = error, !hasLocalActivity {
            return .firstRun
        }
        return .idle
    }
}

/// Which endpoint produced a `QuotaSnapshot` — drives the popover source tags
/// (UI Spec §2.3/§2.5 Codex: "Source: app-server RPC · exact" vs "wham/usage"). STEP_27.
public enum QuotaSource: String, Sendable, Equatable {
    case oauth
    case appServerRPC = "rpc"
    case wham
}

/// One per-model sub-bucket. **Both tools populate it, and they render it differently**
/// (STEP_134): Codex from `additional_rate_limits[]` / `rateLimitsByLimitId` into the collapsed
/// §2.7 section (UI Spec D-10 — only one Codex model has ever had a sub-bucket, so a permanent row
/// would clutter every popover); Claude from the usage endpoint's `limits[]` `weekly_scoped`
/// entries into first-class Account-quota rows (D-94 — claude.ai draws that bar beside the
/// all-models one, and it is the limit a Claude Code user hits first). One model, two placements,
/// each matching what its provider treats the limit as.
///
/// **Every reported window survives (STEP_176 — REV-92 / Baseline §15.2).** A model allowance has
/// its own window *shape*, independent of the main one: the owner's Codex account read on
/// 2026-09-10 carried a weekly-only main allowance (10 080 min, no secondary) beside
/// `GPT-5.3-Codex-Spark` with a five-hour **and** a weekly window (300 + 10 080 min), on both
/// transports (`docs/evidence/REV92/codex_{rpc_ratelimits,wham_usage}_2026-09-10.json`). The
/// four original fields are the allowance's **primary** window and keep their names so every
/// existing reader compiles unchanged; `primaryWindowSeconds` and `secondary` are the extension.
/// Every reported window is persisted to `model_limit_series` by `writePoll` (STEP_209, `v25`);
/// launch restore still does not carry them. **Never infer a duration** from the plan, the slot, or another
/// allowance: an unknown width stays `nil` and gets no period word (Claude's scoped limits report
/// none, and stay that way).
public struct AdditionalRateLimit: Sendable, Equatable {
    /// One window of a model allowance — the same three facts `QuotaSnapshot` keeps for the main
    /// windows, so a model window can be named, drained and reset exactly like one.
    public struct Window: Sendable, Equatable {
        public let usedPercent: Double?
        public let resetsAt: Date?
        /// Width in seconds where the provider reports one; `nil` = unknown, never guessed.
        public let windowSeconds: Int?

        public init(usedPercent: Double?, resetsAt: Date?, windowSeconds: Int? = nil) {
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.windowSeconds = windowSeconds
        }

        /// A present window with nothing in it — no percent, no reset, no width.
        public var isEmpty: Bool { usedPercent == nil && resetsAt == nil && windowSeconds == nil }
    }

    /// Stable identifier — Codex's limit key (`"codex_bengalfox"` for Spark: RPC's
    /// `rateLimitsByLimitId` key and wham's `metered_feature` are the same string). **Null on every
    /// Claude scoped limit observed** — `scope.model.id` is null in the payload, so `name` is the
    /// only handle there and nothing may key on its value.
    public let id: String?
    /// Human-readable name (e.g. a model name) — falls back to `id` for display.
    public let name: String?
    /// The allowance's primary window, split into the three fields it always had.
    public let usedPercent: Double?
    public let resetsAt: Date?
    /// Primary window width in seconds, where reported (RPC `windowDurationMins × 60`, wham
    /// `limit_window_seconds`). `nil` on Claude and on any entry that omits it.
    public let primaryWindowSeconds: Int?
    /// The allowance's secondary (longer) window, where the provider reports one. `nil` = not
    /// reported — never an empty placeholder, never borrowed from the main allowance.
    public let secondary: Window?

    public init(id: String?, name: String?, usedPercent: Double? = nil, resetsAt: Date? = nil,
                primaryWindowSeconds: Int? = nil, secondary: Window? = nil) {
        self.id = id
        self.name = name
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.primaryWindowSeconds = primaryWindowSeconds
        self.secondary = secondary
    }

    /// The primary window in `Window` form, so both windows can be walked alike.
    public var primary: Window {
        Window(usedPercent: usedPercent, resetsAt: resetsAt, windowSeconds: primaryWindowSeconds)
    }

    /// Whether the primary window carries anything at all (a Claude scoped limit always does; a
    /// Codex allowance whose primary came back `null` does not).
    public var hasPrimaryWindow: Bool { !primary.isEmpty }
}

/// Normalized result of one account-quota poll — the single value an `AccountAdapter`
/// returns. Maps onto the `accounts` + `poll_snapshots` columns (§17.1); persistence is
/// performed later by `SQLiteStore.writePoll(snapshot:)` (owned by `PollEngine`).
///
/// Window fields are optional. Claude always populates them (the OAuth usage endpoint returns
/// both windows when reachable, Baseline §8.0.2). Codex may leave them `nil` in a healthy-idle
/// state where RPC/wham return null windows — the §13 Null-window state: display `—`, no
/// warning (Baseline §8.3, §17.3 D1). Header and identity fields are optional too.
public struct QuotaSnapshot: Sendable, Equatable {
    public let tool: Tool

    // MARK: Quota windows (Baseline §8.0.2, §8.3) — nil on Codex null-window (§13, §17.3 D1).
    /// `five_hour.utilization` (Claude) / `primary_window.used_percent` (Codex) — session used %.
    public let primaryUsedPct: Double?
    /// `five_hour.resets_at` (Claude) / `primary_window.reset_at` (Codex).
    public let primaryResetsAt: Date?
    /// Provider-reported **width** of the primary window, in seconds — `limit_window_seconds`
    /// (Codex wham) / `windowDurationMins × 60` (Codex RPC). `nil` on Claude, which reports no
    /// such field, and `nil` on any Codex payload that omits it.
    ///
    /// Codex's grain is plan-dependent and undocumented for some tiers — 30 days on Free/Go,
    /// five hours on Plus/Pro/Business — so it is **read**, never inferred from `plan_type`
    /// (REV-57 §4.1, D-34). Its one consumer today is the unanchored-window rule below; naming
    /// the window from it is deliberately deferred (REV-57 §11).
    public let primaryWindowSeconds: Int?
    /// `seven_day.utilization` (Claude) / `secondary_window.used_percent` (Codex) — Weekly used %.
    public let secondaryUsedPct: Double?
    /// `seven_day.resets_at` (Claude) / `secondary_window.reset_at` (Codex).
    public let secondaryResetsAt: Date?
    /// The provider-reported width of the secondary window, in seconds, where the wire states one
    /// *(STEP_188 — REV-95 §3.1)*. Codex reports it on both transports (`windowDurationMins` on
    /// RPC, `limitWindowSeconds` on wham); **Claude's `seven_day` object carries no width at all**,
    /// so it stays `nil` there. Never filled from `DiscontinuityDetector.secondaryWindowSeconds` —
    /// that constant is the display/event assumption, and a substrate column may not store an
    /// assumption (REV-93 §4, the STEP_181 rule; same discipline as `AdditionalRateLimit`'s
    /// "never infer a duration"). Survives expiry like `primaryWindowSeconds`: a width belongs to
    /// the plan, not to the window that just ended.
    public let secondaryWindowSeconds: Int?

    /// Over-quota flag. Claude: `primaryUsedPct > 100`. Codex: wham `rate_limit.limit_reached`
    /// (D1 working assumption). `nil` = insufficient data (Codex null-window, §17.3 D1).
    public let rateLimitReached: Bool?

    /// Pay-as-you-go state (Baseline §7.1). `isEnabled` drives the over-quota case matrix. `nil`
    /// means the account exposes **no** `extra_usage` object (Enterprise / no pay-as-you-go) — the
    /// §2.4a card is then suppressed entirely, distinct from a present-but-`.disabled` object (the
    /// NO-BACKSTOP state, which renders). Always `nil` for Codex (no credits concept).
    public let extraUsage: ExtraUsage?

    /// Prepaid wallet + auto-reload from the second OAuth call (Baseline §7.1, REV-29). `nil`
    /// when the `/prepaid/credits` call was not made or failed — the §2.4a card then drops the
    /// balance + auto-reload rows and keeps the `extra_usage` rows (§2.4a.4). Claude-only.
    public let prepaid: PrepaidCredits?

    // MARK: Rate-limit headers (Baseline §9.2, §9.5) — optional, present on success only.
    public let rateLimitLimit: Int?
    public let rateLimitRemaining: Int?
    public let rateLimitReset: Date?

    // MARK: Codex-only fields (Baseline §8.2) — nil for Claude.
    /// `spend_control.reached` — drives the Spend control notification (task Step 9).
    public let spendControlReached: Bool?
    /// `rate_limit_reset_credits.available_count` — banked resets; display deferred to Alpha A18.
    public let rateLimitResetCreditsCount: Int?
    /// `credits.balance` — Credit balance row (UI Spec §2.4 Codex). nil = "unavailable" (D1:
    /// null in every capture). STEP_27.
    public let creditsBalance: Double?
    /// Per-model sub-buckets for the §2.7 additional-limits section. Empty when absent. STEP_27.
    public let additionalRateLimits: [AdditionalRateLimit]

    /// Per-user monthly limit (Codex: credits, Baseline §8.2 `individual_limit` / RPC
    /// `individualLimit`, REV-38; Claude Enterprise: monthly spend in money units, §8.0.4
    /// `spend`, REV-40). `nil` = no monthly limit configured. STEP_43/STEP_46.
    public let monthlyLimit: MonthlyLimit?

    // MARK: Provenance (STEP_27)
    /// Which endpoint produced this snapshot — drives popover source tags. nil on legacy paths.
    public let source: QuotaSource?

    /// Origin of a null primary window, when `primaryUsedPct == nil` (§9.5 — R31-4, D1). `nil`
    /// when the primary window is present. Read only by the 429 forensic capture; not displayed.
    public let nullWindowSource: NullWindowSource?

    // MARK: Account identity — fetched once at startup, merged in (Baseline §8.0.3).
    public let email: String?
    /// Raw plan string, never a Swift enum (PATTERNS.md §Naming conventions).
    public let planType: String?

    public init(
        tool: Tool,
        primaryUsedPct: Double?,
        primaryResetsAt: Date?,
        primaryWindowSeconds: Int? = nil,
        secondaryUsedPct: Double?,
        secondaryResetsAt: Date?,
        secondaryWindowSeconds: Int? = nil,
        rateLimitReached: Bool?,
        extraUsage: ExtraUsage? = nil,
        prepaid: PrepaidCredits? = nil,
        rateLimitLimit: Int? = nil,
        rateLimitRemaining: Int? = nil,
        rateLimitReset: Date? = nil,
        spendControlReached: Bool? = nil,
        rateLimitResetCreditsCount: Int? = nil,
        creditsBalance: Double? = nil,
        additionalRateLimits: [AdditionalRateLimit] = [],
        monthlyLimit: MonthlyLimit? = nil,
        source: QuotaSource? = nil,
        nullWindowSource: NullWindowSource? = nil,
        email: String? = nil,
        planType: String? = nil
    ) {
        self.tool = tool
        self.primaryUsedPct = primaryUsedPct
        self.primaryResetsAt = primaryResetsAt
        self.primaryWindowSeconds = primaryWindowSeconds
        self.secondaryUsedPct = secondaryUsedPct
        self.secondaryResetsAt = secondaryResetsAt
        self.secondaryWindowSeconds = secondaryWindowSeconds
        self.rateLimitReached = rateLimitReached
        self.extraUsage = extraUsage
        self.prepaid = prepaid
        self.rateLimitLimit = rateLimitLimit
        self.rateLimitRemaining = rateLimitRemaining
        self.rateLimitReset = rateLimitReset
        self.spendControlReached = spendControlReached
        self.rateLimitResetCreditsCount = rateLimitResetCreditsCount
        self.creditsBalance = creditsBalance
        self.additionalRateLimits = additionalRateLimits
        self.monthlyLimit = monthlyLimit
        self.source = source
        self.nullWindowSource = nullWindowSource
        self.email = email
        self.planType = planType
    }

    /// True when both quota windows are null — the §13 Null-window state (Codex healthy idle).
    public var isNullWindow: Bool {
        primaryUsedPct == nil && secondaryUsedPct == nil
    }

    /// True when this snapshot's primary window was recognised as **unanchored** and had its
    /// reset dropped by `CodexAccountAdapter` (REV-57 §4) — utilization is real, the deadline
    /// never existed. The third member of the non-window family, and the only *partial* one:
    /// null means the provider sent no window, expired means the window is over (R33-7), and
    /// unanchored means it has not started.
    ///
    /// Recognised, not recomputed: the adapter's rule needs `now`, this does not. A snapshot in
    /// this shape comes from that rule on Codex, or — since REV-80 / D-101 — directly from the
    /// Claude adapter, which sets its 18 000 s width on every snapshot and keeps the `0` a
    /// present `five_hour` object carries beside `resets_at: null`. Neither adapter drops an
    /// anchor it kept a duration for otherwise. Reading it here (rather than re-deriving the
    /// arithmetic) is what keeps the display from mislabelling Claude's rare parse-failure shape
    /// — a real window whose `resets_at` we could not read is not a window that has not started
    /// (that shape keeps its real, non-zero utilization).
    ///
    /// **Now survives a restore, which it did not when this rule was written** *(corrected
    /// STEP_102)*. The note here used to read: "not persisted — `poll_snapshots` carries no
    /// duration column, so a stale-restored snapshot reads `false` and the display falls back to a
    /// bare `—`. Deliberate: 'no window open' is a claim about *now*, and an old row cannot make
    /// it." STEP_101 added `poll_snapshots.primary_window_seconds` (P1-28) and restores it, so a
    /// restored snapshot of a genuinely unanchored window now reads `true` and the card says
    /// `Weekly · not started` where it used to say `—`. Kept, not reverted (user ruling): it is the
    /// more honest of the two renders, and it self-corrects on the first live poll either way.
    ///
    /// `StateEngine`'s demolition branch (REV-64 §5) keys on this property, which is why its
    /// semantics are stated exactly rather than left to the stale note.
    public var primaryWindowIsUnanchored: Bool {
        primaryResetsAt == nil && primaryWindowSeconds != nil && primaryUsedPct == 0
    }

    /// How wide the primary window is. **A read field with a fallback, not a constant** (REV-60):
    /// 18,000 s is Claude's true width (its usage endpoint reports none — since REV-80 the Claude
    /// adapter sets it itself, so the fallback now covers only a Codex payload that omits the
    /// field), so it is right wherever it still applies and wrong everywhere it used to be
    /// applied by default. `NotificationEngine.fallbackWindowLength` is
    /// the same fallback for the same reason and stays separate — that one buckets notification
    /// keys from a width that may arrive without a snapshot in hand.
    public var primaryWindowLength: TimeInterval { TimeInterval(primaryWindowSeconds ?? 18_000) }

    /// Where the primary window started (§3.3) — **the one derivation** every window-scoped span
    /// in the app reads. `nil` on a null or unanchored window, which is what the attribution and
    /// off-machine paths take as "no window to anchor to".
    ///
    /// Before REV-60 six sites each subtracted their own hardcoded five hours. On the `go`
    /// account's 43,200-minute window that put the start a month in the *future*, so every local
    /// token event fell outside it and a window spent entirely on this machine reported ≈97%
    /// off-machine (REV-60 §1).
    public var primaryWindowStart: Date? {
        primaryResetsAt?.addingTimeInterval(-primaryWindowLength)
    }

    /// The pace clock's grace, as a fraction of the window width (§11.3, REV-65/D-69): the clock
    /// is silent until this share of the window has elapsed — ~6 min on a 5-hour window, ~3.4 h on
    /// a weekly. Any usage at a window's open is "ahead of linear schedule", so without the grace
    /// every first session of a window would read over-pace. Time-shaped rather than a points
    /// slack: the REV-65 replay showed a 5-point slack suppressing 9 of 10 genuine Claude
    /// warnings, while the grace kills only the window-open false alarms. Slack is 0 by decision.
    public static let paceGraceFraction = 0.02

    /// The §11.3 pace clock (REV-65/D-69) — has this window used more of its quota than of its
    /// calendar? `used% > elapsed%`, computed from `primaryWindowLength` so Claude (which reports
    /// no width) rides the REV-60 fallback rather than silently never firing. `nil` when there is
    /// no populated, anchored window to pace against — and per §11.3, no pace claim means the
    /// exhaustion family cannot fire. `false` inside the grace. Pure over the snapshot: no buffer,
    /// so it holds from the first poll and across restarts. StateEngine (rank 9) and
    /// DisplayFormatter (§2.2a verdict, §1.3 ◔ slot) both read **this** derivation — never fork it
    /// (Baseline §19).
    public func paceExceeded(now: Date) -> Bool? {
        guard let usedPct = primaryUsedPct, let elapsedPct = paceElapsedPct(now: now) else {
            return nil
        }
        guard elapsedPct >= Self.paceGraceFraction * 100 else { return false }
        return usedPct > elapsedPct
    }

    /// The pace clock's other hand (STEP_110 / REV-67 D-73): how much of this window's calendar
    /// has elapsed, in percent, from the same `primaryWindowLength` and reset `paceExceeded` uses
    /// — extracted so the verdict anatomy can show "87% used at 64% of the window" without a
    /// second derivation (Baseline §19). `nil` under exactly `paceExceeded`'s guards (no populated,
    /// anchored window). Unclamped: a window past its reset reads > 100 and one whose anchor is
    /// in the future reads < 0 — callers that display it clamp.
    public func paceElapsedPct(now: Date) -> Double? {
        guard primaryUsedPct != nil, let resetsAt = primaryResetsAt else { return nil }
        let length = primaryWindowLength
        guard length > 0 else { return nil }
        return (length - resetsAt.timeIntervalSince(now)) / length * 100
    }

    /// Plan strings whose Codex allowance is too small for a rate display to mean anything.
    /// Matched case-insensitively; the string itself is never normalised on the way in (§4 — a
    /// raw `String`, never a Swift enum).
    public static let lowAllowancePlans: Set<String> = ["free", "go"]

    /// The width at which a single window, with nothing else in the account, is assumed to be a
    /// consumer allowance rather than a working quota. Both measured consumer shapes are exactly
    /// 43,200 minutes; Plus is 10,080 and must stay out (STEP_101).
    public static let lowAllowanceBackstopWidth = 30 * 86_400

    /// **The low-allowance rule** (§11.3, UI Spec D-60/D-64): Codex reports `free` or `go`, **or**
    /// the account has one window 30 days or wider and nothing else in it — no secondary window,
    /// no monthly limit, no credits, no pay-as-you-go.
    ///
    /// What it gates, all from this one boolean: the whole §2.5 burn card, the runway verdict, the
    /// forecast, six of the seven notification kinds, and the §2.3 tier note. The reason is
    /// §11.3 — on this shape a single turn can move the meter by a fifth of the entire allowance
    /// (`go`, 2026-08-11: twelve turns, 0% → 89%, per-turn deltas `6, 11, 9, 5, 4, 8, 5, 19, 4,
    /// 10, 8`), and both published consumption models die against that. A rate we have failed to
    /// model must not be stated.
    ///
    /// **Why a plan name, when D-58/D-34 say never to branch on `plan_type`** *(re-ruled with the
    /// user 2026-08-13 — STEP_101; the ban stands everywhere else, and this predicate is the one
    /// carve-out)*. The clause this replaces was a **width** test — primary ≥ 7 days — and it
    /// caught Plus, whose window is exactly 7 days wide, on the day the account upgraded: every
    /// Codex alert but Over quota went silent and the popover told a user at 3% used that "one
    /// working session can use most of it". Measured from the per-turn JSONL `rate_limits` block
    /// on 2026-08-13, `go` consumes ~7.1% of its window per turn, `free` ~2.8%, and `plus`
    /// **0.08%** — roughly 200x apart with nothing observed between. REV-63 proposed measuring
    /// that rate at runtime; the user's ruling is that the whole apparatus would exist to set this
    /// one boolean, which a name plus a shape backstop already sets correctly on every shape this
    /// project has captured.
    ///
    /// **The name branch is decisive and unguarded; the guards belong to the backstop**, which is
    /// the branch that is guessing about a plan nobody has seen. An unfamiliar future cheap plan
    /// is still caught if it is shaped like one.
    ///
    /// **Known risk, accepted:** a stale plan string mutes until the app restarts. A long-lived
    /// Codex app-server child kept reporting `planType: go` for the rest of its lifetime after the
    /// 2026-08-12 upgrade, while `wham/usage` saw `plus` at once (REV-63 §7). If a card looks
    /// wrongly muted, check the helper's lifetime before suspecting this rule.
    ///
    /// **Claude never matches, deliberately** (decision 2026-08-13). No Claude plan string has ever
    /// read `free` — observed: `max`, `pro`, `team_enterprise`, and literally `unknown` — Claude
    /// Code requires a paid plan, and its five-hour window refills roughly five times a day, so a
    /// rate display there is as useful as it is on Max. Two lines to add if that ever changes.
    ///
    /// **"No credits" means no credit pool, not no `extraUsage` object.** Both Codex transports
    /// hard-code `extraUsage: .disabled` as a deliberate placeholder — Codex has no credits concept
    /// and the field is Alpha-deferred (P2-7/A2) — so testing for `nil` there matches nothing Codex
    /// ever sends, and the backstop would be dead on the accounts it was written for. Found by
    /// rendering it live on the `go` account, which kept classifying Bad timing at 97%.
    public var isLowAllowanceShape: Bool {
        guard tool == .codex else { return false }
        if let plan = planType?.lowercased(), Self.lowAllowancePlans.contains(plan) { return true }
        guard let width = primaryWindowSeconds, width >= Self.lowAllowanceBackstopWidth
        else { return false }
        guard secondaryUsedPct == nil, secondaryResetsAt == nil else { return false }
        guard monthlyLimit == nil, creditsBalance == nil else { return false }
        let payAsYouGo = extraUsage?.isEnabled == true
            || (extraUsage?.usedCredits.map { $0 > 0 } ?? false)
        return !payAsYouGo
    }

    /// The monthly pool is consummated: the provider's block flag, or a used-% at or over the
    /// ceiling. **One rule, in Core** (REV-96 §3.4 — STEP_193). It lived in `DisplayFormatter`
    /// alone, which is why the card could read "Spend limit reached" while `StateEngine` sat on
    /// rank 12: the Claude adapter never sets `spendControlReached`, and nothing in Core looked
    /// at `usedPercentExact`. The engine, the formatter and the notification engine now read the
    /// same property. *(REV-96 says "derived in the adapter layer"; it is a pure function of the
    /// snapshot, so deriving it here is one definition instead of two and needs no threading
    /// through the snapshot-rebuild sites — the trap STEP_188 hit with the weekly width.)*
    public var monthlyReached: Bool {
        spendControlReached == true || (monthlyLimit?.usedPercentExact ?? 0) >= 100
    }

    /// The limit that is stopping this account, and when it lets go (REV-96 §2.1 — STEP_193).
    /// `nil` when nothing is at the ceiling and no flag is raised.
    ///
    /// **Among the limits that are spent, the one whose reset is latest.** That choice is the
    /// whole fix: on the tester's 4–7 Sep block the provider's flag sat on a five-hour window
    /// reading 0 % while the weekly read 100 % with a Monday reset, so keying the block to
    /// anything the flag touched re-armed the banner every few hours (eleven for one block).
    /// The latest reset is the one that actually has to pass before work resumes.
    ///
    /// Read this from a snapshot that has already been through `degradingExpiredWindows` — the
    /// engine degrades before it classifies — so an expired limit is not a candidate and R33-7's
    /// "the claim expires with its window" needs no second test here.
    ///
    /// **A candidate with no reset cannot key an episode.** There is nothing to compare and
    /// nothing to wait for, so the notification falls back to the §16 `windowStart` cap, exactly
    /// as it does today.
    public var blockEpisode: BlockEpisode? {
        var candidates: [(BlockEpisode.Limit, Date)] = []
        // `spendControlReached` anchors on the monthly where one exists and on the primary
        // window where none does — the same fork `degradingExpiredWindows` already makes for the
        // same flag (REV-38's R33-1 extension). Stated once here rather than split across the
        // two candidates, so the episode and the expiry cannot disagree about which reset owns
        // the flag.
        let flagAnchorsOnMonthly = monthlyLimit != nil
        let primarySpent = (primaryUsedPct ?? 0) >= 100
            || rateLimitReached == true
            || (spendControlReached == true && !flagAnchorsOnMonthly)
        if primarySpent, let at = primaryResetsAt {
            candidates.append((.primary, at))
        }
        if (secondaryUsedPct ?? 0) >= 100, let at = secondaryResetsAt {
            candidates.append((.secondary, at))
        }
        if monthlyReached, flagAnchorsOnMonthly, let at = monthlyLimit?.resetsAt {
            candidates.append((.monthly, at))
        }
        guard let winner = candidates.max(by: { $0.1 < $1.1 }) else { return nil }
        return BlockEpisode(tool: tool, limit: winner.0, limitResetsAt: winner.1)
    }

    // MARK: Long limits — the four tiers (Baseline §11.3/§13, REV-96 §2.2 — STEP_194)

    /// The width assumed for a secondary window whose provider states none. **A fallback, not a
    /// constant** — the same discipline `primaryWindowLength` applies to the primary: Claude's
    /// `seven_day` object carries no width and its weekly genuinely is seven days, so this is
    /// right wherever it still applies. Codex states a width on both transports and rides it
    /// (`secondaryWindowSeconds`, STEP_188), so a re-sized Codex weekly paces against its real
    /// length rather than this number.
    public static let secondaryWindowFallbackSeconds = 7 * 86_400

    /// The tier rule, as one pure function of the two clocks (REV-96 §2.2). Extracted so the
    /// boundary tests can drive it directly and so both limits are classified by one ladder.
    ///
    /// The order is the whole rule: **spent and nearly-spent are position tests and are
    /// deliberately not pace-gated** — being past 90 % of a week sets the verdict whatever the
    /// calendar says — while amber needs all three of a pace that lands past the projection
    /// line, past the floor, and past the window's opening grace. That asymmetry is the At-risk
    /// precedent (REV-65 §4): a gate that suppresses false alarms at a window's open must never
    /// suppress a genuine late one.
    ///
    /// **Amber asks where the pace lands, not whether it is ahead** *(REV-98 §2.1 — STEP_200;
    /// supersedes REV-96 §2.2's bare `used > elapsed`)*. The same two clocks, divided rather than
    /// subtracted. A points margin cannot serve both ends of a period — two points over on day 1
    /// of 7 projects to ~114 % and is real, the same two points on day 6 projects to ~102 % and
    /// is noise — and the projection separates them by construction, without a constant of a new
    /// shape.
    public static func longLimitTier(
        usedPct: Double, elapsedPct: Double, spentByFlag: Bool,
        nearlySpentPct: Double = StateEngine.longLimitNearlySpentPct
    ) -> LongLimitAssessment.Tier {
        if spentByFlag || usedPct >= 100 { return .spent }
        if usedPct >= nearlySpentPct { return .nearlySpent }
        // The grace is time-shaped (§11.3): ~3.4 h into a week, ~14 h into a month. Any usage at
        // a period's open is "ahead of linear schedule", and a points slack would instead eat
        // genuine mid-period warnings. It also guarantees a non-zero divisor below.
        guard elapsedPct >= Self.paceGraceFraction * 100 else { return .onPace }
        guard usedPct >= StateEngine.longLimitAheadFloorPct else { return .onPace }
        // Where the pace lands: what this period finishes at if the current rate holds,
        // `used% / elapsed% × 100`, compared to the line. **Cross-multiplied on purpose** — the
        // division is inexact at the line itself (55 used at 50 % elapsed computes as
        // 110.00000000000001 in IEEE 754), so an exclusive `>` on the quotient would turn a
        // limit sitting *exactly* on the line amber. Same comparison, no floating-point artifact.
        return usedPct * 100 > elapsedPct * StateEngine.longLimitProjectionPct
            ? .aheadOfPace : .onPace
    }

    /// Every long limit this account reports, assessed. Secondary window first, then the monthly
    /// — a stable order, which is what makes the `max(by:)` below deterministic on a tie.
    ///
    /// **An unanchored or reset-less limit yields nothing**, per §11.3: no reset means no pace
    /// claim and no position to be nearly spent *at* — consistent with REV-57/REV-64, where a
    /// window that never started cannot be over-spent. The **primary** window is never assessed
    /// here, including a long one: Codex Plus's seven-day primary keeps its REV-65 "On pace" /
    /// "Above pace" verdict rows and is deliberately not re-tiered by this revision (§3.3).
    public func longLimitAssessments(now: Date) -> [LongLimitAssessment] {
        var out: [LongLimitAssessment] = []
        if let used = secondaryUsedPct, let reset = secondaryResetsAt {
            let seconds = secondaryWindowSeconds ?? Self.secondaryWindowFallbackSeconds
            let elapsed = (Double(seconds) - reset.timeIntervalSince(now)) / Double(seconds) * 100
            out.append(LongLimitAssessment(
                limit: .secondary,
                tier: Self.longLimitTier(usedPct: used, elapsedPct: elapsed, spentByFlag: false),
                usedPct: used, elapsedPct: elapsed, resetsAt: reset, periodSeconds: seconds))
        }
        if let monthly = monthlyLimit, let used = monthly.usedPercentExact,
           let elapsed = monthly.elapsedPctInCycle(now: now),
           let length = monthly.cycleSeconds() {
            out.append(LongLimitAssessment(
                // `monthlyReached` is the flag half — it folds `spendControlReached` in, so the
                // Claude spend meter (whose adapter never sets that flag) and the Codex pool
                // reach `.spent` by the same property.
                limit: .monthly,
                tier: Self.longLimitTier(usedPct: used, elapsedPct: elapsed,
                                         spentByFlag: monthlyReached),
                usedPct: used, elapsedPct: elapsed, resetsAt: monthly.resetsAt,
                periodSeconds: Int(length), usedAmount: monthly.usedAmount,
                limitAmount: monthly.limitAmount, unit: monthly.unit))
        }
        return out
    }

    /// Every long limit, **worst tier first; on a tie the nearer reset first** (REV-96 §2.3).
    ///
    /// One comparator, two readers (STEP_198). The strip, the rank and the notification take the
    /// head of this list; the menu-bar reminder cycles through the elevated ones in this order
    /// (REV-97 §2.3 — "most severe first"). Before this existed the selection was a `max(by:)`
    /// here and the ordering would have been a second copy of the same rule in `DisplayFormatter`
    /// — which is exactly the drift §19 forbids.
    public func longLimitsRanked(now: Date) -> [LongLimitAssessment] {
        longLimitAssessments(now: now).sorted { a, b in
            if a.tier != b.tier { return a.tier > b.tier }
            if a.resetsAt != b.resetsAt { return a.resetsAt < b.resetsAt }
            // `sorted` is not stable, so the order is made **total** rather than left to the
            // input order: a weekly and a monthly at the same tier and the same instant would
            // otherwise alternate between two runs, and the reminder cycle would alternate with
            // them. Secondary before monthly, matching `longLimitAssessments`' own order.
            return a.limit == .secondary
        }
    }

    /// The one long limit that speaks: **the worst tier wins; on a tie the nearer reset wins**
    /// (REV-96 §2.3). Never two — one strip, one rank, one notification, so the user is told
    /// about the limit that will stop them first rather than about both at once.
    public func longLimit(now: Date) -> LongLimitAssessment? {
        longLimitsRanked(now: now).first
    }

    /// This limit's own assessment, when it has one — the row-suffix and hover-card lookup.
    public func longLimit(_ limit: BlockEpisode.Limit, now: Date) -> LongLimitAssessment? {
        longLimitAssessments(now: now).first { $0.limit == limit }
    }

    // MARK: The weekly, for notifications (Baseline §11.3/§16, REV-106 §2.3 — STEP_232)

    /// The one primary width the weekly ladder reads. Provider-reported, never inferred: Codex
    /// states 10 080 minutes on a Plus / Pro seat, and Claude's primary is never this wide.
    public static let weeklyPrimarySeconds = 7 * 86_400

    /// **The account's weekly, for §16 only** (REV-106 §2.3): the secondary window as
    /// `longLimitAssessments` builds it, otherwise a primary whose reported width is seven days,
    /// that is anchored, on a shape that is not low-allowance. Same tier rule, same two clocks —
    /// with one line moved: a seven-day primary is nearly spent at
    /// `weeklyPrimaryNearlySpentPct` (85), where its tab turns red, not at 90 (STEP_238).
    ///
    /// `NotificationEngine` is the only reader. `longLimitAssessments`, `longLimitsRanked` and
    /// `longLimit(now:)` keep excluding the primary, so the strip, ranks 5b and 10, the menu-bar
    /// reminder and every row are untouched by this — a seven-day primary is assessed so it can
    /// be *announced*, not so it can be re-tiered on screen.
    ///
    /// Out, deliberately: a monthly limit (no evidence on a monthly cycle), a per-model
    /// allowance (it stops a model, not the account), the 30-day Free / Go primary (REV-59:
    /// only Over quota fires there) and an unanchored weekly (no reset, so no pace and no
    /// instance to key on).
    public func weeklyForNotifications(now: Date) -> LongLimitAssessment? {
        if let secondary = longLimit(.secondary, now: now) { return secondary }
        guard primaryWindowSeconds == Self.weeklyPrimarySeconds, !isLowAllowanceShape,
              let used = primaryUsedPct, let reset = primaryResetsAt,
              let elapsed = paceElapsedPct(now: now) else { return nil }
        return LongLimitAssessment(
            limit: .primary,
            tier: Self.longLimitTier(usedPct: used, elapsedPct: elapsed,
                                     spentByFlag: rateLimitReached == true,
                                     nearlySpentPct: StateEngine.weeklyPrimaryNearlySpentPct),
            usedPct: used, elapsedPct: elapsed, resetsAt: reset,
            periodSeconds: Self.weeklyPrimarySeconds)
    }

    /// A window reset is only real when `resets_at` moves by more than this — the usage
    /// endpoint's `resets_at` wobbles ±1s between polls — and, dually, a window is only
    /// *expired* once `now` is more than this past its `resets_at` (R33-7). One tolerance for
    /// both readings of the same boundary; `StateEngine` aliases it (Baseline §9.2/§13.4).
    public static let resetJitterTolerance: TimeInterval = 60

    /// Whether a stored reset (unix seconds) and a live one are the **same instant** within that
    /// tolerance. One definition, read by every key that dedupes on a reset — `BlockEpisode` and
    /// `LongLimitAssessment` both compare through it rather than by string, because the provider
    /// wobbles `resets_at` by a second or two inside one window and a string match reads that
    /// wobble as a new instance (STEP_193's finding, generalised in STEP_194).
    public static func isSameResetInstant(_ storedEpoch: TimeInterval, _ date: Date) -> Bool {
        abs(storedEpoch - date.timeIntervalSince1970) <= resetJitterTolerance
    }

    /// An expired window **is** a null window (Baseline §13 item 12, R33-7): a window whose
    /// `resets_at` has passed beyond `resetJitterTolerance` describes spend that has already
    /// been forgiven, so its fields — including the hard-block flags, which are measurements
    /// *about that window* — degrade to the null shape before anyone reads them. Implemented
    /// once, here in Core, and shared by `StateEngine.classify` and `DisplayFormatter`, so the
    /// engine and the card can never disagree about whether a window is over. Returns `self`
    /// unchanged when nothing expired.
    ///
    /// Monthly analogue (REV-38, D-35 — the R33-7 rule at month scale): a `monthlyLimit` whose
    /// `resetsAt` has passed degrades to `nil` — its `used` describes credits already forgiven.
    /// `spendControlReached` anchors to the monthly reset **when a monthly limit exists**
    /// (`individual_limit.reset_at` is the block's recovery timestamp, Baseline §8.3 REV-38
    /// amendment): primary-window expiry then no longer clears the flag; monthly expiry does.
    /// Without a monthly limit the flag keeps its primary-window anchor (the windowed
    /// June-13-shaped block) exactly as before.
    /// The D-26 / D-33 **withdrawal** (REV-80 / D-101): a not-started primary window whose claim
    /// local evidence has falsified (JSONL activity postdating the poll) is rendered in the
    /// §2.2a unknown form — `——` hero, `—` verdict and rows, `——` menu bar — never as `100%`
    /// and never as "No active session". This is the one shape that reaches that form: the
    /// percent and its flags go nil, the width stays (a property of the plan, exactly as in
    /// `degradingExpiredWindows`), the weekly and monthly data are untouched. Display-only; the
    /// state engine never sees it.
    public func withdrawingPrimaryWindow() -> QuotaSnapshot {
        QuotaSnapshot(
            tool: tool,
            primaryUsedPct: nil,
            primaryResetsAt: nil,
            primaryWindowSeconds: primaryWindowSeconds,
            secondaryUsedPct: secondaryUsedPct,
            secondaryResetsAt: secondaryResetsAt,
            secondaryWindowSeconds: secondaryWindowSeconds,
            rateLimitReached: nil,
            extraUsage: extraUsage,
            prepaid: prepaid,
            rateLimitLimit: rateLimitLimit,
            rateLimitRemaining: rateLimitRemaining,
            rateLimitReset: rateLimitReset,
            spendControlReached: spendControlReached,
            rateLimitResetCreditsCount: rateLimitResetCreditsCount,
            creditsBalance: creditsBalance,
            additionalRateLimits: additionalRateLimits,
            monthlyLimit: monthlyLimit,
            source: source,
            nullWindowSource: nullWindowSource,
            email: email,
            planType: planType)
    }

    public func degradingExpiredWindows(now: Date) -> QuotaSnapshot {
        let tolerance = Self.resetJitterTolerance
        let primaryExpired = primaryResetsAt.map { now.timeIntervalSince($0) > tolerance } ?? false
        let secondaryExpired = secondaryResetsAt.map { now.timeIntervalSince($0) > tolerance } ?? false
        let monthlyExpired = monthlyLimit.map { now.timeIntervalSince($0.resetsAt) > tolerance } ?? false
        // R33-7 at sub-bucket grain (STEP_134), **per window since STEP_176**: a model window whose
        // own reset has passed describes spend already forgiven, exactly like a main window's, and
        // is cleared on its own — an expired five-hour Spark window must not take Spark's live
        // weekly with it, and one allowance expiring must not take its siblings. An allowance is
        // dropped only once it has no window left, which is exactly the single-reset behaviour
        // this rule had before the second window existed.
        let liveScopedLimits = additionalRateLimits.compactMap { limit -> AdditionalRateLimit? in
            let primaryGone = limit.resetsAt.map { now.timeIntervalSince($0) > tolerance } ?? false
            let secondaryGone = limit.secondary?.resetsAt
                .map { now.timeIntervalSince($0) > tolerance } ?? false
            if !primaryGone && !secondaryGone { return limit }
            let primary = primaryGone
                ? AdditionalRateLimit.Window(usedPercent: nil, resetsAt: nil,
                                             windowSeconds: limit.primaryWindowSeconds)
                : limit.primary
            let secondary = secondaryGone ? nil : limit.secondary
            // The width survives expiry, as the main window's does (it is a property of the
            // plan); an allowance with neither a percent nor a reset on any window is gone.
            if primary.usedPercent == nil, primary.resetsAt == nil, secondary == nil { return nil }
            return AdditionalRateLimit(id: limit.id, name: limit.name,
                                       usedPercent: primary.usedPercent, resetsAt: primary.resetsAt,
                                       primaryWindowSeconds: primary.windowSeconds,
                                       secondary: secondary)
        }
        let scopedExpired = liveScopedLimits != additionalRateLimits
        guard primaryExpired || secondaryExpired || monthlyExpired || scopedExpired else {
            return self
        }
        let spendControlExpired = monthlyLimit != nil ? monthlyExpired : primaryExpired
        return QuotaSnapshot(
            tool: tool,
            primaryUsedPct: primaryExpired ? nil : primaryUsedPct,
            primaryResetsAt: primaryExpired ? nil : primaryResetsAt,
            // The window's *width* is a property of the plan, not of the window that just ended —
            // it survives expiry so the next poll's unanchored check is not blind for one cycle.
            primaryWindowSeconds: primaryWindowSeconds,
            secondaryUsedPct: secondaryExpired ? nil : secondaryUsedPct,
            secondaryResetsAt: secondaryExpired ? nil : secondaryResetsAt,
            // The weekly width outlives its readings for the same reason the primary's does.
            secondaryWindowSeconds: secondaryWindowSeconds,
            rateLimitReached: primaryExpired ? nil : rateLimitReached,
            extraUsage: extraUsage,
            prepaid: prepaid,
            rateLimitLimit: rateLimitLimit,
            rateLimitRemaining: rateLimitRemaining,
            rateLimitReset: rateLimitReset,
            spendControlReached: spendControlExpired ? nil : spendControlReached,
            rateLimitResetCreditsCount: rateLimitResetCreditsCount,
            creditsBalance: creditsBalance,
            additionalRateLimits: liveScopedLimits,
            monthlyLimit: monthlyExpired ? nil : monthlyLimit,
            source: source,
            nullWindowSource: nullWindowSource,
            email: email,
            planType: planType)
    }
}

/// Claude pay-as-you-go `extra_usage` object (Baseline §7.1, §8.0.2).
///
/// When `isEnabled == false` and no credits were used this window, every optional field is
/// null — this is the normal Case 3 shape, not an error. `usedCredits` is a `Decimal`
/// (minor-unit money), never a binary `Double`.
public struct ExtraUsage: Sendable, Equatable {
    public let isEnabled: Bool
    /// Monthly cap in minor units/cents (e.g. `2000` → $20.00).
    public let monthlyLimit: Int?
    public let usedCredits: Decimal?
    public let utilization: Double?
    public let currency: String?
    public let disabledReason: String?
    /// True when `usedCredits`/`monthlyLimit` were filled from the §7.1 cached-value rule
    /// (toggle flipped off mid-window) rather than the live response — display must label the
    /// value "last observed", never present it as real-time. STEP_27.
    public let usedCreditsIsCached: Bool
    /// True when the credits were mapped from the `spend` meter of a seat that also reports a
    /// five-hour or weekly window (Claude Team — REV-102 / D-125, STEP_218): the organization
    /// pays and sets the cap, the member cannot toggle or top up. Never cached (§7.1).
    public let managedByOrganization: Bool
    /// Minor-unit exponent of `monthlyLimit`, carried from the `spend` money object. `nil` on
    /// the `extra_usage` path, where the cap is cents — read as 2.
    public let currencyExponent: Int?

    public init(
        isEnabled: Bool,
        monthlyLimit: Int? = nil,
        usedCredits: Decimal? = nil,
        utilization: Double? = nil,
        currency: String? = nil,
        disabledReason: String? = nil,
        usedCreditsIsCached: Bool = false,
        managedByOrganization: Bool = false,
        currencyExponent: Int? = nil
    ) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
        self.currency = currency
        self.disabledReason = disabledReason
        self.usedCreditsIsCached = usedCreditsIsCached
        self.managedByOrganization = managedByOrganization
        self.currencyExponent = currencyExponent
    }

    /// The cap in the units `usedCredits` is stated in (`monthlyLimit ÷ 10^exponent`) — the one
    /// home of that division, so the cap comparison and the display cannot disagree on it.
    public var monthlyLimitMajor: Decimal? {
        monthlyLimit.map { Decimal(sign: .plus, exponent: -(currencyExponent ?? 2),
                                   significand: Decimal($0)) }
    }

    /// The all-null disabled shape (Case 3 — hard block, no credits).
    public static let disabled = ExtraUsage(isEnabled: false)
}

/// Prepaid wallet + auto-reload state from `GET /api/oauth/organizations/<org_id>/prepaid/credits`
/// (the second OAuth call, Baseline §7.1, REV-29). Display-only. `autoReloadOn` is presence-only:
/// the populated `auto_reload_settings` shape is unconfirmed (P2-8 +a), so no dollar figure or
/// pre-emptive warning is asserted from it (§2.4a.5).
public struct PrepaidCredits: Sendable, Equatable {
    /// Wallet balance in minor units/cents (e.g. `3024` → $30.24). nil when absent.
    public let amountCents: Int?
    /// `auto_reload_settings != null` ⇒ on. nil when the field was absent from the response.
    public let autoReloadOn: Bool?
    /// When this wallet snapshot was fetched — drives the §2.4a.4 balance/reload freshness stamp,
    /// which ages independently of the quota poll (auto-reload is flipped out-of-band).
    public let asOf: Date?
    /// The wallet's own ISO currency code (STEP_219 — REV-102 §2.5: money renders in the
    /// currency the provider reports). nil when the response carried none.
    public let currency: String?

    public init(amountCents: Int?, autoReloadOn: Bool?, asOf: Date?, currency: String? = nil) {
        self.amountCents = amountCents
        self.autoReloadOn = autoReloadOn
        self.asOf = asOf
        self.currency = currency
    }
}

/// The unit a `MonthlyLimit`'s amounts are denominated in (REV-40, STEP_46). Codex monthly
/// limits are provider credits; Claude Enterprise monthly spend is money in minor units
/// (`amount_minor` + `exponent`, §8.0.4 — `6916` at exponent 2 = $69.16). The amounts stay
/// raw in the model; only the display divides by `10^exponent` (STEP_47).
public enum QuotaUnit: Sendable, Equatable {
    case credits
    case money(currency: String, exponent: Int)
}

/// Normalized per-user monthly limit — one model for both tools (REV-38 Codex credits,
/// REV-40 Claude Enterprise money; the unit rides in `unit`). Codex: Baseline §8.2
/// `spend_control.individual_limit` / RPC `rateLimits.individualLimit`, a workspace-wide pool
/// shared across ChatGPT and Codex, RPC primary / wham fallback. Claude Enterprise: §8.0.4
/// `spend`, single transport. Either way the pool's denominator is backend-scoped, so
/// pace/attribution must only ever use these backend numbers — never local token math
/// (§8.3 REV-38 amendment; §8.0.4 P2-11).
///
/// `source` is control metadata (e.g. `group_based_spend_controls`, or
/// `derived_calendar_month_utc` marking a client-derived Claude reset), is not persisted to
/// `poll_snapshots`, and comes back `nil` on launch restore.
public struct MonthlyLimit: Sendable, Equatable {
    /// Monthly ceiling in `unit` terms (Codex: credits, e.g. 4000; Claude: raw minor units).
    public let limitAmount: Double
    /// Amount consumed this cycle in `unit` terms — backend-reported.
    public let usedAmount: Double
    /// The backend's own integer remaining % — kept verbatim so the row layer never disagrees
    /// with the provider's UI by more than 1pt (R2 rule; the hero recomputes from
    /// `usedPercentExact`).
    public let remainingPercent: Int
    /// Cycle end — start of the next calendar month UTC (Codex: payload `reset_at`; Claude:
    /// client-derived, §8.0.4). Also `spend_control.reached`'s recovery timestamp (R33-1
    /// extension: the block survives staleness while this is future).
    public let resetsAt: Date
    /// Denomination of `limitAmount`/`usedAmount`. Persisted (STEP_46 unit columns).
    public let unit: QuotaUnit
    /// Codex `individual_limit.source` / Claude `derived_calendar_month_utc`. Not persisted.
    public let source: String?

    public init(
        limitAmount: Double,
        usedAmount: Double,
        remainingPercent: Int,
        resetsAt: Date,
        unit: QuotaUnit = .credits,
        source: String? = nil
    ) {
        self.limitAmount = limitAmount
        self.usedAmount = usedAmount
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.unit = unit
        self.source = source
    }

    /// Builds the normalized model from the raw transport fields, or `nil` when any required
    /// field is absent or unparseable. The endpoint sends `limit`/`used` as **strings**
    /// (`"5000"`, `"2376.905242651701"` — §8.2); `Double(_:)` is locale-independent by
    /// definition, so no `NumberFormatter` (a comma-decimal locale must never change parsing).
    public init?(
        limitString: String?,
        usedString: String?,
        remainingPercent: Int?,
        resetsAtUnixSeconds: Int?,
        source: String?
    ) {
        guard let limitString, let limit = Double(limitString),
              let usedString, let used = Double(usedString),
              let remainingPercent,
              let resetsAtUnixSeconds else { return nil }
        self.init(
            limitAmount: limit,
            usedAmount: used,
            remainingPercent: remainingPercent,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(resetsAtUnixSeconds)),
            source: source)
    }

    // MARK: Derivations (Baseline §8.2/§8.3 REV-38 — engine layer, consumed by STEP_44 display)

    /// Exact used % at 1% precision — the hero input (`used/limit`, D-34/E3). The quota row
    /// shows the backend's integer (`100 − remainingPercent`); this never drifts from it by
    /// > 1pt. `nil` on a non-positive limit (nothing meaningful to claim). Unit-independent.
    public var usedPercentExact: Double? {
        guard limitAmount > 0 else { return nil }
        return usedAmount / limitAmount * 100
    }

    /// Where this cycle began: `resetsAt` − 1 calendar month, UTC — the backend anchors the
    /// cycle to calendar months, so the length is 28–31 days and never a fixed 30. Extracted in
    /// STEP_194 because the §11.3 pace clock now points at the monthly too and must measure
    /// against the same cycle the pace divisor uses (Baseline §19: one derivation, two readers).
    public func cycleStart() -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(byAdding: .month, value: -1, to: resetsAt)
    }

    /// Days since the cycle started. The pace divisor, and the E6 confidence gate's
    /// days-elapsed input (UI Spec Part 2 §1.2/§2.2a).
    public func daysElapsedInCycle(now: Date) -> Double? {
        cycleStart().map { now.timeIntervalSince($0) / 86_400 }
    }

    /// The cycle's whole length in seconds — the long-limit assessment's period, and what turns
    /// `elapsedPctInCycle` into a real calendar share rather than a 30-day approximation.
    public func cycleSeconds() -> Double? {
        cycleStart().map { resetsAt.timeIntervalSince($0) }.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The §11.3 pace clock's elapsed hand, pointed at the monthly cycle (REV-96 §2.2/§3.3):
    /// how much of the *month* has gone, in percent. Unclamped, exactly like
    /// `QuotaSnapshot.paceElapsedPct` — a reading past the reset exceeds 100 and one before the
    /// cycle start goes negative; callers that display it clamp.
    public func elapsedPctInCycle(now: Date) -> Double? {
        guard let start = cycleStart(), let length = cycleSeconds() else { return nil }
        return now.timeIntervalSince(start) / length * 100
    }

    /// Average burn in `unit`/day this cycle: backend `used` ÷ `daysElapsedInCycle`. Single-
    /// reading cold start by design (§8.3 REV-38: never local token math). `nil` when less than
    /// one day has elapsed — a fresh cycle's divisor would assert an absurd pace, and the
    /// display's E6 gate wants a placeholder there anyway.
    public func pacePerDay(now: Date) -> Double? {
        guard let daysElapsed = daysElapsedInCycle(now: now), daysElapsed >= 1 else { return nil }
        return usedAmount / daysElapsed
    }

    /// Days until the pool empties at the current pace: `(limit − used) ÷ pace`, floored at 0
    /// (at or past the limit the runway is spent, not unknown). `nil` while pace is `nil` — a
    /// fresh cycle has no honest divisor. The one derivation behind the menu-bar `◔~Nd` slot,
    /// the forecast dot tier, and the verdict, so the three surfaces cannot disagree (§19,
    /// D-34/E8).
    public func runwayDays(now: Date) -> Double? {
        guard let pace = pacePerDay(now: now), pace > 0 else { return nil }
        return max(0, (limitAmount - usedAmount) / pace)
    }

    /// Start of the next calendar month UTC after `date` — the client-derived Claude Enterprise
    /// cycle end (§8.0.4 REV-40: the `spend` payload carries no reset timestamp; calendar-month
    /// UTC was verified out-of-band against claude.ai's own "Resets Aug 1, 00:00 UTC"). Gregorian,
    /// UTC-forced, mirroring `daysElapsedInCycle`. Always tagged `derived_calendar_month_utc` in
    /// `source` — never presented as payload data.
    public static func nextCalendarMonthStartUTC(after date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let monthInterval = calendar.dateInterval(of: .month, for: date) else { return nil }
        return monthInterval.end
    }
}
