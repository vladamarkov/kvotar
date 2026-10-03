import Foundation
import os
import KvotarCore
import ClaudeAdapter
import CodexAdapter
import KvotarUI

/// Live poll driver — the Baseline §9 "PollEngine" role (logs under the `PollEngine`
/// component). Runs each account adapter on its own loop, feeds `ForecastEngine` +
/// `StateEngine`, and pushes the result onto `AppViewModel`. Tools poll independently so one
/// populates while the other is still starting (Baseline §13.3).
///
/// STEP_25 owns the §9 behavior here: per-tool `PollBackoffPolicy` (consecutive-429 ladder,
/// persisted/decaying base per R31-1, ±5s jitter), `poll_health_events` persistence, the
/// §9.3 staleness path (failed polls re-evaluate cached state so the 10-min TTL and crossed-
/// reset invalidation fire), and `RetentionScheduler` startup after the first poll (§17.2).
/// Adapters are injected by `AppDelegate` (the composition root) — engine code never
/// constructs concrete adapter types.
@MainActor
final class PollCoordinator {
    private let viewModel: AppViewModel
    private let store: SQLiteStore?
    private let forecast: ForecastEngine
    private let offMachine: OffMachineEstimator
    /// Monthly-cycle attribution split for the period-quota layout (REV-47 — STEP_65; Codex
    /// admitted in REV-48 — STEP_67). Unit-agnostic by construction: dollars on Claude
    /// Enterprise, credits on Codex Enterprise, keyed per tool inside the estimator.
    private let monthlyAttribution: MonthlyAttributionEstimator
    private let stateEngine: StateEngine
    private let notificationEngine: NotificationEngine
    private let claude: any AccountAdapter
    private let codex: any AccountAdapter
    /// Held concretely (not just inside `codex`) so its `app-server` subprocess can be reaped on
    /// quit — `CodexAccountAdapter` exposes no shutdown seam through the `AccountAdapter` protocol.
    private let codexRPC: CodexRPCClient
    /// Local JSONL adapters — held as their concrete types so their `deltaSignals` streams can
    /// be consumed (the §13.1 Trigger 2 wiring, STEP_26) and their `backfillEvents` sweeps driven
    /// (STEP_95 — deliberately not on the `LocalAdapter` protocol, so mocks and engines are
    /// untouched); also injected into `AttributionEngine` as protocols.
    private let claudeLocal: ClaudeLocalAdapter
    private let codexLocal: CodexLocalAdapter
    /// Derives the popover's local-session / surface / est-value / tok-min data from the local JSONL
    /// streams (Step 22). Nil only when there is no store to persist/query against.
    private let attribution: AttributionEngine?
    /// Runs `runRetentionCleanup` every 30 min (§17.2). Started after the first poll completes.
    private let retention: RetentionScheduler?
    private var retentionStarted = false
    /// Fires once per process, the first time a poll outcome leaves a tool *detected* — anything
    /// but the "no credential and no local activity" classification (`applyUndetected`). The
    /// first-run window's launch gate (STEP_143, `OnboardingGate`) hangs off it: there is no
    /// positive detection signal at launch, and a neither-detected install must never fire this.
    var onFirstToolDetected: (() -> Void)?
    private var firstToolDetectedFired = false
    /// §9.2/§9.3 cadence policy, one ladder per tool (each tool is its own endpoint). Since
    /// REV-39 the base is a constant and the 429 ladder is transient and in-memory, so there is
    /// nothing to seed and nothing to persist — a fresh process correctly starts at 60s.
    private var backoff: [Tool: PollBackoffPolicy] = [.claude: .init(), .codex: .init()]
    /// REV-15 (STEP_27): first-launch persistent-429 grace — after ~10 min of 429s with no
    /// success the tool drops to Idle/fallback while the ladder keeps retrying; self-heals on
    /// the first success.
    private var gracePolicy = FirstPollGracePolicy()
    /// Last successful snapshot per tool — the "cached state" the §9.3 staleness path
    /// re-evaluates while polls fail. Kept through TTL expiry since STEP_32: the popover keeps
    /// rendering it with an "as of" stale marker instead of wiping to the idle card.
    private var lastSnapshot: [Tool: QuotaSnapshot] = [:]
    /// When each tool's last *successful* poll landed — the "as of" time on the stale render.
    private var lastSuccessAt: [Tool: Date] = [:]
    /// The snapshot restored from `poll_snapshots` at launch, in a slot distinct from
    /// `lastSnapshot` so the two provenances stay honest (R33-3): it backs the §9.5 forensic
    /// columns on a pre-success 429 and the staleness path's classification, but never
    /// impersonates a live poll (`hasSucceeded` and §9.4 ceiling context are untouched).
    /// STEP_184 rehydrates recent forecast samples separately from bounded persisted history.
    private var restoredSnapshot: [Tool: QuotaSnapshot] = [:]
    /// `polled_at` of the restored row — the stale render's "as of" before any live success,
    /// and the persisted poll clock the first poll of each tool respects (R33-5).
    private var restoredAt: [Tool: Date] = [:]
    /// Tools currently showing the stale (past-TTL) render, with the state that render carries —
    /// routes JSONL-delta re-renders through the stale path so a delta can't strip the "as of"
    /// marker, and re-applies when the stale classification changes (a stale-kept block expiring
    /// to idle must re-render, R33-1/R33-7). Cleared on success.
    private var staleShown: [Tool: AppState] = [:]
    /// When each tool last completed a poll attempt — gates `wakeRefresh` against the §9.2 floor.
    private var lastPollAt: [Tool: Date] = [:]
    /// The currently-sleeping inter-poll task per tool, so `wakeRefresh` can end just the *sleep*
    /// early (never an in-flight poll) to force an immediate re-poll on wake-from-sleep.
    private var sleepers: [Tool: Task<Void, Never>] = [:]
    /// Tools whose advertised cooldown is written to `settings` (`poll_cooldown_until.<tool>`,
    /// STEP_168 / REV-88) — persisted on a non-zero `Retry-After`, restored at launch, cleared on
    /// the next success. Tracked so the clear costs nothing on the ordinary poll (the settings
    /// no-op skip needs a row to exist; writing nil every success would still cost a read).
    private var cooldownPersisted: Set<Tool> = []
    /// While a hold is pending the sleeper wakes this often to ask the adapter whether the
    /// credential rotated — a read-only Keychain read, the one sanctioned early probe (§9.3).
    private static let credentialProbeSlice: TimeInterval = 120

    private static func cooldownKey(_ tool: Tool) -> String { "poll_cooldown_until.\(tool.rawValue)" }
    /// §9.2 JSONL tripwire (STEP_38): the first local delta after an idle stretch cancels the
    /// tool's sleeper — same mechanism and floor as `wakeRefresh`, per-tool.
    private var tripwire: [Tool: JSONLTripwirePolicy] = [.claude: .init(), .codex: .init()]
    /// §9.2 reset-boundary one-shot (STEP_38): replaces the post-success sleep with a single
    /// poll at `max(resets_at+30s, now+5s)` when a known reset lands before the next tick.
    private var boundary: [Tool: ResetBoundaryPolicy] = [.claude: .init(), .codex: .init()]
    /// §9.2 turn-boundary alignment one-shot (REV-53 §4, STEP_77): when local activity stops, one
    /// floor-respecting poll places an interval boundary at the front edge of the pause, so the
    /// STEP_76 recompute gets a whole classifiable interval out of it.
    private var alignment: [Tool: TurnBoundaryPolicy] = [.claude: .init(), .codex: .init()]
    /// The pending trailing-edge quiet timer per tool. Replaced on every local flush (that is what
    /// makes the mechanism trailing-edge) and cancelled by every completed poll, which has already
    /// placed the boundary the timer was going to ask for.
    private var alignmentTimers: [Tool: Task<Void, Never>] = [:]
    /// §9.2 null-after-hiatus expedite (STEP_45): a null 5-hour window on the first poll after a
    /// long gap earns exactly one quick re-check (+45s) instead of a full base interval.
    /// **Claude only** — on Codex a null window is the normal healthy idle shape (§8.3), so the
    /// expedite would fire after every wake and learn nothing. One instance, not a per-tool
    /// dictionary, for the same reason.
    private var nullExpedite = NullWindowExpeditePolicy()
    /// §9.3 startup network-retry ladder (STEP_38): bounded 15s→45s→120s→300s retries for
    /// network-shaped failures until the first success. Never sees a 429.
    private var startupRetry: [Tool: StartupRetryPolicy] = [.claude: .init(), .codex: .init()]
    /// §17.1 forecast_log sampling clock + row builder (STEP_51). In-memory only — a duplicate
    /// first row after relaunch is harmless data.
    private var forecastLog = ForecastLogRecorder(
        appVersion: ForecastLogRecorder.currentAppVersion())
    /// §11.5's learned tables per tool (STEP_190), and the window anchor each was built under.
    /// Held in memory and recomputed — never persisted, because a stored `p = 0.88` is the kind of
    /// derived conclusion §17's substrate principle keeps out of the database.
    ///
    /// A tool with no entry reads `ShadowTables.empty`, which resolves to the shipped prior alone.
    /// That is the normal state of a fresh install and, until enough `v24`-era windows have closed,
    /// of this machine too.
    private var shadowTables: [Tool: ShadowTables] = [:]
    /// The window anchor each tool's tables were built under, and which tools have been built at
    /// all — two members because a build during a null window stores *no* anchor, and assigning nil
    /// into a dictionary removes the key rather than recording the absence.
    private var shadowTablesAnchor: [Tool: Date] = [:]
    private var shadowTablesBuilt: Set<Tool> = []
    private var shadowRefreshInFlight: Set<Tool> = []
    private var tasks: [Task<Void, Never>] = []
    /// STEP_177 daily local report (REV-92 / Baseline §15.2 "Availability and updates"): one
    /// in-flight read per tool, coalescing every trigger that lands meanwhile into a single
    /// re-run — a burst of JSONL flushes must not queue a burst of reads.
    private var dailyRefreshInFlight: Set<Tool> = []
    private var dailyRefreshPending: Set<Tool> = []
    /// The next local-midnight refresh, re-armed after each fire and on wake / calendar change.
    private var midnightRefresh: Task<Void, Never>?

    // The §9.2 floor — "never poll faster than 45 seconds regardless of state" — is
    // `PollBackoffPolicy.minInterval`. It used to be duplicated here as a local literal; one
    // constant, one meaning (STEP_45). `wakeRefresh` applies it, plus the ladder delay while
    // the transient 429 ladder is elevated.

    init(viewModel: AppViewModel,
         store: SQLiteStore?,
         presenter: UserNotificationPresenter,
         claude: any AccountAdapter,
         codex: any AccountAdapter,
         codexRPC: CodexRPCClient,
         diagnostics: DiagnosticsSink? = nil) {
        self.viewModel = viewModel
        self.store = store
        self.forecast = ForecastEngine()
        self.offMachine = OffMachineEstimator(store: store)
        self.monthlyAttribution = MonthlyAttributionEstimator(store: store)
        self.stateEngine = StateEngine(store: store)
        self.notificationEngine = NotificationEngine(store: store, presenter: presenter)
        self.claude = claude
        self.codex = codex
        self.codexRPC = codexRPC
        // §17.1 `parse_anomalies` (STEP_72): the sink is the local adapters' only diagnostics
        // dependency — they hand it undecodable JSONL lines (field **names** only, never values).
        let claudeLocal = ClaudeLocalAdapter(diagnostics: diagnostics)
        let codexLocal = CodexLocalAdapter(diagnostics: diagnostics)
        self.claudeLocal = claudeLocal
        self.codexLocal = codexLocal
        self.attribution = store.map {
            AttributionEngine(store: $0, claude: claudeLocal, codex: codexLocal)
        }
        self.retention = store.map { RetentionScheduler(store: $0) }

        // User dismissal/open arms the at-risk re-arm path (Baseline §13.2). Weak-captured so the
        // presenter's callback does not retain the engine.
        presenter.onAcknowledge = { [weak notificationEngine] tool, event in
            Task { await notificationEngine?.markDismissed(tool: tool, eventType: event) }
        }
    }

