import Foundation
import KvotarCore

/// Claude OAuth account adapter (Baseline §8.0, §7.1, §5.1; task Step 6).
///
/// Reads the Keychain token via an injected `ClaudeTokenProvider`, calls the OAuth usage and
/// (startup-only) profile endpoints via an injected `HTTPFetcher`, and returns a normalized
/// `QuotaSnapshot`. It owns no poll timer and never writes to `SQLiteStore` — it only reports
/// (ARCHITECTURE.md §Adapter protocols). Cadence and persistence belong to `PollEngine`.
///
/// Implemented as an `actor` because it caches cross-call state (account email, the Case 2
/// mid-window credits value, and current health) that must be accessed safely under Swift 6
/// strict concurrency; the `AccountAdapter` protocol's `var health { get async }` already
/// implies actor isolation.
public actor ClaudeAccountAdapter: AccountAdapter {

    // MARK: Endpoints (Baseline §8.0.2, §8.0.3, §7.1)
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let profileBetaHeader = "oauth-2025-04-20"

    /// Second OAuth call: prepaid wallet + auto-reload (REV-29). `<org_id>` is the profile's
    /// `organization.uuid`. Live-confirmed 2026-07-10.
    static func prepaidURL(orgId: String) -> URL? {
        URL(string: "https://api.anthropic.com/api/oauth/organizations/\(orgId)/prepaid/credits")
    }

    /// The prepaid wallet changes out-of-band and rarely; refetch at most once per this interval
    /// so the second call adds ~7% to OAuth request volume, not 100% (REV-14 throttle risk). Its
    /// own §2.4a.4 age stamp makes the resulting staleness honest.
    static let prepaidMinInterval: TimeInterval = 900

    /// A gap larger than this since the last successful poll marks the next poll as "cold" — the
    /// first poll after a long idle/sleep gap (§20 P1-12, REV-37). Its secondary OAuth calls
    /// (profile, prepaid) are deferred one cadence so we present the minimum footprint on the
    /// shared credential at the contended wake moment. Set above the §9.2 jittered steady-state
    /// max (300 + 5s) so a normal slow-cadence poll is never mistaken for a wake, and below both
    /// `prepaidMinInterval` and the §9.3 `retryAfterCap` so a wake or a post-rate-limit recovery
    /// poll correctly counts as cold.
    static let coldPollThreshold: TimeInterval = 330

    /// The usage endpoint reports `resets_at` with a sub-second value that truncates to two
    /// adjacent whole seconds across polls (observed ±1 s wobble). Downstream, `window_start` is
    /// keyed on the whole-second reset, so that wobble is otherwise mistaken for a 5-hour window
    /// rollover and re-fires the window-reset notification every poll. We de-jitter here: any change
    /// within this tolerance is treated as noise and the anchored value is kept. Comfortably above
    /// the wobble and far below a genuine 5-hour (18000 s) reset jump.
    static let resetJitterTolerance: TimeInterval = 60

    private let tokenProvider: ClaudeTokenProvider
    private let fetcher: HTTPFetcher
    /// Local email fallback file (`~/.claude.json`). Overridable for tests.
    private let localConfigURL: URL

    private var currentHealth: AdapterHealth = .unknown

    /// Cached account email + plan tier + the token they were fetched for (re-fetch only on
    /// token change, §8.0.3). `cachedPlanType` holds the authoritative profile-derived value.
    private var cachedEmail: String?
    private var cachedPlanType: String?
    private var profileFetchedForToken: String?
    /// Enterprise identity from the profile (§8.0.3 REV-40: `organization_type` or `seat_tier`).
    /// Drives only the `/prepaid/credits` skip (hard-403 for Enterprise) and the plan badge —
    /// never the monthly-layout detection, which is `usage.spend != nil` (D-34 discipline).
    private var cachedIsEnterprise = false
    /// Prepaid eligibility from the profile (§7.1 amendment, STEP_168 / REV-88): the endpoint is
    /// "only available for Pro and Max plans" — on any other seat (Team, Enterprise, unknown) it
    /// 403s, and the tester's logs show that a prepaid 403 landing on an already-pressured token
    /// is what earns the one-hour account lockout (35 of 35). nil until the profile answers; only
    /// `true` allows the call — an allowlist, not a denylist, because the server states the
    /// contract in exactly those terms.
    private var cachedPrepaidEligible: Bool?
    /// Latched by a 401/403 from the prepaid endpoint: no further calls for this token, however
    /// the profile read. Cleared on token change with the other per-token caches.
    private var prepaidForbiddenForToken = false
    /// The plan-skip line is logged once per token, not once per cadence window.
    private var prepaidSkipLogged = false
    /// The access token sent on the most recent usage request — a 429 included, an expiry-gated
    /// tick excluded (no request went out). The baseline `credentialChanged()` compares against
    /// while an advertised cooldown is pending (§9.3, STEP_168): a rotation is the one sanctioned
    /// reason to probe before the server's deadline.
    private var lastPolledToken: String?

    /// De-jitter anchors — the last stable `resets_at` emitted per window (see `resetJitterTolerance`).
    /// Cleared on token change so a new account re-anchors cleanly.
    private var lastPrimaryReset: Date?
    private var lastSecondaryReset: Date?

    /// Case 2 mid-window cache: last non-zero credits observed while `extra_usage` was enabled,
    /// scoped to the 5-hour window it belongs to. Invalidated on window reset (Baseline §7.1).
    private struct CreditsCache {
        let usedCredits: Decimal
        let monthlyLimit: Int?
        let currency: String?
        let windowReset: Date
    }
    private var creditsCache: CreditsCache?

    /// Org UUID from the profile — the `<org_id>` for the prepaid call. Cached with email/plan.
    private var cachedOrgId: String?
    /// Last prepaid wallet snapshot (§7.1, REV-29) and the time it was last *attempted* (success
    /// or failure). The attempt time — not just success — gates the `prepaidMinInterval` cadence,
    /// so a failing call cannot hammer the endpoint every poll. A failed refetch keeps the last
    /// good value serving (it ages via its own `asOf`), never dropping a known balance to blank.
    private var cachedPrepaid: PrepaidCredits?
    private var prepaidFetchedAt: Date?

    /// Time of the last successful usage fetch. nil until the first success. Drives the §20 P1-12
    /// wake-stagger (REV-37): a poll whose gap from this exceeds `coldPollThreshold` defers its
    /// secondary OAuth calls one cadence. Only a successful poll updates it (a 429/401/network
    /// error throws first), so recovery from a rate-limited stretch is treated as a cold poll too.
    private var lastFetchAt: Date?

    /// Clock seam — injectable so tests can drive the prepaid cadence gate deterministically.
    private let now: @Sendable () -> Date

    public init(
        tokenProvider: ClaudeTokenProvider,
        fetcher: HTTPFetcher,
        localConfigURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tokenProvider = tokenProvider
        self.fetcher = fetcher
        self.localConfigURL = localConfigURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude.json")
        self.now = now
    }

    public var health: AdapterHealth { currentHealth }

    // MARK: - AccountAdapter

    public func fetchQuotaSnapshot() async throws -> QuotaSnapshot {
        // Three outcomes, deliberately kept apart (STEP_117 / REV-71 §3.2): a credential, no
        // credential (the Keychain item is genuinely absent → setup required), or a read that
        // could not be attempted at all. The third must not enter setup-required mode — it is a
        // transient local failure, and reporting it as "never set up" is what sent the user
        // hunting a sign-in problem they did not have.
        let read: ClaudeCredential?
        do {
            read = try tokenProvider.credential()
        } catch {
            currentHealth = .unknown
            Logger.warning("Claude credential could not be read — not treating as setup required",
                           component: .claudeAccountAdapter, metadata: ["error": "\(error)"])
            throw error
        }
        guard var credential = read else {
            currentHealth = .setupRequired
            Logger.warning("Claude token unavailable — entering setup-required mode",
                           component: .claudeAccountAdapter)
            throw AccountAdapterError.setupRequired
        }

        // Pre-poll expiry gate (§8.0.1/§9.1 — REV-41, STEP_48). The access token has an ~8-hour
        // lifetime and is refreshed only when Claude Code runs, so an idle-overnight Mac wakes
        // with it expired — and the server answers an expired token with `429 rate_limit_error` +
        // a countdown `Retry-After`, not 401, which previously fed the 429 ladder as fake rate
        // pressure. If it is past `expiresAt`, send **no request**: enter the credential-expired
        // result. The credential is re-read fresh every poll (§8.0.1 REV-37 rule), so once Claude
        // Code refreshes it this gate stops firing on the very next tick (zero-network recovery).
        if Self.isCredentialExpired(credential, now: now()) {
            currentHealth = .credentialExpired
            Logger.info("Claude credential expired — gating poll (no request sent)",
                        component: .claudeAccountAdapter)
            throw AccountAdapterError.credentialExpired(details: nil)
        }

        var token = credential.accessToken

        var (data, response) = try await fetcher.get(
            Self.usageURL,
            headers: ["Authorization": "Bearer \(token)"]
        )

        // Change C (REV-37, §8.0.1): a concurrent client (Claude Code / CodexBar, §20 P1-12) may
        // rotate the shared credential between our Keychain read and this GET, yielding a transient
        // 401/403. Re-read once; if the token actually changed, retry the usage GET a single time
        // before declaring re-auth. Same token, a failed re-read, or a second 401/403 → genuine
        // re-auth (checkUsageStatus throws below, as today). One retry, not a loop. Read-only: we
        // never write, delete, or refresh the item.
        if (response.statusCode == 401 || response.statusCode == 403),
           let fresh = try? tokenProvider.credential(),   // try? flattens throw/nil → no retry
           fresh.accessToken != token {
            credential = fresh
            token = fresh.accessToken
            Logger.info("Claude usage 401/403 with a rotated token on disk — retrying once after re-read",
                        component: .claudeAccountAdapter)
            (data, response) = try await fetcher.get(
                Self.usageURL,
                headers: ["Authorization": "Bearer \(token)"]
            )
        }

        // The token this request actually carried (after the Change C swap, before the status check
        // throws on a 429) — the `credentialChanged()` baseline during a cooldown.
        lastPolledToken = token

        // Pass the credential's expiry so a countdown 429 landing within skew of the boundary can
        // be reclassified credential-shaped even if `expiresAt` read valid at gate time (belt-and-
        // braces for a clock running behind true time — §9.1). `credential` is the one used for
        // the GET (Change C may have swapped in a rotated credential above).
        try checkUsageStatus(response, data: data, token: token,
                             expiresAt: credential.expiresAt)

        let usage: ClaudeUsageResponse
        do {
            usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        } catch {
            currentHealth = .unknown
            throw AccountAdapterError.decoding("\(error)")
        }

        // A window with no active session reports `resets_at: null` (null-window shape, §8.0.2 —
        // live capture 2026-07-06: five_hour null all night after inactivity). Parse per window:
        // a null or unparseable reset degrades that one window to nil instead of failing the
        // poll, so live data in the other window (e.g. the weekly %) survives.
        let parsedPrimaryReset = parseReset(usage.fiveHour, label: "five_hour")
        let parsedSecondaryReset = parseReset(usage.sevenDay, label: "seven_day")
        // A genuine token transition (not the first-ever poll) means a new account with unrelated
        // windows → drop the previous account's de-jitter anchors before re-anchoring below.
        // `profileFetchedForToken` is still the previous token here (updated in fetchProfileIfNeeded).
        if let previousToken = profileFetchedForToken, previousToken != token {
            lastPrimaryReset = nil
            lastSecondaryReset = nil
            // New account → drop the previous account's wallet so it is refetched, not shown stale.
            cachedOrgId = nil
            cachedPrepaid = nil
            prepaidFetchedAt = nil
            // The prepaid gate is per token (STEP_168): eligibility is re-read from the new
            // token's profile, the 401/403 latch and the once-per-token log flag start clean, and
            // the Enterprise flag no longer carries over a failed profile fetch.
            cachedPrepaidEligible = nil
            prepaidForbiddenForToken = false
            prepaidSkipLogged = false
            cachedIsEnterprise = false
        }
        // Collapse the endpoint's sub-second `resets_at` wobble to one stable value per window so
        // every downstream consumer (state/notification engines, forecast, UI) sees a genuine reset
        // only when the window truly rolls over.
        let primaryReset = deJitter(parsedPrimaryReset, anchor: &lastPrimaryReset)
        let secondaryReset = deJitter(parsedSecondaryReset, anchor: &lastSecondaryReset)

        // A window that has not started arrives as `{ resets_at: null, utilization: 0 }` — a
        // literal 0, NOT `utilization: null` (live capture 2026-07-07 12:37 UTC, DB-confirmed).
        // REV-80 / D-101 (2026-08-26) reverses the 2026-07-07 rule that dropped that 0 to nil so
        // the §13 Null-window state would fire: the percent is **kept**, and with `primaryResetsAt
        // == nil` and the 18 000 s width below it is exactly the REV-57 unanchored shape Codex
        // emits for its placeholder (`primaryWindowIsUnanchored`), classified Healthy by gate 11
        // and rendered "5-hour · not started" on both tabs. Only an **absent** `five_hour` object
        // (Enterprise, §8.0.2 2026-07-16) is a null window; a present-but-unparseable `resets_at`
        // keeps its real utilization as before (a window is open — we just cannot date it).
        let primaryUtil = usage.fiveHour?.utilization

        // D-37 (REV-40): `spend` is canonical — on Enterprise the `extra_usage` object mirrors
        // it in *minor units* (`used_credits: 6916.0` = $69.16), and routing that mirror
        // through the Pro/Max decimal-dollar pipeline produced the live "$6916.00 of $120.00"
        // bug. When the spend meter is active the mirror is normalized away: card absent,
        // glyph none.
        //
        // "Active meter" — not raw presence: live capture 2026-07-16 (this machine, Max plan)
        // shows Pro/Max payloads ALSO carry `spend`, as a disabled stub (`enabled: false`,
        // `limit: null`, zero used) — the §8.0.4 premise that spend is Enterprise-only is
        // falsified, and suppressing on presence killed the Pro/Max §2.4a card. An active meter
        // (`enabled != false` AND a `limit` object) is the Enterprise-shaped signal; it also
        // holds when the money objects are corrupt (currency mismatch), keeping the minor-unit
        // mirror out of the decimal pipeline even when the monthly mapping degrades to nil.
        let spendIsActiveMeter = usage.spend.map { $0.enabled != false && $0.limit != nil }
            ?? false
        // REV-102 / D-125 (STEP_218): a seat that reports a five-hour or a weekly window (Claude
        // Team) treats an active spend meter as **usage credits paid by the organization**, not
        // as a monthly quota — REV-40 met `spend` on a window-less Enterprise seat, where it is
        // the quota, and that arm is unchanged. Object presence, never the plan string: an
        // un-started five-hour (`resets_at: null`) counts (REV-80). The credits are built from
        // `spend` itself, so the minor-unit `extra_usage` mirror is still never read (D-37).
        let windowedSeat = usage.fiveHour != nil || usage.sevenDay != nil

        // Change B (REV-37, §20 P1-12): a poll whose gap from the last success exceeds
        // `coldPollThreshold` is the first poll after a long idle/sleep gap — the moment the shared
        // credential is most contended. On such a poll make only the usage call (already done) and
        // defer the secondary OAuth calls one cadence: usage alone answers "am I safe?"; email and
        // prepaid can wait. Bounded to one poll (the next poll's gap is normal cadence). A true
        // first-ever poll (`lastFetchAt == nil`) is not a wake — it fetches everything.
        let nowTime = now()
        let deferSecondaries = lastFetchAt.map {
            nowTime.timeIntervalSince($0) > Self.coldPollThreshold
        } ?? false

        let prepaid: PrepaidCredits?
        if deferSecondaries {
            // Serve prepaid from last-good cache (nil-degraded per §2.4a.4); profile stays
            // cached/nil. Both refetch on the next warm poll via their unchanged guards.
            prepaid = cachedPrepaid
            Logger.info("Claude cold poll — deferring secondary OAuth calls one cadence",
                        component: .claudeAccountAdapter)
        } else {
            // Fetch email + plan (and the org id) once per token (startup / token change), never
            // per poll (§8.0.3). Must precede the prepaid call — it supplies the org id.
            await fetchProfileIfNeeded(token: token)
            // Second OAuth call (§7.1, REV-29): prepaid wallet + auto-reload, rate-limited to
            // `prepaidMinInterval`. Wrapped so no failure here can throw out of the quota poll or
            // touch `currentHealth` — the card degrades to its extra_usage-only shape (§2.4a.4).
            prepaid = await refreshPrepaidIfStale(token: token)
        }

        // Decided **after** the profile fetch (STEP_222): the switched-off arm below reads the
        // plan signal, and deciding first showed the wrong card for one cadence after every launch.
        //
        // REV-102 §6 item 1 (STEP_222): about a day after the organization's cap is reached the
        // meter stops reporting the ceiling and switches off — `enabled: false`,
        // `disabled_reason: "out_of_credits"`, no limit, used 0 — so it is no longer an active
        // meter. `can_toggle` cannot tell that from the Pro/Max disabled stub, and whether a
        // Pro/Max seat can also report `out_of_credits` is unobserved, so the reason alone is
        // not safe either: the arm needs the profile to have said **not Pro/Max**
        // (`cachedPrepaidEligible == false`, the REV-88 signal). Profile unknown ⇒ the self-serve
        // arm as before, corrected by the next poll that has one — never guess the plan.
        let orgCreditsSwitchedOff = windowedSeat && !spendIsActiveMeter
            && usage.spend?.disabledReason == "out_of_credits"
            && cachedPrepaidEligible == false
        let extraUsage: ExtraUsage?
        let monthlyLimit: MonthlyLimit?
        if spendIsActiveMeter && windowedSeat {
            extraUsage = Self.orgManagedExtraUsage(from: usage.spend)
            monthlyLimit = nil
        } else if orgCreditsSwitchedOff {
            extraUsage = Self.orgSwitchedOffExtraUsage(from: usage.spend)
            monthlyLimit = nil
        } else {
            extraUsage = spendIsActiveMeter
                ? nil
                : resolveExtraUsage(usage.extraUsage, primaryReset: primaryReset)
            monthlyLimit = Self.monthlyLimit(from: usage.spend, now: now())
        }

        // Plan precedence: authoritative profile value, else normalized Keychain subscriptionType,
        // else the raw Keychain string (still recorded even if it misses the limits-DB key).
        let planType = cachedPlanType
            ?? Self.normalizePlan(credential.subscriptionType)
            ?? credential.subscriptionType

        let headers = Self.parseRateLimitHeaders(response)

        // Anchor the wake-stagger gap on this success (Change B). Only a successful poll advances
        // it, so a stretch of failures widens the gap and the recovery poll counts as cold.
        lastFetchAt = nowTime
        currentHealth = .healthy

        // Model-scoped weekly limits (§8.0.2 — STEP_134): the third bar claude.ai draws, from the
        // same response body, at no extra request cost.
        let scoped = Self.scopedLimits(from: usage)
        if scoped.unnamed > 0 {
            Logger.info("Claude scoped limit with no model name — not displayed",
                        component: .claudeAccountAdapter,
                        metadata: ["count": "\(scoped.unnamed)"])
        }

        let snapshot = QuotaSnapshot(
            tool: .claude,
            primaryUsedPct: primaryUtil,
            primaryResetsAt: primaryReset,
            // Claude's true width, on every snapshot (REV-80 / D-101): the usage endpoint reports
            // none, and the unanchored flag needs it to name a not-started window.
            primaryWindowSeconds: 18_000,
            secondaryUsedPct: usage.sevenDay?.utilization,
            secondaryResetsAt: secondaryReset,
            rateLimitReached: primaryUtil.map { $0 >= 100 },
            extraUsage: extraUsage,
            prepaid: prepaid,
            rateLimitLimit: headers.limit,
            rateLimitRemaining: headers.remaining,
            rateLimitReset: headers.reset,
            additionalRateLimits: scoped.limits,
            monthlyLimit: monthlyLimit,
            source: .oauth,
            // A null five_hour window on Claude is an *absent* `five_hour` object (Enterprise,
            // §8.0.2) — the endpoint itself reports no such window → provider-origin (§9.5). A
            // present object with `resets_at: null` is not-started, not null (REV-80 / D-101).
            nullWindowSource: usage.fiveHour == nil ? .provider : nil,
            email: cachedEmail,
            planType: planType
        )

        Logger.info("Claude poll complete", component: .claudeAccountAdapter,
                    metadata: [
                        "util": primaryUtil.map { "\(Int($0))%" } ?? "—",
                        // REV-80 / D-101: the operator's marker for the overnight shape — `util=—`
                        // no longer is, since a not-started window carries `0%`.
                        "window": usage.fiveHour == nil ? "none"
                            : (primaryReset == nil ? "not-started" : "open"),
                        "weekly": (usage.sevenDay?.utilization).map { "\(Int($0))%" } ?? "—",
                        // STEP_134 — one token per scoped weekly limit, e.g. `Fable:10%`.
                        "scoped": scoped.limits.isEmpty ? "none" : scoped.limits.map {
                            "\($0.name ?? "?"):\($0.usedPercent.map { "\(Int($0))%" } ?? "—")"
                        }.joined(separator: ","),
                        "extra_usage": extraUsage.map {
                            ($0.managedByOrganization ? "org-" : "") + ($0.isEnabled ? "on" : "off")
                        } ?? "absent",
                        "prepaid": prepaid?.amountCents.map { "\($0)¢" } ?? "—",
                        "plan": planType ?? "unknown",
                        "ratelimit_remaining": headers.remaining.map { "\($0)" } ?? "n/a",
                        "email": cachedEmail == nil ? "none" : "<redacted>",
                        // P1-16 forensics (§8.0.4): logged only, never branched on — over-limit
                        // spend semantics are unobserved ("normal" is the only captured severity).
                        "spend_severity": usage.spend?.severity ?? "absent",
                        "member_dashboard": usage.memberDashboardAvailable.map { "\($0)" }
                            ?? "absent",
                    ])

        return snapshot
    }

    /// Keeps the anchored reset when `new` differs by no more than `resetJitterTolerance` (endpoint
    /// wobble), otherwise adopts and re-anchors on `new` (a genuine window rollover). The returned
    /// value is what the rest of the pipeline treats as this poll's `resets_at`. A nil `new` (no
    /// active window) passes through and keeps the anchor — the next real window differs by hours
    /// and re-anchors naturally.
    private func deJitter(_ new: Date?, anchor: inout Date?) -> Date? {
        guard let new else { return nil }
        if let anchor, abs(new.timeIntervalSince(anchor)) <= Self.resetJitterTolerance {
            return anchor
        }
        anchor = new
        return new
    }

    /// The model-scoped weekly limits from `limits[]` (§8.0.2 — STEP_134), plus a count of the
    /// scoped entries this rule could not name. Pure and static so it is unit-testable without a
    /// fetcher.
    ///
    /// **A scoped limit with no model name is skipped, never drawn under a placeholder label.**
    /// `scope.surface` exists in the payload and is null in every capture, so a surface-scoped
    /// entry is a shape nobody here has seen — it goes in the skipped count and is logged, the
    /// bucket-and-monitor idiom this project already applies to unknown Codex originators. The
    /// alternative (a row reading `Model limit  8%`) states a fact about a limit we cannot name.
    ///
    /// `kind` is the whole discriminator: `session` and `weekly_all` restate `five_hour` and
    /// `seven_day`, which keep their existing rows, so only `weekly_scoped` is read here.
    static func scopedLimits(from usage: ClaudeUsageResponse)
        -> (limits: [AdditionalRateLimit], unnamed: Int) {
        guard let entries = usage.limits else { return ([], 0) }
        var limits: [AdditionalRateLimit] = []
        var unnamed = 0
        for entry in entries where entry.kind == "weekly_scoped" {
            guard let name = entry.scope?.model?.displayName, !name.isEmpty else {
                unnamed += 1
                continue
            }
            limits.append(AdditionalRateLimit(
                id: entry.scope?.model?.id,
                name: name,
                usedPercent: entry.percent.map(Double.init),
                resetsAt: entry.resetsAt.flatMap(Self.parseTimestamp),
                // STEP_176: the period is *reported* — `kind: "weekly_scoped"` names it, and the
                // entry resets on the `seven_day` boundary in every capture — so the width is
                // carried, not inferred. No secondary window: the entry has one.
                primaryWindowSeconds: 7 * 86_400))
        }
        return (limits, unnamed)
    }

    /// Per-window `resets_at` parsing: nil window or null `resets_at` is the null-window shape
    /// (§8.0.2); a present-but-unparseable value degrades to nil with a WARNING rather than
    /// failing the poll.
    private func parseReset(_ window: ClaudeUsageResponse.Window?, label: String) -> Date? {
        guard let raw = window?.resetsAt else { return nil }
        guard let date = Self.parseTimestamp(raw) else {
            Logger.warning("Claude resets_at unparseable — treating window as null",
                           component: .claudeAccountAdapter,
                           metadata: ["window": label, "resets_at": raw])
            return nil
        }
        return date
    }

    // MARK: - Status handling (Baseline §8.2, §9.3)

    private func checkUsageStatus(_ response: HTTPURLResponse, data: Data, token: String,
                                  expiresAt: Double?) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401, 403:
            currentHealth = .reauthRequired
            Logger.warning("Claude OAuth rejected token",
                           component: .claudeAccountAdapter,
                           metadata: ["status": "\(response.statusCode)"])
            throw AccountAdapterError.reauthRequired
        case 429:
            // Poll 429 — wait exactly Retry-After; default 120s when absent (§9.3). Capture the
            // response for the self-contained forensic row (§9.5 — R31-4): the body/headers are
            // here right now and were previously discarded one frame later.
            let rawRetryAfter = Self.retryAfterSeconds(response)
            // Belt-and-braces (§9.1 — REV-41, STEP_48): a countdown 429 (non-transient) landing
            // within skew of `expiresAt` is a credential-shaped rejection the strict gate missed
            // because the local clock read behind true time. Reclassify it — it must not feed the
            // ladder. When in doubt (`Retry-After: 0`, absent expiry, or far from the boundary)
            // prefer rate pressure: the gate is the primary defense; this only covers skew.
            if Self.isCredentialShaped429(expiresAt: expiresAt, rawRetryAfter: rawRetryAfter,
                                          now: now()) {
                currentHealth = .credentialExpired
                Logger.info("Claude 429 reclassified credential-expired (countdown near expiry)",
                            component: .claudeAccountAdapter,
                            metadata: ["retry_after": rawRetryAfter.map { "\($0)s" } ?? "absent"])
                let details = RateLimit429Details(
                    statusCode: 429,
                    headers: Self.forensicHeaders(response),
                    body: Self.redactedBody(data, token: token),
                    category: "credential_expired")
                throw AccountAdapterError.credentialExpired(details: details)
            }
            let retryAfter = rawRetryAfter ?? 120
            currentHealth = .rateLimited(retryAfter: retryAfter)
            Logger.warning("Claude poll 429", component: .claudeAccountAdapter,
                           metadata: ["retry_after": "\(retryAfter)s"])
            let details = RateLimit429Details(
                statusCode: 429,
                headers: Self.forensicHeaders(response),
                body: Self.redactedBody(data, token: token),
                category: Self.classify429(rawRetryAfter: rawRetryAfter))
            throw AccountAdapterError.rateLimited(retryAfter: retryAfter, details: details)
        default:
            currentHealth = .unknown
            Logger.warning("Claude OAuth unexpected status",
                           component: .claudeAccountAdapter,
                           metadata: ["status": "\(response.statusCode)"])
            throw AccountAdapterError.httpStatus(response.statusCode)
        }
    }

    // MARK: - extra_usage cached-value rule (Baseline §7.1)

    private func resolveExtraUsage(
        _ raw: ClaudeUsageResponse.ExtraUsageResponse?,
        primaryReset: Date?
    ) -> ExtraUsage? {
        // No `extra_usage` object at all (Enterprise / no pay-as-you-go): the card is suppressed.
        // Distinct from a present-but-disabled object below (NO-BACKSTOP, which renders).
        guard let raw else { return nil }

        // Invalidate the cache when the 5-hour window resets — a reset makes credits stale.
        // A nil reset (null window) also invalidates: the window the credits belonged to is gone.
        if let cache = creditsCache, cache.windowReset != primaryReset {
            creditsCache = nil
        }

        let liveCredits = raw.usedCredits.flatMap(Self.decimal(from:))

        if raw.isEnabled {
            // Case 1 — credits active. Cache the last non-zero value for the current window.
            if let credits = liveCredits, credits > 0, let primaryReset {
                creditsCache = CreditsCache(
                    usedCredits: credits,
                    monthlyLimit: raw.monthlyLimit,
                    currency: raw.currency,
                    windowReset: primaryReset
                )
            }
            return ExtraUsage(
                isEnabled: true,
                monthlyLimit: raw.monthlyLimit,
                usedCredits: liveCredits,
                utilization: raw.utilization,
                currency: raw.currency,
                disabledReason: raw.disabledReason
            )
        }

        // Disabled. Case 2 — credits were active earlier this window: surface the cached value,
        // always labelled "last observed" by the UI. Otherwise Case 3 — all-null disabled shape.
        if let cache = creditsCache {
            return ExtraUsage(
                isEnabled: false,
                monthlyLimit: cache.monthlyLimit,
                usedCredits: cache.usedCredits,
                utilization: nil,
                currency: cache.currency,
                disabledReason: raw.disabledReason,
                // §7.1: the Case 2 value is never presented as real-time, even if the server
                // happens to keep returning `used_credits` after toggle-off (unvalidated, P2-3).
                usedCreditsIsCached: true
            )
        }

        return ExtraUsage(
            isEnabled: false,
            monthlyLimit: raw.monthlyLimit,
            usedCredits: liveCredits,
            utilization: raw.utilization,
            currency: raw.currency,
            disabledReason: raw.disabledReason
        )
    }

    // MARK: - Enterprise monthly spend → MonthlyLimit (Baseline §8.0.4, REV-40)

    /// Normalizes the Enterprise `spend` object into the unit-generalized `MonthlyLimit`, or
    /// `nil` when there is nothing coherent to claim — never a failed poll. Built only when
    /// `enabled != false` and both money objects parse with matching currency + exponent
    /// (a mismatch would make "used of limit" a lie in either unit → nil + WARNING).
    ///
    /// `resetsAt` is **client-derived** (`nextCalendarMonthStartUTC` — the payload carries no
    /// reset timestamp; calendar-month UTC verified out-of-band, §8.0.4) and tagged
    /// `derived_calendar_month_utc` so it is never presented as payload data.
    static func monthlyLimit(
        from spend: ClaudeUsageResponse.SpendResponse?,
        now: Date
    ) -> MonthlyLimit? {
        guard let spend, spend.enabled != false else { return nil }
        guard let used = spend.used?.amountMinor,
              let limit = spend.limit?.amountMinor,
              let percent = spend.percent,
              let resetsAt = MonthlyLimit.nextCalendarMonthStartUTC(after: now) else {
            return nil
        }
        guard spendMoneyIsCoherent(spend) else { return nil }
        return MonthlyLimit(
            limitAmount: Double(limit),
            usedAmount: Double(used),
            remainingPercent: 100 - percent,
            resetsAt: resetsAt,
            unit: .money(currency: spend.limit?.currency ?? "USD",
                         exponent: spend.limit?.exponent ?? 2),
            source: "derived_calendar_month_utc"
        )
    }

    /// `used` and `limit` must share currency + exponent, or "used of limit" is a lie in either
    /// unit → false + WARNING. One check for both readers of the `spend` money objects.
    private static func spendMoneyIsCoherent(_ spend: ClaudeUsageResponse.SpendResponse) -> Bool {
        guard spend.used?.currency == spend.limit?.currency,
              spend.used?.exponent == spend.limit?.exponent else {
            Logger.warning("Claude spend used/limit currency or exponent mismatch — dropping monthly",
                           component: .claudeAccountAdapter,
                           metadata: [
                               "used_currency": spend.used?.currency ?? "nil",
                               "limit_currency": spend.limit?.currency ?? "nil",
                               "used_exponent": spend.used?.exponent.map { "\($0)" } ?? "nil",
                               "limit_exponent": spend.limit?.exponent.map { "\($0)" } ?? "nil",
                           ])
            return false
        }
        return true
    }

    // MARK: - Windowed-seat spend → org-managed ExtraUsage (Baseline §8.0.4, REV-102)

    /// Maps the `spend` meter of a seat that also reports windows (Claude Team) to usage credits
    /// the organization pays for (REV-102 / D-125, STEP_218). `nil` when the money objects do
    /// not parse or disagree — never a failed poll. `monthlyLimit` stays in minor units with
    /// its exponent beside it; `usedCredits` is decimal major units, as on the Pro/Max path.
    /// The §7.1 cached-value rule does not apply: the member cannot toggle these mid-window.
    static func orgManagedExtraUsage(
        from spend: ClaudeUsageResponse.SpendResponse?
    ) -> ExtraUsage? {
        guard let spend,
              let used = spend.used?.amountMinor,
              let limit = spend.limit?.amountMinor,
              spendMoneyIsCoherent(spend) else { return nil }
        let exponent = spend.limit?.exponent ?? 2
        return ExtraUsage(
            isEnabled: spend.enabled != false,
            monthlyLimit: limit,
            usedCredits: Decimal(sign: .plus, exponent: -exponent, significand: Decimal(used)),
            utilization: spend.percent.map(Double.init),
            currency: spend.limit?.currency,
            disabledReason: spend.disabledReason,
            managedByOrganization: true,
            currencyExponent: exponent
        )
    }

    /// The same credits after the provider switched the meter off (`out_of_credits` — REV-102 §6
    /// item 1, STEP_222). No amounts: the payload no longer sends them and nothing is cached
    /// (owner ruling 2026-09-21). Currency and exponent ride `spend.used`, the one money object
    /// left. The caller has already established the seat and the plan.
    static func orgSwitchedOffExtraUsage(
        from spend: ClaudeUsageResponse.SpendResponse?
    ) -> ExtraUsage? {
        guard let spend else { return nil }
        return ExtraUsage(
            isEnabled: false,
            monthlyLimit: nil,
            usedCredits: nil,
            utilization: nil,
            currency: spend.used?.currency,
            disabledReason: spend.disabledReason,
            managedByOrganization: true,
            currencyExponent: spend.used?.exponent
        )
    }

    // MARK: - Profile: email + plan (Baseline §8.0.3)

    /// Fetches account email + plan tier once per access token. On profile-endpoint failure,
    /// falls back to `~/.claude.json` for email (plan is left to the Keychain source). Marks the
    /// token as attempted either way to avoid per-poll requests.
    func fetchProfileIfNeeded(token: String) async {
        guard profileFetchedForToken != token else { return }
        profileFetchedForToken = token

        if let profile = await fetchProfile(token: token) {
            cachedEmail = profile.account.email
            cachedPlanType = Self.planType(from: profile)
            cachedOrgId = profile.organization?.uuid
            cachedIsEnterprise = Self.isEnterprise(profile)
            // Pro/Max-positive, never Enterprise-negative (§7.1 amendment, STEP_168): the two
            // booleans are the server's own statement of who may call `/prepaid/credits`.
            cachedPrepaidEligible =
                profile.account.hasClaudePro == true || profile.account.hasClaudeMax == true
            if cachedEmail != nil { return }
        }
        if let email = readLocalConfigEmail() {
            cachedEmail = email
            Logger.info("Claude email from local config fallback",
                        component: .claudeAccountAdapter, metadata: ["email": "<redacted>"])
        }
    }

    private func fetchProfile(token: String) async -> ClaudeProfileResponse? {
        do {
            let (data, response) = try await fetcher.get(
                Self.profileURL,
                headers: [
                    "Authorization": "Bearer \(token)",
                    "anthropic-beta": Self.profileBetaHeader,
                ]
            )
            guard (200...299).contains(response.statusCode) else {
                Logger.info("Claude profile endpoint non-2xx",
                            component: .claudeAccountAdapter,
                            metadata: ["status": "\(response.statusCode)"])
                return nil
            }
            return try JSONDecoder().decode(ClaudeProfileResponse.self, from: data)
        } catch {
            Logger.info("Claude profile fetch failed; will try local fallback",
                        component: .claudeAccountAdapter, metadata: ["error": "\(error)"])
            return nil
        }
    }

    // MARK: - Credential change during an advertised cooldown (Baseline §9.3, STEP_168)

    /// True when the Keychain now holds a different, unexpired access token than the one the last
    /// usage request carried — the one sanctioned reason to probe inside a server-advertised
    /// cooldown (the tester's 2026-09-07 lockout ended 20 min early right after a rotation, the
    /// only early recovery in 35). Read-only, zero network, no dialog: the same delegated read
    /// every poll makes. With no baseline yet (a hold restored at launch before any poll) the
    /// fresh token becomes the baseline and the answer is false. An expired fresh token is never
    /// a reason to probe — the request would only hit the pre-poll expiry gate and trade a long
    /// hold for the 60 s credential cadence. A read that throws or finds nothing is `false`.
    public func credentialChanged() async -> Bool {
        guard let fresh = try? tokenProvider.credential() else { return false }
        guard let baseline = lastPolledToken else {
            lastPolledToken = fresh.accessToken
            return false
        }
        guard fresh.accessToken != baseline else { return false }
        return !Self.isCredentialExpired(fresh, now: now())
    }

    // MARK: - Prepaid wallet: balance + auto-reload (Baseline §7.1, REV-29)

    /// Returns the prepaid wallet for this poll, refetching only when the cached value is older
    /// than `prepaidMinInterval`. Never throws: a missing org id or any fetch failure returns the
    /// last-good cached value (nil if never fetched) so the quota poll is never blocked or failed
    /// and `currentHealth` is never polluted (Fork C / §2.4a.4).
    func refreshPrepaidIfStale(token: String) async -> PrepaidCredits? {
        // Pro/Max only (§7.1 amendment — REV-40 for Enterprise, generalised by STEP_168 / REV-88
        // after the Team tester's logs): the endpoint hard-403s every other seat, and a prepaid
        // 403 on a pressured token is what the server escalates to a one-hour lockout. Unknown
        // eligibility (no profile yet) cannot call anyway — there is no org id without a profile.
        guard cachedPrepaidEligible == true else {
            if cachedPrepaidEligible == false, !prepaidSkipLogged {
                prepaidSkipLogged = true
                Logger.info("Claude prepaid endpoint skipped — plan is not Pro/Max",
                            component: .claudeAccountAdapter,
                            metadata: ["plan": cachedPlanType ?? "unknown"])
            }
            return nil
        }
        // A 401/403 already answered for this token: never again until the token changes.
        guard !prepaidForbiddenForToken else { return nil }
        guard let orgId = cachedOrgId else { return cachedPrepaid }
        let currentTime = now()
        if let fetchedAt = prepaidFetchedAt,
           currentTime.timeIntervalSince(fetchedAt) < Self.prepaidMinInterval {
            return cachedPrepaid
        }
        // Rate-limit *attempts* (not just successes) to one per interval so a failing endpoint
        // cannot be hammered every poll.
        prepaidFetchedAt = currentTime
        guard let fetched = await fetchPrepaid(orgId: orgId, token: token, asOf: currentTime) else {
            return cachedPrepaid   // keep last-good; it ages via its own asOf (§2.4a.4)
        }
        cachedPrepaid = fetched
        return fetched
    }

    private func fetchPrepaid(orgId: String, token: String, asOf: Date) async -> PrepaidCredits? {
        guard let url = Self.prepaidURL(orgId: orgId) else { return nil }
        do {
            let (data, response) = try await fetcher.get(
                url,
                headers: [
                    "Authorization": "Bearer \(token)",
                    "anthropic-beta": Self.profileBetaHeader,
                ]
            )
            guard (200...299).contains(response.statusCode) else {
                if response.statusCode == 401 || response.statusCode == 403 {
                    // The server has said this token may not call here. Re-hitting it every
                    // 15 min is the request the lockout follows (REV-88) — latch for the token.
                    prepaidForbiddenForToken = true
                    Logger.warning("Claude prepaid endpoint forbidden — no further calls for this token",
                                   component: .claudeAccountAdapter,
                                   metadata: ["status": "\(response.statusCode)"])
                    return nil
                }
                Logger.info("Claude prepaid endpoint non-2xx — card drops balance/auto-reload rows",
                            component: .claudeAccountAdapter,
                            metadata: ["status": "\(response.statusCode)"])
                return nil
            }
            let raw = try JSONDecoder().decode(PrepaidCreditsResponse.self, from: data)
            return PrepaidCredits(
                amountCents: raw.amount,
                autoReloadOn: raw.autoReloadSettings != nil,
                asOf: asOf,
                currency: raw.currency
            )
        } catch {
            Logger.info("Claude prepaid fetch failed; keeping last-known wallet",
                        component: .claudeAccountAdapter, metadata: ["error": "\(error)"])
            return nil
        }
    }

    /// Authoritative plan tier from the profile: `has_claude_max`/`has_claude_pro` booleans map
    /// to the limits-DB keys `"max"`/`"pro"`; then the Enterprise identity signals (§8.0.3
    /// REV-40 — badge `Enterprise · exact`); falls back to the normalized `rate_limit_tier`.
    private static func planType(from profile: ClaudeProfileResponse) -> String? {
        if profile.account.hasClaudeMax == true { return "max" }
        if profile.account.hasClaudePro == true { return "pro" }
        if isEnterprise(profile) { return "enterprise" }
        return normalizePlan(profile.organization?.rateLimitTier)
    }

    /// Either §8.0.3 REV-40 signal identifies Claude Enterprise (tester capture 2026-07-16:
    /// `organization_type: "claude_enterprise"`, `seat_tier: "enterprise_usage_based"`).
    private static func isEnterprise(_ profile: ClaudeProfileResponse) -> Bool {
        profile.organization?.organizationType == "claude_enterprise"
            || profile.organization?.seatTier == "enterprise_usage_based"
    }

    private func readLocalConfigEmail() -> String? {
        guard let data = try? Data(contentsOf: localConfigURL) else { return nil }
        let config = try? JSONDecoder().decode(ClaudeLocalConfig.self, from: data)
        return config?.oauthAccount?.emailAddress
    }

    // MARK: - Header + value parsing

    private static func parseRateLimitHeaders(
        _ response: HTTPURLResponse
    ) -> (limit: Int?, remaining: Int?, reset: Date?) {
        let limit = intHeader(response, "X-RateLimit-Limit")
        let remaining = intHeader(response, "X-RateLimit-Remaining")
        let reset = intHeader(response, "X-RateLimit-Reset").map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        return (limit, remaining, reset)
    }

    private static func retryAfterSeconds(_ response: HTTPURLResponse) -> Int? {
        intHeader(response, "Retry-After")
    }

    private static func intHeader(_ response: HTTPURLResponse, _ name: String) -> Int? {
        guard let value = response.value(forHTTPHeaderField: name) else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - 429 forensic capture (§9.5 — R31-4)

    /// Max stored body length. A 429 body is short JSON; the cap just guards against a pathological
    /// payload bloating a 7-day-retained row.
    private static let maxForensicBodyChars = 4096

    /// Response headers for the forensic row (§9.5), verbatim except any `Authorization` key
    /// (defensively dropped — §10.6; the response never carries it, but never write it regardless).
    private static func forensicHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            let name = String(describing: key)
            if name.caseInsensitiveCompare("Authorization") == .orderedSame { continue }
            out[name] = String(describing: value)
        }
        return out
    }

    /// Redacts credential material and caps length before the body is stored (§10.6): the known
    /// bearer token is replaced verbatim, then the body is truncated. Never write the bearer token.
    private static func redactedBody(_ data: Data, token: String) -> String? {
        guard !data.isEmpty, var body = String(data: data, encoding: .utf8) else { return nil }
        if !token.isEmpty { body = body.replacingOccurrences(of: token, with: "<redacted>") }
        if body.count > maxForensicBodyChars {
            body = String(body.prefix(maxForensicBodyChars)) + "…[truncated]"
        }
        return body
    }

    /// §9.5 `category`, recorded for analysis only — nothing branches on it (§9.2 rule 5). An
    /// absent `Retry-After` (nil) is `unknown`; a present value ≤ floor is `transient` (the 81/82
    /// load-shed case); anything larger is `rate_pressure`.
    private static func classify429(rawRetryAfter: Int?) -> String {
        guard let ra = rawRetryAfter else { return "unknown" }
        return TimeInterval(ra) <= PollBackoffPolicy.retryAfterFloor ? "transient" : "rate_pressure"
    }

    // MARK: - Credential expiry gate (§8.0.1/§9.1 — REV-41, STEP_48)

    /// Clock-skew tolerance for the belt-and-braces 429 reclassification (§9.1). A countdown 429
    /// this close to `expiresAt` is treated as credential-shaped even if `expiresAt` read valid —
    /// covers a local clock running behind true time. The gate itself is strict (no margin), so a
    /// clock running *ahead* never suppresses a valid token (macOS keeps it NTP-synced).
    static let credentialSkewTolerance: TimeInterval = 120

    /// The strict pre-poll gate condition: `now` is at or past the credential's `expiresAt`
    /// (epoch **ms**, §8.0.1). A nil `expiresAt` (absent/unparseable) is never expired — the gate
    /// is a no-op and the adapter behaves exactly as before.
    static func isCredentialExpired(_ credential: ClaudeCredential, now: Date) -> Bool {
        guard let expiresAt = credential.expiresAt else { return false }
        return now.timeIntervalSince1970 >= expiresAt / 1000
    }

    /// The belt-and-braces predicate (§9.1): a **non-transient** countdown 429 (`Retry-After`
    /// present and above the floor — not the `Retry-After: 0` load-shed) landing within
    /// `credentialSkewTolerance` of the credential's `expiresAt`. Symmetric around the boundary;
    /// the `now`-past half is normally unreachable (the strict gate already blocked it), so this
    /// only fires in the clock-behind band. Absent expiry or a transient 429 ⇒ not credential-
    /// shaped (prefer rate pressure).
    static func isCredentialShaped429(expiresAt: Double?, rawRetryAfter: Int?, now: Date) -> Bool {
        guard let expiresAt else { return false }
        guard let raw = rawRetryAfter,
              TimeInterval(raw) > PollBackoffPolicy.retryAfterFloor else { return false }
        return abs(now.timeIntervalSince1970 - expiresAt / 1000) <= credentialSkewTolerance
    }

    /// Converts a JSON number to `Decimal` via its string form to avoid binary-float artifacts
    /// in money values (Baseline §7.1 — parse `used_credits` as `Decimal`).
    private static func decimal(from number: Double) -> Decimal? {
        Decimal(string: String(number))
    }

    /// Normalizes a raw plan/tier string to a limits-DB plan key (`"max"`/`"pro"`). Returns nil
    /// for unrecognized input so callers can fall back to the raw value.
    static func normalizePlan(_ raw: String?) -> String? {
        guard let lowered = raw?.lowercased() else { return nil }
        if lowered.contains("max") { return "max" }
        if lowered.contains("pro") { return "pro" }
        return nil
    }

    /// Parses an ISO-8601 `resets_at` string, tolerating both fractional-second and plain forms.
    /// Formatters are built locally: `ISO8601DateFormatter` is not `Sendable`, so it cannot be a
    /// shared static under Swift 6 strict concurrency.
    static func parseTimestamp(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
