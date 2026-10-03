import Foundation

/// Owns per-tool current/previous state, the `windowResets` event bus, and the transition
/// result (Baseline §13, §13.2, PATTERNS.md §Actor usage). It classifies each evaluation with
/// the §13 priority list — first matching condition wins — and knows nothing about
/// notifications or cooldowns. Transitions are *returned* from `evaluate` (STEP_28) rather
/// than published on a bus, so the caller can arbitrate Path 1 against the same cycle's
/// Path 2 signal without a stream/direct-call race.
///
/// Classification is a pure static function (`classify`) so the whole priority list is unit
/// testable without the actor; the actor adds per-tool memory (previous state, last poll time
/// for the 10-minute cached-state TTL, last reset time for `windowReset`), event emission, and
/// `state_transitions` persistence.
public actor StateEngine {

    // MARK: Thresholds (UI Spec §5 — plan-relative starting values)
    static let atRiskUtilFloor = 75.0
    static let atRiskRunwayGateMin = 30.0
    static let badTimingUtil = 85.0
    static let badTimingResetDistanceMin = 90.0
    static let fastBurnDeltaPct = 20.0
    static let offMachineBurnDeltaPct = 2.0
    static let overQuotaUtil = 100.0
    /// The amber boundary on the low-allowance shape (§13 REV-59 amendment, UI Spec D-60). With
    /// no forecast there is no `runway < minutes-to-reset` comparison left to reach rank 9, so
    /// Elevated is reached from the used percentage alone. Shares its value with the amber step of
    /// `Fmt.thresholdDot`, which paints the same meter in the display.
    static let lowAllowanceElevatedUtil = 60.0
    /// The long-limit amber floor (UI Spec §5, REV-96 §2.2/§3.10): a secondary window or monthly
    /// pool must be at least this spent before being ahead of its calendar can turn it amber.
    ///
    /// It exists because the pace clock alone is trigger-happy early in a long period: 3 % used
    /// on day one of a week is "ahead of schedule" and means nothing. The floor is what makes
    /// amber a statement about the *budget* rather than about the first morning.
    ///
    /// **Replay-derived, not chosen** (STEP_196, `scripts/long_limit_replay.py`, evidence in
    /// `docs/evidence/STEP_196/`). Swept over {0, 30, 40, 50, 60} against twelve Claude weekly
    /// windows, eleven Codex weekly windows and four monthly cycles. On the one window in the
    /// fleet that ever reached 100 %, this value would have gone amber **49 hours** before the
    /// block (40 buys four more hours for double the Claude noise; 60 costs seventeen and
    /// silences the highest Claude window observed). On Claude it fires on 14 of 1 059
    /// post-grace hours across twelve windows, missing none. **One symbol, both providers** —
    /// the sweep gave no reason to fork, and Codex stays formally under-evidenced (REV-96 §5.5).
    public static let longLimitAheadFloorPct = 50.0
    /// The long-limit amber trigger (UI Spec §5, REV-98 §2.1 — STEP_200): a limit past the floor
    /// and past the grace turns amber when its own pace **projects the period to finish past
    /// this** — `used% / elapsed% × 100`. It supersedes REV-96 §2.2's bare `used > elapsed`,
    /// which is this test at 100 and could not tell a rounding error from a blowout.
    ///
    /// **Replay-derived, over the STEP_196 corpus** (`scripts/long_limit_replay.py --projection`,
    /// evidence in `docs/evidence/REV98_projection_replay/`). Claude weekly is the only group
    /// with any sensitivity: 100 fires on 17 of 970 post-day-one hours, 110 on 8, and 115 misses
    /// the tester's 2026-08-28 week — at 80 % the closest any Claude weekly has come to the
    /// ceiling. Codex is flat from 100 to 125 (every Codex amber projects to 117 % or more) and
    /// the one exhausted window in the fleet keeps its full **49-hour** lead at every candidate.
    ///
    /// **The evidence supports any value in [105, 110] and cannot split them** — the same
    /// posture `longLimitNearlySpentPct` takes at 90. 110 is chosen for room above the 100–102
    /// noise band (five sub-1-point Claude ambers, all one run on 21–22 July 2026, on a window
    /// that peaked at 72 %), on whole-integer readings at hourly grain. 105 is the one-constant
    /// fallback if dogfood finds amber too quiet.
    public static let longLimitProjectionPct = 110.0
    /// The long-limit red line (UI Spec §5, REV-96 §2.2/§3.10): at or past this, the limit is
    /// nearly spent whatever the pace, and event 9 fires once for that instance.
    ///
    /// **Replay-derived, and the weakest number in this file** (STEP_196). The fleet contains
    /// exactly **one** exhausted long limit — the tester's Codex weekly, 4 Sep — so 85, 90 and
    /// 95 all warn it, none miss it, and none is measurably better: 90 leads the block by 8 h
    /// and 95 by 7 h, a gap inside the ±1 h grain the hourly corpus can resolve. 90 was kept
    /// because the evidence cannot discriminate, not because it won. Re-grade when a second
    /// exhaustion is ever recorded.
    public static let longLimitNearlySpentPct = 90.0
    /// The weekly ladder's second mark (UI Spec §5, REV-106 §2.6 — STEP_232): a weekly that is
    /// ahead of pace is on step `quarter` at or past this, and on step `half` below it. A
    /// notification mark only — no state, colour or tier reads it.
    ///
    /// **Supported, not proven** (`scripts/long_limit_replay.py --ladder`, evidence in
    /// `docs/evidence/REV106_ladder_replay/`). 70–75 % used reaches all three exhausted weeks
    /// in the fleet and no completed one; 80 misses one of the three. The corpus cannot choose
    /// inside the range, and 75 is `atRiskUtilFloor`, so no new number enters the app.
    public static let weeklySecondNoticePct = 75.0
    /// Where a **seven-day primary** is nearly spent *for notifications* (UI Spec §5, REV-106
    /// §2.4 as amended — STEP_238): the line the weekly-only tab already turns red at, so the
    /// notice and the red state arrive together. A notification mark only — the secondary
    /// weekly, the monthly, rank 5b and every display reader keep `longLimitNearlySpentPct`.
    ///
    /// Defined as Bad timing's line rather than as a number so the two cannot drift: rank 5
    /// is what paints that tab red, and this is the notice that goes with it (owner ruling
    /// 2026-10-02 — at 13 % left the tab had been red for an hour and nothing had been sent).
    public static let weeklyPrimaryNearlySpentPct = badTimingUtil
    /// The line a **model allowance** is promoted at — its own symbol since STEP_194, pinned at
    /// the value Weekly-elevated used to lend it.
    ///
    /// It is deliberately *not* `longLimitNearlySpentPct`. Model windows are neither a secondary
    /// window nor a monthly pool, so REV-96 never tiers them; re-pointing this borrow at the new
    /// red line would silently stop a model allowance warning between 85 % and 90 %, a change
    /// nobody asked for. Retiring `weeklyElevatedUtil` must not move a threshold on its way out.
    public static let modelWindowWarnLinePct = 85.0
    /// De-escalation hysteresis (v5.4 §13.4, REV-17): escalate immediately; adopt a calmer
    /// state only after this many consecutive calmer poll-triggered evaluations. Stops
    /// healthy↔elevated flapping in bursty agentic sessions.
    static let deEscalationCalmPolls = 3
    /// §1.6 money-glyph de-escalation: escalate to a hotter glyph immediately (a real charge must
    /// show at once), demote only after this many confirming poll-triggered evaluations, so a dip
    /// to 99% or a wobble at the arm boundary does not blink. Same grammar as `deEscalationCalmPolls`,
    /// tuned to 2 per REV-29.
    static let glyphDemotePolls = 2
    /// Cached state is shown in preference to a grey fallback until it is this stale (§13, task
    /// line "Cached state TTL: 10 minutes"), then the tool drops to Idle/fallback.
    static let cachedStateTTL: TimeInterval = 600
    /// A window reset is only real when `resets_at` advances by more than this — and a window is
    /// only *expired* once `now` is more than this past its `resets_at` (R33-7). Aliases the one
    /// Core tolerance (`QuotaSnapshot.resetJitterTolerance`) shared with the display's expiry
    /// degradation, so the engine and the card read the same boundary.
    static let resetJitterTolerance: TimeInterval = QuotaSnapshot.resetJitterTolerance

    private let store: SQLiteStore?

    private var currentStates: [Tool: AppState] = [:]
    private var lastSuccessfulPollAt: [Tool: Date] = [:]
    private var lastPrimaryResetsAt: [Tool: Date] = [:]
    /// Last utilization read from a *live* primary window per tool — the utilization-at-crossing
    /// on the §17.1 `window_reset` discontinuity row (STEP_52). Read before the reset evaluation
    /// updates it, so the row carries the last pre-crossing reading, never the new window's;
    /// cleared when a reset fires.
    private var lastLivePrimaryUsedPct: [Tool: Double] = [:]
    /// Consecutive calmer poll-triggered classifications per tool (§13.4 de-escalation hysteresis).
    private var calmStreaks: [Tool: Int] = [:]
    /// §1.6 money-glyph hysteresis state, mirroring `calmStreaks` (display-only). Claude-only in
    /// practice; the map keys on Tool for uniformity.
    private var currentGlyphs: [Tool: MoneyGlyph] = [:]
    private var glyphDemoteStreaks: [Tool: Int] = [:]
    /// §13.4 dominant-agent slot selection — fed the hysteresis-resolved state each evaluation.

    private let windowResetContinuation: AsyncStream<Tool>.Continuation

    /// 5-hour window reset bus — clears per-window notification state (Baseline §13.2).
    public nonisolated let windowResets: AsyncStream<Tool>

    public init(store: SQLiteStore? = nil) {
        self.store = store
        (windowResets, windowResetContinuation) = AsyncStream.makeStream()
    }

    /// The last classified state for `tool`, or `nil` before its first evaluation.
    public func currentState(for tool: Tool) -> AppState? { currentStates[tool] }

    /// Evaluates one tool. Records poll recency (for the TTL), detects a window reset, classifies
    /// via the §13 priority list, and — when the state changed — returns the `StateChange`, writes
    /// `state_transitions`, and logs the transition. The first evaluation for a tool establishes
    /// the state silently (`change == nil`) — unless it lands directly in a hard block, which is
    /// emitted as a transition from nothing (R33-6) so a cold launch into a blocked window can
    /// notify; the per-window notification cap dedupes across relaunches.
    @discardableResult
    public func evaluate(_ inputs: StateInputs) async -> StateEvaluation {
        let tool = inputs.tool

        // A successful poll refreshes the cached-state clock; JSONL deltas do not.
        if inputs.trigger == .poll, inputs.snapshot != nil {
            lastSuccessfulPollAt[tool] = inputs.now
        }

        let resetMoment = detectWindowReset(inputs)
        // Either ending bypasses the §13.4 de-escalation hold and the §1.6 glyph demote hold
        // (REV-85/D-109): rolled over or withdrawn, every held verdict was measured against a
        // window that no longer exists. (The earlier "a demolition must not bypass" reading cited
        // REV-64 §5, which ruled only on taxonomy/notification, never on hysteresis; dogfood
        // 2026-09-01 had the hold painting a fresh 100%-left window with the dead window's
        // At-risk card for 3 calm polls.)
        let windowReset = resetMoment != nil
        // §17.1 row (STEP_52): one per anchor — the R33-7 emission above is the dedup. Written
        // before any await-driven interleaving can re-enter: the anchor is already
        // advanced/cleared, so a reentrant evaluation cannot re-fire this anchor.
        if let moment = resetMoment, let store {
            try? await store.writeDiscontinuityEvents(
                tool: tool, observedAt: inputs.now,
                events: [DiscontinuityObservation(
                    eventType: moment.eventType,
                    // Derived from the width the provider reported, never a literal (REV-64 §6).
                    // `primaryWindowLength` — not `primaryWindowSeconds` — is what keeps Claude on
                    // `five_hour` through its own fallback. No snapshot ⇒ no width claim.
                    windowType: inputs.snapshot.flatMap {
                        DiscontinuityObservation.windowTypeName(seconds: Int($0.primaryWindowLength))
                    },
                    oldValue: String(Int(moment.oldResetsAt.timeIntervalSince1970)),
                    newValue: moment.newResetsAt.map { String(Int($0.timeIntervalSince1970)) },
                    utilizationPct: moment.utilizationPct)])
        }

        // §9.3 window-reset invalidation: while serving *cached* data (pollFailure trigger), a
        // primary `resets_at` that is already in the past means the window rolled over behind
        // our back — every cached utilization number is wrong, so the cache is stale immediately
        // regardless of age. A fresh `.poll` snapshot is never invalidated this way: its numbers
        // are current even when the server reports a just-passed reset boundary.
        let resetCrossed = inputs.trigger == .pollFailure
            && (inputs.snapshot?.primaryResetsAt
                    .map { inputs.now.timeIntervalSince($0) > Self.resetJitterTolerance } ?? false)
        let stale = resetCrossed
            || Self.isStale(lastPollAt: lastSuccessfulPollAt[tool], now: inputs.now)
        // R33-7 ordering: `detectWindowReset` and `resetCrossed` above read the RAW snapshot —
        // degrading first would nil the very `primaryResetsAt` those two rules compare. Only
        // what is classified or displayed (state, util, money glyph) reads the degraded one;
        // `classify` applies the same Core degradation internally so no caller can bypass it.
        let degraded = inputs.snapshot?.degradingExpiredWindows(now: inputs.now)
        let candidate = Self.classify(inputs, isStale: stale)
        let localActive = LocalAttribution.isActive(
            lastActivityAt: inputs.lastLocalActivityAt, now: inputs.now)
        let resolved = Self.resolveHysteresis(
            previous: currentStates[tool], candidate: candidate,
            calmStreak: calmStreaks[tool] ?? 0,
            trigger: inputs.trigger, windowReset: windowReset, localActive: localActive)
        calmStreaks[tool] = resolved.streak
        let newState = resolved.state
        if newState != candidate {
            Logger.debug("De-escalation held", component: .stateEngine,
                         metadata: ["tool": tool.rawValue,
                                    "held": newState.rawValue,
                                    "candidate": candidate.rawValue,
                                    "calm_polls": "\(resolved.streak)/\(Self.deEscalationCalmPolls)"])
        }
        let util = degraded?.primaryUsedPct
        // The block this evaluation sits inside, read once off the same degraded snapshot the
        // classification used (STEP_193) — carried to the coordinator so nothing downstream
        // re-derives it from an undegraded one.
        let episode = degraded?.blockEpisode

        // §1.6 money glyph — display-only, resolved from the shared forecast beside the state.
        // Escalate immediately, demote after `glyphDemotePolls` confirming polls (JSONL deltas may
        // escalate but never advance the demote streak, exactly like `resolveHysteresis`).
        let glyphCandidate = MoneyModel.moneyGlyphInstant(
            snapshot: degraded, forecast: inputs.forecast, now: inputs.now)
        let glyphResolved = Self.resolveGlyphHysteresis(
            previous: currentGlyphs[tool], candidate: glyphCandidate,
            demoteStreak: glyphDemoteStreaks[tool] ?? 0, trigger: inputs.trigger,
            windowReset: windowReset)
        currentGlyphs[tool] = glyphResolved.glyph
        glyphDemoteStreaks[tool] = glyphResolved.streak
        let glyph = glyphResolved.glyph

        let previous = currentStates[tool]
        currentStates[tool] = newState

        guard previous != newState else {
            return StateEvaluation(state: newState, change: nil,
                                   moneyGlyph: glyph, blockEpisode: episode)
        }
        // First evaluation: established silently — except a hard block (R33-6) and Limit nearly
        // spent (D-124, REV-100 §2.4). Path 1 fires on transitions, so a first evaluation landing
        // *directly* in either would notify nothing; emit it as a transition from nothing. Both are
        // position tests, not rates — a rate-derived state has no prior sample to be a *change*
        // from. Relaunch spam is already deduped: the block by the per-window cap and its episode
        // key, rank 5b by its limit-instance key (`nearly_spent.<tool>.<limit>`), all persisted.
        // A relaunch with a saved reading needs neither: restore sets it up stale (Idle) and the
        // first poll is a real transition. The exemption matters when there is no saved reading.
        if previous == nil, !newState.isHardBlock, newState != .limitNearlySpent {
            return StateEvaluation(state: newState, change: nil,
                                   moneyGlyph: glyph, blockEpisode: episode)
        }

        let effectivePrevious = previous ?? .idleFallback
        let change = StateChange(
            tool: tool, previous: effectivePrevious, new: newState, utilizationPct: util,
            runwayMinutes: inputs.forecast.runwayMinutes,
            resetsAt: degraded?.primaryResetsAt,
            // Both read off the degraded snapshot the classification itself used, so the
            // notification engine's window bucketing and its §16 gating describe the same window
            // this transition was decided against (REV-59 §5).
            primaryWindowSeconds: degraded?.primaryWindowSeconds,
            isLowAllowanceShape: degraded?.isLowAllowanceShape ?? false,
            extraUsageEnabled: degraded?.extraUsage?.isEnabled,
            extraUsageUsedCredits: degraded?.extraUsage?.usedCredits,
            extraUsageMonthlyLimit: degraded?.extraUsage?.monthlyLimit,
            extraUsageIsCached: degraded?.extraUsage?.usedCreditsIsCached ?? false,
            // Claude only — Codex snapshots carry `ExtraUsage.disabled`, which is not a card.
            moneyState: tool == .claude ? MoneyModel.moneyState(snapshot: degraded) : nil,
            extraUsageCurrency: degraded?.extraUsage?.currency,
            extraUsageCurrencyExponent: degraded?.extraUsage?.currencyExponent,
            blockEpisode: episode,
            longLimit: degraded?.longLimit(now: inputs.now))
        Logger.debug("Transition: \(effectivePrevious.rawValue)→\(newState.rawValue)",
                     component: .stateEngine,
                     metadata: ["tool": tool.rawValue,
                                "trigger": inputs.trigger.rawValue,
                                "util": util.map { "\(Int($0))%" } ?? "—"])
        if let store {
            try? await store.writeStateTransition(
                tool: tool, from: effectivePrevious, to: newState,
                triggeredBy: inputs.trigger, utilizationPct: util)
        }
        return StateEvaluation(state: newState, change: change,
                               moneyGlyph: glyph, blockEpisode: episode)
    }

    /// The details of one detected window reset — the §17.1 `window_reset` discontinuity row's
    /// content (STEP_52). `newResetsAt` is nil on the expiry-clause fire (Claude's post-reset
    /// null payload carries no `resets_at` — record what is known).
    struct WindowResetMoment {
        /// Which §17.1 row this is: a window that rolled over (`windowReset`) or one the provider
        /// took back while it was still live (`windowDemolished` — REV-64 §5).
        let eventType: DiscontinuityObservation.EventType
        let oldResetsAt: Date
        let newResetsAt: Date?
        /// Last utilization read while the crossed window was live — utilization-at-crossing. On a
        /// demolition this is what the provider forgave.
        let utilizationPct: Double?
    }

    /// Emits `windowReset(tool)` when the 5-hour window rolled over. A reset is **either** a
    /// `resets_at` that *advances* past the anchor by more than the jitter tolerance, **or the
    /// passing of the known one** (R33-7, §13.4): Claude's post-reset payload carries no
    /// `resets_at` at all, so an advance-only test is blind to the rollover precisely when it
    /// happens — the engine must read its own anchor against the clock, not wait to be told.
    /// **A third branch, and it is not a reset** (REV-64 §5 / STEP_102): a remembered anchor still
    /// in the future, against an incoming snapshot the adapter marked *unanchored*, means the
    /// provider **withdrew** a live window. That records a `window_demolished` row and clears the
    /// anchor, but yields nothing on this bus and notifies nobody.
    ///
    /// Fires **once per anchor**: only a live (non-expired) `resets_at` is ever stored, so an
    /// expiry fire clears the anchor and a run of null polls cannot re-emit the event and
    /// re-clear §13.2 notification state every cycle. Reads the RAW snapshot (never degraded).
    /// Returns the reset's details when one was detected (nil otherwise) — any returned moment,
    /// reset or demolition alike, bypasses the §13.4 de-escalation hold (and the §1.6 glyph
    /// demote hold) in the same evaluation (REV-85), and the caller writes the §17.1 row.
    private func detectWindowReset(_ inputs: StateInputs) -> WindowResetMoment? {
        let tool = inputs.tool
        let raw = inputs.snapshot?.primaryResetsAt
        let rawIsLive = raw.map { inputs.now.timeIntervalSince($0) <= Self.resetJitterTolerance }
            ?? false
        // Read before this evaluation refreshes the slot: on the advance-clause fire the
        // current snapshot's utilization already belongs to the NEW window.
        let utilAtCrossing = lastLivePrimaryUsedPct[tool]
        var reset = false
        var advanced = false
        var demolished = false
        let old = lastPrimaryResetsAt[tool]
        if let old {
            advanced = raw.map { $0.timeIntervalSince(old) > Self.resetJitterTolerance } ?? false
            let expired = inputs.now.timeIntervalSince(old) > Self.resetJitterTolerance
            // Third branch (REV-64 §5): the provider **withdrew** a live window. Neither of the
            // clauses above fits — the adapter nulled the anchor upstream so nothing advanced, and
            // the remembered anchor is still in the future so nothing expired. Both stayed false
            // on 2026-08-13, so no row was written **and** the anchor was never cleared; the corpse
            // then served as the "before" half of the next real reset six hours later.
            demolished = !advanced && !expired
                && inputs.snapshot?.primaryWindowIsUnanchored == true
            reset = advanced || expired || demolished
        }
        if rawIsLive {
            lastPrimaryResetsAt[tool] = raw
        } else if reset {
            lastPrimaryResetsAt[tool] = nil
        }
        // Utilization slot: a fired reset invalidates the pre-crossing reading; a live window's
        // reading (re-)seeds it — including on the same evaluation that fired the advance clause.
        if reset { lastLivePrimaryUsedPct[tool] = nil }
        if rawIsLive, let util = inputs.snapshot?.primaryUsedPct {
            lastLivePrimaryUsedPct[tool] = util
        }
        guard reset, let old else { return nil }
        if demolished {
            // **No `windowReset(tool)` and no notification.** The user's quota improved; there is
            // nothing to act on. Keeping it off the bus is also what keeps this entirely outside
            // STEP_101's notification scope — the two steps do not interact.
            Logger.info("Live window withdrawn by provider", component: .stateEngine,
                        metadata: ["tool": tool.rawValue,
                                   "withdrawn_reset": String(Int(old.timeIntervalSince1970)),
                                   "util": utilAtCrossing.map { "\(Int($0))%" } ?? "—"])
            return WindowResetMoment(eventType: .windowDemolished, oldResetsAt: old,
                                     newResetsAt: nil, utilizationPct: utilAtCrossing)
        }
        windowResetContinuation.yield(tool)
        Logger.debug("Window reset detected", component: .stateEngine,
                     metadata: ["tool": tool.rawValue])
        // new = the payload's anchor only when it actually advanced — on a pure expiry fire a
        // stale payload may still carry the OLD `resets_at`, which must not pose as the new one.
        return WindowResetMoment(eventType: .windowReset, oldResetsAt: old,
                                 newResetsAt: advanced ? raw : nil,
                                 utilizationPct: utilAtCrossing)
    }

    /// §13.4 de-escalation hysteresis (REV-17, v5.4): escalations (and re-confirmations of the
    /// held state) adopt immediately and clear the calm streak; a calmer candidate is held until
    /// `deEscalationCalmPolls` consecutive poll-triggered evaluations agree. Bypassed — adopted
    /// at once — on a window reset **or demolition** (either way the measured window no longer
    /// exists — REV-85/D-109) and on any drop to
    /// Idle/fallback (staleness/data-loss must never leave a warning frozen on dead data).
    /// JSONL-delta and pollFailure evaluations hold without advancing the count ("N calm polls"
    /// is poll-triggered evaluations verbatim). A held state emits no transition.
    ///
    /// One extra bypass (REV-23): leaving `off_machine_burn` while local is active adopts the calmer
    /// state at once. A resumed local session is definitive proof the burn is *not* off-machine, so
    /// the alarming "Claude Code is idle" banner must not linger for the 3-poll de-escalation while
    /// the burn card simultaneously shows an active local session. This fires on JSONL-delta too, so
    /// the first local write after a lull clears the banner immediately.
    static func resolveHysteresis(
        previous: AppState?, candidate: AppState, calmStreak: Int,
        trigger: StateTrigger, windowReset: Bool, localActive: Bool
    ) -> (state: AppState, streak: Int) {
        guard let previous else { return (candidate, 0) }
        guard candidate.priorityRank > previous.priorityRank else { return (candidate, 0) }
        if windowReset || candidate == .idleFallback { return (candidate, 0) }
        if previous == .offMachineBurn && localActive { return (candidate, 0) }
        guard trigger == .poll else { return (previous, calmStreak) }
        let streak = calmStreak + 1
        return streak >= deEscalationCalmPolls ? (candidate, 0) : (previous, streak)
    }

    /// §1.6 money-glyph hysteresis — the same escalate-now / demote-after-N rule as
    /// `resolveHysteresis`, applied to `MoneyGlyph.rank` with `N = glyphDemotePolls` (2). A hotter
    /// glyph (higher rank) adopts immediately and clears the streak; a cooler candidate is held
    /// until `glyphDemotePolls` consecutive poll-triggered evaluations agree. JSONL-delta /
    /// pollFailure evaluations may escalate but do not advance the demote streak. Reuses the §13.4
    /// primitive's *rule*, not the AppState-typed function (which ranks by `priorityRank` and
    /// carries state-specific bypasses with no money analogue).
    static func resolveGlyphHysteresis(
        previous: MoneyGlyph?, candidate: MoneyGlyph, demoteStreak: Int, trigger: StateTrigger,
        windowReset: Bool = false
    ) -> (glyph: MoneyGlyph, streak: Int) {
        guard let previous else { return (candidate, 0) }
        guard candidate.rank < previous.rank else { return (candidate, 0) }  // escalate/hold now
        // R33-7 + REV-85: a window reset or demolition bypasses the demote hold, exactly like
        // the §13.4 state bypass — a red `charging` `$` measured against a spent (or withdrawn)
        // window must not outlive it by 2 polls.
        if windowReset { return (candidate, 0) }
        guard trigger == .poll else { return (previous, demoteStreak) }      // only polls demote
        let streak = demoteStreak + 1
        return streak >= glyphDemotePolls ? (candidate, 0) : (previous, streak)
    }

    /// True once cached state has aged past the TTL, or when no successful poll has ever landed.
    /// Public since REV-33: `PollCoordinator` reads the same rule to decide when a stale-kept
    /// hard block switches from the frozen live render to the `· as of [t]` stale render.
    public static func isStale(lastPollAt: Date?, now: Date) -> Bool {
        guard let lastPollAt else { return true }
        return now.timeIntervalSince(lastPollAt) > cachedStateTTL
    }

    /// Pure §13 priority-list classification — first matching condition wins. Burn-derived
    /// warnings (at-risk, elevated, fast-burn, off-machine) are naturally gated to ≥ 2 polls
    /// because their inputs (`runwayMinutes`, deltas) are `nil` during 0–1 poll cold start
    /// (§11.4); directly-observed hard blocks (over-quota, spend-control) and bad-timing are
    /// not gated, since suppressing an observed block would be unsafe.
    public static func classify(_ inputs: StateInputs, isStale: Bool) -> AppState {
        // R33-7: an expired primary window IS a null window (§13 item 12) — degrade before
        // reading anything, so no hard block can be classified from a window that no longer
        // exists, on any trigger. Applied here (not only in `evaluate`) so the rule holds for
        // every caller by construction; the display shares the same Core degradation.
        let snapshot = inputs.snapshot?.degradingExpiredWindows(now: inputs.now)

        // 1 & 13. Idle/fallback — no usable data ever, or cached state aged past the TTL.
        //         Cached, non-stale state is always shown in preference to a grey fallback.
        guard let snapshot else { return .idleFallback }

        // REV-33 (R33-1): stale/restored data classifies from monotone-safe inputs only.
        // Utilization is monotone non-decreasing within a window, so a cached snapshot is a
        // *lower bound* on the truth: an already-consummated hard block (§13 ranks 2/3) with
        // `resets_at` still in the future keeps that rank — the block is a fact with an expiry,
        // not a decaying estimate. Everything else — every rate-derived warning, and Bad timing
        // deliberately (a stale sub-100 number can only understate) — falls to Idle/fallback
        // exactly as before. The expiry clause is the degradation above: an expired window has
        // no hard-block flags left to read, so no second `now ≥ resets_at` rule exists here.
        if isStale {
            // **The anchor is the blocking limit's reset, not the primary's** (REV-96 §3.1 —
            // STEP_193). `blockEpisode` is exactly "some limit is spent and its reset is still
            // ahead": the degradation above already nil'd any limit whose reset had passed, so
            // an episode existing here *is* the survival test, and the REV-38 monthly anchor is
            // one of the three candidates rather than a special case. What this fixes: the
            // tester's weekly was spent for three days while the five-hour window rolled
            // underneath it, and anchoring on the primary dropped the block to Idle in every poll
            // gap — fourteen Over-quota ↔ Idle flips, and a fresh banner after each one.
            guard snapshot.blockEpisode != nil else { return .idleFallback }
            // Rank 2 before rank 3, as below: the two predicates are the same ones the fresh path
            // uses, so a stale block and a live one can never classify differently.
            if snapshot.spendControlReached == true || snapshot.monthlyReached {
                return .spendControl
            }
            return .overQuota
        }

        let util = snapshot.primaryUsedPct
        let runway = inputs.forecast.runwayMinutes
        // One assessment, read by ranks 5b and 10 below (Baseline §19). Computed off the same
        // degraded snapshot everything else here reads, so a limit whose reset has passed is
        // already gone rather than being tiered from a window that no longer exists.
        let longLimit = snapshot.longLimit(now: inputs.now)

        // 2. Spend control reached / hard block. **Both tools since STEP_193** (REV-96 §3.1):
        //    a monthly pool at its ceiling is a block whether or not the provider says so, which
        //    is what gives the Claude Team/Enterprise spend limit a state at all — that adapter
        //    never sets `spendControlReached`, so the card read "Spend limit reached" while the
        //    engine sat on rank 12 Null-window and nothing fired.
        if snapshot.spendControlReached == true || snapshot.monthlyReached { return .spendControl }

        // 3. Over quota — utilization ≥ 100% or an observed hard block. The Claude usage endpoint
        //    caps `utilization` at exactly 100.0 (never above — real-data finding 2026-07-05), so a
        //    fully-spent window reports 100, not >100; a strict `>` never fired here in production.
        //    **The secondary counts too since STEP_193** (REV-96 §3.1): a spent weekly stops the
        //    account, and before this it rendered amber Weekly-elevated unless the provider
        //    happened to raise a flag.
        if let util, util >= Self.overQuotaUtil { return .overQuota }
        if let weekly = snapshot.secondaryUsedPct, weekly >= Self.overQuotaUtil { return .overQuota }
        if snapshot.rateLimitReached == true { return .overQuota }

        // 3a. The low-allowance rule (§11.3/§13 REV-59 amendment, UI Spec D-60/D-64): with no burn
        //     and no runway, state comes from the used percentage alone. Sits *below* the two
        //     hard blocks — those are observed, not forecast, and are the one verdict that still
        //     matters here — and *above* every rate-derived rank.
        //
        //     Ranks 4–7 and 8 are thereby unreachable, exactly as during a §11.4 cold start: no
        //     new state, no new rank, severity tiers unchanged. Three of them have no inputs left
        //     anyway. **Bad timing (rank 5) is the exception and is why this branch must be
        //     explicit**: its gates are "used ≥ 85%" and "reset ≥ 90 min away", neither of which
        //     is rate-derived, and the second is permanently true on a 30-day window — left to the
        //     list below it would pin a red critical state and its "you risk hitting the limit"
        //     hint on the card for weeks at a time. Rank 10 (Weekly-elevated) is unreachable by
        //     construction: the shape has no secondary window. Rank 12 (Null-window) still catches
        //     an absent or unanchored window, because this branch requires a present utilization.
        if snapshot.isLowAllowanceShape, let util {
            return util >= Self.lowAllowanceElevatedUtil ? .elevated : .healthy
        }

        // 4. At risk — util ≥ 75% AND runway < 30 min.
        if let util, util >= Self.atRiskUtilFloor,
           let runway, runway < Self.atRiskRunwayGateMin {
            return .atRisk
        }

        // 5. Bad timing — util ≥ 85% AND reset ≥ 90 min away.
        if let util, util >= Self.badTimingUtil,
           let minutesToReset = minutesToReset(snapshot, now: inputs.now),
           minutesToReset >= Self.badTimingResetDistanceMin {
            return .badTiming
        }

        // 5b. Limit nearly spent (REV-96 §2.3 — STEP_194) — a secondary window or monthly pool
        //     at or past `longLimitNearlySpentPct`, whatever the pace. Red. Ranked here so a
        //     five-hour *red* state (At risk, Bad timing) still speaks first while a five-hour
        //     amber does not: a limit that is about to stop you outranks Elevated.
        //
        //     `.spent` cannot reach this line — a spent secondary is rank 3 and a reached monthly
        //     is rank 2, both above — so the test is the exact tier, never "at least".
        if longLimit?.tier == .nearlySpent { return .limitNearlySpent }

        // 6. Fast burn spike — Δutil ≥ 20% between two consecutive polls, ≤ 5 min apart and
        // recent (STEP_189). The input is bounded by `ForecastEngine.fastBurnMaxPollGap`, so the
        // rank no longer depends on two polls happening to land inside a 2-minute wall clock —
        // which at the 120s base (REV-89) they rarely do.
        if let delta = inputs.fastBurnDelta, delta >= Self.fastBurnDeltaPct {
            return .fastBurnSpike
        }

        // 7. Off-machine burn — account rising ≥ 2% over 2 polls AND local *confirmed* idle. Idle
        // is a recency gap (activity observed but now older than `LocalAttribution.idleGap`), not a
        // token rate over a short window: Claude Code writes usage lines only at turn completion, so
        // a rate floor misreads a long local turn as idle and false-fires off-machine (REV-23). A
        // never-observed local session (`nil`) is "cannot confirm" and does not fire.
        if let burnDelta = inputs.utilDeltaLast2Polls, burnDelta >= Self.offMachineBurnDeltaPct,
           LocalAttribution.isConfirmedIdle(lastActivityAt: inputs.lastLocalActivityAt, now: inputs.now) {
            return .offMachineBurn
        }

        // 8. Multi-surface (Codex only) — two or more active surface buckets. `PollCoordinator`
        // counts real surfaces only: a `Subagent · …` bucket is a helper thread running *inside*
        // a surface, never a second one (D-99, via `SurfaceWorkSplit`).
        if inputs.tool == .codex, inputs.activeSurfaceBucketCount >= 2 { return .multiSurface }

        // 9. Elevated — dual-horizon since REV-65/D-69: projected exhaustion before the window
        //    resets (runway < minutes-to-reset) AND over pace (used% > elapsed% of the window,
        //    §11.3 pace clock) while the At-risk/Bad-timing gates are unmet (guaranteed by
        //    priority order). The burn average spans minutes; against a weekly window the runway
        //    comparison alone is unlosable, and 5% weekly used classified Elevated for 19% of an
        //    evening. No reset time, no runway, or no pace claim → gate cannot fire. At-risk and
        //    Fast-burn above are deliberately not pace-gated — they backstop the late-window burst.
        if util != nil, let runway,
           let minutesToReset = minutesToReset(snapshot, now: inputs.now),
           runway < minutesToReset,
           snapshot.paceExceeded(now: inputs.now) == true {
            return .elevated
        }

        // 10. Limit ahead of pace (REV-96 §2.3 — STEP_194; **replaces Weekly-elevated**) — the
        //     assessment's amber tier on whichever long limit is worst, while no warning state is
        //     active (guaranteed by priority order). Display-only, fires nothing.
        //
        //     What changed beyond the name: the old rank was `weekly ≥ 85%` and nothing else, so
        //     it could not tell 85% with five days left from 85% with three hours left, it never
        //     looked at a monthly at all, and a weekly at 100% rendered *amber* under it unless
        //     the provider raised its block flag. An account with no secondary window still
        //     cannot reach this rank — it now simply has no assessment rather than a nil compare.
        //
        //     **It requires a populated primary window, and rank 5b does not.** Where none
        //     exists the account is on the REV-38/40 monthly layout, whose rank-12 slot already
        //     paints its own amber from the E6 forecast gate — a second amber source would be two
        //     rules colouring one meter, and it would displace the layout that owns the whole
        //     render there (§2.4: on that shape "the monthly is already the hero and the tiers
        //     colour it"). Red is different: rank 12 has no way to say *nearly spent* and no way
        //     to fire event 9, which is exactly what an Enterprise seat at 92 % of its budget
        //     needs, so 5b above is left to pre-empt it.
        if util != nil, longLimit?.tier == .aheadOfPace { return .limitAheadOfPace }

        // 11. Healthy — quota window present and none of the above.
        if util != nil { return .healthy }

        // 12. Null-window — no active primary window; neutral informational state, not an error.
        //     Codex reports both windows null; Claude (STEP_32) reports a null five_hour with a
        //     live weekly (weekly ≥ 85% is already routed to weekly-elevated by priority order).
        return .nullWindow
    }

    /// Minutes from `now` until the primary window resets, or `nil` if unknown / already past.
    private static func minutesToReset(_ snapshot: QuotaSnapshot, now: Date) -> Double? {
        guard let resetsAt = snapshot.primaryResetsAt else { return nil }
        let minutes = resetsAt.timeIntervalSince(now) / 60
        return minutes >= 0 ? minutes : nil
    }
}