    func start() {
        // Subscribe the notification engine to the window-reset bus. Path 1 (transitions) no
        // longer rides a bus: every evaluate call site below hands its StateChange to
        // `evaluateCycle` together with the poll signal, so the §16 no-stacking arbitration sees
        // both (STEP_28). Prior-run notification rows need no launch sweep (§13.2 v5.17) —
        // enforcement scopes window_start = current, and rows age out via the cleanup job.
        let engine = notificationEngine
        let resets = stateEngine.windowResets
        tasks.append(Task {
            await engine.start(windowResets: resets)
        })
        // Begin consuming the local JSONL streams so per-tool attribution is ready by first poll,
        // and the delta-signal streams so meaningful JSONL deltas re-evaluate state between polls
        // (§13.1 Trigger 2; the adapters only watch once `attribution.start()` runs).
        if let attribution {
            tasks.append(Task { [weak self] in
                // STEP_77 turn-boundary alignment: every local flush (re)arms this tool's quiet
                // timer. The `deltaSignals` subscription below cannot serve — it carries only
                // *meaningful* deltas (§13.1), and an ordinary turn is not one. Registered before
                // `start()` so the first flush of the launch is already observed.
                await attribution.setActivityObserver { tool, at in
                    Task { @MainActor in self?.handleLocalActivity(tool: tool, at: at) }
                }
                await attribution.start()
                // STEP_95: the sweep must start only after both watchers seeded their
                // end-of-file offsets — everything before those seeds is the sweep's job,
                // everything after is the watchers'; starting earlier would leave a gap
                // between the sweep's read end and the seed point.
                self?.startJSONLBackfill()
            })
            tasks.append(Task { [claudeLocal] in
                for await signal in claudeLocal.deltaSignals { await self.handleLocalDelta(signal) }
            })
            tasks.append(Task { [codexLocal] in
                for await signal in codexLocal.deltaSignals { await self.handleLocalDelta(signal) }
            })
        }
        // Launch restore (STEP_32 §9.3, REV-33): render the last persisted poll per tool —
        // *classified* through the StateEngine (`.restore` trigger), so a still-true hard block
        // opens red with its banner instead of a false-calm idle card (R33-1) — and seed the
        // engine's reset anchor + the §9.5 forensic context (R33-3). `hasSucceeded` stays unset:
        // restored data must not impersonate a live poll. STEP_184 separately rehydrates the
        // bounded forecast buffer from recent same-window samples.
        // The poll loops start only after restore so the first poll can respect the persisted
        // poll clock (R33-5) and never races the restore render.
        // STEP_177: both tools start `loading` so the section never reads "no local activity"
        // before the first read; the midnight timer is armed once per launch and re-arms itself.
        for tool in Tool.allCases { viewModel.applyDailyReport(tool: tool, .loading) }
        armMidnightRefresh()
        let restore = Task { await self.restorePersistedSnapshots() }
        tasks.append(restore)
        tasks.append(Task { [claude] in
            await restore.value
            await self.runLoop(tool: .claude, adapter: claude)
        })
        tasks.append(Task { [codex] in
            await restore.value
            await self.runLoop(tool: .codex, adapter: codex)
        })
    }

    private func restorePersistedSnapshots() async {
        guard let store else { return }
        for tool in [Tool.claude, .codex] {
            let seedNow = Date()
            if let samples = try? await store.readForecastSeedSamples(
                tool: tool, since: seedNow.addingTimeInterval(-ForecastEngine.seedLookback)) {
                await forecast.seed(tool: tool, samples: samples, now: seedNow)
            }
            // An advertised cooldown outlives the process (STEP_168 / REV-88): the tester's
            // 12:37 relaunch on 2026-09-07 polled 54 s into a one-hour lockout and was refused
            // again. Read before the snapshot guard — a tool whose first-ever poll 429'd has a
            // cooldown and no snapshot. A past value is a no-op inside `seedHold`.
            if let raw = (try? await store.readSetting(key: Self.cooldownKey(tool))) ?? nil,
               let epoch = TimeInterval(raw) {
                let until = Date(timeIntervalSince1970: epoch)
                let now = Date()
                if until > now {
                    backoff[tool]!.seedHold(until: until, now: now)
                    cooldownPersisted.insert(tool)
                    Logger.info("Restored advertised cooldown", component: .pollEngine,
                                metadata: ["tool": tool.rawValue,
                                           "remaining": "\(Int(backoff[tool]!.holdRemaining(now: now)))s"])
                } else {
                    cooldownPersisted.insert(tool)   // stale row — cleared on the next success
                }
            }
            guard let (snapshot, polledAt) = try? await store.readLatestPollSnapshot(tool: tool)
            else { continue }
            // Seed engine memory before any display decision (R33-3/R33-5): the forensic
            // fallback and the persisted poll clock hold regardless of what renders.
            restoredSnapshot[tool] = snapshot
            restoredAt[tool] = polledAt
            // A live poll may have landed while the read was in flight — never clobber it.
            guard !viewModel.hasSucceeded(tool) else { continue }
            // REV-44: attribute against the reset-anchored window (§3.3) so the restore render's
            // §2.5a/§2.5b local card matches the live path, not a rolling now−5h. The width comes
            // off the snapshot (REV-60) — never a five-hour assumption.
            let windowStart = snapshot.primaryWindowStart
            let local = await attribution?.attribution(for: tool, windowStart: windowStart)
            let now = Date()
            // Classify the restored snapshot (R33-1). `.restore` never refreshes the §9.3 TTL
            // clock, so the engine classifies it as stale — monotone-safe inputs only: a hard
            // block with a live window keeps its rank, everything else is Idle/fallback. The
            // evaluation also seeds `lastPrimaryResetsAt` (a relaunch across a rollover must
            // still emit `windowReset` on its first poll) and may emit the R33-6 first-eval
            // hard-block change, which the per-window notification cap dedupes across launches.
            let restoredForecast = Forecast(tool: tool, tier: .unknown, runwayMinutes: nil,
                                            burnRatePerMin: nil, isEstimate: false, pollCount: 0)
            let inputs = StateInputs(
                tool: tool, snapshot: snapshot, health: .unknown,
                forecast: restoredForecast,
                trigger: .restore, now: now,
                lastLocalActivityAt: local?.lastActivityAt)
            let evaluation = await stateEngine.evaluate(inputs)
            await logForecast(tool: tool, snapshot: snapshot, forecast: restoredForecast,
                              evaluation: evaluation, now: now)
            guard !viewModel.hasSucceeded(tool) else { continue }
            // The restore render *is* the stale render — register it so JSONL-delta re-renders
            // route through the stale path instead of stripping the "as of" marker (STEP_32).
            staleShown[tool] = evaluation.state
            viewModel.applyCached(tool: tool, state: evaluation.state, snapshot: snapshot,
                                  asOf: polledAt, localAttribution: local, now: now)
            await notificationEngine.evaluateCycle(change: evaluation.change, signal: nil,
                                                   now: now)
            // A restorable snapshot is a detected tool — the gate need not wait out the
            // persisted poll clock on a migrated or relaunched store.
            noteDetectionOutcome(tool)
            Logger.info("Restored last persisted poll", component: .pollEngine,
                        metadata: ["tool": tool.rawValue,
                                   "state": evaluation.state.rawValue,
                                   "age": "\(Int(now.timeIntervalSince(polledAt)))s"])
        }
        // STEP_177: the first daily read of the launch, independent of whether anything was
        // restorable — a tool with no persisted poll still has a local corpus to report.
        refreshDailyReports(reason: "launch")
    }

    /// Fires `onFirstToolDetected` once. Called after a poll outcome or a restore has been
    /// applied: an undetected tool has already been dropped from `detectedTools` by then, so
    /// "still listed" means detected.
    private func noteDetectionOutcome(_ tool: Tool) {
        guard !firstToolDetectedFired, viewModel.detectedTools.contains(tool) else { return }
        firstToolDetectedFired = true
        onFirstToolDetected?()
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        midnightRefresh?.cancel()
        midnightRefresh = nil
        if let attribution { Task { await attribution.stop() } }
        if let retention { Task { await retention.stop() } }
        // Terminate the Codex app-server child so it does not outlive the app (STEP_24). Called from
        // `AppDelegate.applicationWillTerminate` via `stop()`.
        codexRPC.shutdown()
    }

    /// Outcome of one poll — lets `runLoop` pick the next delay via the backoff policy.
    /// `networkShaped` routes a transient network failure into the startup retry ladder
    /// (STEP_38); classified inside `pollOnce`, where the error is in hand.
    private enum PollOutcome {
        case success
        case rateLimited(retryAfter: Int, details: RateLimit429Details?)
        /// Credential-shaped rejection (§9.1 — REV-41, STEP_48): the expiry gate fired
        /// (`details == nil`, no request sent) or a countdown 429 was reclassified (`details`
        /// captured). Routed away from the ladder — never advances the consecutive count, never
        /// mutates or persists the base. `details` feeds the `credential_expired` forensic row.
        case credentialExpired(details: RateLimit429Details?)
        case failed(networkShaped: Bool)
    }

    // The persisted per-tool base interval (`poll_base_interval.<tool>`, R31-1) is **gone**
    // (REV-39 / STEP_45): the base is a constant, so there is nothing left to learn, store, or
    // restore. Migration `v13_drop_persisted_poll_base` deletes any rows a prior build wrote.

