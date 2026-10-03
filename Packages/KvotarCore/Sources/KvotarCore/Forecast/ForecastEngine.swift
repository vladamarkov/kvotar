import Foundation

/// Owns the rolling utilization-delta buffer and computes runway (Baseline §11, PATTERNS.md
/// §Actor usage). The live buffer is in-memory and per-tool; at launch it is rehydrated from the
/// same bounded `poll_snapshots` history so a process restart does not erase valid evidence.
///
/// The engine is a pure reporter: it records normalized snapshots and returns a `Forecast`.
/// It never polls, never writes to `SQLiteStore`, and holds no notion of app state.
public actor ForecastEngine {

    /// One persisted primary-window observation used only to rehydrate the live buffer at launch.
    /// It carries exactly the fields the burn calculation consumes; account identity and the
    /// secondary/monthly meters never enter this series.
    public struct SeedSample: Sendable, Equatable {
        public let usedPct: Double
        public let polledAt: Date
        public let resetsAt: Date?
        public let windowSeconds: Int?

        public init(usedPct: Double, polledAt: Date, resetsAt: Date?, windowSeconds: Int?) {
            self.usedPct = usedPct
            self.polledAt = polledAt
            self.resetsAt = resetsAt
            self.windowSeconds = windowSeconds
        }
    }

    /// One buffered utilization sample: the primary-window used-percent at a moment in time.
    private struct Sample {
        let usedPct: Double
        let at: Date
    }

    /// Rolling window size for the burn-rate average (Baseline §11.2/§11.3), **and** the §11.4
    /// cold-start threshold: `isEstimate` clears here, the initialisation line logs here, and
    /// `ForecastLogRecorder.tier` grades `forecast_log` against it. Since REV-74/D-84 it is no
    /// longer the buffer's cap on every window — that is `bufferPolicy(windowLength:).countCap`,
    /// which equals this on short windows and is 60 on long ones. The two were deliberately not
    /// merged: retention is about *span*, cold start is about how many polls initialise the
    /// average, and REV-65 already settled that they are different questions.
    static let bufferSize = 10
    /// Below this burn rate, show the reset countdown rather than a runway (§11.2).
    static let nearZeroBurnPerMin = 0.001
    /// Samples older than this are dropped before the next one lands (§11.2a, REV-35). It replaces
    /// the old "gap > 10 min ⇒ wipe the buffer" rule, which threw away a still-valid anchor every
    /// time the Mac idle-slept for ten minutes and left the average reading 0 for up to 10 polls
    /// (the 2026-07-14 "No active burn" incident: a 614s gap, then two polls both reading 44%).
    /// Ageing out individual samples keeps the anchor across a short gap — the account delta over
    /// it is exact, and the window burns in wall time whether or not we were awake to watch — while
    /// an overnight sleep still ages the whole buffer out to a clean cold start. One hour is above
    /// 10 × the 300s max poll interval (50 min), so a full 10-poll average is never truncated at
    /// any legal cadence, and it bounds how far a flat sleep interval can dilute the average.
    static let sampleMaxAge: TimeInterval = 3600
    /// Public launch lookback for the poll driver. Kept equal to the engine's own age bound so
    /// SQLite never reads evidence the engine will immediately reject.
    public static let seedLookback: TimeInterval = sampleMaxAge
    /// The account endpoints quantize utilization to whole percent (§11.2a, REV-35).
    static let utilizationQuantumPct = 1.0
    /// Span a **zero** delta must cover before it is evidence of no burn rather than of burn too
    /// slow to have moved the integer yet (§11.2a). One quantum (1%) over this span is 0.1 %/min —
    /// the display's own "none" tier boundary — so below it a flat reading cannot even support the
    /// weakest calm claim the UI makes, and burn is reported unknown (`nil`) instead of zero.
    static let zeroBurnResolvableSpan: TimeInterval = 600
    /// The trim may not shrink the buffer's first→last span below this while over the count cap
    /// (§11.2a, REV-65/STEP_106): the zero-proof above plus one base-cadence poll of margin.
    /// Without it the two constants collide — 10 samples at the 60s base span 540s, one minute
    /// short of the proof forever, so an idle meter sat on `Measuring…` at exactly the cadence the
    /// app runs most and flipped to "Nothing burning" only when the 429 ladder slowed polling. At
    /// 60s the buffer settles at 12 samples; at every cadence ≥ 120s the count cap governs alone.
    /// At the 120 s base (STEP_169) the cap holds 10 samples ≈ 18 minutes: the zero-proof is a
    /// span rule, so it still resolves after ~10 minutes flat; the average simply remembers
    /// longer, as it already did whenever the ladder ran at 120 s. Accepted, cap unchanged.
    static let zeroBurnRetentionSpan: TimeInterval = 660
    /// A `resets_at` advance beyond this is a genuine window rollover (mirrors
    /// `StateEngine.resetJitterTolerance` — the endpoint wobbles ±1s between polls).
    static let resetJitterTolerance: TimeInterval = 60
    /// How far apart two polls may sit and still be read as one fast-burn measurement, and how
    /// stale the newer of them may be at evaluation time (§13 rank 6, REV-95 §3.4 — STEP_189).
    /// Two and a half base ticks: wide enough that the 120s cadence (±5s jitter) always qualifies
    /// and a single missed poll usually does, narrow enough that the rise is still recent news.
    /// Beyond it the pair makes no claim — it is not a slower spike, it is no longer a spike.
    public static let fastBurnMaxPollGap: TimeInterval = 300

    // MARK: Buffer policy — how much evidence a window's width deserves (REV-74/D-84, §11.2a)

    /// The three constants above, as one width-keyed set. A five-hour window and a weekly one are
    /// not the same measurement problem: one percent of five hours is a small thing, and eleven
    /// minutes of evidence resolves it; one percent of a *week* is a big thing, and eleven minutes
    /// cannot tell a single tick from a sustained rate. Live 2026-08-19 (Codex Plus): a weekly
    /// meter moving 17 → 26 % over 100 minutes — about nine times the week's even pace — was seen
    /// one tick at a time and the pill flapped `none ↔ low` all evening.
    struct BufferPolicy {
        /// Count cap for the trim. Not the §11.4 cold-start threshold — see `bufferSize`.
        let countCap: Int
        /// Span a **zero** delta must cover before it counts as evidence of no burn (Rule 1).
        let zeroProofSpan: TimeInterval
        /// Span the trim may not cut below while over `countCap` (REV-65's span-aware trim).
        let retentionSpan: TimeInterval
    }

    /// A window this wide or wider gets the long policy — the REV-65/D-69 long-window boundary,
    /// reused rather than restated, so the pace hero and the burn buffer agree about what "long"
    /// means (`DisplayFormatter` keys its calm pace family on the same number).
    public static let longWindowFrom: TimeInterval = 86_400

    /// Five hours and anything narrower: today's constants, unchanged to the digit.
    static let shortWindowBuffer = BufferPolicy(countCap: bufferSize,
                                                zeroProofSpan: zeroBurnResolvableSpan,
                                                retentionSpan: zeroBurnRetentionSpan)

    /// A day or wider: an hour of evidence. The three numbers stand in exactly the same relation
    /// as the short set, scaled up — and the zero-proof is **derived, not chosen**, twice over.
    /// It must be *reachable*: `sampleMaxAge` drops samples past 3600s, so the buffer's span can
    /// never quite reach 3600 and a 3600s proof would leave an idle weekly window on `Measuring…`
    /// forever — REV-65's collision, reintroduced. 3000s is 50 minutes, which is also 10 × the
    /// 300s poll ceiling, the same derivation `sampleMaxAge` itself uses. With the retention floor
    /// at 3060s the span sits in [3060, 3600] at every legal cadence (45s → 69 samples, 60s → 60,
    /// 300s → ~12), so the proof always finishes.
    ///
    /// **What `none` claims here, stated rather than hidden:** a flat 50 minutes bounds burn below
    /// one quantum / 50 min = 0.02 %/min ≈ 2× a weekly window's even pace — the `low` band, not a
    /// strictly earned zero below the `none` boundary, which would need 5h 36m flat. The bound is
    /// accepted because it reaches exactly one surface, the burn pill: on long windows the header
    /// is the REV-65 pace row, computed from used-% against elapsed-% with no buffer in the loop,
    /// so "Nothing burning" never renders from it (REV-74 §3.3).
    static let longWindowBuffer = BufferPolicy(countCap: 60,
                                               zeroProofSpan: 3000,
                                               retentionSpan: 3060)

    /// Pass `QuotaSnapshot.primaryWindowLength` — never `primaryWindowSeconds`, which is nil on
    /// any Codex payload that omits it (Claude sets its own 18 000 s since REV-80); the fallback
    /// is five hours, so an unstated width keeps today's behaviour.
    static func bufferPolicy(windowLength: TimeInterval) -> BufferPolicy {
        windowLength >= longWindowFrom ? longWindowBuffer : shortWindowBuffer
    }

    /// Last ≤ `bufferSize` samples per tool, oldest first. Codex null-window polls are not
    /// buffered (no usable `usedPct`) so a spell of null windows does not pollute the average.
    private var buffers: [Tool: [Sample]] = [:]
    /// The same samples with the **count trim left off** — everything inside `sampleMaxAge`,
    /// oldest first. §11.5's `long_rate` is measured over it: logged by `shadow(...)` on both
    /// tools, and since REV-105 (STEP_230) part of the rate Claude's five-hour runway divides by.
    ///
    /// It is a second ring rather than a wider cap because the two answer different questions. The
    /// shipped buffer is deliberately short — at the 120 s base it holds 10 samples ≈ 18 minutes on
    /// a five-hour window (REV-89) — and REV-95 §3.3 wants a rate measured over the trailing hour
    /// *beside* it, not instead of it. On a window of a day or wider `countCap` is 60 and the two
    /// rings already coincide, which is the case the contract's "the untrimmed ≤ 1 h history it
    /// already keeps for the long-window policy" was describing; on a five-hour window they do not,
    /// and without this the long rate would have nothing to read.
    private var rawBuffers: [Tool: [Sample]] = [:]
    /// Whether the §11.4 "10 polls complete" INFO line has been logged for a tool (log once).
    private var loggedFullInit: Set<Tool> = []
    /// Last seen primary `resets_at` per tool — window-rollover detection for buffer clearing.
    private var lastResetsAt: [Tool: Date] = [:]

    /// Pure over its buffers. The §11.1 Inferred-runway tier — and the store/limits inputs it
    /// needed — was retired by REV-80 / D-101 (STEP_147): it fired only on the nil-percent shape
    /// D-101 removed, and its runway was never displayed (REV-54 §6).
    public init() {}

    /// Replaces one tool's empty launch buffer with recent persisted account observations.
    /// The same reset/drop and width-aware trimming rules as live recording apply. Future and
    /// expired rows are rejected here rather than trusted merely because they came from SQLite.
    public func seed(tool: Tool, samples persisted: [SeedSample], now: Date = Date()) {
        var samples: [Sample] = []
        var raw: [Sample] = []
        var lastReset: Date?

        for item in persisted.sorted(by: { $0.polledAt < $1.polledAt }) {
            let age = now.timeIntervalSince(item.polledAt)
            guard age >= 0, age <= Self.sampleMaxAge else { continue }

            if let last = samples.last, item.usedPct < last.usedPct {
                samples.removeAll()
                raw.removeAll()
            }
            if let newReset = item.resetsAt {
                if let old = lastReset,
                   newReset.timeIntervalSince(old) > Self.resetJitterTolerance {
                    samples.removeAll()
                    raw.removeAll()
                }
                lastReset = newReset
            }

            samples.append(Sample(usedPct: item.usedPct, at: item.polledAt))
            raw.append(Sample(usedPct: item.usedPct, at: item.polledAt))
            let width = TimeInterval(item.windowSeconds ?? 18_000)
            let policy = Self.bufferPolicy(windowLength: width)
            while samples.count > policy.countCap, let last = samples.last,
                  last.at.timeIntervalSince(samples[1].at) >= policy.retentionSpan {
                samples.removeFirst()
            }
        }

        buffers[tool] = samples
        rawBuffers[tool] = raw
        lastResetsAt[tool] = lastReset
        if samples.count >= Self.bufferSize {
            loggedFullInit.insert(tool)
        } else {
            loggedFullInit.remove(tool)
        }
    }

    /// Clears the rolling buffer for `tool` — called by the poll driver when cached state is
    /// invalidated (§9.3): stale samples must not seed the burn average after recovery.
    public func reset(tool: Tool) {
        buffers[tool] = []
        rawBuffers[tool] = []
        lastResetsAt[tool] = nil
    }

    /// Records one poll's primary-window utilization for `tool` and returns the current forecast.
    ///
    /// Null-window snapshots (Codex healthy idle, §11.3) are recorded as a poll for cold-start
    /// counting but contribute no sample — runway is suspended while windows stay null.
    ///
    /// **Invariant: no sample older than `sampleMaxAge` survives any `record` call, window or
    /// not** (§11.2a; corrected v5.21 — REV-54 §7 / STEP_81). Ageing is a wall-clock rule on
    /// REV-35's own premise — the window burns in wall time whether or not we were awake to watch
    /// it — so the sweep runs *before* the window guard. Applying it only on polls that carried a
    /// window aged the buffer by windowed-polls rather than by time: a null-window run did nothing
    /// at all, and the buffer held a photograph of the moment before the window closed for as long
    /// as the run lasted (live 2026-07-23: 65 minutes of a re-served `0.032 %/min`).
    ///
    /// Before appending, the buffer is also cleared when the samples straddle a window rollover
    /// (`resets_at` advanced, or utilization dropped — the pre-reset samples would read as ~0 burn
    /// for up to 10 polls). Those two clears stay *inside* the guard: both compare against a
    /// `usedPct` a null poll does not have.
    ///
    /// `tables` are the §11.5 tables the Claude five-hour rate is blended with (REV-105); the
    /// caller hands the same ones to `shadow(for:tables:now:)` so the logged blend is the one used.
    @discardableResult
    public func record(snapshot: QuotaSnapshot, at now: Date = Date(),
                       tables: ShadowTables = .empty) async -> Forecast {
        // Oldest-first, so this drops a prefix: a short gap (sleep, a missed poll) keeps its
        // anchor and the next delta is measured across it; a long one leaves a cold start.
        // Written back unconditionally — on a null poll this is the only thing that runs, and
        // the decay has to be durable for the *next* poll to see it.
        var samples = buffers[snapshot.tool, default: []]
        samples.removeAll { now.timeIntervalSince($0.at) > Self.sampleMaxAge }
        buffers[snapshot.tool] = samples
        // The shadow's untrimmed ring ages by the same wall clock, on the same premise and in the
        // same place — outside the window guard, so a null-window run decays it too (§11.2a Rule 2,
        // REV-54 §7). Everything below that clears `samples` clears this as well.
        var raw = rawBuffers[snapshot.tool, default: []]
        raw.removeAll { now.timeIntervalSince($0.at) > Self.sampleMaxAge }
        rawBuffers[snapshot.tool] = raw

        if let usedPct = snapshot.primaryUsedPct {
            if let last = samples.last, usedPct < last.usedPct {
                samples.removeAll()
                raw.removeAll()
            }
            if let newReset = snapshot.primaryResetsAt {
                if let old = lastResetsAt[snapshot.tool],
                   newReset.timeIntervalSince(old) > Self.resetJitterTolerance {
                    samples.removeAll()
                    raw.removeAll()
                }
                lastResetsAt[snapshot.tool] = newReset
            }
            samples.append(Sample(usedPct: usedPct, at: now))
            raw.append(Sample(usedPct: usedPct, at: now))
            rawBuffers[snapshot.tool] = raw
            // Span-aware trim (§11.2a, REV-65): evict the oldest only while what remains still
            // spans the zero-proof — the count cap must not make "Nothing burning" unprovable.
            // The cap and the floor come from the window's own width (REV-74/D-84): a weekly
            // window keeps an hour, a five-hour window the eleven minutes it always kept. A width
            // that changes across a poll needs no special path — the next trim simply uses the
            // new policy (long → short evicts down, short → long stops evicting).
            let policy = Self.bufferPolicy(windowLength: snapshot.primaryWindowLength)
            while samples.count > policy.countCap, let last = samples.last,
                  last.at.timeIntervalSince(samples[1].at) >= policy.retentionSpan {
                samples.removeFirst()
            }
            buffers[snapshot.tool] = samples

            // §11.4's threshold, not the cap: the `~est.` label and this line clear at 10 polls on
            // every window width. What the buffer *holds* is the policy's business; what it takes
            // to initialise an average is not (REV-65's distinction, kept by REV-74).
            if samples.count >= Self.bufferSize, !loggedFullInit.contains(snapshot.tool) {
                loggedFullInit.insert(snapshot.tool)
                let span = samples.last!.at.timeIntervalSince(samples[0].at)
                Logger.info("Burn rate fully initialised",
                            component: .forecastEngine,
                            metadata: ["tool": snapshot.tool.rawValue,
                                       "samples": "\(samples.count)",
                                       "span_s": "\(Int(span.rounded()))",
                                       "cap": "\(policy.countCap)"])
            }
        }
        return await forecast(for: snapshot, tables: tables, now: now)
    }

    /// Current forecast for `snapshot.tool` given `snapshot`'s live window state. Pure over the
    /// buffers and the tables handed in — call after `record` for the up-to-date result, or
    /// directly to re-evaluate.
    ///
    /// **Which rate (§11.2, REV-105 — STEP_230).** On Claude's short window the runway divides by
    /// the §11.5 blend, and at ≥ `StateEngine.atRiskUtilFloor` used by the faster of the blend and
    /// the 18-minute rate — the blend is calmer by design, and calm is wrong at the top of a
    /// window. Wherever the blend has no value (unknown account state, a stale newest reading,
    /// both rates unresolved) the 18-minute rate is used unchanged. Codex and long windows keep
    /// the 18-minute rate. Every reader takes this `Forecast`, so they move together (§19).
    public func forecast(for snapshot: QuotaSnapshot, tables: ShadowTables = .empty,
                         now: Date = Date()) async -> Forecast {
        let tool = snapshot.tool
        let samples = buffers[tool, default: []]
        let pollCount = samples.count

        // Low-allowance rule (§11.3 REV-59 amendment, UI Spec D-60/D-64): the window is populated and
        // the buffer may be full, and neither fact helps. On a meter where one turn can cost
        // anywhere from 4 to 19 points of the whole month, a ten-poll average is arithmetic over
        // real numbers that describes nothing that will happen next. Per §11.2a's standing
        // discipline the outputs are **absent, not zero** — no burn rate, no runway, and therefore
        // no verdict and no `Measuring…` promise of a number we would never usefully deliver.
        //
        // `record` above is deliberately untouched: samples keep landing, so the §11.2a sweep
        // invariant is not forked and the per-poll history stays available. We suppress the
        // output, not the observation.
        if snapshot.isLowAllowanceShape {
            return Forecast(tool: tool, tier: .unknown, runwayMinutes: nil,
                            burnRatePerMin: nil, isEstimate: false, pollCount: pollCount)
        }

        // Null-window (Codex healthy idle, §11.3): suspend runway; no denominator to burn against.
        if snapshot.isNullWindow {
            return Forecast(tool: tool, tier: .creditBased, runwayMinutes: nil,
                            burnRatePerMin: nil, isEstimate: false, pollCount: pollCount)
        }

        guard let usedPct = snapshot.primaryUsedPct else {
            return Forecast(tool: tool, tier: .unknown, runwayMinutes: nil,
                            burnRatePerMin: nil, isEstimate: false, pollCount: pollCount)
        }

        // Cold start 0–1 polls (§11.4): reset countdown only — never a runway or burn rate.
        guard pollCount >= 2 else {
            return Forecast(tool: tool, tier: .fullRunway, runwayMinutes: nil,
                            burnRatePerMin: nil, isEstimate: false, pollCount: pollCount)
        }

        let short = burnRatePerMin(
            samples, zeroProofSpan: Self.bufferPolicy(windowLength: snapshot.primaryWindowLength).zeroProofSpan)
        var burn = short
        // The one rate-selection branch (REV-105 §2.1–§2.2) — the revert target.
        if tool == .claude, let rates = blendRates(for: snapshot, tables: tables, now: now) {
            burn = usedPct >= StateEngine.atRiskUtilFloor
                ? max(short ?? rates.blend, rates.blend) : rates.blend
        }
        let isEstimate = pollCount < Self.bufferSize   // 2–9 polls → `~est.` (§11.4)
        // The span the burn average covers — surfaced only where a burn is (STEP_110): the
        // anatomy labels its burn row with it, and a span without a rate would be a claim about
        // a measurement that did not resolve. It is the span of the rate actually chosen (D-130):
        // the buffer's when the 18-minute rate was taken, the trailing hour's otherwise.
        let span = burn == nil ? nil
            : burnSpanMinutes(burn == short ? samples : rawBuffers[tool, default: []])

        // Near-zero burn (§11.2): runway would be meaningless — show reset countdown instead.
        guard let burn, burn > Self.nearZeroBurnPerMin else {
            return Forecast(tool: tool, tier: .fullRunway, runwayMinutes: nil,
                            burnRatePerMin: burn, isEstimate: isEstimate, pollCount: pollCount,
                            burnSpanMinutes: span, shortBurnRatePerMin: short)
        }

        let remaining = max(0, 100 - usedPct)
        let runway = remaining / burn
        return Forecast(tool: tool, tier: .fullRunway, runwayMinutes: runway,
                        burnRatePerMin: burn, isEstimate: isEstimate, pollCount: pollCount,
                        burnSpanMinutes: span, shortBurnRatePerMin: short)
    }

    // MARK: - §11.5 shadow outputs (REV-95 §3.3 — STEP_190)

    /// The §11.5 shadow outputs for `snapshot`, or `nil` where the rule can say nothing.
    ///
    /// **Rendered nowhere, gating nothing, notifying nothing** — with one promotion: STEP_191
    /// graded the blend and REV-105 made it Claude's five-hour rate, which `forecast(for:)` takes
    /// from the same `blendRates` derivation. The probability and the range stay in shadow. The
    /// result goes straight to `forecast_log` beside the shipped runway so the two rates can be
    /// graded against each other on identical inputs. It is deliberately *not* a field on
    /// `Forecast`: the three consumers that must never see the probability or the range all take
    /// a `Forecast`, so the type system enforces the separation.
    ///
    /// Pure over the two rings and the tables handed in — the engine still reads no database. The
    /// tables come from `ShadowTablesReader`, which `PollCoordinator` refreshes at launch and on
    /// window close.
    ///
    /// `nil` under five guards. The first four are the shipped runway's own — low-allowance shape,
    /// null window, no utilization, cold start — so the shadow never claims a number where the
    /// product refuses one. The fifth is §11.5's: **the account state is unknown** when no sample
    /// sits near `now − 10 min` or `now − 30 min`, and an unknown state is a missing row, never
    /// `quiet` ("we did not look" is not "nothing happened"). Long windows are out of scope in this
    /// revision (§3.3: short windows only; the long-window shadow waits on REV-95 §3.5).
    public func shadow(for snapshot: QuotaSnapshot, tables: ShadowTables,
                       now: Date = Date()) -> ShadowForecast? {
        guard let rates = blendRates(for: snapshot, tables: tables, now: now) else { return nil }
        let range = tables.riseRange(for: rates.state)
        return ShadowForecast(version: ShadowPolicy.version,
                              blendRate: rates.blend,
                              riseProbability: tables.probability(for: rates.state),
                              riseP10: range.p10,
                              riseP90: range.p90)
    }

    /// The §11.5 account state and blend for `snapshot`, or `nil` under the five guards
    /// `shadow(for:tables:now:)` documents. One derivation with two readers: the shadow logs it,
    /// and on Claude `forecast(for:tables:now:)` divides the runway by it (REV-105), so the
    /// logged blend and the rate the verdict used cannot differ.
    private func blendRates(for snapshot: QuotaSnapshot, tables: ShadowTables,
                            now: Date) -> (state: ShadowAccountState, blend: Double)? {
        let tool = snapshot.tool
        guard !snapshot.isLowAllowanceShape, !snapshot.isNullWindow,
              snapshot.primaryUsedPct != nil,
              snapshot.primaryWindowLength < Self.longWindowFrom else { return nil }

        let samples = buffers[tool, default: []]
        let raw = rawBuffers[tool, default: []]
        guard samples.count >= 2 else { return nil }
        guard let state = accountState(raw, now: now) else { return nil }

        let policy = Self.bufferPolicy(windowLength: snapshot.primaryWindowLength)
        let short = burnRatePerMin(samples, zeroProofSpan: policy.zeroProofSpan)
        let long = burnRatePerMin(raw, zeroProofSpan: policy.zeroProofSpan)
        // "whichever exists if only one does" (§11.5). Both unresolved is no rate at all — the
        // §11.2a discipline: render nothing rather than zero, and log nothing rather than a guess.
        switch (short, long) {
        case let (short?, long?):
            let alpha = tables.alpha(for: state)
            return (state, alpha * short + (1 - alpha) * long)
        case let (short?, nil): return (state, short)
        case let (nil, long?): return (state, long)
        case (nil, nil): return nil
        }
    }

    /// §11.5's conditioning variable: did the account move in the last 10 minutes, else the last
    /// 30? `nil` when the ring holds no sample near either instant — the unknown case.
    ///
    /// Both lookbacks are required even for `burning`, deliberately: without the 30-minute
    /// neighbour a ring that only reaches back 12 minutes would report `burning` and `quiet` from
    /// the same evidence depending on which way the last tick fell, and the training set (which
    /// requires both) would then describe a different population from the live path.
    private func accountState(_ raw: [Sample], now: Date) -> ShadowAccountState? {
        guard let current = raw.last,
              now.timeIntervalSince(current.at) <= ShadowPolicy.originMatchTolerance,
              let past10 = nearest(raw, to: now.addingTimeInterval(-600)),
              let past30 = nearest(raw, to: now.addingTimeInterval(-1800)) else { return nil }
        if current.usedPct - past10.usedPct >= ShadowPolicy.riseThreshold { return .burning }
        if current.usedPct - past30.usedPct >= ShadowPolicy.riseThreshold { return .paused }
        return .quiet
    }

    /// The buffered sample closest to `target`, within `ShadowPolicy.originMatchTolerance`.
    private func nearest(_ samples: [Sample], to target: Date) -> Sample? {
        samples
            .filter { abs($0.at.timeIntervalSince(target)) <= ShadowPolicy.originMatchTolerance }
            .min { abs($0.at.timeIntervalSince(target)) < abs($1.at.timeIntervalSince(target)) }
    }

    /// How many samples the untrimmed §11.5 ring holds for `tool` — the shadow's own history, with
    /// no consumer on the shipped path. Exposed so the ageing and clearing rules can be asserted
    /// directly rather than inferred from a rate.
    func rawSampleCount(for tool: Tool) -> Int {
        rawBuffers[tool, default: []].count
    }

    /// Utilization delta over the last `seconds` for `tool`, or `nil` when fewer than two
    /// samples span that window. Powers the Fast-burn-spike signal (Δutil ≥ 20% in 2 min).
    public func utilDelta(for tool: Tool, overSeconds seconds: TimeInterval, now: Date = Date()) -> Double? {
        let samples = buffers[tool, default: []]
        guard samples.count >= 2 else { return nil }
        let cutoff = now.addingTimeInterval(-seconds)
        let inWindow = samples.filter { $0.at >= cutoff }
        guard let first = inWindow.first, let last = inWindow.last, inWindow.count >= 2 else {
            return nil
        }
        return last.usedPct - first.usedPct
    }

    /// The buffered burn-average measurement window for `tool` (REV-18): the first→last sample
    /// span the §11.2 burn rate is computed over, plus its total utilization delta. The
    /// off-machine estimator measures local burn over this exact span so account and local
    /// rates are time-aligned, and gates calibration on `usedPctDelta` (the endpoint's
    /// integer-quantized utilization makes small deltas mostly noise).
    public struct BurnWindow: Sendable, Equatable {
        public let start: Date
        public let end: Date
        public let usedPctDelta: Double
    }

    /// The current `BurnWindow` for `tool`, or `nil` with < 2 samples (no burn rate exists —
    /// mirrors `burnRatePerMin`'s guard) or a zero-length span. Delta clamps to 0 like the
    /// burn rate does, so a straddled reset cannot report a negative window delta.
    public func burnWindow(for tool: Tool) -> BurnWindow? {
        let samples = buffers[tool, default: []]
        guard let first = samples.first, let last = samples.last, samples.count >= 2,
              last.at > first.at else { return nil }
        return BurnWindow(start: first.at, end: last.at,
                          usedPctDelta: max(0, last.usedPct - first.usedPct))
    }

    /// Δ primary-window utilization between the two most recent buffered polls for `tool` — the
    /// Off-machine "account rising" signal (§13 rule 7). `nil` with < 2 samples; a negative delta
    /// (window reset) clamps to 0 so a rollover does not read as a rise.
    public func utilDeltaLast2Polls(for tool: Tool) -> Double? {
        let samples = buffers[tool, default: []]
        guard samples.count >= 2 else { return nil }
        return max(0, samples[samples.count - 1].usedPct - samples[samples.count - 2].usedPct)
    }

    /// The same pair, bounded — the Fast-burn-spike signal (§13 rank 6, REV-95 §3.4, STEP_189).
    /// `utilDelta(overSeconds: 120)` asked for two samples inside a 120s wall clock, which the
    /// 120s base cadence (REV-89) almost never provides: five fires in seven weeks, four of them
    /// at the old 60s base (Spike D F7). Measuring *between the two polls we have* is
    /// cadence-independent; the bound is what keeps it a measurement rather than an extrapolation.
    ///
    /// `nil` with < 2 samples, when the pair spans more than `withinSeconds`, **or when the newer
    /// poll is itself older than that** — a spike that ended is not a spike now, and without the
    /// second clause a JSONL-triggered evaluation could re-assert one from an hour-old pair
    /// (samples live `sampleMaxAge`). The clock-relative rule this replaces expired on its own.
    /// A negative delta (window rollover) clamps to 0, as in the unbounded form above.
    public func utilDeltaLast2Polls(for tool: Tool, withinSeconds: TimeInterval,
                                    now: Date = Date()) -> Double? {
        let samples = buffers[tool, default: []]
        guard samples.count >= 2 else { return nil }
        let newer = samples[samples.count - 1]
        let older = samples[samples.count - 2]
        guard newer.at.timeIntervalSince(older.at) <= withinSeconds,
              now.timeIntervalSince(newer.at) <= withinSeconds else { return nil }
        return max(0, newer.usedPct - older.usedPct)
    }

    /// Average utilization delta per minute across the buffered samples (§11.2/§11.3). `nil`
    /// when < 2 samples or the samples span no time. Negative deltas (a window reset) clamp to 0
    /// so a reset does not read as "burning backwards".
    ///
    /// **A zero delta is `nil`, not zero, until it spans `zeroBurnResolvableSpan`** (§11.2a,
    /// REV-35). Utilization arrives quantized to whole percent, so a flat reading only bounds burn
    /// below `utilizationQuantumPct / span` — at the 2026-07-14 incident's 4-minute span that
    /// bound is 0.25 %/min, and the account was in fact burning ~0.5 %/min while the app reported
    /// 0.0 and rendered "No active burn". Zero is a *claim* here (it drives the burn≈0 verdict and
    /// the "none" pill); it must be earned, and only a span over which one quantum would already
    /// have landed earns it. Unresolvable is `nil` — the honest "we cannot say yet".
    /// First→last sample span in minutes — the denominator of `burnRatePerMin`, exposed so the
    /// verdict anatomy can label its burn row ("Burn (last 9m)") with the same span the rate was
    /// measured over. `nil` under the same guards as the rate (< 2 samples, zero-length span).
    private func burnSpanMinutes(_ samples: [Sample]) -> Double? {
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else {
            return nil
        }
        let seconds = last.at.timeIntervalSince(first.at)
        guard seconds > 0 else { return nil }
        return seconds / 60
    }

    /// `zeroProofSpan` is the window's own (REV-74/D-84) — 600s on five hours, 3000s on a day or
    /// wider, where one quantum is a far bigger claim and takes far longer to become evidence.
    private func burnRatePerMin(_ samples: [Sample], zeroProofSpan: TimeInterval) -> Double? {
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else {
            return nil
        }
        let seconds = last.at.timeIntervalSince(first.at)
        guard seconds > 0 else { return nil }
        let delta = max(0, last.usedPct - first.usedPct)
        guard delta > 0 || seconds >= zeroProofSpan else { return nil }
        return delta / (seconds / 60)
    }
}
