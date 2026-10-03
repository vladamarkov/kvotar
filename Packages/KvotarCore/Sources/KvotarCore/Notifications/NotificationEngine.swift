import Foundation

/// Turns qualified state transitions and per-poll signals into rare, actionable notifications
/// (Baseline §16, §13.2). It owns all cooldown, re-arm, max-per-window, and window-reset logic;
/// the `StateEngine` knows nothing about notifications, and copy lives in the presenter.
///
/// Two firing paths (§13.2), reconciled per cycle in `evaluateCycle` (STEP_28 — no stacking,
/// UI Spec §4.2 / D-11): each path contributes *candidates*, and at most one notification —
/// the highest §16-priority candidate — fires per evaluation cycle per tool. Suppressed
/// candidates are not persisted, so their caps and cooldowns are untouched and they stay
/// eligible on the next cycle.
/// - **Path 1 — transition-based** (`change`, returned by `StateEngine.evaluate`): over-quota,
///   at-risk first fire, bad-timing, spend-control. Because `StateEngine` reports a change only
///   on a real transition and stays silent on a tool's first evaluation, launching *into* an
///   existing warning state never notifies (UI Spec §4.2).
/// - **Path 2 — signal/re-arm** (`signal`, built by the poll driver): fast-burn, off-machine,
///   multi-surface, window-reset pre/post, at-risk re-arm, and the weekly ladder (REV-106 —
///   decided here; delivered while `WeeklyLadder.isEnabled` is on, which it is since STEP_233).
///
/// Re-arm eligibility and max-per-window are derived from `COUNT(*)`/`dismissed_at` queries against
/// `notification_events` (§13.2) — the only cross-poll memory kept in the actor is the sustained
/// off-machine counter, the per-window "was in warning" flag, and the last seen window/reset time.
public actor NotificationEngine {

    // MARK: Tuning constants (UI Spec §4/§5 — starting values, hardcoded in Pre-Alpha)
    /// The window width assumed when the provider reports none. **A fallback, not a constant**
    /// (REV-59 §5): Claude's usage endpoint returns no width and its windows genuinely are five
    /// hours, so this is right where it still applies and wrong everywhere it used to be applied
    /// by default. Codex reports its width, and `windowStart` buckets on that.
    static let fallbackWindowLength: Int = 5 * 3600
    static let atRiskRearmRunwayMin = 10.0
    static let atRiskMaxPerWindow = 2
    static let badTimingMaxPerWindow = 1
    static let overQuotaMaxPerWindow = 1
    static let spendControlMaxPerWindow = 1
    static let fastBurnDeltaPct = 20.0
    static let fastBurnCooldown: TimeInterval = 600      // 10 min
    static let fastBurnMaxPerWindow = 2                  // UI Spec §4 "Max per episode: 2"
    static let offMachineDeltaPct = 2.0
    static let offMachineSustainedPolls = 2
    static let offMachineCooldown: TimeInterval = 1200   // 20 min
    static let offMachineMaxPerWindow = 3
    static let multiSurfaceMinBuckets = 2
    static let multiSurfaceDeltaPct = 10.0
    static let multiSurfaceCooldown: TimeInterval = 600  // 10 min
    static let multiSurfaceMaxPerWindow = 2              // UI Spec §4 "Max per episode: 2"
    static let preResetWindowMin = 30.0
    static let postResetGuardMin = 270.0                 // > 4h30m confirms a genuine reset
    static let windowResetPreMaxPerWindow = 1
    static let windowResetPostMaxPerWindow = 1
    /// A window key change only counts as a rollover when the reset instant has genuinely advanced
    /// by more than this — insurance against a jittery `resets_at` flipping the whole-second key
    /// back and forth and re-firing the post-reset notification every poll. Far below a real 5-hour
    /// reset; the adapter already de-jitters, this is a second line of defense (Baseline §21 #11).
    static let minResetAdvanceForRollover: TimeInterval = 60

    /// States that arm the pre-reset warning (UI Spec §4 "previous state was warning").
    /// Defined on `AppState` since STEP_188 so the grading substrate reads the same set.
    static let warningStates: Set<AppState> = AppState.warningStates

    private let store: SQLiteStore?
    private let presenter: NotificationPresenter
    /// `WeeklyLadder.isEnabled`, injectable so the tests can run the ladder both ways
    /// whatever the shipped constant says (STEP_232; on since STEP_233).
    private let weeklyLadderEnabled: Bool

    // Per-tool cross-poll memory.
    private var windowStartByTool: [Tool: Int] = [:]
    private var lastResetsAt: [Tool: Date] = [:]
    /// Last provider-reported window width per tool — the fallback bucket for `markDismissed`,
    /// which runs outside a poll cycle and has no signal to read the width off (REV-59 §5).
    private var lastWindowSeconds: [Tool: Int] = [:]
    private var offMachineSustained: [Tool: Int] = [:]
    private var wasInWarningThisWindow: [Tool: Bool] = [:]
    private var hadOpenWindowLastPoll: [Tool: Bool] = [:]

    private var observationTasks: [Task<Void, Never>] = []

    public init(store: SQLiteStore?, presenter: NotificationPresenter,
                weeklyLadderEnabled: Bool = WeeklyLadder.isEnabled) {
        self.store = store
        self.presenter = presenter
        self.weeklyLadderEnabled = weeklyLadderEnabled
    }

    deinit { observationTasks.forEach { $0.cancel() } }

    // MARK: Wiring

    /// Subscribes to the `StateEngine` `windowResets` bus, which clears fired-notification state
    /// for the ended window. Path 1 and Path 2 arrive together via `evaluateCycle`, called by the
    /// poll driver on every evaluation (STEP_28 — a separate transition bus raced the same
    /// cycle's poll signal, defeating the §16 no-stacking arbitration).
    public func start(windowResets: AsyncStream<Tool>) {
        observationTasks.append(Task { [weak self] in
            for await tool in windowResets { await self?.handleWindowReset(tool) }
        })
    }

    // MARK: Per-cycle arbitration (Baseline §16, UI Spec §4.2 / D-11 — STEP_28)

    /// One evaluation cycle for one tool. Collects the Path 1 transition candidate (if the state
    /// changed) and all Path 2 signal candidates (if a poll signal is available — JSONL-delta and
    /// staleness evaluations pass `signal: nil`), then fires only the single highest-§16-priority
    /// candidate. Losers are logged and NOT persisted, so their caps/cooldowns are not consumed
    /// and they stay eligible next cycle. Ties resolve to the earliest-collected candidate — the
    /// transition, when both paths offer the same rank.
    public func evaluateCycle(
        change: StateChange?, signal: NotificationSignal?, now: Date
    ) async {
        // An episode ends when a *poll* no longer sees a blocking limit (REV-96 §2.1): recovery,
        // or the blocking limit's reset passing, which the R33-7 degradation already turned into
        // "no episode". Only a poll signal can say so — a JSONL delta or a staleness evaluation
        // carries no account reading, and must never end a block by silence.
        if let signal, signal.blockEpisode == nil { await setEpisodeKey(signal.tool, nil) }
        // Same idea, one period longer: retire a nearly-spent instance whose reset has passed
        // (§3.5). Only a poll carries an account reading, so only a poll does this housekeeping.
        if let signal { await expirePassedNearlySpentValues(signal) }
        if let signal { await expirePassedLadderValues(signal) }

        var candidates: [NotificationDecision] = []
        if let change, let c = await transitionCandidate(change, signal: signal, now: now) {
            candidates.append(c)
        }
        if let signal {
            candidates.append(contentsOf: await signalCandidates(signal))
        }
        // STEP_144: a disabled group is dropped *before* arbitration — a switched-off
        // higher-priority event must not silence an enabled lower one — and before `fire`,
        // so it consumes no cap and leaves no row (re-enabling starts clean).
        candidates = await dropDisabledGroups(candidates)
        guard let winnerIndex = candidates.indices.min(by: {
            candidates[$0].eventType.arbitrationPriority
                < candidates[$1].eventType.arbitrationPriority
        }) else { return }
        for (index, loser) in candidates.enumerated() where index != winnerIndex {
            logSuppressed(loser.tool, loser.eventType, reason: "arbitration")
        }
        await fire(candidates[winnerIndex], now: now)
    }

    // MARK: Path 1 — transition-based (Baseline §13.2)

    private func transitionCandidate(
        _ change: StateChange, signal: NotificationSignal?, now: Date
    ) async -> NotificationDecision? {
        let ws = Self.windowStart(resetsAt: change.resetsAt,
                                  windowSeconds: change.primaryWindowSeconds, now: now)
        // Belt-and-braces for the low-allowance rule (§16 REV-59 amendment, D-64): At risk and
        // Bad timing are already unreachable there — `StateEngine.classify` returns Elevated/Healthy
        // from the used percentage before it reaches those ranks — and Spend control is excluded
        // by the rule itself (it requires a monthly limit, which the backstop forbids and neither
        // named plan has). Stated anyway so the surviving set is legible at the gate rather than
        // only inferable from another file.
        if change.isLowAllowanceShape, change.new != .overQuota {
            switch change.new {
            case .atRisk: logSuppressed(change.tool, .atRisk, reason: "low_allowance_shape")
            case .badTiming: logSuppressed(change.tool, .badTiming, reason: "low_allowance_shape")
            case .spendControl: logSuppressed(change.tool, .spendControl, reason: "low_allowance_shape")
            default: break   // every other state was never a Path 1 candidate
            }
            return nil
        }
        switch change.new {
        case .overQuota:
            return await blockDecision(change, signal: signal, .overQuota, ws,
                                       max: Self.overQuotaMaxPerWindow,
                                       copyVariant: Self.overQuotaVariant(change))
        case .atRisk:
            return await transitionDecision(change, signal: signal, .atRisk, ws,
                                            max: Self.atRiskMaxPerWindow)
        case .badTiming:
            // REV-106 §2.4: on a seven-day primary "85 % with the reset ≥ 90 minutes away" is a
            // position mark, not a predicament — event 9 replaces it, on the same poll since
            // STEP_238 (`weeklyPrimaryNearlySpentPct` is this line; it was 10 % left). The
            // *state* is untouched; only event 2 is not sent. Read off the change, because this
            // transition can arrive without a poll signal. The low-allowance shape has already
            // returned above, so a seven-day width here is a weekly.
            if change.primaryWindowSeconds == QuotaSnapshot.weeklyPrimarySeconds {
                guard !weeklyLadderEnabled else {
                    logSuppressed(change.tool, .badTiming, reason: "weekly_primary")
                    return nil
                }
                Logger.info("Ladder would suppress bad_timing", component: .notificationEngine,
                            metadata: ["tool": change.tool.rawValue])
            }
            return await transitionDecision(change, signal: signal, .badTiming, ws,
                                            max: Self.badTimingMaxPerWindow)
        case .spendControl:                                          // ⚠ D1 (working assumption)
            return await blockDecision(change, signal: signal, .spendControl, ws,
                                       max: Self.spendControlMaxPerWindow)
        case .limitNearlySpent:
            return await nearlySpentDecision(change, signal: signal, ws)
        default:
            return nil
        }
    }

    /// Over-quota copy variant — the full §7.1 three-case matrix (STEP_27): Claude case 1
    /// (credits accruing), case 2 (credits used earlier this window, toggle now off — the
    /// cached/last-observed value carried on the `StateChange`), case 3 (hard block, no
    /// credits); Codex is a single hard-block copy (no variant). Case 1 is the banner's
    /// "running on usage credits" copy (REV-102 §2.6 — STEP_221), so a spent cap — credits on,
    /// nothing left to charge — is case 3: the block is real.
    static func overQuotaVariant(_ change: StateChange) -> String? {
        guard change.tool == .claude else { return nil }
        if change.moneyState == .capReached { return "case_3" }
        if change.extraUsageEnabled == true { return "case_1" }
        if let used = change.extraUsageUsedCredits, used > 0 { return "case_2" }
        return "case_3"
    }

    /// Over quota / Spend control — **one banner per block episode** (REV-96 §2.1 — STEP_193).
    ///
    /// The cap used to be one per `window_start`, which is one per *five-hour window instance*.
    /// A block that outlives the five-hour window — a spent weekly, a reached monthly — therefore
    /// re-armed every few hours: the tester's weekly block of 4–7 Sep produced **eleven** banners,
    /// one per rollover underneath it. Keyed to the episode instead, a rollover, a stale gap and a
    /// relaunch are all the same block, and a second limit reaching the ceiling inside it changes
    /// the copy rather than the count.
    ///
    /// With **no episode to key on** — a block flagged with no usable reset anywhere — this falls
    /// back to the per-window cap, so that path is never worse than what ships today.
    private func blockDecision(
        _ change: StateChange, signal: NotificationSignal?,
        _ type: NotificationEventType, _ windowStart: Int,
        max: Int, copyVariant: String? = nil
    ) async -> NotificationDecision? {
        guard let episode = change.blockEpisode else {
            return await transitionDecision(change, signal: signal, type, windowStart,
                                            max: max, copyVariant: copyVariant)
        }
        guard await !episode.matches(storedKey: storedEpisodeKey(change.tool)) else {
            logSuppressed(change.tool, type, reason: "episode_already_fired")
            return nil
        }
        return decision(change, signal: signal, type, windowStart,
                        copyVariant: copyVariant, blockEpisode: episode,
                        longLimit: change.longLimit?.limit == episode.limit ? change.longLimit : nil)
    }

    /// The per-tool block-episode key (§17.1 `block_episode.<tool>`), mirrored in memory so an
    /// ordinary poll costs no settings read. The outer optional is "not loaded yet"; the inner one
    /// is "loaded, no episode".
    private var blockEpisodeKeys: [Tool: String?] = [:]

    private func storedEpisodeKey(_ tool: Tool) async -> String? {
        if let cached = blockEpisodeKeys[tool] { return cached }
        let raw = (try? await store?.readSetting(key: BlockEpisode.settingsKey(for: tool))) ?? nil
        blockEpisodeKeys[tool] = raw
        return raw
    }

    private func setEpisodeKey(_ tool: Tool, _ key: String?) async {
        guard await storedEpisodeKey(tool) != key else { return }
        blockEpisodeKeys[tool] = key
        try? await store?.writeSetting(key: BlockEpisode.settingsKey(for: tool), value: key)
    }

    /// Event 9 — **once per limit instance** (REV-96 §3.2 — STEP_194).
    ///
    /// The instance is the limit plus its reset (`nearly_spent.<tool>.<limit>` in `settings`,
    /// value the reset in unix seconds), so a new week or a new month fires again while the same
    /// one never fires twice — across a five-hour rollover, a stale gap and a relaunch, exactly
    /// like the block episode beside it. Compared through the Core reset tolerance rather than by
    /// string, because the provider wobbles `resets_at` by a second inside one period.
    ///
    /// **There is no per-window cap here and that is deliberate.** The `notification_events`
    /// window bucket is the *five-hour* window; a weekly warning keyed to it would re-arm every
    /// few hours, which is the defect STEP_193 removed next door.
    ///
    /// With no assessment on the change — a rank-5b transition that carried none, which the
    /// classifier cannot produce — nothing fires rather than something unkeyed.
    private func nearlySpentDecision(
        _ change: StateChange, signal: NotificationSignal?, _ windowStart: Int
    ) async -> NotificationDecision? {
        guard let limit = change.longLimit else {
            logSuppressed(change.tool, .limitNearlySpent, reason: "no_assessment")
            return nil
        }
        let stored = await storedNearlySpentValue(change.tool, limit.limit)
        guard !limit.matchesNearlySpent(storedValue: stored) else {
            logSuppressed(change.tool, .limitNearlySpent, reason: "instance_already_fired")
            return nil
        }
        return NotificationDecision(
            tool: change.tool, eventType: .limitNearlySpent, windowStart: windowStart,
            copyVariant: limit.limit.rawValue,
            utilizationPct: change.utilizationPct, resetsAt: limit.resetsAt,
            project: signal?.project, longLimit: limit)
    }

    /// The per-(tool, limit) nearly-spent keys (§17.1 `nearly_spent.<tool>.<limit>`), mirrored in
    /// memory exactly like `blockEpisodeKeys` so an ordinary poll costs no settings read. The
    /// outer optional is "not loaded yet"; the inner one is "loaded, nothing stored".
    private var nearlySpentValues: [String: String?] = [:]

    private func storedNearlySpentValue(_ tool: Tool, _ limit: BlockEpisode.Limit) async -> String? {
        let key = LongLimitAssessment.nearlySpentSettingsKey(tool: tool, limit: limit)
        if let cached = nearlySpentValues[key] { return cached }
        let raw = (try? await store?.readSetting(key: key)) ?? nil
        nearlySpentValues[key] = raw
        return raw
    }

    private func setNearlySpentValue(_ tool: Tool, _ limit: BlockEpisode.Limit,
                                     _ value: String?) async {
        guard await storedNearlySpentValue(tool, limit) != value else { return }
        let key = LongLimitAssessment.nearlySpentSettingsKey(tool: tool, limit: limit)
        nearlySpentValues[key] = value
        try? await store?.writeSetting(key: key, value: value)
    }

    /// §3.5 housekeeping: a stored instance whose reset has passed is gone, so its row goes with
    /// it. Nothing depends on this for correctness — a new instance has a different reset and
    /// would not match anyway — it keeps `settings` from accumulating one dead row per period.
    private func expirePassedNearlySpentValues(_ s: NotificationSignal) async {
        for limit in BlockEpisode.Limit.allCases {
            guard let raw = await storedNearlySpentValue(s.tool, limit),
                  let epoch = TimeInterval(raw),
                  epoch <= s.now.timeIntervalSince1970 else { continue }
            await setNearlySpentValue(s.tool, limit, nil)
        }
    }

    // MARK: The weekly ladder (Baseline §16, REV-106 §2.2 / §2.4 — STEP_232)

    /// What the ladder offers on this poll: event 10 for the step the weekly is standing on,
    /// and — on a seven-day primary only — event 9 at the red line.
    ///
    /// **Level-triggered against what has already been announced**, not edge-triggered on a
    /// state change. On any fresh poll the step the weekly stands on is a candidate if it is
    /// deeper than the deepest step already announced for this instance, so:
    /// - a step that loses arbitration is offered again on the next poll (nothing is written
    ///   until `fire`);
    /// - a launch that finds the weekly past an unannounced mark announces it once;
    /// - an overtaken step is never sent — the first reading at 23 % left sends `quarter` and
    ///   `half` can no longer follow;
    /// - the five-hour window's state does not gate it. Rank 10 holds only while no warning is
    ///   active; the ladder reads the assessment, not the rank.
    ///
    /// Only a poll signal carries a weekly, so a restored reading, a staleness evaluation and a
    /// JSONL delta can never reach this.
    ///
    /// **While the switch is off** every decision is logged as *would send*, nothing is
    /// returned, and so nothing is written or delivered.
    private func ladderCandidates(
        _ s: NotificationSignal, windowStart: Int
    ) async -> [NotificationDecision] {
        guard let weekly = s.weekly else { return [] }
        let key = WeeklyLadder.settingsKey(tool: s.tool, limit: weekly.limit)
        var candidates: [NotificationDecision] = []

        // The red line. On a secondary this is rank 5b's transition (Path 1), unchanged. On a
        // seven-day primary rank 5 (Bad timing) outranks 5b, so no such transition exists and
        // the event is decided here, under the same `nearly_spent.*` key with the primary as
        // the limit (§2.4) — at 85 % used there, the tier's line on that shape (STEP_238).
        if weekly.tier >= .nearlySpent { ladderReachedRedLine[key] = weekly.resetsAt }
        let nearlySpentStored = await storedNearlySpentValue(s.tool, weekly.limit)
        if weekly.limit == .primary, weekly.tier == .nearlySpent,
           !weekly.matchesNearlySpent(storedValue: nearlySpentStored) {
            if weeklyLadderEnabled {
                candidates.append(NotificationDecision(
                    tool: s.tool, eventType: .limitNearlySpent, windowStart: windowStart,
                    copyVariant: weekly.limit.rawValue, utilizationPct: s.utilizationPct,
                    resetsAt: weekly.resetsAt, project: s.project, longLimit: weekly))
            } else {
                logLadder("Ladder would send limit_nearly_spent", s.tool, weekly, step: nil)
            }
        }

        // The two early steps. Nearly spent and spent count as announced-below: once either
        // has been reached in an instance — announced (the stored key) or seen by this process
        // — neither early step can follow.
        guard let step = WeeklyLadder.step(for: weekly) else { return candidates }
        let reachedRedLine = weekly.matchesNearlySpent(storedValue: nearlySpentStored)
            || ladderReachedRedLine[key].map {
                QuotaSnapshot.isSameResetInstant($0.timeIntervalSince1970, weekly.resetsAt)
            } == true
        let announced = reachedRedLine
            ? WeeklyLadder.depthBelowEarlySteps
            : WeeklyLadder.announcedStep(
                storedValue: await storedLadderValue(s.tool, weekly.limit), for: weekly)?.depth ?? 0
        guard step.depth > announced else {
            logSuppressed(s.tool, .limitAheadOfPace, reason: "step_already_announced")
            return candidates
        }
        if weeklyLadderEnabled {
            candidates.append(NotificationDecision(
                tool: s.tool, eventType: .limitAheadOfPace, windowStart: windowStart,
                copyVariant: step.rawValue, utilizationPct: s.utilizationPct,
                resetsAt: weekly.resetsAt, longLimit: weekly))
        } else {
            logLadder("Ladder would send", s.tool, weekly, step: step)
        }
        return candidates
    }

    /// Weekly instances this process has seen at or past the red line, by ladder key — the
    /// in-memory half of "reached counts as announced-below". The persisted half is the
    /// `nearly_spent.*` key event 9 writes when it fires.
    private var ladderReachedRedLine: [String: Date] = [:]

    /// The per-(tool, limit) ladder keys (§17.1 `ladder.<tool>.<limit>`), mirrored in memory
    /// exactly like `nearlySpentValues` beside them.
    private var ladderValues: [String: String?] = [:]

    private func storedLadderValue(_ tool: Tool, _ limit: BlockEpisode.Limit) async -> String? {
        let key = WeeklyLadder.settingsKey(tool: tool, limit: limit)
        if let cached = ladderValues[key] { return cached }
        let raw = (try? await store?.readSetting(key: key)) ?? nil
        ladderValues[key] = raw
        return raw
    }

    private func setLadderValue(_ tool: Tool, _ limit: BlockEpisode.Limit,
                                _ value: String?) async {
        guard await storedLadderValue(tool, limit) != value else { return }
        let key = WeeklyLadder.settingsKey(tool: tool, limit: limit)
        ladderValues[key] = value
        try? await store?.writeSetting(key: key, value: value)
    }

    /// Housekeeping, as `expirePassedNearlySpentValues`: a ladder row whose week has reset is
    /// about a week that no longer exists. A new instance would not match it anyway.
    private func expirePassedLadderValues(_ s: NotificationSignal) async {
        for limit in BlockEpisode.Limit.allCases {
            guard let stored = WeeklyLadder.parse(await storedLadderValue(s.tool, limit)),
                  stored.epoch <= s.now.timeIntervalSince1970 else { continue }
            await setLadderValue(s.tool, limit, nil)
        }
    }

    private nonisolated func logLadder(
        _ message: String, _ tool: Tool, _ weekly: LongLimitAssessment, step: WeeklyLadder.Step?
    ) {
        var metadata = ["tool": tool.rawValue, "limit": weekly.limit.rawValue,
                        "used": String(format: "%.0f", weekly.usedPct),
                        "elapsed": String(format: "%.1f", weekly.elapsedPct)]
        if let step { metadata["step"] = step.rawValue }
        Logger.info(message, component: .notificationEngine, metadata: metadata)
    }

    private func transitionDecision(
        _ change: StateChange, signal: NotificationSignal?,
        _ type: NotificationEventType, _ windowStart: Int,
        max: Int, copyVariant: String? = nil
    ) async -> NotificationDecision? {
        guard await underCap(change.tool, type, windowStart, max: max) else {
            logSuppressed(change.tool, type, reason: "max_per_window")
            return nil
        }
        return decision(change, signal: signal, type, windowStart, copyVariant: copyVariant)
    }

    /// Builds a Path-1 decision once the gate — per-window cap or per-episode key — has passed.
    /// The same-cycle poll signal supplies the local context (project/surfaces) when available;
    /// JSONL-delta and staleness cycles pass no signal, and those fields stay nil (STEP_27).
    private func decision(
        _ change: StateChange, signal: NotificationSignal?,
        _ type: NotificationEventType, _ windowStart: Int,
        copyVariant: String?, blockEpisode: BlockEpisode? = nil,
        longLimit: LongLimitAssessment? = nil
    ) -> NotificationDecision {
        NotificationDecision(
            tool: change.tool, eventType: type, windowStart: windowStart, copyVariant: copyVariant,
            utilizationPct: change.utilizationPct, runwayMinutes: change.runwayMinutes,
            resetsAt: change.resetsAt,
            model: signal?.model,
            project: signal?.project,
            surfaces: signal?.surfaces ?? [],
            extraUsageUsedCredits: change.extraUsageUsedCredits,
            extraUsageMonthlyLimit: change.extraUsageMonthlyLimit,
            extraUsageCurrency: change.extraUsageCurrency,
            extraUsageCurrencyExponent: change.extraUsageCurrencyExponent,
            blockEpisode: blockEpisode,
            longLimit: longLimit)
    }

    // MARK: Path 2 — signal / re-arm (Baseline §13.2)

    /// Collects all poll-completion candidates for one tool. Detects window rollover and updates
    /// per-window memory *unconditionally* — that is observation state, not firing state, so it
    /// must advance even when a resulting candidate later loses arbitration.
    private func signalCandidates(_ s: NotificationSignal) async -> [NotificationDecision] {
        let tool = s.tool
        let ws = Self.windowStart(resetsAt: s.resetsAt,
                                  windowSeconds: s.primaryWindowSeconds, now: s.now)
        let previousWS = windowStartByTool[tool]
        windowStartByTool[tool] = ws
        let isFirstPoll = previousWS == nil
        // Continuity gate (docs/NOTIFICATIONS.md §5 Option A): a rollover only *reads* as "your
        // window has reset" when the previous poll still saw the old window open. If the previous
        // poll was the null-window shape (idle — `resets_at: null`), the new window is a fresh
        // start the user opened themselves, not a reset — post-reset stays silent, while the
        // housekeeping below still runs.
        let previousPollHadOpenWindow = hadOpenWindowLastPoll[tool] ?? false
        hadOpenWindowLastPoll[tool] = s.resetsAt != nil

        var candidates: [NotificationDecision] = []

        // Window rollover — reset per-window memory, then offer the post-reset notification
        // under the new window (Baseline §13.2, UI Spec §4 event 6). The ended window's rows
        // stay (90d substrate retention, §17.2); enforcement never sees them because every
        // query scopes window_start = current.
        // A key change alone is not enough: require the reset instant to have advanced past the
        // jitter tolerance, so a ±1s wobble in `resets_at` is not mistaken for a genuine rollover.
        // `lastResetsAt[tool]` still holds the previous poll's reset here (updated below).
        // Rollover is detected exactly once, so a post-reset candidate that loses arbitration is
        // lost for the window — accepted (STEP_28 decision): right after a reset utilization is
        // ~0 and all warning memory was just cleared, so a higher-priority competitor is a
        // cross-reset artifact, and §16 no-stacking is the hard rule.
        let resetAdvanced: Bool = {
            guard let previous = lastResetsAt[tool], let current = s.resetsAt else { return false }
            return current.timeIntervalSince(previous) > Self.minResetAdvanceForRollover
        }()
        if let previousWS, previousWS != ws, resetAdvanced {
            offMachineSustained[tool] = 0
            wasInWarningThisWindow[tool] = false
            if previousPollHadOpenWindow,
               let c = await windowResetPostCandidate(s, windowStart: ws) {
                candidates.append(c)
            } else if !previousPollHadOpenWindow {
                logSuppressed(tool, .windowResetPost, reason: "fresh_start_after_idle")
            }
        }

        if Self.warningStates.contains(s.state) { wasInWarningThisWindow[tool] = true }
        if let r = s.resetsAt { lastResetsAt[tool] = r }
        if let width = s.primaryWindowSeconds { lastWindowSeconds[tool] = width }

        // Window changed (§4.1a — STEP_146): one candidate per fact this poll recorded. Above the
        // low-allowance gate on purpose — it is a fact about the windows, not a rate — and with no
        // cap or cooldown: the signal exists only on the poll that observed it. A candidate that
        // loses arbitration is lost, like the post-reset one (the §2.8 line and History still
        // carry the fact).
        for fact in s.windowFacts {
            candidates.append(NotificationDecision(
                tool: tool, eventType: .windowChanged, windowStart: ws,
                copyVariant: fact.kind.rawValue, primaryWindowSeconds: s.primaryWindowSeconds,
                windowFact: fact))
        }

        // The low-allowance rule fires nothing on this path (§16 REV-59 amendment, UI Spec §4.1 /
        // D-60/D-64). At risk and Off-machine are forecast/rate-derived and have no inputs left once
        // §11.3 stops producing a burn rate; Fast burn and Multi-surface are rate-gated on a meter
        // where a 45-point two-minute jump is an ordinary turn; Window reset is off **by user
        // ruling** — on a 30-day window it fires once a month and carries nothing to act on.
        //
        // **Window reset needed no un-muting for Plus** *(STEP_101, re-ruled 2026-08-13)*: the
        // ruling above was argued for a 30-day window and still holds there, and Plus simply stops
        // reaching this gate once the rule stops testing window width. One boolean, corrected at
        // its source — the same self-correction the §2.3 tier note gets (REV-63 §5). Anything
        // reaching this list is a shape where a reset genuinely carries nothing to act on.
        //
        // The gate sits *below* all the bookkeeping above deliberately: rollover detection, the
        // per-window memory clear, `lastResetsAt` and `hadOpenWindowLastPoll` are observation
        // state, not firing state, and must advance whether or not anything fires.
        guard !s.isLowAllowanceShape else {
            for type in [NotificationEventType.atRisk, .fastBurnSpike, .offMachineBurn,
                         .multiSurface, .windowResetPre, .windowResetPost] {
                logSuppressed(tool, type, reason: "low_allowance_shape")
            }
            return candidates.filter { $0.eventType == .overQuota || $0.eventType == .windowChanged }
        }

        if let c = await atRiskRearmCandidate(s, windowStart: ws) { candidates.append(c) }
        if let c = await fastBurnCandidate(s, windowStart: ws) { candidates.append(c) }
        if let c = await offMachineCandidate(s, windowStart: ws) { candidates.append(c) }
        if let c = await multiSurfaceCandidate(s, windowStart: ws) { candidates.append(c) }
        candidates.append(contentsOf: await ladderCandidates(s, windowStart: ws))
        if !isFirstPoll, let c = await windowResetPreCandidate(s, windowStart: ws) {
            candidates.append(c)
        }
        return candidates
    }

    /// At-risk re-arm — once, after the first at-risk fire was dismissed and runway drops under
    /// 10 min (UI Spec §4 event 1). Capped by the same 2-per-window ceiling as the first fire.
    private func atRiskRearmCandidate(
        _ s: NotificationSignal, windowStart: Int
    ) async -> NotificationDecision? {
        guard s.state == .atRisk,
              let runway = s.runwayMinutes, runway < Self.atRiskRearmRunwayMin,
              let store else { return nil }
        guard let last = try? await store.lastNotificationEvent(
            tool: s.tool, eventType: .atRisk, windowStart: windowStart),
              last.dismissedAt != nil else { return nil }
        guard await underCap(s.tool, .atRisk, windowStart, max: Self.atRiskMaxPerWindow) else {
            return nil
        }
        return NotificationDecision(
            tool: s.tool, eventType: .atRisk, windowStart: windowStart, copyVariant: "rearm",
            utilizationPct: s.utilizationPct, runwayMinutes: runway, resetsAt: s.resetsAt,
            project: s.project)
    }

    /// Fast burn — ≥ 20% between two consecutive polls ≤ 5 min apart (STEP_189; was a 2-minute
    /// wall-clock window the 120s base could not fill), 10-min cooldown, 2-per-window cap
    /// (UI Spec §4 event 4 "Max per episode: 2" — STEP_28).
    private func fastBurnCandidate(
        _ s: NotificationSignal, windowStart: Int
    ) async -> NotificationDecision? {
        guard let delta = s.fastBurnDelta, delta >= Self.fastBurnDeltaPct else { return nil }
        guard await cooldownElapsed(s.tool, .fastBurnSpike, windowStart,
                                    cooldown: Self.fastBurnCooldown, now: s.now),
              await underCap(s.tool, .fastBurnSpike, windowStart,
                             max: Self.fastBurnMaxPerWindow) else { return nil }
        return NotificationDecision(
            tool: s.tool, eventType: .fastBurnSpike, windowStart: windowStart, copyVariant: nil,
            utilizationPct: s.utilizationPct, deltaPct: delta, model: s.model,
            project: s.project, surfaces: s.surfaces)
    }

    /// Off-machine burn — account rising while local is idle, sustained across 2+ polls, 20-min
    /// cooldown, 3-per-window cap (UI Spec §4 event 5). `nil` local metrics break the sustained
    /// run (cannot confirm idle), so this stays dormant until attribution supplies the inputs.
    private func offMachineCandidate(
        _ s: NotificationSignal, windowStart: Int
    ) async -> NotificationDecision? {
        let rising = (s.utilDeltaLast2Polls ?? 0) >= Self.offMachineDeltaPct
        // Idle = local activity observed but now older than the recency gap (REV-23), not a
        // token-rate floor — a long local turn writes no usage line and must not read as idle. A
        // never-observed session (`nil`) is "cannot confirm" and stays dormant.
        let localIdle = LocalAttribution.isConfirmedIdle(lastActivityAt: s.lastLocalActivityAt, now: s.now)
        guard rising && localIdle else { offMachineSustained[s.tool] = 0; return nil }

        let sustained = (offMachineSustained[s.tool] ?? 0) + 1
        offMachineSustained[s.tool] = sustained
        guard sustained >= Self.offMachineSustainedPolls else { return nil }
        guard await cooldownElapsed(s.tool, .offMachineBurn, windowStart,
                                    cooldown: Self.offMachineCooldown, now: s.now),
              await underCap(s.tool, .offMachineBurn, windowStart,
                             max: Self.offMachineMaxPerWindow) else { return nil }
        return NotificationDecision(
            tool: s.tool, eventType: .offMachineBurn, windowStart: windowStart, copyVariant: nil,
            utilizationPct: s.utilizationPct, resetsAt: s.resetsAt, project: s.project)
    }

    /// Multi-surface (Codex only) — 2+ active surfaces burning together, 10-min cooldown
    /// (UI Spec §4 event 6, Codex).
    private func multiSurfaceCandidate(
        _ s: NotificationSignal, windowStart: Int
    ) async -> NotificationDecision? {
        guard s.tool == .codex,
              s.activeSurfaceBucketCount >= Self.multiSurfaceMinBuckets,
              let delta = s.utilDeltaShortWindow, delta >= Self.multiSurfaceDeltaPct else {
            return nil
        }
        guard await cooldownElapsed(s.tool, .multiSurface, windowStart,
                                    cooldown: Self.multiSurfaceCooldown, now: s.now),
              await underCap(s.tool, .multiSurface, windowStart,
                             max: Self.multiSurfaceMaxPerWindow) else {
            return nil
        }
        return NotificationDecision(
            tool: s.tool, eventType: .multiSurface, windowStart: windowStart, copyVariant: nil,
            utilizationPct: s.utilizationPct, deltaPct: delta, model: s.model,
            project: s.project, surfaces: s.surfaces)
    }

    /// Pre-reset — window resets soon while the user is (or was) in a warning state this window
    /// (UI Spec §4 event 6). Once per window.
    private func windowResetPreCandidate(
        _ s: NotificationSignal, windowStart: Int
    ) async -> NotificationDecision? {
        guard let resetsAt = s.resetsAt else { return nil }
        let minsToReset = resetsAt.timeIntervalSince(s.now) / 60
        guard minsToReset > 0, minsToReset < Self.preResetWindowMin,
              wasInWarningThisWindow[s.tool] == true else { return nil }
        guard await underCap(s.tool, .windowResetPre, windowStart,
                             max: Self.windowResetPreMaxPerWindow) else { return nil }
        return NotificationDecision(
            tool: s.tool, eventType: .windowResetPre, windowStart: windowStart, copyVariant: nil,
            resetsAt: resetsAt, primaryWindowSeconds: s.primaryWindowSeconds)
    }

    /// Post-reset — a genuine reset (new reset > 4h30m away) was detected on rollover. Once per
    /// window (UI Spec §4 event 6). `windowStart` is already the new window.
    private func windowResetPostCandidate(
        _ s: NotificationSignal, windowStart: Int
    ) async -> NotificationDecision? {
        guard let resetsAt = s.resetsAt else { return nil }
        let minsToReset = resetsAt.timeIntervalSince(s.now) / 60
        guard minsToReset > Self.postResetGuardMin else { return nil }
        guard await underCap(s.tool, .windowResetPost, windowStart,
                             max: Self.windowResetPostMaxPerWindow) else { return nil }
        return NotificationDecision(
            tool: s.tool, eventType: .windowResetPost, windowStart: windowStart, copyVariant: nil,
            resetsAt: resetsAt, primaryWindowSeconds: s.primaryWindowSeconds)
    }

    // MARK: Window reset (Baseline §13.2)

    /// `windowReset(tool)` from `StateEngine` — resets per-window in-memory state only.
    /// `notification_events` rows are no longer deleted here (§13.2 v5.17 — they age out at
    /// 90 days via the shared cleanup job); prior-window rows are invisible to enforcement
    /// because every enforcement query scopes window_start = current.
    func handleWindowReset(_ tool: Tool) async {
        offMachineSustained[tool] = 0
        wasInWarningThisWindow[tool] = false
        // **The block episode is deliberately not cleared here** (STEP_193). A five-hour rollover
        // inside a spent weekly is the same block; ending the episode on the rollover is exactly
        // the defect this step removes. Only a poll that sees no blocking limit ends it.
        Logger.debug("Window reset — reset per-window notification state",
                     component: .notificationEngine, metadata: ["tool": tool.rawValue])
        // D-128 (STEP_226): a delivered "at risk" or "quota exceeded" about the window that just
        // ended is no longer true; the presenter decides which notices that covers.
        await presenter.windowDidReset(tool)
    }

    // MARK: User dismissal (re-arm eligibility)

    /// Marks the most recent fire of `type` in the current window as dismissed so the at-risk
    /// re-arm path becomes eligible (§13.2). Called by the presenter's delegate on user dismissal.
    public func markDismissed(tool: Tool, eventType: NotificationEventType, now: Date = Date()) async {
        let ws = windowStartByTool[tool]
            ?? Self.windowStart(resetsAt: lastResetsAt[tool],
                                windowSeconds: lastWindowSeconds[tool], now: now)
        try? await store?.markNotificationDismissed(
            tool: tool, eventType: eventType, windowStart: ws,
            dismissedAt: Int(now.timeIntervalSince1970))
    }

    // MARK: Gating helpers

    /// True when fewer than `max` rows of `type` exist in this window (max-per-window gate).
    private func underCap(
        _ tool: Tool, _ type: NotificationEventType, _ windowStart: Int, max: Int
    ) async -> Bool {
        guard let store else { return true }
        let count = (try? await store.countNotificationEvents(
            tool: tool, eventType: type, windowStart: windowStart)) ?? 0
        return count < max
    }

    /// True when the cooldown has elapsed since the last fire of `type` in this window.
    private func cooldownElapsed(
        _ tool: Tool, _ type: NotificationEventType, _ windowStart: Int,
        cooldown: TimeInterval, now: Date
    ) async -> Bool {
        guard let store,
              let last = try? await store.lastNotificationEvent(
                tool: tool, eventType: type, windowStart: windowStart) else { return true }
        return now.timeIntervalSince1970 - Double(last.firedAt) >= cooldown
    }

    /// Writes the fired-notification row then delivers via the presenter (Baseline §13.2 order:
    /// write-then-deliver). A store write failure is logged by `SQLiteStore` and does not block
    /// delivery.
    private func fire(_ decision: NotificationDecision, now: Date) async {
        try? await store?.writeNotificationEvent(
            tool: decision.tool, eventType: decision.eventType,
            firedAt: Int(now.timeIntervalSince1970), windowStart: decision.windowStart,
            copyVariant: decision.copyVariant)
        // Written before delivery, like the row above: a block episode that fired must stay fired
        // across a crash, a rollover and a relaunch (STEP_193).
        if let episode = decision.blockEpisode { await setEpisodeKey(decision.tool, episode.key) }
        // Written before delivery for the same reason: a nearly-spent warning that fired must
        // stay fired for that week or month, across a rollover, a gap and a relaunch (STEP_194).
        if decision.eventType == .limitNearlySpent, let limit = decision.longLimit {
            await setNearlySpentValue(decision.tool, limit.limit, limit.nearlySpentStoredValue)
        }
        // And the ladder's own key, only here: a step that lost arbitration wrote nothing and
        // is a candidate again on the next poll (REV-106 §2.2 — STEP_232).
        if decision.eventType == .limitAheadOfPace, let weekly = decision.longLimit,
           let step = decision.copyVariant.flatMap(WeeklyLadder.Step.init(rawValue:)) {
            await setLadderValue(decision.tool, weekly.limit,
                                 WeeklyLadder.storedValue(for: weekly, step: step))
        }
        await presenter.present(decision)
        Logger.info("Notification fired", component: .notificationEngine,
                    metadata: ["tool": decision.tool.rawValue,
                               "event": decision.eventType.rawValue,
                               "variant": decision.copyVariant ?? "—",
                               "episode": decision.blockEpisode?.key ?? "—"])
    }

    /// Reads each candidate group's `settings` row once (absent ⇒ the group's default; no store ⇒
    /// defaults) and keeps only candidates whose group is on.
    private func dropDisabledGroups(_ candidates: [NotificationDecision]) async -> [NotificationDecision] {
        guard !candidates.isEmpty else { return candidates }
        var enabled: [NotificationGroup: Bool] = [:]
        for group in Set(candidates.compactMap { $0.eventType.group }) {
            let raw = try? await store?.readSetting(key: group.settingsKey)
            enabled[group] = NotificationGroup.isEnabled(raw ?? nil, for: group)
        }
        return candidates.filter { candidate in
            // No group ⇒ no switch ⇒ always on (window changed, STEP_146).
            guard let group = candidate.eventType.group else { return true }
            if enabled[group] == true { return true }
            logSuppressed(candidate.tool, candidate.eventType, reason: "group_disabled")
            return false
        }
    }

    private nonisolated func logSuppressed(
        _ tool: Tool, _ type: NotificationEventType, reason: String
    ) {
        Logger.debug("Notification suppressed", component: .notificationEngine,
                     metadata: ["tool": tool.rawValue, "event": type.rawValue, "reason": reason])
    }

    /// The unix-second start of the window a `resetsAt` belongs to, or a coarse clock-based bucket
    /// of the same width when the window is null (Codex null-window / an unanchored one) so
    /// over-quota and spend-control still key to a stable window.
    ///
    /// **`windowSeconds` is the provider-reported width** (REV-59 §5). It used to be a hardcoded
    /// five hours, and every per-window cap, cooldown key and `stableRequestID` was derived from
    /// it — insurance denominated in the wrong units, the same defect class REV-57 §3 named in its
    /// guards 3 and 4. The cost was live and reachable: a block on an *unanchored* 30-day window
    /// takes the clock-bucket branch, and a five-hour bucket rolls 144 times inside that window, so
    /// one unchanged block re-notified the user every five hours. Falls back to five hours when the
    /// provider reports no width, which today means Claude, where five hours is the truth.
    static func windowStart(resetsAt: Date?, windowSeconds: Int?, now: Date) -> Int {
        let width = windowSeconds ?? fallbackWindowLength
        if let resetsAt { return Int(resetsAt.timeIntervalSince1970) - width }
        let n = Int(now.timeIntervalSince1970)
        return n - (n % width)
    }
}