    private func runLoop(tool: Tool, adapter: any AccountAdapter) async {
        // R33-5 (§9.2 "the poll clock is durable too"): the first poll respects the previous
        // process's poll time — a relaunch must not poll 4 seconds after an outgoing process
        // that had just 429'd. Costs the user nothing: the restored snapshot (correctly
        // classified, R33-1) is already rendering. Runs through the sleeper slot so a manual
        // re-check or wake-refresh can cut it short exactly like an inter-poll sleep.
        let age = restoredAt[tool].map { Date().timeIntervalSince($0) }
        // A restored advertised cooldown (STEP_168) extends the R33-5 delay to its deadline.
        let delay = max(PollBackoffPolicy.firstPollDelay(age: age, base: PollBackoffPolicy.defaultBase),
                        backoff[tool]!.holdRemaining(now: Date()))
        if delay > 0 {
            Logger.info("First poll delayed to respect persisted poll clock",
                        component: .pollEngine,
                        metadata: ["tool": tool.rawValue,
                                   "age": "\(Int(age ?? 0))s",
                                   "delay": "\(Int(delay))s"])
            await sleepRespectingHold(tool: tool, adapter: adapter, total: delay)
        }
        while !Task.isCancelled {
            // Captured before the poll: the §9.2 cold-gap anchor for the null-window expedite is
            // the previous *successful* poll (matching STEP_42's `lastFetchAt` semantics — a
            // stretch of failures widens the gap, and the recovery poll counts as cold), and
            // `pollOnce` is about to overwrite it. `restoredAt` covers a launch whose first poll
            // has not landed yet; nil means no success has ever been observed.
            let coldGapAnchor = lastSuccessAt[tool] ?? restoredAt[tool]
            let outcome = await pollOnce(tool: tool, adapter: adapter)
            let pollCompletedAt = Date()
            lastPollAt[tool] = pollCompletedAt
            // `pollOnce` has already classified an undetected tool (`applyUndetected`), so
            // "still listed" after it returns means detected — by success or by any failure
            // that is not the setup-required shape.
            noteDetectionOutcome(tool)
            // STEP_77: this poll *is* an interval boundary, so any pending alignment timer is
            // moot; the policy re-arms (at most one alignment poll between two scheduled polls)
            // and re-anchors its per-window cap on the window this poll observed.
            alignmentTimers[tool]?.cancel()
            alignmentTimers[tool] = nil
            alignment[tool]!.pollCompleted(primaryResetsAt: lastSnapshot[tool]?.primaryResetsAt)
            // §17.2: retention starts after the *first* poll (any tool, any outcome) so launch
            // cleanup never races the popover's initial population.
            startRetentionIfNeeded()

            let interval: TimeInterval
            switch outcome {
            case .success:
                let step = backoff[tool]!.succeeded(jitter: .random(in: -5...5),
                                                    now: pollCompletedAt)
                if step.recovered {
                    Logger.info("Poll recovered after rate limiting", component: .pollEngine,
                                metadata: ["tool": tool.rawValue])
                }
                if cooldownPersisted.contains(tool) {
                    cooldownPersisted.remove(tool)
                    try? await store?.writeSetting(key: Self.cooldownKey(tool), value: nil)
                }
                startupRetry[tool]!.succeeded()
                // Two state-shaped one-shots may want this sleep (§9.1 — neither is on the 429
                // ladder). The boundary policy is consulted first because it mutates its own
                // once-per-boundary bookkeeping; then the sooner of the two wins, and a boundary
                // poll landing earlier also satisfies the expedite (it re-reads the window).
                //
                // Reset-boundary one-shot (§9.2, STEP_38): if a known reset lands before the
                // next tick, replace this sleep with a single poll just past the boundary —
                // still one timer per endpoint, so no two concurrent polls.
                var oneShots: [TimeInterval] = []
                if let snapshot = lastSnapshot[tool],
                   let oneShot = boundary[tool]!.oneShotDelay(
                       primaryResetsAt: snapshot.primaryResetsAt,
                       weeklyResetsAt: snapshot.secondaryResetsAt,
                       now: pollCompletedAt, plannedDelay: step.delay) {
                    Logger.info("Reset-boundary one-shot scheduled", component: .pollEngine,
                                metadata: ["tool": tool.rawValue,
                                           "delay": "\(Int(oneShot))s"])
                    oneShots.append(oneShot)
                }
                // Null-after-hiatus expedite (§9.2, STEP_45): a 5-hour window that comes back
                // empty on the first poll after a long gap is usually the provider not having
                // re-materialized it yet — worth one quick look, not a faster cadence. Claude
                // only, and never on the Enterprise monthly layout, where a null 5-hour window
                // is the normal shape (§8.3 — the same exclusion REV-46 made). "Empty" is null
                // *or not-started* (REV-80 / D-101): consumer Claude's overnight shape now
                // carries `0%` and no reset instead of a nil percent.
                if tool == .claude, let snapshot = lastSnapshot[tool], snapshot.monthlyLimit == nil,
                   let expedite = nullExpedite.expediteDelay(
                       primaryWindowIsNull: snapshot.primaryUsedPct == nil
                           || snapshot.primaryWindowIsUnanchored,
                       gapSinceLastSuccess: coldGapAnchor.map {
                           pollCompletedAt.timeIntervalSince($0)
                       },
                       plannedDelay: step.delay) {
                    Logger.info("Null-window expedite scheduled", component: .pollEngine,
                                metadata: ["tool": tool.rawValue,
                                           "delay": "\(Int(expedite))s"])
                    oneShots.append(expedite)
                }
                interval = oneShots.min() ?? step.delay
            case .rateLimited(let retryAfter, let details):
                let step = backoff[tool]!.rateLimited(retryAfter: retryAfter,
                                                      now: pollCompletedAt)
                await writePollHealthEvent(tool: tool, retryAfter: retryAfter, step: step,
                                           details: details)
                Logger.warning("Poll rate-limited", component: .pollEngine,
                               metadata: ["tool": tool.rawValue,
                                          "retry_after": "\(retryAfter)s",
                                          "wait": "\(Int(step.waitSeconds))s",
                                          "consecutive": "\(step.consecutiveCount)",
                                          "base": "\(step.baseIntervalAtTime)s"])
                // A countdown is a deadline the next process must honour too (STEP_168 / REV-88).
                // A zero `Retry-After` sets no hold and writes nothing.
                if let holdUntil = backoff[tool]!.holdUntil {
                    cooldownPersisted.insert(tool)
                    try? await store?.writeSetting(
                        key: Self.cooldownKey(tool),
                        value: String(Int(holdUntil.timeIntervalSince1970)))
                }
                interval = step.waitSeconds
            case .credentialExpired(let details):
                // Credential-shaped (§9.1/§9.2 rule 6 — REV-41, STEP_48): never touch the 429
                // ladder — an expired token is token-scoped, not the endpoint's response to our
                // cadence. Log the forensic row, then keep ticking at the *current* steady
                // cadence (`failed` never advances a rung) so the next tick re-reads the
                // credential and polls straight through the moment Claude Code refreshes it —
                // zero-network recovery in ~one cadence.
                await writeCredentialExpiredHealthEvent(tool: tool, details: details)
                Logger.info("Poll gated — credential expired", component: .pollEngine,
                            metadata: ["tool": tool.rawValue,
                                       "reclassified": "\(details != nil)",
                                       "base": "\(Int(backoff[tool]!.steadyDelay(now: pollCompletedAt)))s"])
                interval = backoff[tool]!.failed(jitter: .random(in: -5...5),
                                                 now: pollCompletedAt)
            case .failed(let networkShaped):
                // Startup network-retry ladder (§9.3, STEP_38): a transient network-shaped
                // failure before the first success retries on 15s→45s→120s→300s, then clears.
                // 429s never reach this branch (caught as `.rateLimited` above) — rate-shaped
                // and network-shaped failures never share a ladder (§9.1).
                if networkShaped, let rung = startupRetry[tool]!.networkFailureDelay() {
                    Logger.info("Startup network retry", component: .pollEngine,
                                metadata: ["tool": tool.rawValue, "delay": "\(Int(rung))s"])
                    interval = rung
                } else {
                    interval = backoff[tool]!.failed(jitter: .random(in: -5...5),
                                                     now: pollCompletedAt)
                }
            }
            await sleepRespectingHold(tool: tool, adapter: adapter, total: interval)
        }
    }

