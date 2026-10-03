import Foundation
import KvotarCore

/// Codex account-quota adapter (Baseline §8.1, §8.2, §8.3, §8.7, §5.2; task Step 9).
///
/// Applies the RPC-primary → `wham/usage`-fallback precedence (ARCHITECTURE.md §Data source map,
/// §Timeout chain): it tries the app-server RPC first and, on any RPC failure or 429, falls through
/// to the direct `wham/usage` client before surfacing an error. It normalizes either source into a
/// shared `QuotaSnapshot` and reports only — it owns no poll timer and never writes to
/// `SQLiteStore` (persistence is `writePoll`, owned by `PollEngine`).
///
/// Null-window rule (§8.3, §13): `rate_limit: null` (wham) or `primary: null` (RPC) is a healthy
/// no-active-window state — leave the window fields `nil` (display `—`), do not set a warning /
/// `rateLimitReached` on null alone.
///
/// `actor` because it caches cross-call identity (`email`, `planType`) and health under Swift 6
/// strict concurrency, matching `ClaudeAccountAdapter` and the `AccountAdapter` protocol's
/// `var health { get async }`.
public actor CodexAccountAdapter: AccountAdapter {

    private let rpc: CodexRPCPolling
    private let wham: CodexWhamClient
    private let metadataReader: CodexSQLiteMetadataReader
    private let overallBudget: Duration

    private var currentHealth: AdapterHealth = .unknown

    /// Thrown when a poll exceeds the §13.3 overall Codex budget across the RPC + wham legs.
    /// Surfaces to the caller as a generic failure → Idle/fallback (not a rate-limit).
    public struct OverallBudgetExceeded: Error {}

    /// Cached account identity — Codex carries `email`/`plan_type` on every RPC/wham response, but
    /// we still only expose them once resolved and reuse them if a later poll omits them (§8.0.3 /
    /// §8.2 identity handling).
    private var cachedEmail: String?
    private var cachedPlanType: String?

    /// Last observed unanchored-window verdict, so `noteUnanchored` logs edges, not levels.
    private var wasUnanchored = false

    /// The previous poll's **raw** `(when we asked, what the provider said)` pair — the input to the
    /// invariance clause below (REV-64 §4). Recorded *before* the rule nulls an unanchored anchor,
    /// because the dropped value is exactly what the next poll has to compare against.
    ///
    /// One slot serves both transports: a poll runs RPC **or** wham, never both — the monthly
    /// supplement calls `mergeWhamSupplement`, not `normalize(wham:)` — so the two can never
    /// interleave observations into this pair.
    private var lastRawAnchor: (askedAt: Date, resetsAt: Date)?

    /// - Parameter overallBudget: total wall-clock budget across the RPC + wham legs of one poll
    ///   (Baseline §13.3: 18s; RPC worst case ≈12s + wham 10s would otherwise reach ≈22s).
    public init(
        rpc: CodexRPCPolling,
        wham: CodexWhamClient,
        metadataReader: CodexSQLiteMetadataReader = CodexSQLiteMetadataReader(),
        overallBudget: Duration = .seconds(18)
    ) {
        self.rpc = rpc
        self.wham = wham
        self.metadataReader = metadataReader
        self.overallBudget = overallBudget
    }

    public var health: AdapterHealth { currentHealth }

    // MARK: - AccountAdapter

    /// One poll with RPC → wham precedence, bounded by the §13.3 overall Codex budget. Any RPC error
    /// (timeout, crash, 429, or unavailable binary) falls through to `wham/usage` before an error is
    /// surfaced (ARCHITECTURE.md §Data source map; on RPC 429, fall through before counting the 429,
    /// §9.3). If the combined RPC + wham sequence exceeds `overallBudget`, both legs are cancelled
    /// and `OverallBudgetExceeded` is thrown → Idle/fallback.
    public func fetchQuotaSnapshot() async throws -> QuotaSnapshot {
        do {
            return try await withDeadline(overallBudget) { try await self.fetchQuotaSnapshotInner() }
        } catch is OverallBudgetExceeded {
            currentHealth = .unknown
            Logger.warning("Codex poll exceeded overall budget", component: .codexAccountAdapter,
                           metadata: ["budget": "\(overallBudget)"])
            throw OverallBudgetExceeded()
        }
    }

    /// Runs `work` but throws `OverallBudgetExceeded` if it outlasts `budget`. The losing branch is
    /// cancelled; because `CodexRPCClient.call` is cancellation-aware and wham is a URLSession fetch,
    /// both legs unwind promptly on expiry.
    private func withDeadline<T: Sendable>(
        _ budget: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: budget)
                throw OverallBudgetExceeded()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func fetchQuotaSnapshotInner() async throws -> QuotaSnapshot {
        do {
            let (account, rateLimits) = try await rpc.poll()
            var snapshot = normalize(account: account, rateLimits: rateLimits)
            snapshot = await supplementMonthlyLimitIfNeeded(snapshot)
            snapshot = applyUsageLimitedSignal(to: snapshot)
            currentHealth = .healthy
            logPoll("RPC", snapshot)
            return snapshot
        } catch {
            Logger.info("Codex RPC unavailable — falling through to wham/usage",
                        component: .codexAccountAdapter, metadata: ["error": "\(error)"])
            return try await fetchViaWham()
        }
    }

    private func fetchViaWham() async throws -> QuotaSnapshot {
        do {
            let result = try await wham.fetchUsage()
            let snapshot = applyUsageLimitedSignal(to: normalize(wham: result.usage, headers: result.headers))
            currentHealth = .healthy
            logPoll("wham", snapshot)
            return snapshot
        } catch let error as AccountAdapterError {
            currentHealth = Self.health(for: error)
            throw error
        } catch {
            currentHealth = .unknown
            Logger.warning("Codex wham/usage fallback failed",
                           component: .codexAccountAdapter, metadata: Logger.metadata(for: error))
            throw error
        }
    }

    // MARK: - Normalization: RPC (Baseline §8.1)

    /// Maps the two RPC result payloads into a `QuotaSnapshot`. Windows are taken from
    /// `account/rateLimits/read`; `null` primary/secondary → Null-window (fields `nil`, no warning).
    /// **`spendControlReached` *is* carried by RPC** (STEP_98, corrected from the opposite claim):
    /// the 2026-08-12 capture shows it on every `account/rateLimits/read` body, beside
    /// `rateLimitReachedType`. **Banked resets** (`rateLimitResetCredits`) are the half that
    /// remains wham-only here — the RPC body does carry them, but nothing below maps them.
    /// An **unanchored** primary window loses its reset here (REV-57 §4/§5).
    func normalize(account: CodexAccountRead, rateLimits: CodexRateLimits,
                   now: Date = Date()) -> QuotaSnapshot {
        mergeIdentity(email: account.account.email,
                      planType: account.account.planType ?? rateLimits.rateLimits.planType)

        let limits = rateLimits.rateLimits
        let primary = limits.primary
        let secondary = limits.secondary

        // RPC reports the window width in minutes; wham in seconds. Normalize to seconds here so
        // the rule below and `QuotaSnapshot` speak one unit (REV-57 §4.1).
        let primaryWindowSeconds = primary?.windowDurationMins.map { $0 * 60 }
        let primaryResetsAt = Self.date(primary?.resetsAt)
        let unanchored = Self.isUnanchoredWindow(
            usedPct: primary?.usedPercent, resetsAt: primaryResetsAt,
            windowSeconds: primaryWindowSeconds, now: now, previous: lastRawAnchor)
        recordRawAnchor(resetsAt: primaryResetsAt, windowSeconds: primaryWindowSeconds,
                        usedPct: primary?.usedPercent, askedAt: now)
        noteUnanchored(unanchored, source: "RPC", windowSeconds: primaryWindowSeconds)

        // D1: working assumption — validate when blocked-state captured.
        // RPC blocked shape is unconfirmed; when windows are null we treat it as healthy/no-active
        // window and defer over-quota detection to wham (§8.3, §20 D1). With windows present, a
        // non-nil `rateLimitReachedType` is the provisional over-quota signal.
        let reached: Bool?
        if primary == nil && secondary == nil {
            reached = nil
        } else {
            reached = limits.rateLimitReachedType != nil
        }

        return QuotaSnapshot(
            tool: .codex,
            // Utilization survives an unanchored window — 0% is true and useful; only the
            // deadline was fiction (REV-57 §4).
            primaryUsedPct: primary?.usedPercent,
            primaryResetsAt: unanchored ? nil : primaryResetsAt,
            primaryWindowSeconds: primaryWindowSeconds,
            secondaryUsedPct: secondary?.usedPercent,
            secondaryResetsAt: Self.date(secondary?.resetsAt),
            // Same minutes → seconds normalization as the primary above (STEP_188): the wire has
            // always carried this and nothing read it.
            secondaryWindowSeconds: secondary?.windowDurationMins.map { $0 * 60 },
            rateLimitReached: reached,
            // Codex `credits`/`extra_usage` is Alpha-deferred (P2-7 / A2, §8.1 "Extra charge row
            // (Alpha)"): `credits` is null on Enterprise (the only validated plan), so `.disabled`
            // is intentional here, not an unhandled field.
            extraUsage: .disabled,
            spendControlReached: limits.spendControlReached,
            rateLimitResetCreditsCount: nil,
            creditsBalance: limits.credits?.balance,
            additionalRateLimits: Self.additionalLimits(from: rateLimits, now: now),
            monthlyLimit: Self.monthlyLimit(from: limits.individualLimit),
            source: .appServerRPC,
            email: cachedEmail,
            planType: cachedPlanType
        )
    }

    /// Live Enterprise/Business accounts can return a healthy RPC null-window with no
    /// `individualLimit`, while `wham/usage` carries the monthly workspace limit. Treat wham as a
    /// field supplement in that narrow shape instead of letting the next RPC poll erase the monthly
    /// layout. Supplement failure is non-fatal: the RPC poll remains healthy.
    private func supplementMonthlyLimitIfNeeded(_ snapshot: QuotaSnapshot) async -> QuotaSnapshot {
        guard snapshot.monthlyLimit == nil,
              snapshot.isNullWindow,
              Self.isPeriodQuotaPlan(snapshot.planType)
        else { return snapshot }

        do {
            let result = try await wham.fetchUsage()
            guard let monthly = Self.monthlyLimit(from: result.usage.spendControl?.individualLimit) else {
                return snapshot
            }
            Logger.info("Codex RPC missing monthly limit — supplemented from wham/usage",
                        component: .codexAccountAdapter,
                        metadata: ["plan": snapshot.planType ?? "unknown"])
            return Self.mergeWhamSupplement(into: snapshot, usage: result.usage,
                                            headers: result.headers, monthly: monthly, now: Date())
        } catch {
            Logger.info("Codex monthly supplement unavailable — keeping RPC poll",
                        component: .codexAccountAdapter,
                        metadata: ["error": "\(error)"])
            return snapshot
        }
    }

    private static func isPeriodQuotaPlan(_ planType: String?) -> Bool {
        guard let planType = planType?.lowercased() else { return false }
        return planType == "enterprise" || planType == "business"
    }

    private static func mergeWhamSupplement(into snapshot: QuotaSnapshot,
                                            usage: CodexWhamUsage,
                                            headers: CodexRateLimitHeaders,
                                            monthly: MonthlyLimit,
                                            now: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: snapshot.tool,
            primaryUsedPct: snapshot.primaryUsedPct,
            primaryResetsAt: snapshot.primaryResetsAt,
            primaryWindowSeconds: snapshot.primaryWindowSeconds,
            secondaryUsedPct: snapshot.secondaryUsedPct,
            secondaryResetsAt: snapshot.secondaryResetsAt,
            // Carried for completeness; this path is null-window-gated, so it is always nil here.
            secondaryWindowSeconds: snapshot.secondaryWindowSeconds,
            rateLimitReached: snapshot.rateLimitReached,
            extraUsage: snapshot.extraUsage,
            prepaid: snapshot.prepaid,
            rateLimitLimit: snapshot.rateLimitLimit ?? headers.limit,
            rateLimitRemaining: snapshot.rateLimitRemaining ?? headers.remaining,
            rateLimitReset: snapshot.rateLimitReset ?? headers.reset,
            spendControlReached: usage.spendControl?.reached ?? snapshot.spendControlReached,
            rateLimitResetCreditsCount: usage.rateLimitResetCredits?.availableCount
                ?? snapshot.rateLimitResetCreditsCount,
            creditsBalance: usage.credits?.balance ?? snapshot.creditsBalance,
            additionalRateLimits: snapshot.additionalRateLimits.isEmpty
                ? additionalLimits(fromWham: usage.additionalRateLimits, now: now)
                : snapshot.additionalRateLimits,
            monthlyLimit: monthly,
            source: .wham,
            nullWindowSource: snapshot.nullWindowSource,
            email: snapshot.email ?? usage.email,
            planType: snapshot.planType ?? usage.planType
        )
    }

    /// Extracts the non-primary entries of `rateLimitsByLimitId` as model allowances, **every
    /// window intact** (STEP_176 — Baseline §15.2). Confirmed 2026-09-10: the main `codex` entry
    /// does appear in the dictionary (skipped by id), and `codex_bengalfox` (Spark) carries a full
    /// `Limits` object with `primary` 300 min and `secondary` 10 080 min — the RPC decoder already
    /// decoded both; only this mapper was throwing them away. Sorted by key for a stable order.
    static func additionalLimits(from rateLimits: CodexRateLimits,
                                 now: Date = Date()) -> [AdditionalRateLimit] {
        guard let byId = rateLimits.rateLimitsByLimitId else { return [] }
        let primaryId = rateLimits.rateLimits.limitId
        return byId
            .filter { key, entry in key != primaryId && entry.limitId != primaryId }
            .sorted { $0.key < $1.key }
            .map { key, entry in
                let primary = modelWindow(usedPct: entry.primary?.usedPercent,
                                          resetsAt: date(entry.primary?.resetsAt),
                                          windowSeconds: entry.primary?.windowDurationMins.map { $0 * 60 },
                                          now: now)
                let secondary = entry.secondary.map {
                    modelWindow(usedPct: $0.usedPercent, resetsAt: date($0.resetsAt),
                                windowSeconds: $0.windowDurationMins.map { $0 * 60 }, now: now)
                }
                return AdditionalRateLimit(
                    id: entry.limitId ?? key,
                    name: entry.limitName,
                    usedPercent: primary.usedPercent,
                    resetsAt: primary.resetsAt,
                    primaryWindowSeconds: primary.windowSeconds,
                    secondary: secondary)
            }
    }

    /// The wham twin (STEP_176), shared by `normalize(wham:)` and `mergeWhamSupplement` so the
    /// monthly-supplement path cannot silently lose a window the direct path keeps. The nested
    /// `rate_limit` object is the captured shape; the flat pre-capture fields are the fallback.
    /// `id` is `metered_feature` — the same key RPC sorts by — so the two transports name one
    /// allowance identically. Provider order is kept (the array is already the provider's list).
    static func additionalLimits(fromWham entries: [CodexWhamUsage.AdditionalLimit]?,
                                 now: Date) -> [AdditionalRateLimit] {
        (entries ?? []).map { entry in
            let primaryRaw = entry.rateLimit?.primaryWindow ?? entry.primaryWindow
            let primary = modelWindow(usedPct: primaryRaw?.usedPercent ?? entry.usedPercent,
                                      resetsAt: date(primaryRaw?.resetAt ?? entry.resetAt),
                                      windowSeconds: primaryRaw?.limitWindowSeconds,
                                      now: now)
            let secondary = entry.rateLimit?.secondaryWindow.map {
                modelWindow(usedPct: $0.usedPercent, resetsAt: date($0.resetAt),
                            windowSeconds: $0.limitWindowSeconds, now: now)
            }
            return AdditionalRateLimit(
                id: entry.meteredFeature ?? entry.limitId,
                name: entry.limitName,
                usedPercent: primary.usedPercent,
                resetsAt: primary.resetsAt,
                primaryWindowSeconds: primary.windowSeconds,
                secondary: secondary)
        }
    }

    /// One model window, with REV-57's **two-clause** unanchored rule applied (0 % used and a
    /// deadline sitting exactly one width out): the deadline is dropped, the 0 % kept. Observed on
    /// Spark's five-hour window on both transports (2026-09-10: `reset_after_seconds` exactly
    /// 18 000, and the RPC and wham probes 54 s apart reported deadlines 54 s apart — recomputed
    /// per request, the REV-57 signature). STEP_102's third clause (drift across polls) is
    /// deliberately **not** applied here: it needs a per-window predecessor, and nothing fires on
    /// a model window — no reset detection, no notification, no forecast — so the cost of the
    /// two-clause rule is at most the ≤ 60 s "not started" flash on a display row at a genuine
    /// window start, never the storm the third clause was written to prevent.
    static func modelWindow(usedPct: Double?, resetsAt: Date?, windowSeconds: Int?,
                            now: Date) -> AdditionalRateLimit.Window {
        let unanchored = isUnanchoredCandidate(usedPct: usedPct, resetsAt: resetsAt,
                                               windowSeconds: windowSeconds, now: now)
        return AdditionalRateLimit.Window(usedPercent: usedPct,
                                          resetsAt: unanchored ? nil : resetsAt,
                                          windowSeconds: windowSeconds)
    }

    // MARK: - Normalization: wham/usage (Baseline §8.2, §8.3)

    /// Maps a `wham/usage` response into a `QuotaSnapshot`. `rate_limit: null` → Null-window
    /// (fields `nil`, no warning). `spend_control.reached` and banked resets are carried here.
    /// `headers` are the rate-limit headers observed on the same response (Step 10, §9.2) — the
    /// RPC path has no HTTP headers, so `normalize(account:rateLimits:)` never populates these.
    func normalize(wham usage: CodexWhamUsage, headers: CodexRateLimitHeaders = .empty,
                   now: Date = Date()) -> QuotaSnapshot {
        mergeIdentity(email: usage.email, planType: usage.planType)

        let rateLimit = usage.rateLimit
        let primary = rateLimit?.primaryWindow
        let secondary = rateLimit?.secondaryWindow

        // Already seconds on this transport (`limit_window_seconds`); the RPC twin converts from
        // minutes. Same rule, same units, so the two sources cannot disagree (REV-57 §5).
        let primaryWindowSeconds = primary?.limitWindowSeconds
        let primaryResetsAt = Self.date(primary?.resetAt)
        let unanchored = Self.isUnanchoredWindow(
            usedPct: primary?.usedPercent, resetsAt: primaryResetsAt,
            windowSeconds: primaryWindowSeconds, now: now, previous: lastRawAnchor)
        recordRawAnchor(resetsAt: primaryResetsAt, windowSeconds: primaryWindowSeconds,
                        usedPct: primary?.usedPercent, askedAt: now)
        noteUnanchored(unanchored, source: "wham", windowSeconds: primaryWindowSeconds)

        // D1: working assumption — validate when blocked-state captured.
        // `rate_limit: null` = healthy/no-active-window → nil (§8.3). Otherwise `limit_reached`
        // is the provisional over-quota trigger (§8.2, §20 D1).
        let reached: Bool? = rateLimit == nil ? nil : (rateLimit?.limitReached ?? false)

        return QuotaSnapshot(
            tool: .codex,
            primaryUsedPct: primary?.usedPercent,
            primaryResetsAt: unanchored ? nil : primaryResetsAt,
            primaryWindowSeconds: primaryWindowSeconds,
            secondaryUsedPct: secondary?.usedPercent,
            secondaryResetsAt: Self.date(secondary?.resetAt),
            // Already seconds on this transport, exactly as the primary width above (STEP_188).
            secondaryWindowSeconds: secondary?.limitWindowSeconds,
            rateLimitReached: reached,
            // Codex `credits`/`extra_usage` Alpha-deferred (P2-7 / A2, §8.1) — null on Enterprise,
            // so `.disabled` is intentional. See the RPC normalize path above.
            extraUsage: .disabled,
            rateLimitLimit: headers.limit,
            rateLimitRemaining: headers.remaining,
            rateLimitReset: headers.reset,
            spendControlReached: usage.spendControl?.reached,
            rateLimitResetCreditsCount: usage.rateLimitResetCredits?.availableCount,
            creditsBalance: usage.credits?.balance,
            additionalRateLimits: Self.additionalLimits(fromWham: usage.additionalRateLimits, now: now),
            monthlyLimit: Self.monthlyLimit(from: usage.spendControl?.individualLimit),
            source: .wham,
            email: cachedEmail,
            planType: cachedPlanType
        )
    }

    // MARK: - Helpers

    /// RPC `individualLimit` → normalized `MonthlyLimit` (Baseline §8.2, REV-38). `nil` when the
    /// field is null/absent (no monthly limit configured) or a required numeric fails to parse —
    /// string parsing is `MonthlyLimit`'s locale-safe failable init, shared with the wham twin.
    static func monthlyLimit(from limit: CodexRateLimits.IndividualLimit?) -> MonthlyLimit? {
        guard let limit else { return nil }
        return MonthlyLimit(
            limitString: limit.limit,
            usedString: limit.used,
            remainingPercent: limit.remainingPercent,
            resetsAtUnixSeconds: limit.resetsAt,
            source: limit.source)
    }

    /// wham `spend_control.individual_limit` → normalized `MonthlyLimit` — same rule as the RPC
    /// twin above; only the transport key set differs (`resetAt` vs `resetsAt`).
    static func monthlyLimit(from limit: CodexWhamUsage.IndividualLimit?) -> MonthlyLimit? {
        guard let limit else { return nil }
        return MonthlyLimit(
            limitString: limit.limit,
            usedString: limit.used,
            remainingPercent: limit.remainingPercent,
            resetsAtUnixSeconds: limit.resetAt,
            source: limit.source)
    }

    /// Folds in `goals_1.sqlite`'s `usage_limited` signal (Baseline §8.5, task Step 12) —
    /// opportunistic secondary over-quota detection alongside the primary RPC/wham windows.
    /// Only ever turns `rateLimitReached` on; a normal/empty `thread_goals` table never clears
    /// a `true` that RPC/wham already reported.
    private func applyUsageLimitedSignal(to snapshot: QuotaSnapshot) -> QuotaSnapshot {
        guard metadataReader.hasUsageLimitedGoal() else { return snapshot }
        return QuotaSnapshot(
            tool: snapshot.tool,
            primaryUsedPct: snapshot.primaryUsedPct,
            primaryResetsAt: snapshot.primaryResetsAt,
            primaryWindowSeconds: snapshot.primaryWindowSeconds,
            secondaryUsedPct: snapshot.secondaryUsedPct,
            secondaryResetsAt: snapshot.secondaryResetsAt,
            secondaryWindowSeconds: snapshot.secondaryWindowSeconds,
            rateLimitReached: true,
            extraUsage: snapshot.extraUsage,
            rateLimitLimit: snapshot.rateLimitLimit,
            rateLimitRemaining: snapshot.rateLimitRemaining,
            rateLimitReset: snapshot.rateLimitReset,
            spendControlReached: snapshot.spendControlReached,
            rateLimitResetCreditsCount: snapshot.rateLimitResetCreditsCount,
            creditsBalance: snapshot.creditsBalance,
            additionalRateLimits: snapshot.additionalRateLimits,
            monthlyLimit: snapshot.monthlyLimit,
            source: snapshot.source,
            email: snapshot.email,
            planType: snapshot.planType
        )
    }

    /// Updates the cached identity, keeping a previously-resolved value when a later poll omits it.
    private func mergeIdentity(email: String?, planType: String?) {
        if let email { cachedEmail = email }
        if let planType { cachedPlanType = planType }
    }

    private static func date(_ unixSeconds: Int?) -> Date? {
        unixSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    // MARK: - Unanchored windows (REV-57 §4)

    /// **An unanchored window is not a window.**
    ///
    /// While `used_percent == 0` the Codex backend answers a hypothetical rather than saying "no
    /// window is open": it returns `reset_at = request_time + limit_window_seconds`, recomputed on
    /// **every** request (spike F4/R19/R20). The reported deadline therefore slides forward with
    /// wall-clock, advancing by exactly one poll gap per poll — and every guard that asks "did the
    /// reset move?" is comparing the advance against the poll cadence itself, which it cannot win
    /// (REV-57 §3: 89 reset notifications in 90 minutes, one per poll, plus a matching run of
    /// fabricated `discontinuity_events` rows).
    ///
    /// **Three clauses, all required** *(third added REV-64 §4 / STEP_102)*.
    ///
    /// `used_percent == 0` was documented here as the clause that keeps a real window "that happens
    /// to sit one window-width out — possible for a single poll right after a genuine reset" from
    /// being read as one that never started. **It cannot do that job, and the claim is withdrawn.**
    /// A window is anchored by its *first turn*, whose usage has not registered yet, so 0% is the
    /// **normal** condition at a genuine start, not the exception. The two clauses do not vote
    /// independently — they fire together, exactly when they must not. Captured 2026-08-13
    /// 10:34:47, twenty seconds after a real window opened: the true anchor sat 604,780s out,
    /// inside the 60s band, and was discarded. It stays as a **conservative guard** (it costs
    /// nothing and the provider does tie the behaviour to 0%), no longer as the disambiguator.
    ///
    /// The clause that *does* distinguish them keys on the placeholder's real defining property:
    /// not its **value** but its **invariance**. The backend recomputes `reset_at = request_time +
    /// width` on every request, so `reset − now` is **constant across polls**; a real anchor is
    /// fixed in absolute time, so its `reset − now` **shrinks by the elapsed time**. Measured on
    /// the captured sequence: 0s drift between two placeholder polls, 20s at the real start, 62s
    /// across a 62s gap once anchored, and 0s across an 89-minute sleep.
    ///
    /// **Strictly narrowing, which is the safety argument.** A third *required* clause can only
    /// make the rule fire **less** often, so REV-57's 87-notification storm cannot return — bounded
    /// in the safe direction by construction, not by tuning. It is also **gap-independent**:
    /// invariance holds across a 90-minute sleep exactly as across a 60s poll, so nothing here is
    /// expressed as a fraction of the cadence (what defeated all four of REV-57's original guards).
    /// And it does not reopen §13.4's ruling that "no threshold expressed in seconds can
    /// distinguish a sliding anchor from the cadence" — that ruling is about a threshold on the
    /// anchor's *value*; this compares two consecutive observations of the same quantity.
    ///
    /// **The cost, stated rather than glossed:** the rule is no longer a pure static function of
    /// `now`. REV-57 chose statelessness deliberately; STEP_102 spends it, because invariance is
    /// the only signal keyed on what the provider actually does rather than on a coincidence of
    /// arithmetic. `previous` is the caller's retained raw pair; **nil (the first poll of a
    /// process) falls back to the two-clause rule** — bounded at one poll, and REV-64 §11 rules
    /// against persisting the pair across relaunches to close it.
    ///
    /// Claude does not use this rule: its adapter produces the unanchored shape directly from a
    /// present `five_hour` with `resets_at: null` (REV-80 / D-101 — before that it set no width
    /// at all, and the guard exited on the first line). The sliding-anchor rule stays Codex-only
    /// by construction, not by a tool check —
    /// keying on `plan_type` is what D-34 rejected, and the grain varies by plan anyway (five
    /// hours on Plus/Pro/Business, 30 days on Free/Go — spike S2/S4).
    static func isUnanchoredWindow(
        usedPct: Double?, resetsAt: Date?, windowSeconds: Int?, now: Date,
        previous: (askedAt: Date, resetsAt: Date)? = nil
    ) -> Bool {
        guard isUnanchoredCandidate(usedPct: usedPct, resetsAt: resetsAt,
                                    windowSeconds: windowSeconds, now: now),
              let resetsAt else { return false }
        guard let previous else { return true }
        let drift = previous.resetsAt.timeIntervalSince(previous.askedAt)
            - resetsAt.timeIntervalSince(now)
        return abs(drift) <= anchorDriftTolerance
    }

    /// REV-57's original two clauses, on their own: 0% used, and a deadline sitting one window
    /// width out within the jitter tolerance. Two jobs, which is why it is named rather than
    /// inlined — it decides whether the rule *may* engage at all, **and** whether this reading is
    /// a usable predecessor for the next poll's drift comparison.
    ///
    /// **Only a placeholder-shaped reading is a usable predecessor** *(STEP_102, found in test —
    /// REV-64 §4 does not say this and its worked table does not cover the case)*. Drift answers
    /// "is the provider recomputing this deadline, or is it standing still?", and that question is
    /// only meaningful when the previous reading was a candidate for the same answer. Feed it a
    /// **live anchored** window instead and the arithmetic is nonsense: at the 2026-08-13
    /// withdrawal the predecessor was a real 3%-used anchor 583,313 s out and the successor a fresh
    /// placeholder 604,800 s out, giving 21,487 s of "drift" — so the withdrawal poll would read as
    /// a **real anchor**, `StateEngine`'s advance clause would fire against the dead one, and the
    /// step would fabricate the very `window_reset` row it exists to delete. Falling back to the
    /// two-clause rule there restores the pre-STEP_102 verdict, which was already correct for this
    /// shape, and hands the demolition branch the unanchored snapshot it keys on.
    static func isUnanchoredCandidate(
        usedPct: Double?, resetsAt: Date?, windowSeconds: Int?, now: Date
    ) -> Bool {
        guard let windowSeconds, let resetsAt, usedPct == 0 else { return false }
        let overshoot = resetsAt.timeIntervalSince(now) - TimeInterval(windowSeconds)
        return abs(overshoot) <= QuotaSnapshot.resetJitterTolerance
    }

    /// How far `reset − now` may move between two polls and still read as the provider recomputing
    /// its placeholder rather than a real anchor standing still (REV-64 §4). Observed placeholder
    /// drift is **exactly 0s** on every captured poll, against the ±1s endpoint wobble REV-57
    /// documents — the margin is not delicate.
    ///
    /// Unlike the 60s jitter band this constant is **not load-bearing**: widening it degrades
    /// toward the pre-STEP_102 behaviour (a `not started` flash of up to one poll at a genuine
    /// window start), never toward the notification storm.
    static let anchorDriftTolerance: TimeInterval = 5

    /// Retains this poll's **raw** pair for the next poll's invariance clause — called with the
    /// value straight off the payload, *before* `QuotaSnapshot` is built with the anchor nulled.
    /// A payload carrying no anchor at all (a provider null-window) clears the pair: there is
    /// nothing to be invariant about, and a stale pair from before the gap would compare two
    /// unrelated windows.
    private func recordRawAnchor(resetsAt: Date?, windowSeconds: Int?, usedPct: Double?,
                                 askedAt: Date) {
        guard let resetsAt,
              Self.isUnanchoredCandidate(usedPct: usedPct, resetsAt: resetsAt,
                                         windowSeconds: windowSeconds, now: askedAt)
        else {
            lastRawAnchor = nil
            return
        }
        lastRawAnchor = (askedAt: askedAt, resetsAt: resetsAt)
    }

    /// Logs the unanchored window on **transition only** — this state persists for as long as the
    /// user leaves the quota untouched (days, on a 30-day grain), and a per-poll line would be the
    /// log-noise twin of the notification storm this rule exists to stop.
    private func noteUnanchored(_ unanchored: Bool, source: String, windowSeconds: Int?) {
        guard unanchored != wasUnanchored else { return }
        wasUnanchored = unanchored
        if unanchored {
            Logger.info("Codex window not started — reset anchor dropped",
                        component: .codexAccountAdapter,
                        metadata: ["source": source,
                                   "window_seconds": windowSeconds.map(String.init) ?? "—"])
        } else {
            Logger.info("Codex window anchored", component: .codexAccountAdapter,
                        metadata: ["source": source])
        }
    }

    private static func health(for error: AccountAdapterError) -> AdapterHealth {
        switch error {
        case .reauthRequired: return .reauthRequired
        case .setupRequired: return .setupRequired
        case .rateLimited(let retryAfter, _): return .rateLimited(retryAfter: retryAfter)
        // `.credentialUnreadable` is deliberately **not** `.setupRequired` (STEP_117 / REV-71
        // §3.2): we could not read `auth.json`, which says nothing about whether the user is
        // signed in. `.unknown` is the existing "detected, currently failing" health and forks no
        // display state, so the popover takes the idle path rather than the first-run welcome.
        case .credentialUnreadable: return .unknown
        // Codex never throws `.credentialExpired` (its auth posture differs — the expiry gate is
        // Claude-only, §8.0.1/STEP_48); mapped for exhaustiveness only.
        case .credentialExpired, .httpStatus, .decoding: return .unknown
        }
    }

    private func logPoll(_ source: String, _ snapshot: QuotaSnapshot) {
        Logger.info("Codex poll complete", component: .codexAccountAdapter,
                    metadata: [
                        "source": source,
                        "window": snapshot.isNullWindow ? "null" : "tracked",
                        "primary": snapshot.primaryUsedPct.map { "\(Int($0))%" } ?? "—",
                        "reached": snapshot.rateLimitReached.map { "\($0)" } ?? "n/a",
                        "spend_control": snapshot.spendControlReached.map { "\($0)" } ?? "n/a",
                        "monthly": snapshot.monthlyLimit == nil ? "missing" : "present",
                        // STEP_176 — one token per model allowance, both windows:
                        // `GPT-5.3-Codex-Spark:0%/0%` (primary/secondary; `—` = not reported).
                        "scoped": snapshot.additionalRateLimits.isEmpty ? "none"
                            : snapshot.additionalRateLimits.map { limit in
                                let name = limit.name ?? limit.id ?? "?"
                                let p = limit.usedPercent.map { "\(Int($0))%" } ?? "—"
                                let s = limit.secondary.map { $0.usedPercent.map { "\(Int($0))%" } ?? "—" }
                                return s.map { "\(name):\(p)/\($0)" } ?? "\(name):\(p)"
                            }.joined(separator: ","),
                        "plan": cachedPlanType ?? "unknown",
                        "email": cachedEmail == nil ? "none" : "<redacted>",
                    ])
    }
}