    /// The one inter-poll sleep (STEP_168). Tracked in `sleepers` so `wakeRefresh`, the tripwire,
    /// the alignment fire and a manual re-check can cancel just this sleep (the loop then iterates
    /// into an immediate `pollOnce`); cancelling it never touches the outer `runLoop` task or a poll.
    ///
    /// While an advertised cooldown is pending the sleep runs in `credentialProbeSlice` pieces and
    /// asks the adapter between them whether the credential rotated — a read-only Keychain read,
    /// zero network. A rotation drops the hold and returns early (the one sanctioned probe: the
    /// tester's only early recovery in 35 lockouts followed a rotation). Cancellation is checked
    /// after every slice and around the actor hop: a cancelled sleep must return, never spin
    /// through the remaining slices; a wake landing during the adapter call must still win. The
    /// deadline is wall-clock, so a system sleep ends the wait at the deadline rather than
    /// sleeping the leftover — the same thing `wakeRefresh` already forces.
    private func sleepRespectingHold(tool: Tool, adapter: any AccountAdapter,
                                     total: TimeInterval) async {
        let sleeper = Task { [weak self] in
            let deadline = Date().addingTimeInterval(max(1, total))
            while !Task.isCancelled {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return }
                guard let self else { return }
                let held = self.backoff[tool]!.isHeld(now: Date())
                let slice = held ? min(remaining, Self.credentialProbeSlice) : remaining
                try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
                guard !Task.isCancelled, held else { continue }
                if await adapter.credentialChanged(), !Task.isCancelled {
                    self.backoff[tool]!.clearHold()
                    if self.cooldownPersisted.contains(tool) {
                        self.cooldownPersisted.remove(tool)
                        try? await self.store?.writeSetting(key: Self.cooldownKey(tool), value: nil)
                    }
                    Logger.info("Credential changed during cooldown — probing",
                                component: .pollEngine, metadata: ["tool": tool.rawValue])
                    return
                }
            }
        }
        sleepers[tool] = sleeper
        await sleeper.value
        sleepers[tool] = nil
    }

    /// The STEP_168 hold gate for an *automatic* trigger: while a server-advertised cooldown is
    /// pending, wake, tripwire and alignment do not poll — the tester's log shows 1–7 such probes
    /// per lockout, each refused with the same countdown. Logged at DEBUG so a bundle explains a
    /// silent trigger. The manual re-check deliberately does not pass through here.
    private func heldByCooldown(tool: Tool, trigger: String, now: Date) -> Bool {
        guard backoff[tool]!.isHeld(now: now) else { return false }
        Logger.debug("Poll trigger held — advertised cooldown", component: .pollEngine,
                     metadata: ["tool": tool.rawValue, "trigger": trigger,
                                "remaining": "\(Int(backoff[tool]!.holdRemaining(now: now)))s"])
        return true
    }

    /// Forces an immediate re-poll of each tool whose last poll is older than the §9.2 floor.
    /// Called on wake-from-sleep (AppDelegate) — a suspended `Task.sleep` would otherwise strand
    /// the popover on the pre-sleep snapshot (a mid-sleep window reset reads as stale) until the
    /// next scheduled poll. Cancels only the sleeper, so an in-flight poll is untouched and no two
    /// concurrent polls hit the same endpoint. Never bypasses the floor, so rapid re-wakes cannot
    /// hammer the (throttle-sensitive, REV-14) account endpoints.
    ///
    /// **Wake politeness (§9.2, STEP_45 Change C).** While the transient 429 ladder is elevated
    /// the floor rises to the ladder delay: wake and launch are the most contended moment on a
    /// shared credential, and cutting a 300s ladder wait short to re-hit an endpoint that just
    /// refused us is the eager re-hit STEP_42's wake-stagger was written to avoid. At rung 0 —
    /// the normal case — the floor is the plain 45s minimum, exactly as before.
    func wakeRefresh() {
        let now = Date()
        for tool in [Tool.claude, .codex] {
            if heldByCooldown(tool: tool, trigger: "wake", now: now) { continue }
            let floor = pollFloor(tool: tool, now: now)
            if let last = lastPollAt[tool], now.timeIntervalSince(last) < floor {
                continue
            }
            sleepers[tool]?.cancel()   // ends the sleep early → loop iterates → immediate pollOnce
        }
        Logger.info("Wake-from-sleep refresh", component: .pollEngine)
        // STEP_177: the day may have rolled over during sleep, and the suspended midnight timer
        // cannot be trusted to have fired — re-arm it and read now, floor or no floor: this is a
        // local read, not a poll.
        armMidnightRefresh()
        refreshDailyReports(reason: "wake")
    }

    // MARK: - Daily local report (STEP_177 — REV-92 / Baseline §15.2)

    /// The popover opened (`MenuBarController.onOpen`): read today's report so the section shows
    /// what landed since the last trigger. Local only — never a poll. The same open is the
    /// reader's acknowledgement of any amber reminder (REV-100 §2.2 — STEP_211); the quota window
    /// shares this hook, so a look there counts too.
    func popoverOpened() {
        refreshDailyReports(reason: "open")
        viewModel.acknowledgeReminders()
    }

    /// The system time zone or clock changed: local midnight moved, so the population moved.
    func calendarChanged() {
        armMidnightRefresh()
        refreshDailyReports(reason: "calendar")
    }

    private func refreshDailyReports(reason: String) {
        for tool in Tool.allCases { refreshDailyReport(tool, reason: reason) }
    }

    /// One coalesced read of `tool`'s daily report. Success replaces the view model's report;
    /// a failure keeps the last successful one under `.unavailable(retained:)` so the section
    /// can show dated numbers rather than a fabricated zero (a failed read never renders as
    /// "no local activity observed today"). Runs at `.utility` off the poll loop; the calendar is
    /// read at call time so a zone change is honoured on the very next read.
    private func refreshDailyReport(_ tool: Tool, reason: String) {
        guard let attribution else { return }
        if dailyRefreshInFlight.contains(tool) {
            dailyRefreshPending.insert(tool)
            return
        }
        dailyRefreshInFlight.insert(tool)
        Task(priority: .utility) { [weak self] in
            let now = Date()
            let calendar = Calendar.current
            let result: Result<DailyLocalReport, Error>
            do {
                result = .success(try await attribution.dailyReport(for: tool, now: now,
                                                                    calendar: calendar))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { self?.finishDailyRefresh(tool: tool, reason: reason,
                                                            result: result, now: now) }
        }
    }

    private func finishDailyRefresh(tool: Tool, reason: String,
                                    result: Result<DailyLocalReport, Error>, now: Date) {
        switch result {
        case .success(let report):
            viewModel.applyDailyReport(tool: tool, .available(report), now: now)
            let selection = report.selection()
            Logger.info("Daily local report", component: .attributionEngine,
                        metadata: ["tool": tool.rawValue, "reason": reason,
                                   "tokens": "\(report.totalTokens)",
                                   "sessions": "\(report.sessionCount)",
                                   "projects": "\(report.projects.count)",
                                   "shown": "\(selection.rows.count)",
                                   "more": "\(selection.moreCount)",
                                   "value": String(format: "%.2f", report.value)])
        case .failure(let error):
            let retained = viewModel.dailyReport(for: tool)?.report
            viewModel.applyDailyReport(tool: tool,
                                       .unavailable(retained: retained, failedAt: now), now: now)
            Logger.warning("Daily local report read failed", component: .attributionEngine,
                           metadata: ["tool": tool.rawValue, "reason": reason,
                                      "retained": retained == nil ? "none" : "kept",
                                      "error": "\(error)"])
        }
        dailyRefreshInFlight.remove(tool)
        if dailyRefreshPending.remove(tool) != nil {
            refreshDailyReport(tool, reason: "coalesced")
        }
    }

    /// Sleeps until the next local midnight (`LocalDayPolicy`, calendar arithmetic — never
    /// `+ 86 400 s`), then reads both tools and re-arms. Two seconds of slack keep the read on
    /// the new day's side of the boundary.
    private func armMidnightRefresh() {
        midnightRefresh?.cancel()
        let now = Date()
        let boundary = LocalDayPolicy.nextBoundary(after: now, calendar: .current)
        let delay = max(1, boundary.timeIntervalSince(now) + 2)
        midnightRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.refreshDailyReports(reason: "midnight")
                self?.armMidnightRefresh()
            }
        }
    }

    /// The §9.2 floor for an *automatic* expedite: the plain 45s minimum, raised to the ladder
    /// delay while the transient 429 ladder is elevated. Shared by `wakeRefresh` and the STEP_77
    /// turn-boundary fire — one constant, one meaning. The user-initiated expedite (`recheck`)
    /// deliberately bypasses it; see its own doc comment.
    private func pollFloor(tool: Tool, now: Date) -> TimeInterval {
        guard backoff[tool]!.isElevated(now: now) else { return PollBackoffPolicy.minInterval }
        return max(PollBackoffPolicy.minInterval, backoff[tool]!.steadyDelay(now: now))
    }

    /// Forces an immediate re-poll of a single `tool` — the first-run "Re-check" button (STEP_30).
    /// Unlike `wakeRefresh`, it bypasses the 45s floor: this is an explicit user action, not an
    /// automatic wake, so it should always take effect. Cancels only the sleeper (an in-flight
    /// poll is untouched); the loop then iterates straight into `pollOnce`.
    /// The pricing table the running app actually loaded, for the diagnostics bundle (STEP_91).
    /// `nil` before the first load or when the bundled file was unreadable.
    func pricingTableStamp() async -> (version: String, updated: String)? {
        await attribution?.pricingTableStamp() ?? nil
    }

    /// The History window's payload (STEP_109), through the attribution engine so it prices with
    /// the same table the popover does. `nil` when there is no store — the window then says so.
    func historyReport() async -> HistoryReport? {
        await attribution?.historyReport()
    }

    func recheck(tool: Tool) {
        sleepers[tool]?.cancel()
        Logger.info("Manual re-check", component: .pollEngine, metadata: ["tool": tool.rawValue])
    }

    @discardableResult
    private func pollOnce(tool: Tool, adapter: any AccountAdapter) async -> PollOutcome {
        let outcome = await pollOnceInner(tool: tool, adapter: adapter)
        // STEP_177: today's local report is refreshed on every poll cycle **regardless of
        // outcome** — the section must never depend on the account endpoint answering.
        refreshDailyReport(tool, reason: "poll")
        return outcome
    }

    private func pollOnceInner(tool: Tool, adapter: any AccountAdapter) async -> PollOutcome {
        do {
            let snapshot = try await adapter.fetchQuotaSnapshot()
            let health = await adapter.health
            // One table set and one instant for this evaluation's forecast and its shadow row
            // (REV-105 — STEP_230): the blend the runway divided by is the blend the log keeps,
            // even if a table rebuild lands between the awaits below. An absent entry is
            // `ShadowTables.empty`, which resolves to the shipped prior — an evaluation never
            // waits on a rebuild.
            let blendTables = shadowTables[tool] ?? .empty
            let recordedAt = Date()
            let forecastResult = await forecast.record(snapshot: snapshot, at: recordedAt,
                                                       tables: blendTables)
            let shortDelta = await forecast.utilDelta(for: tool, overSeconds: 120)
            let twoPollDelta = await forecast.utilDeltaLast2Polls(for: tool)
            // Off-machine idle floor — the local token count on this machine over the last 2 min.
            // 0 (confirmed idle) when there is no attribution engine, which is the safe default.
            let localTokens = await attribution?.localTokensLast2Min(for: tool)
            // Current-window attribution, aligned to the real quota window (§3.3:
            // `primaryResetsAt −` the *reported* window width, REV-60; AttributionEngine falls
            // back per §3.3 when nil).
            // Fetched before StateInputs so the local-derived signals feed classification.
            let windowStart = snapshot.primaryWindowStart
            // Idle "last window" retrospective (REV-46 — STEP_64): on a fresh null 5-hour window
            // (non-monthly) there is no current window to anchor to, so re-anchor the §2.5a/§2.5b
            // attribution to the *last* active window's span. The fresh-idle precondition means no
            // newer activity exists (any would have created an active window), so the open-ended
            // `since:` is uncontaminated. `offMachine.record` below deliberately keeps the original
            // (nil) `windowStart` — its null-window path already returns the last window's share.
            let now = Date()
            // Rank 6's input (STEP_189): the rise between the last two polls, valid only while
            // they are close together and recent. Computed here rather than beside `shortDelta`
            // above because its recency half is measured against this evaluation's own clock.
            let fastBurnDelta = await forecast.utilDeltaLast2Polls(
                for: tool, withinSeconds: ForecastEngine.fastBurnMaxPollGap, now: now)
            let lastActiveWindow: DateInterval? =
                (snapshot.primaryResetsAt == nil && snapshot.monthlyLimit == nil)
                ? (try? await store?.lastActiveWindow(tool: tool, now: now)) ?? nil
                : nil
            // Local-day anchor for the §2.5a/§2.5b sections (REV-47/48 §2.4 monthly — STEP_65/67;
            // REV-49 §2.3 windowed Codex — STEP_69): when there is no window to anchor on, the
            // sections answer "what did I do today" and the attribution anchors on local midnight.
            // See `localDayGrain` for the two routes in and why the anchor and the rendered grain
            // are one value.
            let isMonthlyLayout = snapshot.monthlyLimit != nil
            let (localDay, localDayAnchor) = await localDayGrain(
                tool: tool, isMonthlyLayout: isMonthlyLayout,
                windowConfirmed: snapshot.primaryResetsAt != nil,
                hasRetrospective: Self.retrospectiveAvailable(snapshot, lastActiveWindow),
                now: now)
            let attributionWindowStart = localDayAnchor ?? lastActiveWindow?.start ?? windowStart
            let local = await attribution?.attribution(for: tool, windowStart: attributionWindowStart)
            // Helper buckets are not surfaces (D-99). `surfaceShares` mixes real surfaces with
            // `Subagent · …` threads, and a helper *runs inside* the surface that spawned it — so
            // counting the raw list read one Codex Desktop plus its own subagents as concurrent
            // surfaces and held §13 rule 8 on. Split once, here, and hand the engines the same
            // definition `DisplayFormatter` names from. Since STEP_192 the count is the split's
            // `activeSurfaces(now:)` — buckets with a token event inside the 8-minute idle gap —
            // not `surfaces`, which is the whole window's split (A28: a surface used once on
            // Monday held the Codex tab amber all week).
            let work = SurfaceWorkSplit(local?.surfaceShares ?? [])
            let activeSurfaces = work.activeSurfaces(now: now)
            let inputs = StateInputs(tool: tool, snapshot: snapshot, health: health,
                                     forecast: forecastResult, trigger: .poll, now: now,
                                     fastBurnDelta: fastBurnDelta,
                                     utilDeltaLast2Polls: twoPollDelta,
                                     localTokensLast2Min: localTokens,
                                     activeSurfaceBucketCount: activeSurfaces.count,
                                     subagentCount: local?.subagentCount ?? 0,
                                     lastLocalActivityAt: local?.lastActivityAt)
            let evaluation = await stateEngine.evaluate(inputs)
            let state = evaluation.state
            // `now:` threaded so the `quota_series` row's `polled_at` and the recompute's clock
            // agree to the second (REV-53/STEP_76 — the newest interval's settlement check).
            // `lastLocalActivityAt:` is the §12 liveness timestamp this poll's `Local source` row
            // is rendered from — the newest of {local file write, in-memory token event, persisted
            // event} (STEP_170). Stamping it on the series row is what lets the §12.2 walk tell a
            // stretch the user worked through from one they were away for, twenty minutes before
            // Codex writes the turn's `token_count` (STEP_173). Same value, so the row and the
            // Elsewhere number cannot disagree.
            if let store {
                try? await store.writePoll(snapshot: snapshot,
                                           lastLocalActivityAt: local?.lastActivityAt, now: now)
            }
            // §11.5 shadow (STEP_190): rebuild the tables when this poll's window is not the one
            // they were built under (launch, then once per rollover), then compute this
            // evaluation's outputs from whatever tables are already in hand — never waiting on the
            // rebuild, which is a background read for a number nobody can see.
            refreshShadowTablesIfWindowMoved(tool, anchor: snapshot.primaryResetsAt)
            let shadow = await forecast.shadow(for: snapshot, tables: blendTables,
                                               now: recordedAt)
            await logForecast(tool: tool, snapshot: snapshot, forecast: forecastResult,
                              evaluation: evaluation, shadow: shadow, now: now)
            // §17.1 discontinuity moments (STEP_52): the consecutive-poll comparison, against
            // the launch-restored snapshot before the first in-process success so an overnight
            // change is caught — and never duplicated on restart, since equal values compare
            // clean. (`window_reset` rows ride the StateEngine's §13.2 event instead.)
            let previousSnapshot = lastSnapshot[tool] ?? restoredSnapshot[tool]
            // The plan-damping gate's input (REV-73 §4.2 / D-81 — STEP_121). Read **only** on the
            // rare poll where the plan string actually moved, so the steady path is untouched: two
            // provider sources arguing about a name is not a reason to query the substrate 1,400
            // times a day. Empty on the first observation, which is the correct reading — one
            // disagreement is an observation; its twentieth repetition is not.
            var recentPlanChanges: [PlanTransition] = []
            if let store, let previousPlan = previousSnapshot?.planType,
               let currentPlan = snapshot.planType, previousPlan != currentPlan {
                recentPlanChanges = ((try? await store.planChanges(
                    tool: tool,
                    since: now.addingTimeInterval(-PlanChangeStability.dampingWindow),
                    until: now)) ?? [])
                    .map { PlanTransition(at: $0.at, from: $0.from, to: $0.to) }
                if PlanChangeStability.isDamped(from: previousPlan, to: currentPlan, at: now,
                                                history: recentPlanChanges) {
                    // DEBUG, never INFO: this is a standing condition, and STEP_75's field episode
                    // is what one INFO line per occurrence looks like after 25 hours.
                    Logger.debug("Plan change damped — unstable name pair",
                                 component: .pollEngine,
                                 metadata: ["tool": tool.rawValue,
                                            "plan": "\(previousPlan)→\(currentPlan)"])
                }
            }
            let moments = DiscontinuityDetector.detect(
                previous: previousSnapshot, current: snapshot, now: now,
                recentPlanChanges: recentPlanChanges)
            // REV-69 §17.1: a Codex `early_reset` is "written together with" an observed
            // `available_count` decrement. No column carries it and the field has read 0 in every
            // stored payload (STEP_114 probe), so the decrement is logged, not stored — the hourly
            // count survives in `history_rollups.rate_limit_reset_credits_count_last`.
            if moments.contains(where: { $0.eventType == .earlyReset }),
               let before = previousSnapshot?.rateLimitResetCreditsCount,
               let after = snapshot.rateLimitResetCreditsCount, after < before {
                Logger.info("Banked reset used with early reset", component: .pollEngine,
                            metadata: ["tool": tool.rawValue,
                                       "banked_resets": "\(before)→\(after)"])
            }
            if let store, !moments.isEmpty {
                try? await store.writeDiscontinuityEvents(tool: tool, observedAt: now,
                                                          events: moments)
                Logger.info("Discontinuity recorded", component: .pollEngine,
                            metadata: ["tool": tool.rawValue,
                                       "types": moments.map(\.eventType.rawValue)
                                           .joined(separator: ",")])
            }
            lastSnapshot[tool] = snapshot
            lastSuccessAt[tool] = now
            staleShown[tool] = nil
            // Cumulative window attribution for the Burn-rate split bar / Off-machine row
            // (REV-53 — STEP_76): retrospective whole-window recompute. The estimator re-walks
            // this window's `quota_series` (this poll's row included — `writePoll` ran above)
            // against landed `local_usage_events`; a settled zero-token interval is exact
            // off-machine, everything else Local. No liveness proxy — idleness is judged in
            // hindsight behind the in-flight guard, so a long turn's late JSONL self-corrects.
            let windowAttribution = await offMachine.record(
                tool: tool, resetsAt: snapshot.primaryResetsAt,
                windowSeconds: snapshot.primaryWindowLength,
                currentUsedPct: snapshot.primaryUsedPct, now: now)
            // Monthly attribution split + trailing spend rate (REV-47 — STEP_65; REV-48 — STEP_67):
            // fold this poll's exact meter delta into the cycle accumulator and compute the
            // trailing rate from persisted samples — this poll's own row included (`writePoll`
            // ran above). The monthly meter keeps the REV-27 interval rule with the 8-minute
            // liveness discriminator (REV-53 leaves it untouched — window attribution above no
            // longer uses it). Amounts go in raw, in the meter's own scale (Claude dollars,
            // Codex credits): nothing here inspects `QuotaUnit`. Claude display consumes both
            // since STEP_66; Codex in STEP_68.
            var monthlyAttributionResult: MonthlyAttribution?
            var monthlyRatePerHour: Double?
            if isMonthlyLayout, let limit = snapshot.monthlyLimit {
                let localValueLast8Min = await attribution?.localValuePerMin(
                    for: tool, from: now.addingTimeInterval(-LocalAttribution.idleGap), until: now)
                monthlyAttributionResult = await monthlyAttribution.record(
                    tool: tool, cycleReset: limit.resetsAt, usedAmount: limit.usedAmount,
                    localValueLast8Min: localValueLast8Min, now: now)
                let samples = ((try? await store?.readMonthlyUsedSamples(
                    tool: tool, since: now.addingTimeInterval(-3_900))) ?? nil) ?? []
                monthlyRatePerHour = MonthlySpendRate.compute(samples: samples)
            }
            // Unpriced-model drain (REV-62 §5.3 / STEP_92): everything `resolvePricing`
            // priced at the provider fallback since the last cycle — the attribution reads
            // above are where those lookups ran. One merge-upsert per cycle; empty (and free)
            // in the steady state where every observed model has a pricing row.
            if let store {
                let unpriced = UnpricedModelCollector.shared.drain()
                if !unpriced.isEmpty {
                    try? await store.upsertUnpricedModels(unpriced)
                    Logger.info("Unpriced models recorded", component: .pollEngine,
                                metadata: ["models": unpriced.map { "\($0.provider)/\($0.model)" }
                                    .joined(separator: ",")])
                }
            }
            gracePolicy.succeeded(tool: tool)
            viewModel.apply(tool: tool, snapshot: snapshot, forecast: forecastResult,
                            state: state, localAttribution: local, offMachine: windowAttribution,
                            fastBurnDelta: fastBurnDelta,
                            moneyGlyph: evaluation.moneyGlyph,
                            lastActiveWindow: lastActiveWindow,
                            monthlyAttribution: monthlyAttributionResult,
                            monthlyRatePerHour: monthlyRatePerHour, localDay: localDay)

            // One notification cycle: the Path 1 transition (if any) and the Path 2 poll signal —
            // off-machine idle inputs, Multi-surface bucket count, active model/project/surfaces
            // for the §4 copy — arbitrated together so at most one banner fires (§16, STEP_28).
            let signal = NotificationSignal(
                tool: tool, state: state, utilizationPct: snapshot.primaryUsedPct,
                runwayMinutes: forecastResult.runwayMinutes, resetsAt: snapshot.primaryResetsAt,
                primaryWindowSeconds: snapshot.primaryWindowSeconds,
                // §16 REV-59 amendment (D-60): read once, off the same snapshot the state and the
                // forecast were decided from, so the engine's gating describes this poll's window.
                isLowAllowanceShape: snapshot.isLowAllowanceShape,
                // §4.1a (STEP_146): this poll's window facts, folded — a restructuring is one.
                windowFacts: WindowFact.fold(moments),
                // The block this poll observed (STEP_193) — taken from the evaluation rather than
                // re-derived, so it comes off the snapshot the engine actually classified (which
                // has been through `degradingExpiredWindows`). Its absence here ends an episode.
                blockEpisode: evaluation.blockEpisode,
                // The worst long limit this poll saw (STEP_194) — what retires a spent
                // `nearly_spent.*` key once its period rolls over.
                longLimit: snapshot.degradingExpiredWindows(now: now).longLimit(now: now),
                // The weekly the ladder reads (STEP_232) — the secondary, or a seven-day primary.
                weekly: snapshot.degradingExpiredWindows(now: now)
                    .weeklyForNotifications(now: now),
                utilDeltaShortWindow: shortDelta, fastBurnDelta: fastBurnDelta,
                utilDeltaLast2Polls: twoPollDelta,
                localTokensLast2Min: localTokens,
                lastLocalActivityAt: local?.lastActivityAt,
                activeSurfaceBucketCount: activeSurfaces.count,
                model: local?.model, project: local?.project,
                surfaces: activeSurfaces.map(\.label), now: now)
            await notificationEngine.evaluateCycle(change: evaluation.change,
                                                   signal: signal, now: now)
            Logger.info("Poll complete", component: .pollEngine,
                        metadata: ["tool": tool.rawValue, "state": state.rawValue,
                                   "util": snapshot.primaryUsedPct.map { "\(Int($0))%" } ?? "—"])
            return .success
        } catch AccountAdapterError.rateLimited(let retryAfter, let details) {
            // A 429 is a "retry soon" signal, not an unavailable account: keep the pre-first-poll
            // "Connecting…" card (never the fallback) and retry per the §9.3 ladder — the endpoint
            // routinely 429s the very first poll and recovers in seconds. But not forever: after
            // the REV-15 grace window (~10 min, mirroring the §9.3 TTL) with no success since
            // launch, drop to Idle/fallback while the ladder keeps retrying quietly; the first
            // success self-heals (STEP_27). Once a tool has succeeded this freezes the last-known
            // state — until the staleness evaluation below drops it past the TTL.
            // R33-4: grace expiry must not wipe a still-true block — `applyUnavailable` only
            // when nothing is restorable; with a restored snapshot the staleness evaluation
            // below keeps (or re-renders) the stale card, correctly classified.
            if !viewModel.hasSucceeded(tool), gracePolicy.rateLimited(tool: tool, now: Date()),
               restoredSnapshot[tool] == nil {
                viewModel.applyUnavailable(tool: tool)
                Logger.info("First-launch grace expired — showing fallback",
                            component: .pollEngine, metadata: ["tool": tool.rawValue])
            }
            await evaluateStaleness(tool: tool, adapter: adapter)
            return .rateLimited(retryAfter: retryAfter, details: details)
        } catch AccountAdapterError.credentialExpired(let details) {
            // Credential-shaped rejection (§9.1 — REV-41, STEP_48): the expiry gate fired, or a
            // countdown 429 was reclassified. Treat rendering exactly like a freeze — before the
            // first success show the idle/unavailable interim (STEP_49 turns this into the D-38
            // "sign-in expired" card), but never wipe a restorable block (R33-4). The credential
            // is present, so this is never the first-run/undetected path. Route through the
            // staleness path so the freeze reason (`.credentialExpired`) reaches the display, then
            // return the credential-shaped outcome so `runLoop` leaves the ladder untouched.
            if !viewModel.hasSucceeded(tool), restoredSnapshot[tool] == nil {
                viewModel.applyUnavailable(tool: tool)
            }
            await evaluateStaleness(tool: tool, adapter: adapter)
            return .credentialExpired(details: details)
        } catch {
            // First-poll failure with no prior success → Idle/fallback (Baseline §13.3). Once a tool
            // has succeeded, a later failure freezes the last-known state (§9.3) — the footer's
            // "Updated X min ago" conveys the staleness until the TTL invalidates the cache.
            // No credential AND no local JSONL activity observed → the tool is *undetected* and
            // renders nothing in the menu bar (§1.0 v4.6; JSONL presence is since-launch —
            // AttributionEngine's in-memory recency, the same signal as the §15.1 tie-break).
            if !viewModel.hasSucceeded(tool) {
                let hasLocalActivity = await attribution?.lastActivityAt(for: tool) != nil
                switch DetectionStatus.classify(error: error, hasLocalActivity: hasLocalActivity) {
                case .firstRun: viewModel.applyUndetected(tool: tool)
                case .idle:
                    // R33-4 (same rule as grace expiry): a pre-success failure must not wipe a
                    // restorable render — the restored card, incl. a still-true block, stands.
                    if restoredSnapshot[tool] == nil { viewModel.applyUnavailable(tool: tool) }
                }
            }
            Logger.warning("Poll failed", component: .pollEngine,
                           metadata: Logger.metadata(for: error)
                               .merging(["tool": tool.rawValue]) { current, _ in current })
            await evaluateStaleness(tool: tool, adapter: adapter)
            return .failed(networkShaped: StartupRetryPolicy.isNetworkShaped(error))
        }
    }

    /// §9.3 staleness path: every failed or rate-limited poll re-evaluates the *cached* state
    /// (trigger `.pollFailure`, which never refreshes the TTL clock) so the 10-min TTL and the
    /// crossed-`resets_at` invalidation can fire. The cached snapshot is the last live poll, or
    /// the launch-restored one before any success (R33-4). Past the TTL the display degrades to
    /// the stale render (STEP_32): last-known snapshot kept with an "as of" marker — but the
    /// classification survives for a still-true hard block (R33-1), so the stale card can stay
    /// red with its banner; it re-renders whenever the stale classification changes (a block
    /// expiring with its window must drop to the idle presentation on that poll, R33-7). The
    /// forecast buffer is cleared on entering staleness so stale samples never seed
    /// post-recovery burn. The loop keeps retrying on its normal cadence.
    private func evaluateStaleness(tool: Tool, adapter: any AccountAdapter) async {
        let cached = lastSnapshot[tool] ?? restoredSnapshot[tool]
        let forecastResult: Forecast
        if let cached {
            forecastResult = await forecast.forecast(for: cached,
                                                     tables: shadowTables[tool] ?? .empty)
        } else {
            forecastResult = Forecast(tool: tool, tier: .unknown, runwayMinutes: nil,
                                      burnRatePerMin: nil, isEstimate: false, pollCount: 0)
        }
        let now = Date()
        let health = await adapter.health
        let inputs = StateInputs(tool: tool, snapshot: cached, health: health,
                                 forecast: forecastResult, trigger: .pollFailure, now: now)
        let evaluation = await stateEngine.evaluate(inputs)
        let state = evaluation.state
        await logForecast(tool: tool, snapshot: cached, forecast: forecastResult,
                          evaluation: evaluation, now: now)
        // TTL-driven transitions produce no Path 2 signal; a change into idle/fallback yields no
        // candidate, but the transport must not silently drop other transitions (STEP_28).
        await notificationEngine.evaluateCycle(change: evaluation.change, signal: nil, now: now)
        // The stale render applies on Idle/fallback (TTL or crossed-reset invalidation — both
        // immediate, §9.3) and on a stale-kept hard block once past the TTL (R33-1; within the
        // TTL the frozen live render with its aging freshness stamp is the honest display).
        let pastTTL = StateEngine.isStale(lastPollAt: lastSuccessAt[tool], now: now)
        let wantsStaleRender = state == .idleFallback || (state.isHardBlock && pastTTL)
        if wantsStaleRender, let cached, let asOf = lastSuccessAt[tool] ?? restoredAt[tool],
           staleShown[tool] != state {
            if staleShown[tool] == nil { await forecast.reset(tool: tool) }
            staleShown[tool] = state
            // REV-44: reset-anchored window for the §2.5a/§2.5b local card (matches the live path).
            let windowStart = cached.primaryWindowStart
            let local = await attribution?.attribution(for: tool, windowStart: windowStart)
            // Freeze reason (REV-37 — STEP_41): a `.rateLimited` health forks the null verdict to
            // "Reconnecting…" (throttled, not idle). Reuses the `health` already fetched above.
            viewModel.applyCached(tool: tool, state: state, snapshot: cached, asOf: asOf,
                                  localAttribution: local, freezeReason: health, now: now)
            Logger.info("Cached state stale — keeping last-known display",
                        component: .pollEngine,
                        metadata: ["tool": tool.rawValue,
                                   "state": state.rawValue,
                                   "as_of": "\(Int(now.timeIntervalSince(asOf)))s ago"])
        }
    }

    /// §9.2 turn-boundary alignment (REV-53 §4, STEP_77) — one local JSONL flush landed. Replaces
    /// this tool's quiet timer; if that timer survives `TurnBoundaryPolicy.quietDelay` the turn is
    /// over, and `fireAlignmentPoll` places an interval boundary at the front edge of whatever
    /// pause follows. Re-arming on every flush is what keeps the mechanism trailing-edge: nothing
    /// fires mid-burst, so a busy session cannot spend the per-window cap before its first pause.
    // MARK: - JSONL launch backfill (STEP_95, REV-62 §4.2)

    /// First-run sweep horizon when no watermark exists: 90 days — the app's standing retention
    /// horizon (`poll_health_events`, `state_transitions`, `notification_events`), user decision
    /// 2026-08-12. On a routine relaunch the watermark replaces it: every file touched since we
    /// were last up is re-read in full, which is the only rule that fills mid-stream gaps.
    private static let backfillHorizon: TimeInterval = 90 * 86400

    /// Spawns the one-shot background sweep over pre-launch JSONL bytes, both tools sequentially
    /// on a single `.utility` task — it cannot block launch (nothing awaits it) and cannot flood
    /// the poll loop (it never touches it). See `JSONLBackfillReader` for what the sweep
    /// deliberately does not do (no delta signals, no quota-429 replay).
    private func startJSONLBackfill() {
        guard store != nil else { return }
        tasks.append(Task(priority: .utility) { [weak self] in
            await self?.runBackfill(tool: .claude)
            await self?.refreshDailyReport(.claude, reason: "backfill")
            await self?.runBackfill(tool: .codex)
            await self?.refreshDailyReport(.codex, reason: "backfill")
            // STEP_93: the one-shot attribution enrichment runs after both backfills so every
            // row the sweeps just inserted (which carry their own columns) is already in place
            // and only genuinely historical rows remain to fill.
            await self?.runAttributionEnrichment(tool: .claude)
            await self?.runAttributionEnrichment(tool: .codex)
            // STEP_94: the one-shot re-emission cleanup runs last — it deletes, and everything
            // above only inserts or fills, so this ordering can never delete a row a prior
            // sweep was about to justify.
            await self?.runCodexReEmissionCleanup()
            // STEP_100: the surface repair runs after the cleanup, so it never rewrites a label
            // on a row that is about to be deleted as a re-emission.
            await self?.runCodexSurfaceAttributionRepair()
            // STEP_103: the forked-history cleanup runs last for the same reason the
            // re-emission cleanup runs after the fills — it only deletes.
            await self?.runCodexForkedHistoryCleanup()
            // STEP_177: the enrichment and cleanups above can relabel or remove today's rows.
            await self?.refreshDailyReports(reason: "backfill-repairs")
        })
    }

    /// One tool's sweep: read the watermark, sweep files touched after it (or after the 90-day
    /// horizon on first run), log what was recovered, then advance the watermark to *sweep start*
    /// — a crash mid-sweep leaves the old watermark, so the next launch simply re-sweeps and the
    /// `(tool, dedup_key)` guard in `backfillTokenEvents` makes the re-read free.
    private func runBackfill(tool: Tool) async {
        guard let store else { return }
        let key = "jsonl_backfill_watermark_\(tool.rawValue)"
        let stored = (try? await store.readSetting(key: key)) ?? nil
        let watermark = stored.flatMap { Int($0) }
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let sweepStart = Date()
        let cutoff = watermark ?? sweepStart.addingTimeInterval(-Self.backfillHorizon)
        let write: @Sendable ([TokenEvent]) async -> JSONLBackfillReader.WriteCounts? = { events in
            try? await store.backfillTokenEvents(events)
        }
        let summary: JSONLBackfillReader.Summary
        switch tool {
        case .claude: summary = await claudeLocal.backfillEvents(since: cutoff, write: write)
        case .codex: summary = await codexLocal.backfillEvents(since: cutoff, write: write)
        }
        // The record STEP_95 task 4 asks for: the one-off jump in the 30-day figures after this
        // ships must be explainable from the log rather than alarming.
        Logger.info("JSONL backfill complete", component: tool == .claude
                        ? .claudeLocalAdapter : .codexLocalAdapter,
                    metadata: ["first_run": watermark == nil ? "true" : "false",
                               "cutoff": "\(Int(cutoff.timeIntervalSince1970))",
                               "files": "\(summary.filesScanned)",
                               "vanished": "\(summary.filesVanished)",
                               "parsed": "\(summary.eventsParsed)",
                               "inserted": "\(summary.eventsInserted)",
                               "inserted_tokens": "\(summary.insertedTokens)",
                               "duration_s": "\(Int(Date().timeIntervalSince(sweepStart)))"])
        try? await store.writeSetting(
            key: key, value: String(Int(sweepStart.timeIntervalSince1970)))
    }

    /// STEP_93's one-shot attribution enrichment (user ruling 2026-08-12): re-read the 90-day
    /// JSONL corpus and fill the v15 per-event `model`/`surface_bucket` columns on rows written
    /// before those columns existed — an UPDATE of the two new columns only, matched on
    /// `(tool, dedup_key)`, never touching a token quantity (REV-43). Claude's pass finishes
    /// with the placeholder-session repair: sessions renamed by a zero-token `<synthetic>` line
    /// take their last real model back.
    ///
    /// Gated on a completion stamp, not a watermark — the sweep covers a fixed horizon once;
    /// a crash before the stamp just re-runs it (each column fills only where NULL, so the
    /// re-run is free). Runs on the same single `.utility` task as the backfill, after it.
    private func runAttributionEnrichment(tool: Tool) async {
        guard let store else { return }
        let key = "jsonl_attribution_enrichment_done_\(tool.rawValue)"
        guard ((try? await store.readSetting(key: key)) ?? nil) == nil else { return }
        let sweepStart = Date()
        let cutoff = sweepStart.addingTimeInterval(-Self.backfillHorizon)
        let enriched = OSAllocatedUnfairLock(initialState: 0)
        let write: @Sendable ([TokenEvent]) async -> JSONLBackfillReader.WriteCounts? = { events in
            guard let updated = try? await store.enrichTokenEventAttribution(events) else {
                return nil
            }
            enriched.withLock { $0 += updated }
            // The reader's insert accounting is unused here; the sweep result we care about is
            // the update count accumulated above.
            return JSONLBackfillReader.WriteCounts(inserted: 0, insertedTokens: 0)
        }
        let summary: JSONLBackfillReader.Summary
        switch tool {
        case .claude: summary = await claudeLocal.backfillEvents(since: cutoff, write: write)
        case .codex: summary = await codexLocal.backfillEvents(since: cutoff, write: write)
        }
        let repaired = tool == .claude
            ? ((try? await store.repairPlaceholderSessionModels()) ?? 0) : 0
        // Same rationale as the backfill log: the displayed per-model rows move once, now, and
        // the log must make that explainable rather than alarming.
        Logger.info("Attribution enrichment complete", component: tool == .claude
                        ? .claudeLocalAdapter : .codexLocalAdapter,
                    metadata: ["files": "\(summary.filesScanned)",
                               "vanished": "\(summary.filesVanished)",
                               "parsed": "\(summary.eventsParsed)",
                               "rows_enriched": "\(enriched.withLock { $0 })",
                               "sessions_repaired": "\(repaired)",
                               "duration_s": "\(Int(Date().timeIntervalSince(sweepStart)))"])
        try? await store.writeSetting(
            key: key, value: String(Int(sweepStart.timeIntervalSince1970)))
    }

    /// STEP_94 (a)'s one-shot historical cleanup: the parser now drops a Codex turn whose
    /// cumulative `total_token_usage` has not advanced (a re-emission), but 92 of the corpus's
    /// 192 re-emissions were ingested before the rule existed, and no SQL can find them — the
    /// cumulative totals that expose them live only in the JSONL. So: re-parse the whole Codex
    /// tree (cutoff `.distantPast`, not the 90-day horizon — the residue reaches back to March,
    /// in files whose mtimes are far older than any watermark) collecting every dedup key a
    /// clean parse yields per session, then let the store delete rows whose key a clean parse
    /// no longer produces. Completion-stamped like the enrichment; the store method carries the
    /// safety bounds (near-now rows exempt, mass-deletion guard per session).
    private func runCodexReEmissionCleanup() async {
        guard let store else { return }
        let key = "jsonl_reemission_cleanup_done_codex"
        guard ((try? await store.readSetting(key: key)) ?? nil) == nil else { return }
        let sweepStart = Date()
        let kept = OSAllocatedUnfairLock(initialState: [String: Set<String>]())
        let collect: @Sendable ([TokenEvent]) async -> JSONLBackfillReader.WriteCounts? = { events in
            kept.withLock { keptKeys in
                for event in events {
                    keptKeys[event.sessionId, default: []].insert(event.dedupKey)
                }
            }
            return JSONLBackfillReader.WriteCounts(inserted: 0, insertedTokens: 0)
        }
        let summary = await codexLocal.backfillEvents(since: .distantPast, write: collect)
        let deleted = (try? await store.reconcileCodexReEmissions(
            keptKeys: kept.withLock { $0 },
            olderThan: sweepStart.addingTimeInterval(-600))) ?? 0
        Logger.info("Re-emission cleanup complete", component: .codexLocalAdapter,
                    metadata: ["files": "\(summary.filesScanned)",
                               "parsed": "\(summary.eventsParsed)",
                               "deleted": "\(deleted)",
                               "duration_s": "\(Int(Date().timeIntervalSince(sweepStart)))"])
        try? await store.writeSetting(
            key: key, value: String(Int(sweepStart.timeIntervalSince1970)))
    }

    /// STEP_103's one-shot forked-history cleanup: the parser now drops a `token_count` event
    /// stamped within the fork window of a fork-marked `session_meta` line (inherited history —
    /// the parent thread's turns replayed into the fork's file), but 78 such rows were ingested
    /// before the rule existed and no SQL can find them: the fork marker and the timestamps
    /// that expose them live only in the JSONL. So: re-parse the whole Codex tree (cutoff
    /// `.distantPast` — the older case is six weeks back, far older than any watermark)
    /// collecting every dedup key a clean parse still yields, then hand the store **only the
    /// fork-marked sessions'** kept-sets to delete against.
    ///
    /// The kept-keys map is seeded from `forkMarkedSessionIds()` — every marker session starts
    /// with an **empty** set — before the parse fills them in. This is load-bearing: the
    /// 2026-07-03 fork is a 100% phantom whose clean parse yields zero events, so an
    /// event-driven collection alone would never name it and its 32 rows would survive.
    /// Completion-stamped like its siblings; a crash before the stamp costs a free re-run
    /// (deleting already-deleted keys is a no-op).
    private func runCodexForkedHistoryCleanup() async {
        guard let store else { return }
        let key = "jsonl_forked_history_cleanup_done_codex"
        guard ((try? await store.readSetting(key: key)) ?? nil) == nil else { return }
        let sweepStart = Date()
        let kept = OSAllocatedUnfairLock(initialState: [String: Set<String>]())
        let collect: @Sendable ([TokenEvent]) async -> JSONLBackfillReader.WriteCounts? = { events in
            kept.withLock { keptKeys in
                for event in events {
                    keptKeys[event.sessionId, default: []].insert(event.dedupKey)
                }
            }
            return JSONLBackfillReader.WriteCounts(inserted: 0, insertedTokens: 0)
        }
        let summary = await codexLocal.backfillEvents(since: .distantPast, write: collect)
        // Read *after* the sweep: each file visit runs `captureOriginator`, so by now the
        // adapter has seen every file's `session_meta` and the marker list is complete.
        let markerIds = await codexLocal.forkMarkedSessionIds()
        let allKept = kept.withLock { $0 }
        var markerKept: [String: Set<String>] = [:]
        for id in markerIds { markerKept[id] = allKept[id] ?? [] }
        let deleted = (try? await store.reconcileForkedThreadHistory(
            keptKeys: markerKept,
            olderThan: sweepStart.addingTimeInterval(-600))) ?? (events: 0, sessions: 0)
        Logger.info("Forked-history cleanup complete", component: .codexLocalAdapter,
                    metadata: ["files": "\(summary.filesScanned)",
                               "parsed": "\(summary.eventsParsed)",
                               "marker_sessions": "\(markerIds.count)",
                               "deleted_events": "\(deleted.events)",
                               "deleted_sessions": "\(deleted.sessions)",
                               "duration_s": "\(Int(Date().timeIntervalSince(sweepStart)))"])
        try? await store.writeSetting(
            key: key, value: String(Int(sweepStart.timeIntervalSince1970)))
    }

    /// STEP_100's one-shot surface-attribution repair: re-read the Codex tree and rewrite the
    /// per-event/per-session `surface_bucket` where the corrected rule disagrees with what the
    /// old parser stored.
    ///
    /// The enrichment above cannot cover this — it fills NULLs, and these rows are populated with
    /// the wrong value. Before REV-63 every `("Codex Desktop", "vscode")` session was labelled
    /// `IDE extension` (the desktop app reports the VS Code shell's name for itself) and every
    /// subagent-spawned thread `Unknown`; since STEP_93 that verdict is stored per event, so the
    /// fix would otherwise reach only events ingested from launch onwards while the whole stored
    /// corpus kept telling a desktop-only user they had used an editor extension.
    ///
    /// **Cutoff `.distantPast`, like the re-emission cleanup and unlike the 90-day enrichment**:
    /// the mislabelled rows reach back to the start of the Codex corpus, in files whose mtimes
    /// are far older than any watermark. Completion-stamped, and the update is idempotent (it
    /// matches only rows that disagree), so a crash before the stamp costs a free re-run.
    ///
    /// Codex only. Claude's buckets come from `isSidechain`/`attributionAgent` on each line and
    /// were never affected by this defect, so a Claude pass would rewrite nothing.
    ///
    /// **Second generation, STEP_137 (REV-76 / D-95).** The rule moved again: a
    /// `thread_source: "subagent"` tag with no `parent_thread_id` is a top-level thread, not an
    /// unidentified helper, and the old reading had put 502.6M tokens of the user's own work under
    /// `Subagent · Unknown`. That is the same class of stored-verdict problem this sweep was built
    /// for, so the sweep is reused unchanged and only its completion stamp moves — the key carries
    /// a generation suffix, and the STEP_100 stamp on an existing install becomes a vestigial row.
    /// One sweep still covers both generations: it always re-parses with the *current* parser, so
    /// a machine that never ran the first repair gets both corrections in this pass, and a fresh
    /// install (nothing mislabelled to begin with) parses the tree once rather than twice.
    private func runCodexSurfaceAttributionRepair() async {
        guard let store else { return }
        let key = "jsonl_surface_repair_done_codex_d95"
        guard ((try? await store.readSetting(key: key)) ?? nil) == nil else { return }
        let sweepStart = Date()
        let repaired = OSAllocatedUnfairLock(initialState: 0)
        let write: @Sendable ([TokenEvent]) async -> JSONLBackfillReader.WriteCounts? = { events in
            guard let updated = try? await store.repairSurfaceAttribution(events) else { return nil }
            repaired.withLock { $0 += updated }
            // The reader's insert accounting is unused here (same as the enrichment): the result
            // that matters is the update count accumulated above.
            return JSONLBackfillReader.WriteCounts(inserted: 0, insertedTokens: 0)
        }
        let summary = await codexLocal.backfillEvents(since: .distantPast, write: write)
        // The §2.5b bar moves once, now, for the whole corpus — the log has to make that
        // explainable rather than alarming, exactly as the backfill and enrichment logs do.
        Logger.info("Surface attribution repair complete", component: .codexLocalAdapter,
                    metadata: ["files": "\(summary.filesScanned)",
                               "vanished": "\(summary.filesVanished)",
                               "parsed": "\(summary.eventsParsed)",
                               "rows_repaired": "\(repaired.withLock { $0 })",
                               "duration_s": "\(Int(Date().timeIntervalSince(sweepStart)))"])
        try? await store.writeSetting(
            key: key, value: String(Int(sweepStart.timeIntervalSince1970)))
    }

    private func handleLocalActivity(tool: Tool, at latestEventAt: Date) {
        guard let delay = alignment[tool]!.activityObserved(now: Date(),
                                                            latestEventAt: latestEventAt)
        else { return }
        alignmentTimers[tool]?.cancel()
        alignmentTimers[tool] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            fireAlignmentPoll(tool: tool)
        }
    }

    /// The quiet stretch survived. Cancels only the sleeper — the loop iterates into an immediate
    /// `pollOnce` — exactly as the JSONL tripwire and `wakeRefresh` do; a poll is never awaited on
    /// this path (MainActor serialization). The floor is the shared ladder-aware one, so nothing
    /// fires while the transient 429 ladder is elevated.
    private func fireAlignmentPoll(tool: Tool) {
        alignmentTimers[tool] = nil
        let now = Date()
        // STEP_168: a pending advertised cooldown outranks the alignment cap — the fire is not
        // spent, so the policy re-arms on the next flush once the hold has passed.
        if heldByCooldown(tool: tool, trigger: "alignment", now: now) { return }
        guard alignment[tool]!.fire(now: now,
                                    lastPollAt: lastPollAt[tool] ?? restoredAt[tool],
                                    floor: pollFloor(tool: tool, now: now)) else { return }
        Logger.info("Turn-boundary alignment poll", component: .pollEngine,
                    metadata: ["tool": tool.rawValue,
                               "fires_this_window": "\(alignment[tool]!.firesSpentThisWindow)"])
        sleepers[tool]?.cancel()
    }

    /// §13.1 Trigger 2 — a meaningful JSONL delta (subagent/surface change, burn-tier crossing,
    /// or quota-429) re-evaluates state between polls against the *cached* snapshot plus fresh
    /// local signals. Debounced 5s adapter-side; `.jsonlDelta` never refreshes the §9.3 TTL
    /// clock, so this cannot keep stale account data alive.
    private func handleLocalDelta(_ signal: LocalDeltaSignal) async {
        let tool = signal.tool
        // JSONL tripwire (§9.2, STEP_38): the first delta after an idle stretch cancels this
        // tool's sleeper — the loop iterates into an immediate poll, so fresh account data lands
        // seconds after the first turn of a session. Same mechanism as `wakeRefresh`, same 45s
        // floor (against the restored poll clock before the first in-process poll, so a burst of
        // flushes — or a launch mid-session — cannot hammer the endpoint or defeat R33-5).
        // STEP_168: gated before the policy so a held trip is not consumed — the tester's log
        // shows tripwire polls fired into a one-hour countdown and refused every time.
        if heldByCooldown(tool: tool, trigger: "tripwire", now: Date()) {
            // The delta is still recorded below; only the poll is withheld.
        } else if tripwire[tool]!.deltaArrived(now: Date(),
                                               lastPollAt: lastPollAt[tool] ?? restoredAt[tool]) {
            Logger.info("JSONL tripwire — immediate poll", component: .pollEngine,
                        metadata: ["tool": tool.rawValue])
            sleepers[tool]?.cancel()
        }
        await writeQuota429Events(signal)

        // Before any live success the launch-restored snapshot backs delta evaluations (R33-4) —
        // without it a JSONL delta would classify from a nil snapshot and wipe a restored block.
        let cached = lastSnapshot[tool] ?? restoredSnapshot[tool]
        // One table set and one instant for the forecast and its shadow row — see `pollOnceInner`.
        let blendTables = shadowTables[tool] ?? .empty
        let forecastAt = Date()
        let forecastResult: Forecast
        if let cached {
            forecastResult = await forecast.forecast(for: cached, tables: blendTables,
                                                     now: forecastAt)
        } else {
            forecastResult = Forecast(tool: tool, tier: .unknown, runwayMinutes: nil,
                                      burnRatePerMin: nil, isEstimate: false, pollCount: 0)
        }
        let shortDelta = await forecast.utilDelta(for: tool, overSeconds: 120)
        let twoPollDelta = await forecast.utilDeltaLast2Polls(for: tool)
        let localTokens = await attribution?.localTokensLast2Min(for: tool)
        let windowStart = cached?.primaryWindowStart
        let now = Date()
        // Rank 6's input (STEP_189) — see `pollOnceInner`: bounded on this evaluation's clock, so
        // a JSONL delta long after the spike re-asserts nothing.
        let fastBurnDelta = await forecast.utilDeltaLast2Polls(
            for: tool, withinSeconds: ForecastEngine.fastBurnMaxPollGap, now: now)
        // The day grain and anchor are recomputed here, not inherited: a delta re-render must not
        // revert the §2.5a grain to the 5-hour window (nor re-anchor its rows to a rolling `now−5h`)
        // between polls — on the monthly layout there is no window to fall back on (REV-47 §2.4),
        // and on windowed Codex the fallback is a decision about the *cached* snapshot's window
        // (REV-49 §2.3). Cheap: already-existing session-count reads.
        let isMonthlyLayout = cached?.monthlyLimit != nil
        // The idle retrospective anchor is recomputed here for the same reason (REV-82 —
        // STEP_151): without it a delta re-render on a fresh null window re-anchored the rows to a
        // rolling `now−5h` and the header flipped back to the live grain between polls.
        let lastActiveWindow: DateInterval? =
            (cached != nil && cached?.primaryResetsAt == nil && cached?.monthlyLimit == nil)
            ? (try? await store?.lastActiveWindow(tool: tool, now: now)) ?? nil
            : nil
        let (localDay, localDayAnchor) = await localDayGrain(
            tool: tool, isMonthlyLayout: isMonthlyLayout,
            windowConfirmed: cached?.primaryResetsAt != nil,
            hasRetrospective: Self.retrospectiveAvailable(cached, lastActiveWindow),
            now: now)
        let local = await attribution?.attribution(
            for: tool, windowStart: localDayAnchor ?? lastActiveWindow?.start ?? windowStart)
        // Helper buckets are not surfaces (D-99). `surfaceShares` mixes real surfaces with
        // `Subagent · …` threads, and a helper *runs inside* the surface that spawned it — so
        // counting the raw list read one Codex Desktop plus its own subagents as concurrent
        // surfaces and held §13 rule 8 on. Split once, here, and hand the engines the same
        // definition `DisplayFormatter` names from — the recency-filtered `activeSurfaces(now:)`
        // since STEP_192, as in `pollOnceInner`.
        let activeSurfaces = SurfaceWorkSplit(local?.surfaceShares ?? []).activeSurfaces(now: now)
        let adapter = tool == .claude ? claude : codex
        let health = await adapter.health
        let inputs = StateInputs(tool: tool, snapshot: cached, health: health,
                                 forecast: forecastResult, trigger: .jsonlDelta, now: now,
                                 fastBurnDelta: fastBurnDelta,
                                 utilDeltaLast2Polls: twoPollDelta,
                                 localTokensLast2Min: localTokens,
                                 activeSurfaceBucketCount: activeSurfaces.count,
                                 subagentCount: local?.subagentCount ?? 0,
                                 lastLocalActivityAt: local?.lastActivityAt)
        let evaluation = await stateEngine.evaluate(inputs)
        let state = evaluation.state
        // §11.5 shadow (STEP_190). No table refresh here — a JSONL delta is not a window boundary,
        // and the poll path owns that trigger. The shadow's own recency bound is what keeps a delta
        // arriving long after the last poll from re-asserting a stale reading.
        var shadow: ShadowForecast?
        if let cached {
            shadow = await forecast.shadow(for: cached, tables: blendTables, now: forecastAt)
        }
        await logForecast(tool: tool, snapshot: cached, forecast: forecastResult,
                          evaluation: evaluation, shadow: shadow, now: now)
        // Path-1 notification for a delta-driven transition (e.g. JSONL-observed over-quota)
        // fires immediately through the same arbitration entry point — no poll signal here, so
        // the transition is the only candidate (STEP_28).
        await notificationEngine.evaluateCycle(change: evaluation.change, signal: nil, now: now)
        // Refresh the popover with the delta-driven result. `recordsPoll: false` — this is
        // cached account data; the footer's staleness clock must reflect real polls only.
        // A tool already showing the stale (past-TTL) render stays on the stale path so the
        // delta refreshes the local rows without stripping the "as of" marker (STEP_32).
        if let cached {
            if staleShown[tool] != nil, let asOf = lastSuccessAt[tool] ?? restoredAt[tool] {
                staleShown[tool] = state
                viewModel.applyCached(tool: tool, state: state, snapshot: cached, asOf: asOf,
                                      localAttribution: local, freezeReason: health, now: now)
            } else {
                // A JSONL delta between polls carries no fresh account utilization, so no new
                // usage may be invented — but the recompute may legitimately *improve*: the
                // landed turn's tokens or elapsed guard time can settle a pending interval
                // (REV-53 — STEP_76). `current(for:)` re-walks the window read-only.
                let windowAttribution = await offMachine.current(for: tool)
                // Same discipline for the monthly split: `current(for:)` is the non-advancing
                // read (STEP_65), so the cumulative rows keep rendering between polls without a
                // meter delta being attributed to an interval nothing measured.
                var monthlySplit: MonthlyAttribution?
                var monthlyRate: Double?
                if isMonthlyLayout {
                    monthlySplit = await monthlyAttribution.current(for: tool)
                    // The trailing rate is a pure function of already-persisted snapshots, so
                    // recomputing it here returns the same answer the last poll produced rather
                    // than blinking the `$/hr` row to `—` between polls.
                    let samples = ((try? await store?.readMonthlyUsedSamples(
                        tool: tool, since: now.addingTimeInterval(-3_900))) ?? nil) ?? []
                    monthlyRate = MonthlySpendRate.compute(samples: samples)
                }
                viewModel.apply(tool: tool, snapshot: cached, forecast: forecastResult,
                                state: state, localAttribution: local,
                                offMachine: windowAttribution,
                                fastBurnDelta: fastBurnDelta,
                                moneyGlyph: evaluation.moneyGlyph,
                                lastActiveWindow: lastActiveWindow,
                                monthlyAttribution: monthlySplit,
                                monthlyRatePerHour: monthlyRate,
                                localDay: localDay, recordsPoll: false)
            }
        }
        Logger.debug("JSONL delta evaluated", component: .pollEngine,
                     metadata: ["tool": tool.rawValue, "state": state.rawValue,
                                "surface": "\(signal.surfaceBucketChanged)",
                                "subagent": "\(signal.subagentCountChanged)",
                                "burn_tier": "\(signal.burnTierCrossed)",
                                "quota_429s": "\(signal.quota429Observations.count)"])
        // STEP_177: local ingestion landed — refresh the day's report (coalesced).
        refreshDailyReport(tool, reason: "jsonl")
    }

    /// The local sections' day grain and their attribution anchor. `(nil, nil)` means "keep the
    /// 5-hour grammar" — the confirmed reset-anchored window — and is what the formatter reads to
    /// pick both section titles, so grain and anchor can never disagree.
    ///
    /// Two ways to land on a day: the **monthly layout** (REV-47 §2.4 — STEP_65; REV-48 §2.4 —
    /// STEP_67), which has no window to anchor on — local midnight while today has sessions,
    /// yesterday's midnight when today is quiet (the recap gate *is* "no events since midnight", so
    /// the open-ended `since:` is uncontaminated), `.none` when both days are quiet; and **windowed
    /// Codex with an unconfirmed window start and no window to recap** (REV-49 §2.3 — STEP_69),
    /// where local midnight supersedes the §3.3 session-meta guess as these sections' anchor. The
    /// latter is always `.today`, never yesterday: with a prior 5-hour window on record the idle
    /// "last window" retrospective (REV-82 — STEP_151, taking up REV-49 §2.4's deferral) wins
    /// instead — `hasRetrospective` — and the anchor falls through to `lastActiveWindow`, exactly
    /// as on Claude.
    ///
    /// Shared by the poll path and the JSONL-delta re-render so the two can never disagree about
    /// which day is being shown. `sessionCount` is per-tool scoped already.
    /// Whether the idle "last window" retrospective can fire for this snapshot (REV-82 — STEP_151).
    /// Beyond a prior window on record it needs the current window to be the **5-hour** width:
    /// `quota_series` persists no width, so `lastActiveWindow`'s span is five hours by construction
    /// and would misname a 30-day Free/Go window. On Claude the width is always five hours (REV-80),
    /// so this changes nothing there. The display-side gate (`primaryWindowIsUnanchored`, fresh
    /// only) lives in `DisplayFormatter`; this decides only whether "today" yields the anchor.
    private static func retrospectiveAvailable(_ snapshot: QuotaSnapshot?,
                                               _ lastActiveWindow: DateInterval?) -> Bool {
        lastActiveWindow != nil && snapshot?.primaryWindowSeconds == 18_000
    }

    private func localDayGrain(tool: Tool, isMonthlyLayout: Bool, windowConfirmed: Bool,
                               hasRetrospective: Bool, now: Date) async -> (LocalDayGrain?, Date?) {
        let midnight = Calendar.current.startOfDay(for: now)
        guard isMonthlyLayout else {
            guard tool == .codex, !windowConfirmed, !hasRetrospective else { return (nil, nil) }
            return (.today, midnight)
        }
        let todaySessions = ((try? await store?.sessionCount(tool: tool, since: midnight)) ?? nil) ?? 0
        if todaySessions > 0 { return (.today, midnight) }
        let yesterdayMidnight = midnight.addingTimeInterval(-86_400)
        let yesterdaySessions =
            ((try? await store?.sessionCount(tool: tool, since: yesterdayMidnight)) ?? nil) ?? 0
        if yesterdaySessions > 0 { return (.yesterday, yesterdayMidnight) }
        return (LocalDayGrain.none, midnight)
    }

    /// §17.1 (STEP_51): one `forecast_log` row when the tool's 300s sample clock has elapsed or
    /// this evaluation produced a transition — called after every §13 evaluation. `guard let
    /// store` first so a store-less run never advances the clock; `try?` because a failed write
    /// (logged WARN in the store) must never block the evaluation path.
    ///
    /// `shadow` (STEP_190) is supplied by the two paths that hold a live account reading and a real
    /// engine forecast. The launch-restore and staleness paths pass nothing on purpose: their
    /// `Forecast` is a hand-built placeholder or a reading the app is already calling stale, and
    /// pairing a live shadow with a non-prediction would give STEP_191 a pair it cannot grade.
    private func logForecast(tool: Tool, snapshot: QuotaSnapshot?, forecast: Forecast,
                             evaluation: StateEvaluation, shadow: ShadowForecast? = nil,
                             now: Date) async {
        guard let store,
              let entry = forecastLog.entry(tool: tool, snapshot: snapshot, forecast: forecast,
                                            evaluation: evaluation, shadow: shadow, now: now)
        else { return }
        try? await store.writeForecastLog(entry)
    }

    /// Rebuilds one tool's §11.5 tables from `quota_series` + `forecast_log` (STEP_190).
    ///
    /// Called at launch and **on window close** — the anchor the tables were built under having
    /// moved — so the read runs about once per quota window, never per poll. Detection is by
    /// comparing anchors here rather than by subscribing to `StateEngine.windowResets`, whose one
    /// consumer is `NotificationEngine`: the coordinator already holds both anchors, and a second
    /// subscriber on that stream would be a new failure mode for no new information.
    ///
    /// Coalesced per tool. A failed read leaves the previous tables in place — the same
    /// failed-is-not-empty rule STEP_177 set for the daily report — because falling back to the
    /// prior on a transient SQLite error would silently change what gets logged.
    private func refreshShadowTables(_ tool: Tool, anchor: Date?, reason: String) {
        guard let store, !shadowRefreshInFlight.contains(tool) else { return }
        shadowRefreshInFlight.insert(tool)
        let task = Task(priority: .utility) { [weak self] in
            defer { self?.shadowRefreshInFlight.remove(tool) }
            let now = Date()
            let since = now.addingTimeInterval(-ShadowPolicy.trainingLookback)
            guard let points = try? await store.quotaSeriesRange(tool: tool, since: since,
                                                                 until: now),
                  let exposures = try? await store.forecastLogWindowExposure(tool: tool,
                                                                            since: since,
                                                                            until: now)
            else {
                Logger.debug("Shadow tables read failed — keeping previous",
                             component: .forecastEngine, metadata: ["tool": tool.rawValue])
                return
            }
            let tables = ShadowTablesReader.build(tool: tool, points: points,
                                                  exposures: exposures, now: now)
            guard let self else { return }
            self.shadowTables[tool] = tables
            self.shadowTablesBuilt.insert(tool)
            self.shadowTablesAnchor[tool] = anchor
            Logger.info("Shadow tables rebuilt", component: .forecastEngine,
                        metadata: ["tool": tool.rawValue, "reason": reason,
                                   "windows": "\(tables.completedWindows)",
                                   "origins": "\(tables.originCount)"])
        }
        tasks.append(task)
    }

    /// Rebuilds the tables when this poll's window is not the one they were built under — the
    /// "on window close" trigger of §11.5. The first poll of a process always rebuilds, which is
    /// the "at launch" half; after that a rebuild costs one thirty-day read per window rollover.
    private func refreshShadowTablesIfWindowMoved(_ tool: Tool, anchor: Date?) {
        let built = shadowTablesBuilt.contains(tool)
        let known = shadowTablesAnchor[tool]
        let moved: Bool
        switch (built, known, anchor) {
        case (false, _, _): moved = true                       // the launch build
        case let (true, old?, new?):
            moved = abs(new.timeIntervalSince(old)) > QuotaSnapshot.resetJitterTolerance
        case (true, nil, .some): moved = true                  // built while idle; a window opened
        case (true, _, nil): moved = false                     // a null window ends nothing
        }
        guard moved else { return }
        refreshShadowTables(tool, anchor: anchor, reason: built ? "window_close" : "launch")
    }

    /// §9.4 — joins JSONL quota-429 observations with poll-side context (utilization%,
    /// plan_type) into `quota_limit_events`, the self-learning ceiling's input. Working
    /// assumption: attributed to the 5-hour window — JSONL carries no window discriminator
    /// (noted in STEP_26). Skipped without a successful poll: utilization at the limit is
    /// unknown, and a row without it would poison the ceiling estimate.
    private func writeQuota429Events(_ signal: LocalDeltaSignal) async {
        guard !signal.quota429Observations.isEmpty, let store else { return }
        let tool = signal.tool
        guard let snapshot = lastSnapshot[tool], let util = snapshot.primaryUsedPct else {
            Logger.debug("Quota 429 observed without poll context — not recorded",
                         component: .pollEngine, metadata: ["tool": tool.rawValue])
            return
        }
        // The store applies the §9.4 plausibility floor (STEP_80) and reports what it accepted, so
        // this line counts writes rather than observations — a sub-floor observation used to log
        // "recorded" for a row that was never written.
        var recorded = 0
        for observation in signal.quota429Observations {
            let written = (try? await store.writeQuotaLimitEvent(
                tool: tool, timestamp: observation.observedAt, utilizationPct: util,
                windowType: .fiveHour, sourceFile: observation.sourceFile,
                planType: snapshot.planType ?? "")) ?? false
            if written { recorded += 1 }
        }
        Logger.info("Quota 429 observed", component: .pollEngine,
                    metadata: ["tool": tool.rawValue,
                               "recorded": "\(recorded)",
                               "discarded": "\(signal.quota429Observations.count - recorded)",
                               "util": "\(Int(util))%"])
    }

    /// §9.5 — endpoint per tool: a Claude 429 comes from the OAuth usage endpoint; a *surfaced*
    /// Codex 429 means the wham leg 429'd (an RPC 429 falls through to wham inside
    /// `CodexAccountAdapter` and only counts when wham also 429s — §9.3 Codex rule). An RPC 429
    /// rescued by a wham success is a successful poll and is not persisted; `"rpc"` stays
    /// reserved for a future per-leg report.
    private func writePollHealthEvent(tool: Tool, retryAfter: Int,
                                      step: PollBackoffPolicy.RateLimitStep,
                                      details: RateLimit429Details?) async {
        guard let store else { return }
        let endpoint: PollHealthEndpoint = tool == .claude ? .oauthUsage : .whamUsage
        // Copy the last-good account context onto the row now (§9.5 — R31-4): `poll_snapshots`
        // retains only 2h, so it cannot be joined at read time. Before the first success of this
        // process the launch-restored snapshot stands in (R33-3) — the columns came back null on
        // every post-relaunch 429 in the REV-33 incident, which is exactly when they matter.
        let last = lastSnapshot[tool] ?? restoredSnapshot[tool]
        try? await store.writePollHealthEvent(
            tool: tool, endpoint: endpoint, retryAfterSeconds: retryAfter,
            consecutiveCount: step.consecutiveCount, baseIntervalAtTime: step.baseIntervalAtTime,
            details: details,
            lastPrimaryUsedPct: last?.primaryUsedPct,
            lastSecondaryUsedPct: last?.secondaryUsedPct,
            lastPrimaryResetsAt: last?.primaryResetsAt,
            lastExtraUsageEnabled: last?.extraUsage?.isEnabled,
            nullWindowSource: last?.nullWindowSource)
    }

    /// §9.5/§9.1 — one `credential_expired` forensic row per gated (or reclassified) poll (REV-41,
    /// STEP_48). Records the *current, unchanged* ladder state (this class never advances it) and
    /// the last-good account context, copied at write time (§9.5 — poll_snapshots retains 2h).
    /// `retry_after_seconds` is written NULL by the store; a reclassified 429's countdown is
    /// preserved inside `details.headers`. Claude-only — the endpoint is always the OAuth usage
    /// leg (Codex has a different auth posture and is out of scope, §8.0.1).
    private func writeCredentialExpiredHealthEvent(tool: Tool,
                                                   details: RateLimit429Details?) async {
        guard let store else { return }
        let last = lastSnapshot[tool] ?? restoredSnapshot[tool]
        try? await store.writeCredentialExpiredEvent(
            tool: tool, endpoint: .oauthUsage,
            consecutiveCount: backoff[tool]!.consecutive429s,
            baseIntervalAtTime: Int(backoff[tool]!.steadyDelay(now: Date())),
            details: details,
            lastPrimaryUsedPct: last?.primaryUsedPct,
            lastSecondaryUsedPct: last?.secondaryUsedPct,
            lastPrimaryResetsAt: last?.primaryResetsAt,
            lastExtraUsageEnabled: last?.extraUsage?.isEnabled,
            nullWindowSource: last?.nullWindowSource)
    }

    /// Starts the 30-min retention loop once, after the first poll completes (§17.2).
    private func startRetentionIfNeeded() {
        guard !retentionStarted, let retention else { return }
        retentionStarted = true
        tasks.append(Task { await retention.start() })
    }
}
