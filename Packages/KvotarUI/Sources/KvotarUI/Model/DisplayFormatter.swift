import Foundation
import KvotarCore

/// Maps live engine output (`AppState` + `QuotaSnapshot` + `Forecast`) onto the pure display
/// models the views render (Baseline §14/§14.1 menu bar, §15 popover; UI Spec §1.2/§1.3). Pure
/// static functions — no I/O, no state — so `AppViewModel` stays a thin `@MainActor` bridge and
/// the whole mapping is unit-testable against the `StubData` shapes.
///
/// Step 15 scope: the account-quota path is wired. Local-JSONL-derived sections (burn-rate token
/// split, per-surface bars, est-value rows, local session rows) arrive with the AttributionEngine,
/// so `localSession` is left `nil` and the burn-rate card shows the exact endpoint-derived
/// `% / min` only. Off-machine-burn / multi-surface states cannot occur yet (their inputs are
/// deferred), but their formatting is handled for completeness.
public enum DisplayFormatter {

    // MARK: State → dot / phase

    /// The status-dot colour for a semantic state (UI Spec §1.2). Null-window is `neutral`
    /// (informational, not grey); idle/fallback is `grey` (Baseline §13).
    public static func dot(for state: AppState) -> StatusDot {
        switch state {
        case .healthy:                                             return .green
        case .elevated, .limitAheadOfPace, .fastBurnSpike, .offMachineBurn,
             .multiSurface:                                        return .amber
        case .atRisk, .badTiming, .overQuota, .spendControl,
             .limitNearlySpent:                                    return .red
        case .nullWindow:                                          return .neutral
        case .idleFallback:                                        return .grey
        }
    }

    /// The popover phase for a state. Only Idle/fallback renders the idle card; every other
    /// classified state (including Null-window) renders content. Loading precedes any state and
    /// is owned by `AppViewModel`, not produced here.
    public static func phase(for state: AppState) -> PopoverPhase {
        state == .idleFallback ? .idle : .content
    }

    // MARK: Menu bar (Baseline §14, §14.1 v5.4; UI Spec §1.0–§1.5)

    /// Pre-first-poll loading slot for a tool: `CL …` / `CX …`, grey dot (Baseline §13.3).
    /// Gauge bar renders as an empty track.
    public static func loadingMenuBar(_ tool: Tool) -> ToolMenuBarDisplay {
        ToolMenuBarDisplay(prefix: tool.menuBarPrefix, dot: .grey, percentText: "…", timeSlot: nil)
    }

    /// The one-tool menu-bar slot for a classified state. *(D-113 — STEP_172: the `localActive`
    /// parameter is gone. The §1.3 runway slot no longer asks whether tokens are flowing locally;
    /// it reads the popover's own exhaustion decision — see `menuBarTimeSlot`.)*
    public static func toolMenuBar(tool: Tool, state: AppState, snapshot: QuotaSnapshot?,
                                   forecast: Forecast?,
                                   glyph: MoneyGlyph = .none,
                                   now: Date = Date()) -> ToolMenuBarDisplay {
        let dot = dot(for: state)
        let moneySymbol = Fmt.moneyGlyphSymbol(snapshot?.extraUsage?.currency)
        switch phase(for: state) {
        case .loading:
            return loadingMenuBar(tool)
        case .idle, .firstRun:
            // `.firstRun` never reaches here — an undetected tool's menu slot is set nil directly
            // (AppViewModel.applyUndetected); grouped with idle only to keep the switch exhaustive.
            return ToolMenuBarDisplay(prefix: tool.menuBarPrefix, dot: dot,
                                      percentText: "––", timeSlot: "est")
        case .content:
            // REV-38 / D-34 monthly menu-bar grammar: a monthly limit with no populated 5-hour
            // window carries the monthly used % with day-granularity slots (E8) — `——` would
            // claim "no reading" while we hold one. The forecast supplies dot/tier (E6) only at
            // the rank the monthly story owns (Null-window); a higher-rank state that can fire
            // with null windows (multi-surface — local-signal-driven; spend control — already
            // red) keeps its own colour: the state machine is never demoted by a calm forecast.
            // **A monthly-hero layout keeps its day-unit slots** (REV-96 §2.5 — STEP_195): the
            // ⚠ slot exists to name a limit the header is *not* about, and here the header is
            // about the monthly. The `state != .limitAheadOfPace` guard STEP_194 left here is
            // gone with it — rank 10 requires a populated primary window, and a populated
            // primary is exactly what makes `monthlyLayoutLimit` nil, so the combination it was
            // guarding cannot occur. Window precedence: `monthlyLayoutLimit` returns nil the
            // moment a primary window populates, resuming the standard grammar (the builder keys
            // off `primary != nil`, never `individualLimit != nil`).
            // Both tools since STEP_47 (REV-40/D-36): purely data-driven — Codex
            // `individualLimit` and the Claude Enterprise spend meter ride one grammar
            // (`CL 58% ↻16d`); the E8 clause was authored per-layout, not per-tool.
            if let monthly = monthlyLayoutLimit(snapshot),
               let usedPct = monthly.usedPercentExact {
                let fDot = monthlyForecastDot(snapshot: snapshot, monthly: monthly, now: now)
                let forecastOwnsColour = state == .nullWindow
                return ToolMenuBarDisplay(prefix: tool.menuBarPrefix,
                                          dot: forecastOwnsColour ? fDot : dot,
                                          percentText: Fmt.percentLeft(usedPct),
                                          timeSlot: monthlyMenuBarSlot(snapshot: snapshot,
                                                                       monthly: monthly,
                                                                       stale: false, now: now),
                                          glyph: glyph, moneySymbol: moneySymbol)
            }
            // The same test `headerVerdict` forks on: the null state, or a snapshot rendered
            // without a percent — the D-26 withdrawal of a not-started window arrives here as
            // the latter (REV-80 / D-101), so the bar reads `——` while the card reads `—`.
            let util = snapshot?.primaryUsedPct
            if state == .nullWindow || (snapshot != nil && util == nil) {
                return ToolMenuBarDisplay(prefix: tool.menuBarPrefix, dot: dot,
                                          percentText: "——", timeSlot: "est")
            }
            let percentText = util.map(Fmt.percentLeft) ?? "––"
            // Low-allowance shape (D-60 — STEP_88): the dot comes from the used percentage, the
            // same display-only repaint the monthly branch above performs. `stale: false` — this
            // whole branch is the live path; `staleMenuBar` owns the cached render and its greys.
            let repaintDot = lowAllowanceRepaintPct(snapshot: snapshot, state: state, stale: false)
                .map(lowAllowanceDot)
            // The limit that stopped you takes the bar (REV-97 §2.5 — STEP_198), and since
            // STEP_210 the limit about to stop you too (rank 5b, REV-100 §2.1). Held, never
            // cycled: neither is a reminder, and the shape below *is* the steady string.
            // The reading is the same on both sides of this branch (REV-98 §2.3 — STEP_202): a
            // block suppresses the reminder line and keeps the limit, so the episode holds
            // through the block instead of restarting when it lifts.
            let reading = longLimitReading(tool: tool, state: state, snapshot: snapshot, now: now)
            if let block = longLimitBlockShape(tool: tool, state: state, snapshot: snapshot,
                                               now: now) {
                return ToolMenuBarDisplay(prefix: tool.menuBarPrefix, dot: repaintDot ?? dot,
                                          percentText: block.percentText,
                                          timeSlot: block.timeSlot, glyph: glyph,
                                          moneySymbol: moneySymbol, longLimits: reading)
            }
            // Otherwise the ordinary string, plus whatever reminders this account owes (§2.1).
            // The ◔/↻ slot is the steady phase's, back where STEP_195 took it from.
            let slot = menuBarTimeSlot(state: state, snapshot: snapshot, forecast: forecast,
                                       now: now)
            return ToolMenuBarDisplay(
                prefix: tool.menuBarPrefix, dot: repaintDot ?? dot,
                percentText: percentText, timeSlot: slot, glyph: glyph,
                moneySymbol: moneySymbol, longLimits: reading)
        }
    }

    /// Menu-bar slot while rendering *cached* data (STEP_32 stale-keep, §9.3): last-known
    /// percent, grey dot (stale/calm), no time slot — a cached countdown would lie — and the
    /// empty gauge track (REV-9). An expired primary window degrades to the null `——` form.
    /// Exception (REV-33, §1.2 v5.0 note): a stale/restored **hard block** keeps its red dot,
    /// percent, and critical tier — quota cannot be un-spent, so only the time slot degrades;
    /// every other stale state greys out exactly as before.
    public static func staleMenuBar(tool: Tool, state: AppState = .idleFallback,
                                    snapshot: QuotaSnapshot?,
                                    now: Date = Date()) -> ToolMenuBarDisplay {
        let degraded = degradeExpiredWindows(snapshot, now: now)
        let percent = degraded?.primaryUsedPct.map(Fmt.percentLeft)
        // E10 (locked 2026-07-16, P1-15): the stale-monthly row keeps its percent (a D-35 lower
        // bound — monthly quota is monotone for the whole period) *and* its `↻Nd` reset slot
        // (the monthly `reset_at` is a calendar fact that does not rot with the snapshot),
        // under the standard stale-keep grey dot; ◔ never renders stale. A stale reached keeps
        // red (R33-1 extension). A month that rolled over unseen had `monthlyLimit` degraded to
        // nil above and falls through to the `——` unknown form.
        // Both tools since STEP_47 (REV-40) — E10 was authored per-layout, not per-tool.
        if percent == nil, let monthly = degraded?.monthlyLimit,
           let usedPct = monthly.usedPercentExact {
            let daysToReset = monthly.resetsAt.timeIntervalSince(now) / 86_400
            let slot = daysToReset > 0 ? "↻\(Fmt.dayScale(daysToReset))" : nil
            if state.isHardBlock {
                return ToolMenuBarDisplay(prefix: tool.menuBarPrefix, dot: dot(for: state),
                                          percentText: Fmt.percentLeft(usedPct), timeSlot: slot)
            }
            return ToolMenuBarDisplay(prefix: tool.menuBarPrefix, dot: .grey,
                                      percentText: Fmt.percentLeft(usedPct), timeSlot: slot)
        }
        if state.isHardBlock, let percent {
            // A long-limit block keeps saying *which* limit while the reading behind it ages
            // (REV-97 §2.5 — STEP_198): `CL ⚠wk 0%`, with the slot withheld like every other
            // stale-keep, because a cached countdown would lie. Which limit blocked is not a
            // countdown — it is a fact about a limit that cannot un-spend itself (R33-1), so it
            // survives the staleness that takes the time slot.
            if let block = longLimitBlockShape(tool: tool, state: state, snapshot: degraded,
                                               now: now) {
                return ToolMenuBarDisplay(prefix: tool.menuBarPrefix, dot: dot(for: state),
                                          percentText: block.percentText, timeSlot: nil)
            }
            return ToolMenuBarDisplay(prefix: tool.menuBarPrefix, dot: dot(for: state),
                                      percentText: percent, timeSlot: nil)
        }
        return ToolMenuBarDisplay(prefix: tool.menuBarPrefix, dot: .grey,
                                  percentText: percent ?? "——",
                                  timeSlot: percent == nil ? "est" : nil)
    }

    /// The §1.0 display-mode matrix — everything the status item renders, as one value.
    /// `claude`/`codex` nil = undetected (no credentials AND no JSONL) → that tool renders
    /// nothing anywhere.
    ///
    /// D-98 (REV-78) cut this from six modes to three. The `dominant:` parameter went with
    /// Adaptive and Compact glyph — the only two arms that ever read it — and so did the gauge.
    public static func menuBarRender(mode: MenuBarDisplayMode,
                                     claude: ToolMenuBarDisplay?,
                                     codex: ToolMenuBarDisplay?) -> MenuBarRender {
        let detected = [claude, codex].compactMap { $0 }

        // One line per tool, carrying **both phases** (REV-97 §2.1 — STEP_198). The phase index
        // stays nil here: the formatter says what the bar *can* show, the schedule says what it
        // is showing, and STEP_199 is where the second half arrives.
        func line(_ d: ToolMenuBarDisplay) -> MenuBarRender.TextLine {
            MenuBarRender.TextLine(steady: d.fullString, reminders: d.reminders,
                                   dot: d.dot, glyph: d.glyph, moneySymbol: d.moneySymbol,
                                   transition: d.transition)
        }

        func singleToolLine(_ display: ToolMenuBarDisplay?) -> [MenuBarRender.TextLine] {
            display.map { [line($0)] } ?? []
        }

        // D-78 (REV-71 §3.3) — no tool detected: one neutral Kvotar mark, in every mode. This is
        // deliberately gated on the **detected set**, not on "this mode produced no lines": the
        // modes below each used to invent their own empty render, and the single-tool modes still
        // legitimately render nothing when the *other* tool is the detected one (a mark there
        // would claim nothing is detected while something is). One path, one meaning.
        guard !detected.isEmpty else { return MenuBarRender(content: .nothingDetected) }

        switch mode {
        case .bothStacked:
            return MenuBarRender(lines: detected.map(line))
        case .claudeOnly:
            return MenuBarRender(lines: singleToolLine(claude))
        case .codexOnly:
            return MenuBarRender(lines: singleToolLine(codex))
        }
    }

    /// Menu-bar time slot per the §1.3 runway rule (D-113 — STEP_172): the popover's own
    /// exhaustion decision (`exhaustionRunwayMinutes` — exhaustion before a known reset, plus the
    /// §11.3 pace clock), and the bar's own urgency threshold of 60 minutes on top. Otherwise the
    /// `↻` reset countdown when the reset is known; `nil` when neither is known (percent-only
    /// slot). A runway with no known reset time cannot confirm "exhaustion before reset", so it
    /// never shows.
    ///
    /// **The fourth condition — "tokens flowing in JSONL" (STEP_27) — is retired here**, and its
    /// `localActive` parameter with it. It was the bar's alone: `headerVerdict` never had it, so
    /// on 2026-09-08 the popover read `Won't make it — you'll be blocked in ~11m` while the bar
    /// read `CL 5% ↻1h04m`, the urgent estimate reachable only by opening the popover. Local
    /// silence neither proves the account stopped spending nor invalidates an accepted forecast —
    /// the estimate is withdrawn by the forecast changing or by the freshness rules, exactly as
    /// it is in the card. The anti-jitter intent survives in the pace clock, which STEP_27
    /// predates.
    /// `wk` / `mo` — the two-letter name of a long limit, as the bar says it.
    static func longLimitMenuBarScope(_ limit: BlockEpisode.Limit) -> String {
        limit == .monthly ? "mo" : "wk"
    }

    /// What the bar knows about a tool's long limits, and which of them it reminds about —
    /// `CL ⚠wk 8%`, most severe first (REV-97 §2.1/§2.3/§3.1 — STEP_198; the reading itself,
    /// REV-98 §2.3 — STEP_202).
    ///
    /// **`.unknown` is not "no warning".** Loading, idle, a null window and a monthly-hero layout
    /// carry no long-limit assessment the bar reads, and a stale render must not assert a tier off
    /// a frozen snapshot (D-35). All of them return `.unknown`, which holds the episode rather than
    /// ending it — the distinction the schedule could not make before this step, and the reason a
    /// relaunch, a failed poll and a genuine recovery all replayed the reminder from the top.
    ///
    /// **`.live` names exactly the elevated limits**, whether or not the bar reminds about them.
    /// A confirmed block and a five-hour warning both suppress the reminder *string* and keep the
    /// limit in the reading, so the episode holds through them and does not restart when they
    /// clear.
    ///
    /// **This replaces STEP_195's permanent `⚠wk8%` slot.** That slot held the bar's one time
    /// slot for as long as the weekly stayed under the line — days, on a Max plan — so the
    /// five-hour reset a reader looks at forty times a day was gone, and the weekly's own reset,
    /// the thing that ends the problem, was shown nowhere. The reminder says strictly more in
    /// five seconds a minute and gives the other fifty-five back.
    ///
    /// **Who reminds** is the state ranking, not a new predicate: rank 10 (amber), plus the
    /// §8.0.4 reached-monthly-with-unverified-effect case. Every five-hour warning outranks it, so
    /// "the five-hour speaks first" (§2.4) needs no test of its own here — a tight primary has
    /// already classified as At risk or Bad timing and never reaches this function. A confirmed
    /// block and rank 5b (red) remind nothing: their shape *is* the steady string
    /// (`longLimitBlockShape`, REV-100 §2.1 — STEP_210), held rather than cycled. A weekly amber
    /// beside a red monthly therefore has no line either — the red limit holds the bar.
    ///
    /// **Amber reminds too** (owner ruling, 2026-09-14). It is display-only and never notifies,
    /// but the dot alone could not say which limit, how much was left, or when it resets.
    static func longLimitReading(tool: Tool, state: AppState, snapshot: QuotaSnapshot?,
                                 now: Date) -> LongLimitReading {
        guard let snapshot else { return .unknown }
        let prefix = tool.menuBarPrefix
        // Who reminds is the state ranking, not a new predicate (§2.4). A block says its piece
        // through the steady string, and a five-hour warning outranks both long-limit ranks — in
        // both cases the limit stays in the reading and loses only its line.
        let reminds = (state == .limitNearlySpent || state == .limitAheadOfPace)
            && longLimitBlockShape(tool: tool, state: state, snapshot: snapshot, now: now) == nil
        // Worst tier first, then the nearer reset — Core's one comparator (`longLimitsRanked`),
        // filtered to the limits that have something to warn about. A second limit sitting calmly
        // on pace does not get a turn in the cycle, and has no episode either.
        let statuses = snapshot.longLimitsRanked(now: now)
            .filter(\.isElevated)
            .map { assessment in
                LongLimitStatus(
                    limit: assessment.limit, tier: assessment.tier, resetsAt: assessment.resetsAt,
                    reminderText: reminds
                        ? reminderString(prefix: prefix,
                                         scope: longLimitMenuBarScope(assessment.limit),
                                         leftPct: assessment.remainingPct)
                        : nil)
            }
        return .live(statuses)
    }

    /// The reminder's whole string: `CL ⚠wk 43%` — provider, limit, and what is left of it
    /// (REV-98 §2.4 / §3.6 — STEP_203).
    ///
    /// **It carries no reset any more.** Variant D draws this as one larger vertically-centred
    /// line in place of the stacked rows, and the reset moves to the popover — a headline with
    /// three things in it reads at a glance where one with four does not. The **steady** phase
    /// and the §2.5 **held block** are untouched and keep their slot, minutes and all.
    private static func reminderString(prefix: String, scope: String, leftPct: Double) -> String {
        "\(prefix) ⚠\(scope) \(Fmt.percent(leftPct))"
    }

    /// The **held** menu-bar shape while a long limit is what stopped you (REV-97 §2.5 —
    /// STEP_198): `⚠wk 0%` + the blocking limit's own countdown, returned as the percent and slot
    /// halves of the ordinary string so `fullString` assembles it unchanged.
    ///
    /// This settles what STEP_195 deferred. Until now a weekly block read `CL 81% ↻3h` beside a
    /// red dot — the *five-hour* number and the *five-hour* reset — while the popover hero read
    /// `0% Weekly quota left`. The five-hour percent is either irrelevant (nothing can use it) or
    /// actively misleading, and the reset it showed was not the one that ends the block.
    ///
    /// `nil` when the primary is what blocked (today's `CL 0% ↻48m` is already right) and when no
    /// episode is keyed at all. The countdown is **D-59's**, not §2.7's compact form: a block
    /// string sits on screen for days, so it keeps the precision every other permanent countdown
    /// in the bar has.
    ///
    /// **Rank 5b takes the same shape, with the percent that is left** (REV-100 §2.1 / D-124 —
    /// STEP_210): `CX ⚠wk 8% ↻2d`. The tester's weekly crossed 90 % on 2026-09-16 and the bar held
    /// `CX 96% ↻41m` — the five-hour, idle and irrelevant — while the weekly surfaced only in a
    /// five-second reminder he never saw. In red the weekly is what will stop him this week, so it
    /// stands in the bar, held, like a block. The lead assessment is the one the rank was
    /// classified from (`longLimitsRanked`), and its reset is the limit's own. Because
    /// `longLimitReading` already suppresses reminders wherever this shape exists, red leaves the
    /// cycle with no predicate of its own; the cycle is amber's alone.
    static func longLimitBlockShape(tool: Tool, state: AppState, snapshot: QuotaSnapshot?,
                                    now: Date) -> (percentText: String, timeSlot: String?)? {
        if state == .limitNearlySpent {
            guard let lead = snapshot?.longLimitsRanked(now: now).first,
                  lead.tier == .nearlySpent else { return nil }
            let slot = Fmt.countdown(to: lead.resetsAt, from: now).map { "↻\($0)" }
            return ("⚠\(longLimitMenuBarScope(lead.limit)) \(Fmt.percent(lead.remainingPct))", slot)
        }
        guard state == .overQuota || state == .spendControl,
              let episode = snapshot?.blockEpisode, episode.limit != .primary else { return nil }
        let scope = longLimitMenuBarScope(episode.limit)
        // Not the assessment's `remainingPct`: a blocking limit is at its ceiling by definition,
        // and reading a percent back off a snapshot that may have been degraded or restored would
        // be a chance to print something other than zero for a limit that is spent.
        let slot = Fmt.countdown(to: episode.limitResetsAt, from: now).map { "↻\($0)" }
        return ("⚠\(scope) 0%", slot)
    }

    static func menuBarTimeSlot(state: AppState, snapshot: QuotaSnapshot?, forecast: Forecast?,
                                now: Date) -> String? {
        if let runway = exhaustionRunwayMinutes(state: state, snapshot: snapshot,
                                                forecast: forecast, now: now), runway < 60 {
            return "◔~\(Int(runway.rounded()))m"
        }
        if let reset = snapshot?.primaryResetsAt, let cd = Fmt.countdown(to: reset, from: now) {
            return "↻\(cd)"
        }
        return nil
    }

    // MARK: Popover — Claude (UI Spec Part 1 §2)

    // `monthlyAttribution`/`monthlyRatePerHour`/`localDay` (REV-47/D-42 — STEP_65 Core, STEP_66
    // display) are the Claude monthly layout's three forks: the §2.3 attribution split, the §2.4
    // live `$/hr` pill, and the §2.5a day grain (whose presence also drops §2.5b). All three are
    // nil on Pro/Max, where every section renders exactly as before.
    public static func claude(state: AppState, snapshot: QuotaSnapshot?, forecast: Forecast?,
                              localAttribution: LocalAttribution? = nil,
                              offMachine: WindowAttribution? = nil,
                              fastBurnDelta: Double? = nil,
                              staleAsOf: Date? = nil, pollAsOf: Date? = nil,
                              freezeReason: AdapterHealth? = nil,
                              lastActiveWindow: DateInterval? = nil,
                              monthlyAttribution: MonthlyAttribution? = nil,
                              monthlyRatePerHour: Double? = nil,
                              localDay: LocalDayGrain? = nil,
                              dailyReport: DailyLocalReportState? = nil,
                              now: Date = Date()) -> ClaudeDisplayState {
        // Stale render (STEP_32, §9.3): cached/restored data keeps showing with a grey dot and an
        // "as of h:mm" source tag instead of wiping to the idle card; windows whose reset has
        // passed degrade to the null-window presentation (REV-16 — never an expired countdown).
        // A stale hard block keeps the state's own red dot (REV-33): the verdict is current,
        // only the numbers behind it are stamped with their real age.
        let stale = staleAsOf != nil
        var dot: StatusDot = stale && !state.isHardBlock ? .grey : dot(for: state)
        // Always-show (STEP_32, dogfood phase): content whenever any snapshot exists. The idle
        // card remains only for the no-data-at-all paths (undetected / setup-required / never
        // succeeded with nothing restorable).
        let phase: PopoverPhase = snapshot == nil && phase(for: state) == .idle ? .idle : .content
        guard phase == .content else {
            return ClaudeDisplayState(dot: dot, phase: phase)
        }
        // REV-37 (§9.3 / §2.2a, STEP_41): on the stale path a window degraded by expiry (R33-7) is
        // *unknown*, never "No active session" — **regardless of local activity**. D-26's local
        // signal is blind to off-machine burn (Claude Web leaves no local trace), which is exactly
        // when the stale-expired window read as empty on 2026-07-15. Computed from the pre-degrade
        // snapshot (`degradeExpiredWindows` below nils the `resets_at` the expiry test reads).
        // REV-40 (D-35 port): extended to a monthly spend cycle whose (derived, §8.0.4) reset
        // passed unseen — the month-rollover analogue at month scale, mirroring `codex()`.
        let expiredOnStale = stale && (
            (snapshot?.primaryResetsAt.map {
                now.timeIntervalSince($0) > QuotaSnapshot.resetJitterTolerance
            } ?? false)
            || (snapshot?.monthlyLimit.map {
                now.timeIntervalSince($0.resetsAt) > QuotaSnapshot.resetJitterTolerance
            } ?? false))
        let snapshot = stale ? degradeExpiredWindows(snapshot, now: now) : snapshot
        // REV-40 / D-36 — the monthly (period-quota) layout, Claude Enterprise spend. Since the
        // STEP_178 cutover the meter is an ordinary limit: it is the hero only when the §15.2
        // selection promotes it (never over a populated window, D-34), and otherwise it is a row
        // in Other Limits. The dot below is the one thing the layout still owns outright.
        if !stale, state == .nullWindow, let monthly = monthlyLayoutLimit(snapshot) {
            // Fresh monthly layout: the tab dot follows the monthly forecast (E6 gate) — the
            // same derivation as the menu bar and verdict (§19) — not the calm null-window
            // neutral. Only the rank the monthly story *owns* is repainted: a higher-rank state
            // that can fire with null windows (multi-surface, weekly-elevated) keeps its own
            // dot — the state machine's authority is never demoted by a calm forecast. Stale
            // keeps the grey/red-block logic above (E10/R33-1).
            dot = monthlyForecastDot(snapshot: snapshot, monthly: monthly, now: now)
        }
        // D-26 (§9.3 / §2.2a, STEP_38): a not-started 5-hour window is known-obsolete once local
        // JSONL activity postdates the snapshot's poll time — the "not started" claim is falsified
        // and withdrawn (unknown verdict), with nothing asserted in its place. `staleAsOf`/
        // `pollAsOf` are exactly the snapshot's poll time on their respective render paths;
        // `lastActivityAt` is store-seeded (REV-30), so the comparison survives restart.
        // Claude-specific per Baseline §9.3. STEP_41 broadens the withdrawal to the
        // expired-on-stale case above, which the local signal cannot reach. Re-keyed from "nil
        // percent" to `primaryWindowIsUnanchored` by REV-80 / D-101 (the shape now carries `0%`);
        // the withdrawn snapshot is what every builder below renders, so hero, verdict, rows and
        // menu bar reach the unknown form through the one `util == nil` path they always had.
        let polledAt = staleAsOf ?? pollAsOf
        let localObsolete = notStartedWithdrawn(snapshot: snapshot, polledAt: polledAt,
                                                lastActivityAt: localAttribution?.lastActivityAt,
                                                freezeReason: freezeReason)
        let nullWindowObsolete = expiredOnStale || localObsolete
        // Idle "last window" retrospective (REV-46 — STEP_64, Claude Pro/Max): on a *fresh*
        // not-started 5-hour window with a prior window on record, the window-scoped sections
        // (§2.5a/§2.5b and the off-machine row) recap the LAST quota window — past-tense, full
        // span, re-anchored. A recap is a different speech act from the live claim (D-26/D-33), so
        // it fires only fresh (never on the stale/expired `——` path) and never on the monthly
        // layout (a null 5-hour window is Enterprise's normal healthy-idle state, §8.3). Re-keyed
        // on the flag by REV-80 / D-101; read from the pre-withdrawal snapshot.
        let idleLastWindow: DateInterval? = (staleAsOf == nil
            && snapshot?.primaryWindowIsUnanchored == true && monthlyLayoutLimit(snapshot) == nil)
            ? lastActiveWindow : nil
        let rendered = localObsolete ? snapshot?.withdrawingPrimaryWindow() : snapshot
        let rec = recommendation(tool: .claude, state: state, snapshot: rendered,
                                 forecast: forecast, attribution: localAttribution,
                                 fastBurnDelta: fastBurnDelta, now: now)
        // STEP_176: one selection per render — the header, its two facts and Other Limits all
        // read it, so the four cannot name different limits.
        let selection = selectLimit(tool: .claude, state: state, snapshot: rendered,
                                    forecast: forecast, staleAsOf: staleAsOf, now: now)
        let facts = headerFacts(tool: .claude, selection: selection, snapshot: rendered,
                                forecast: forecast, offMachine: offMachine,
                                monthlyRatePerHour: monthlyRatePerHour,
                                monthlyAttribution: monthlyAttribution, staleAsOf: staleAsOf,
                                retrospective: idleLastWindow != nil, now: now)
        let quotaTag = sourceTag(base: "Source: Claude account", asOf: pollAsOf,
                                 staleAsOf: staleAsOf, now: now)
        return ClaudeDisplayState(
            dot: dot, phase: .content,
            header: header(tool: .claude, state: state, snapshot: rendered, forecast: forecast,
                           staleAsOf: staleAsOf, nullWindowObsolete: nullWindowObsolete,
                           freezeReason: freezeReason, accountBurn: facts.burn,
                           notSeenLocally: facts.notSeen, selection: selection,
                           sourceTag: quotaTag, now: now),
            creditsCard: creditsCard(snapshot: rendered, forecast: forecast,
                                     pollAsOf: pollAsOf, staleAsOf: staleAsOf, now: now),
            recommendation: rec?.text,
            recommendationSeverity: rec?.severity ?? .warning,
            recommendationURL: monthlyNearCap(rendered) != nil ? manageCreditsURL : nil,
            sourceFreeze: sourceFreeze(freezeReason, tool: .claude),
            otherLimits: otherLimitsSection(selection, tool: .claude, state: state,
                                            snapshot: rendered, sourceTag: quotaTag,
                                            staleAsOf: staleAsOf, now: now),
            // STEP_177: the daily local section, read from the retained report — never from
            // the window-anchored attribution above, whose population is a different span.
            localActivity: localActivitySection(tool: .claude, report: dailyReport,
                                                attribution: localAttribution,
                                                snapshot: rendered, now: now))
    }

    // MARK: Popover — Codex (UI Spec Part 2 §2)

    // `monthlyAttribution`/`monthlyRatePerHour`/`localDay` (REV-48/D-43 — STEP_67 Core, STEP_68
    // display) are the Codex monthly layout's three forks, the structural twins of the Claude
    // params above: the §2.1 "Elsewhere" attribution split, the §2.3 live `credits/hr` pill, and
    // the §2.4 day grain. All three are nil on windowed (consumer) Codex, which is why every
    // fork below is expressed as a nil-test on them rather than a tool or layout test.
    public static func codex(state: AppState, snapshot: QuotaSnapshot?, forecast: Forecast?,
                             localAttribution: LocalAttribution? = nil,
                             offMachine: WindowAttribution? = nil,
                             fastBurnDelta: Double? = nil,
                             staleAsOf: Date? = nil, pollAsOf: Date? = nil,
                             freezeReason: AdapterHealth? = nil,
                             lastActiveWindow: DateInterval? = nil,
                             monthlyAttribution: MonthlyAttribution? = nil,
                             monthlyRatePerHour: Double? = nil,
                             localDay: LocalDayGrain? = nil,
                             dailyReport: DailyLocalReportState? = nil,
                             now: Date = Date()) -> CodexDisplayState {
        // Stale render + always-show: same rules as the Claude tab (STEP_32; REV-33 for the
        // hard-block red dot).
        let stale = staleAsOf != nil
        // Idle "last window" retrospective, Codex (REV-82 — STEP_151, taking up REV-49 §2.4's
        // deferral): the Claude gate verbatim — fresh, unanchored, non-monthly — plus the 5-hour
        // width, because `lastActiveWindow`'s span is five hours by construction (`quota_series`
        // persists no width) and a 30-day Free/Go window must keep degrading to "today". The
        // coordinator applies the same width test before yielding the anchor, so the two agree.
        let idleLastWindow: DateInterval? = (!stale
            && snapshot?.primaryWindowIsUnanchored == true && monthlyLayoutLimit(snapshot) == nil
            && snapshot?.primaryWindowSeconds == 18_000)
            ? lastActiveWindow : nil
        var dot: StatusDot = stale && !state.isHardBlock ? .grey : dot(for: state)
        let phase: PopoverPhase = snapshot == nil && phase(for: state) == .idle ? .idle : .content
        guard phase == .content else {
            return CodexDisplayState(dot: dot, phase: phase)
        }
        // REV-37 (STEP_41): a stale window degraded by expiry is *unknown*, never "No active
        // window". Codex has no D-26 local-activity path (Claude-specific per §9.3), so the
        // expired-on-stale test is the whole withdrawal condition here. REV-38 (D-35) extends
        // it to a monthly limit whose month rolled over unseen — the R33-7 analogue at month
        // scale; both tests read the pre-degrade snapshot.
        let expiredOnStale = stale && (
            (snapshot?.primaryResetsAt.map {
                now.timeIntervalSince($0) > QuotaSnapshot.resetJitterTolerance
            } ?? false)
            || (snapshot?.monthlyLimit.map {
                now.timeIntervalSince($0.resetsAt) > QuotaSnapshot.resetJitterTolerance
            } ?? false))
        let snapshot = stale ? degradeExpiredWindows(snapshot, now: now) : snapshot
        let isNull = state == .nullWindow || snapshot?.isNullWindow == true
        // REV-38 / D-34 — the monthly (period-quota) layout. The *section* renders whenever a
        // monthly limit exists; hero / verdict / dot / menu bar follow it only while no 5-hour
        // window is populated (window precedence).
        let monthlyLayout = snapshot?.monthlyLimit != nil
        if !stale, state == .nullWindow, let monthly = monthlyLayoutLimit(snapshot) {
            // Fresh monthly layout: the tab dot follows the monthly forecast (E6 gate) — the
            // same derivation as the menu bar and verdict (§19) — not the calm null-window
            // neutral. Only the rank the monthly story *owns* is repainted: a higher-rank state
            // that can fire with null windows (multi-surface — local-signal-driven; spend
            // control — already red) keeps its own dot, the state machine's authority is never
            // demoted by a calm forecast. Stale keeps the grey/red-block logic above (E10/R33-1).
            dot = monthlyForecastDot(snapshot: snapshot, monthly: monthly, now: now)
        }
        // Low-allowance shape (D-60 — STEP_88): the tab dot follows the used percentage, because
        // the state has no red to offer here (see `lowAllowanceDot`). Same posture as the monthly
        // repaint directly above — display-only, never over a hard block, never over stale grey.
        if let pct = lowAllowanceRepaintPct(snapshot: snapshot, state: state, stale: stale) {
            dot = lowAllowanceDot(pct)
        }
        let lowAllowance = snapshot?.isLowAllowanceShape == true
        let rec = recommendation(tool: .codex, state: state, snapshot: snapshot,
                                 forecast: forecast, attribution: localAttribution,
                                 fastBurnDelta: fastBurnDelta, now: now)
        // STEP_176: one selection per render (see `claude()`).
        let selection = selectLimit(tool: .codex, state: state, snapshot: snapshot,
                                    forecast: forecast, staleAsOf: staleAsOf, now: now)
        let facts = headerFacts(tool: .codex, selection: selection, snapshot: snapshot,
                                forecast: forecast, offMachine: offMachine,
                                monthlyRatePerHour: monthlyRatePerHour,
                                monthlyAttribution: monthlyAttribution, staleAsOf: staleAsOf,
                                retrospective: idleLastWindow != nil, now: now)
        let quotaTag = sourceTag(base: codexQuotaSourceBase(snapshot?.source),
                                 asOf: pollAsOf, staleAsOf: staleAsOf, now: now)
        return CodexDisplayState(
            dot: dot, phase: .content,
            header: header(tool: .codex, state: state, snapshot: snapshot, forecast: forecast,
                           staleAsOf: staleAsOf, nullWindowObsolete: expiredOnStale,
                           freezeReason: freezeReason, accountBurn: facts.burn,
                           notSeenLocally: facts.notSeen, selection: selection,
                           sourceTag: quotaTag, now: now),
            // The tier note + upgrade link (D-61 — REV-59 §7, STEP_89). Gated here rather than in
            // the view, which Claude shares: the shape test belongs in the one place that already
            // knows the shape (the STEP_85 lesson on the retired `quotaRows`). Always visible on
            // this shape — user ruling; a percentage of a ceiling OpenAI will not state is
            // unreadable without it, and shape-gating means it vanishes by itself on upgrade.
            //
            // **It gets no second gate** *(REV-63 §5 — STEP_101)*. The note's second sentence,
            // "one working session can use most of it", is the same rate claim the mute makes, so
            // when the rule was a window-width proxy the note lied to a Plus user at 3% used for a
            // day — and correcting the rule corrected the copy with no code here at all. A second
            // gate would have been two places to keep in agreement about one fact.
            quotaNote: lowAllowance ? CodexDisplayState.unpublishedLimitNote : nil,
            quotaNoteURL: lowAllowance ? upgradeCodexPlanURL : nil,
            creditsSpend: codexCreditsSpend(snapshot: snapshot, attribution: localAttribution,
                                            slimmed: monthlyLayout),
            recommendation: rec?.text,
            recommendationSeverity: rec?.severity ?? .warning,
            recommendationURL: monthlyNearCap(snapshot) != nil ? requestLimitIncreaseURL : nil,
            nullWindowNote: isNull && !monthlyLayout
                ? "Account quota windows are null (healthy idle). Showing local token data."
                : nil,
            sourceFreeze: sourceFreeze(freezeReason, tool: .codex),
            windowGrain: windowGrain(seconds: snapshot?.primaryWindowSeconds),
            otherLimits: otherLimitsSection(selection, tool: .codex, state: state,
                                            snapshot: snapshot, sourceTag: quotaTag,
                                            staleAsOf: staleAsOf, now: now),
            localActivity: localActivitySection(tool: .codex, report: dailyReport,
                                                attribution: localAttribution,
                                                snapshot: snapshot, now: now))
    }

    /// The freeze reason the source-tag hover card may name (UI Spec Part 3 §5.2 rule 4 —
    /// STEP_111): the same two-way fork `headerVerdict` makes — a rate-limited freeze is
    /// "Reconnecting…" (D-33), an expired credential is "sign-in expired" (D-38, Claude only —
    /// the Codex adapter never reports it and the Codex cell names one reason). Anything else is
    /// no freeze the card may speak of.
    static func sourceFreeze(_ health: AdapterHealth?, tool: Tool) -> SourceFreeze? {
        switch health {
        case .rateLimited?: return .reconnecting
        case .credentialExpired?: return tool == .claude ? .signInExpired : nil
        default: return nil
        }
    }

    /// Codex account-quota source tag reflects the leg that produced the snapshot
    /// (UI Spec §2 Codex / prototype tabbed view; STEP_27). RPC wording when unknown —
    /// RPC is the primary path.
    private static func codexQuotaSourceBase(_ source: QuotaSource?) -> String {
        source == .wham ? "Source: wham/usage" : "Source: app-server RPC"
    }

    /// Per-source freshness tag (UI Spec v4.7 §2.2a, D-21). One continuous grammar driven by the
    /// source's own last-success time `asOf`: live data claims `· exact` plus an always-on age
    /// stamp (`· exact · 12s ago`), turning amber past 2 minutes (`· exact · 4m ago`). Past the
    /// §9.3 TTL the caller passes `staleAsOf` and the tag degrades to the honest `· as of 11:32 pm`
    /// (dated `· as of Jul 5, 11:32 pm` when not from today), dropping the exact/age stamp (STEP_32
    /// stale-keep). `asOf` nil (previews / no timestamp) → plain `· exact`. Never polling mechanics.
    private static func sourceTag(base: String, asOf: Date?, staleAsOf: Date?,
                                  now: Date) -> SourceTag {
        if let stale = staleAsOf {
            return SourceTag(base: "\(base) · as of \(asOfStamp(stale, now: now))")
        }
        guard let asOf else { return SourceTag(base: "\(base) · exact") }
        let age = max(0, now.timeIntervalSince(asOf))
        return SourceTag(base: "\(base) · exact", age: Fmt.relativeAge(age), ageIsAmber: age >= PollBackoffPolicy.freshnessAmberAge)
    }

    /// The stale-keep "as of" stamp value — "2:24 pm" same-day, dated "Jul 5, 2:24 pm" across
    /// days (one grammar for source tags and the D-35 stale verdict detail).
    static func asOfStamp(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? Fmt.clock(date) : "\(Fmt.monthDay(date)), \(Fmt.clock(date))"
    }

    /// Whether a not-started primary window (`primaryWindowIsUnanchored`) is rendered
    /// **withdrawn** — the §2.2a unknown form instead of `100%` — re-keyed from the nil-percent
    /// null window by REV-80 / D-101. Two triggers, both from the old null branch: the D-26 test
    /// (Baseline §9.3 — local JSONL activity postdating the poll falsifies the claim) and the
    /// D-33 / D-38 freeze forks (a `.rateLimited` or `.credentialExpired` freeze is a
    /// "Reconnecting…" / sign-in-expired verdict over a `——` hero, never a confident `100%`).
    /// One pure predicate, read by `claude()` for the popover and by `AppViewModel` for the menu
    /// bar, so the two surfaces withdraw together (Baseline §19). Claude-specific — Codex
    /// null/not-started semantics are D1 territory, and `codex()` never calls this.
    public static func notStartedWithdrawn(snapshot: QuotaSnapshot?, polledAt: Date?,
                                           lastActivityAt: Date?,
                                           freezeReason: AdapterHealth? = nil) -> Bool {
        guard snapshot?.primaryWindowIsUnanchored == true else { return false }
        switch freezeReason {
        case .rateLimited, .credentialExpired: return true
        default: break
        }
        guard let polledAt, let lastActivityAt else { return false }
        return lastActivityAt > polledAt
    }

    /// **The §2.2a row is removed on a window that has not started** (D-123, amending REV-80 /
    /// D-101 — STEP_207), exactly as D-60 removes it on the low-allowance shape and for the same
    /// reason: every branch below the null-window fork answers with a claim about **burn**, and
    /// there is nothing to burn yet. Live 2026-09-15 13:33 local — the owner's five-hour window
    /// rolled over at 13:30 and the account returned `utilization: 0, resets_at: null` for two
    /// polls; the rollover clears the forecast buffer, so the header read `Measuring…`, and held
    /// idle past the §11.2a zero-proof it would have read `Nothing burning`, a calm belonging to
    /// no window. The fact is already on screen twice without the row — the `not started` hero
    /// detail line and E-01's card on the caption — and the §2.2 long-limit strip is a sibling of
    /// the verdict block, so a weekly that needs attention still says so.
    ///
    /// Gated on the **hero** as well as the shape: a blocked weekly or a promoted monthly over an
    /// unanchored five-hour is a verdict about that *other* limit, and a rule about this one must
    /// not remove it. Those branches all return above `headerVerdict`'s call to this, so the gate
    /// states the rule rather than trusting branch order to keep meaning what it means today.
    ///
    /// One derivation, two readers (PATTERNS — "two surfaces that must agree call one function"):
    /// `headerVerdict` returns nil from it, and `header` stamps `verdictFamily = .notStarted` from
    /// it, so the §2.8 delta line can tell a *removed* row from an absent one.
    static func verdictRemovedAsNotStarted(snapshot: QuotaSnapshot?,
                                           selection: AccountLimitSelection) -> Bool {
        selection.hero?.id == .primaryWindow && snapshot?.primaryWindowIsUnanchored == true
    }

    /// A window whose reset has passed is presented as the null-window shape — the cached %
    /// belongs to a window that no longer exists, and an expired countdown must never render
    /// (REV-16). Delegates to the one Core degradation (`QuotaSnapshot.degradingExpiredWindows`,
    /// R33-7) shared with `StateEngine.classify`, so the engine and the display can never
    /// disagree about whether a window is over — on 2026-07-14 they did, and the card rendered
    /// "No active session" directly above a red block banner.
    static func degradeExpiredWindows(_ snapshot: QuotaSnapshot?, now: Date) -> QuotaSnapshot? {
        snapshot?.degradingExpiredWindows(now: now)
    }

    // MARK: Section builders

    static func header(tool: Tool, state: AppState, snapshot: QuotaSnapshot?, forecast: Forecast?,
                       staleAsOf: Date? = nil, nullWindowObsolete: Bool = false,
                       freezeReason: AdapterHealth? = nil,
                       accountBurn: HeaderFact? = nil, notSeenLocally: HeaderFact? = nil,
                       selection providedSelection: AccountLimitSelection? = nil,
                       sourceTag: SourceTag? = nil,
                       now: Date) -> HeaderSection {
        // Per-window null handling (STEP_32): a null primary no longer suppresses the weekly
        // surfaces — Claude's overnight shape is a null five_hour with a live weekly, and that
        // weekly data must render — only the hero/progress side keys off the null primary.
        let util = snapshot?.primaryUsedPct
        // REV-38 / D-34: with no populated 5-hour window the monthly layout supplies the hero —
        // monthly used %, recomputed from `used/limit` at 1% (E3). A populated window takes the
        // hero back (precedence); the stale path keeps the monthly hero as a D-35 lower bound
        // (muted via the grey dot + stale badge, exactly the stale-keep treatment).
        let monthlyHero = monthlyLayoutLimit(snapshot)?.usedPercentExact
        // **The hero is the selected limit (STEP_176 — REV-92 / Baseline §15.2).** `util ??
        // monthlyHero` was the whole rule until now; the selection keeps that as its default and
        // adds the promotions — a Weekly-elevated weekly, a model window or a monthly meter past
        // its own line over a calm primary. Every field below that used to read the primary now
        // reads the hero, so the number, bar, caption, bridge and card cannot name different limits.
        let selection = providedSelection ?? selectLimit(
            tool: tool, state: state, snapshot: snapshot,
            forecast: forecast, staleAsOf: staleAsOf, now: now)
        let hero = selection.hero
        // The number says what's left (REV-77 / D-97): hero and bar read **remaining**, floored
        // at 0, and the bar drains with it. Over quota is `0%` over an empty bar — the §0.5
        // overflow stripe is retired; the `106%` survives as the bridge line's used figure.
        let heroSource = hero?.usedPercent
        let heroText = heroSource.map(Fmt.percentLeft) ?? "——"
        let progress = Fmt.remaining(heroSource ?? 100) / 100
        let heroIsPrimary = hero?.id == .primaryWindow || hero == nil
        let heroElement: ExplanationElement = {
            switch hero?.id {
            case .secondaryWindow?: return .secondaryWindow
            case .monthly?: return .monthlyUsed
            case .modelWindow?: return .heroPercent // unreachable: models never own the header
            default: return (util == nil && monthlyHero != nil) ? .monthlyUsed : .heroPercent
            }
        }()

        // The badge is the display-mapped plan name and nothing else (§2.2/D-49, REV-54): no
        // "· exact"/"· community est." confidence token, and never an invented "· credit" suffix
        // (STEP_27). A confidence claim belongs to the *data*, not to the subscription — "Max ·
        // exact" parses as "your plan is exactly Max" — and it already has a correct home in the
        // per-section source tags ("Source: Claude account · exact · 2m ago", §2.2a/D-21), where
        // the word modifies the source. It was also on in ~100% of renders, so only its absence
        // informed. Freshness and credits keep their tells in the pill *styling* below.
        let onCredits = tool == .claude && snapshot?.extraUsage?.isEnabled == true
        let stale = staleAsOf != nil
        let planBadge = snapshot?.planType.map(planDisplayName) ?? "—"
        return HeaderSection(
            heroText: heroText,
            progress: progress,
            verdict: headerVerdict(tool: tool, state: state, snapshot: snapshot,
                                   forecast: forecast, nullWindowObsolete: nullWindowObsolete,
                                   freezeReason: freezeReason, stale: stale,
                                   staleAsOf: staleAsOf, selection: selection, now: now),
            // D-123: the removed row still has an identity for the §2.8 delta line to read.
            verdictFamily: verdictRemovedAsNotStarted(snapshot: snapshot,
                                                      selection: selection) ? .notStarted : nil,
            planBadge: planBadge,
            badgeKind: stale ? .stale : (onCredits ? .credit : .exact),
            email: snapshot?.email,

            // E-15, not E-04, whenever the monthly meter supplies the hero (REV-75/D-89 — STEP_128):
            // the number is then a money/credit figure against an organisation's limit, and the
            // percent-of-window card would explain something that is not on screen. A populated
            // window takes the hero back and E-04 with it, by the same precedence. E-02 / E-22
            // for a weekly / model hero (STEP_176).
            heroExplanation: heroElement,
            // A non-primary hero inherits no runway (Baseline §15.2): E-04's live line is the
            // primary series' and is dropped, never re-denominated.
            // A monthly hero is E-15, and since STEP_195 it carries E-15's *tier* sentence where
            // the limit has one (REV-96 §3.9) — the same `longLimitCardLive` its `OTHER LIMITS`
            // row reads, so the meter explains itself identically wherever it is drawn. Without a
            // tier it falls back to the drop it has always taken.
            heroLive: heroIsPrimary
                ? heroLive(snapshot: snapshot, forecast: forecast, util: util,
                           monthlyHero: monthlyHero, stale: stale, now: now)
                : (hero?.id == .monthly
                    ? (stale ? .dropped(.monthlyLayout)
                             : longLimitCardLive(snapshot?.longLimit(.monthly, now: now),
                                                 tool: tool, snapshot: snapshot, now: now)
                                 ?? .dropped(.monthlyLayout))
                    : .dropped(.noRunway)),
            // E-01 again — the caption and the primary quota row are the same element, so they
            // share the one derivation rather than each computing a start (Baseline §19).
            windowScopeLive: heroIsPrimary ? primaryWindowLive(snapshot: snapshot, now: now) : nil,
            // §5.2 rule 8 — from the same figure the hero was drawn from, stale or not: the card
            // opens with what is left and what is used whenever a percent is on screen.
            heroBridge: ExplanationRegistry.bridgeLine(utilization: heroSource),
            selection: selection,
            limitCaption: limitCaption(hero),
            accountBurn: accountBurn,
            notSeenLocally: notSeenLocally,
            modelWarnings: modelLimitWarnings(selection, now: now),
            // The reset the D-58 caption used to own, now a line of its own under the verdict —
            // still stated exactly once (REV-66 / D-70), and now stated under a promoted hero too,
            // which STEP_176 left captionless (STEP_178).
            heroDetails: heroDetailLines(hero, heroReason: selection.heroReason, tool: tool,
                                         snapshot: snapshot,
                                         staleAsOf: staleAsOf, now: now),
            sourceTag: sourceTag,
            // The hero and its meter are about the limit in the hero, so a long-limit rank does
            // not repaint them (REV-96 §5.7) — the same one test the verdict's colour takes.
            heroCue: dot(for: longLimitScopesPrimary(tool: tool, state: state, snapshot: snapshot,
                                                     selection: selection) ? .healthy : state),
            longLimitStrip: longLimitStrip(tool: tool, state: state, selection: selection,
                                           snapshot: snapshot, staleAsOf: staleAsOf, now: now))
    }

    /// E-04's live line — the one thing the hero `%` does not already say: what is *left*, and in
    /// what units (REV-75/D-89; the numbers line is why the element survived a proposed kill).
    ///
    /// Two variants, chosen by shape and nothing else. **A window a day or wider takes `.pace`**
    /// — including the free/go 30-day shape — because D-69 already settled that a long window
    /// answers with the calendar rather than with burst grammar, and the pace clock needs no burn
    /// buffer, so the line holds from poll 1. A short window takes `.runway` when a runway exists
    /// and drops otherwise — the old `.remaining` fallback (`40% used, 60% left`) is now the
    /// rule 8 bridge line on every percentage card (REV-77 / D-97), so a second line saying the
    /// same thing was retired with the spec row.
    ///
    /// Dropped, in order: the monthly layout (the hero is E-15 there — a money meter, not a window
    /// percent), the `——` placeholder, and staleness (a remaining-as-time claim from a frozen
    /// reading is the confident claim D-35 refuses).
    static func heroLive(snapshot: QuotaSnapshot?, forecast: Forecast?, util: Double?,
                         monthlyHero: Double?, stale: Bool, now: Date) -> ExplanationLive {
        if util == nil, monthlyHero != nil { return .dropped(.monthlyLayout) }
        guard let snapshot, let util else { return .dropped(.placeholderHero) }
        guard !stale else { return .dropped(.stale) }
        if snapshot.primaryWindowLength >= 86_400 {
            let elapsed = snapshot.paceElapsedPct(now: now).map { min(100, max(0, $0)) }
            // The same sign convention the anatomy's shape C settled in STEP_129: `util − elapsed`
            // positive means you have used *more* than the calendar would by now. Worded in the
            // anatomy Pace-row's over/under/on vocabulary, not "ahead of the calendar": "ahead"
            // reads as good news and never says *what* is ahead.
            let pace = elapsed.map { e -> String in
                let diff = (util - e).rounded()
                if diff > 0 { return "over pace" }
                if diff < 0 { return "under pace" }
                return "on pace"
            }
            return ExplanationRegistry.liveLine(
                .heroPercent, variant: .pace, tool: snapshot.tool,
                values: ["elapsed": elapsed.map(Fmt.percentNumber),
                         "period": windowPeriodNoun(seconds: snapshot.primaryWindowSeconds),
                         "pace": pace],
                missing: .noPace)
        }
        guard let runway = forecast?.runwayMinutes, runway > 0 else { return .dropped(.noRunway) }
        return ExplanationRegistry.liveLine(
            .heroPercent, variant: .runway, tool: snapshot.tool,
            values: ["runway": Fmt.durationHM(runway)],
            missing: .noRunway)
    }

    /// The thin-margin split for the resets-first verdict (UI Spec §2.2a/§5, D-31): margin
    /// (`|runway − minutes-to-reset|`) below this renders "Safe, barely" instead of "Safe at
    /// this pace" — both green, a copy variant within Healthy. Its **own display constant**,
    /// seeded from §3.2's at-risk gate but deliberately not wired to it (§3.2 gates on runway
    /// and is tuned in dogfooding; a notification tune must not silently move popover copy).
    static let thinMarginMinutes = 30.0

    /// **The exhaustion decision, made once for both surfaces** (D-113 — STEP_172; Baseline §19).
    /// Returns the runway the §2.2a "Won't make it" rows and the §1.3 `◔` slot are both about,
    /// or nil when this is not the exhaustion case. The bar and the verdict used to test
    /// separately and disagreed in the field: 2026-09-08, Claude at 5% left with an 11-minute
    /// runway and a reset 64 minutes out rendered `Won't make it — you'll be blocked in ~11m` in
    /// the popover and `CL 5% ↻1h04m` in the bar, because the bar demanded recent local tokens
    /// on top (retired here — see `menuBarTimeSlot`) and did not require a positive runway.
    ///
    /// Two parts, in `headerVerdict`'s own order. **Pre-emption** — the states whose branch owns
    /// the header *above* the exhaustion arm; there they have already returned, so the guards are
    /// redundant in that caller and load-bearing in the menu bar, which reaches this point in
    /// states `toolMenuBar` does not fork on (spend control, over quota, low allowance). Do not
    /// delete them as dead code: `testMenuBarRunwayImpliesExhaustionVerdict` sweeps every state
    /// and is what keeps this list level with the ladder above.
    /// **Then the arm's own test** — a positive runway, a future reset, exhaustion before that
    /// reset, and the §11.3 pace clock firing (REV-65/D-69). The pace clock itself stays in Core
    /// on `QuotaSnapshot`; this never forks it.
    ///
    /// The menu bar's own `< 60` urgency cap is deliberately **not** here — it is §1.3's
    /// threshold for what deserves the slot, not part of deciding that exhaustion is happening.
    static func exhaustionRunwayMinutes(state: AppState, snapshot: QuotaSnapshot?,
                                        forecast: Forecast?, now: Date) -> Double? {
        let util = snapshot?.primaryUsedPct
        if monthlyLayoutLimit(snapshot) != nil { return nil }
        if state == .spendControl { return nil }
        if state == .nullWindow || util == nil { return nil }
        if state == .idleFallback { return nil }
        if state == .overQuota || (util ?? 0) >= 100 { return nil }
        // The long-limit ranks say nothing about the five-hour window's runway, so they never
        // select the exhaustion row (REV-96 §2.4 — the strip carries the long limit instead).
        if state == .limitNearlySpent || state == .limitAheadOfPace { return nil }
        if snapshot?.isLowAllowanceShape == true { return nil }
        // STEP_176: the exhaustion arm is the primary series' and renders only under a primary
        // hero — a promoted weekly/model/monthly hero must never sit over a five-hour runway
        // (Baseline §15.2). Generalises the `.weeklyElevated` line above; under the state-first
        // rule a promotion happens only when the primary is calm, so this changes no live case
        // and exists so the two surfaces stay level by construction.
        if selectLimit(tool: snapshot?.tool ?? .claude, state: state, snapshot: snapshot,
                       forecast: forecast, now: now).hero?.id != .primaryWindow { return nil }
        guard let runway = forecast?.runwayMinutes, runway > 0,
              let minutesToReset = snapshot?.primaryResetsAt.map({ $0.timeIntervalSince(now) / 60 }),
              minutesToReset > 0, runway < minutesToReset,
              snapshot?.paceExceeded(now: now) == true else { return nil }
        return runway
    }

    /// **True while a long-limit rank owns the colour and the primary window owns the header**
    /// (REV-96 §2.4 / §5.7 — STEP_194 for the verdict, STEP_195 for the hero and its meter).
    ///
    /// Rank 5b is red and rank 10 amber *about the weekly or the monthly*. The hero number, the
    /// meter under it and line 1 are all about the **five-hour window**, which in this state is
    /// fine and says so — a red `64%` over a green `Safe at this pace` is the header
    /// contradicting itself, which is what shipped for one afternoon of STEP_195 before the
    /// fixtures were looked at. The account's colour lives in the strip, the tab dot and the
    /// menu-bar dot: the three surfaces that are about the account rather than about the next
    /// five hours.
    ///
    /// False the moment the long limit takes the hero (a block), where every surface is about
    /// that limit and they agree by being one thing.
    static func longLimitScopesPrimary(tool: Tool, state: AppState, snapshot: QuotaSnapshot?,
                                       selection: AccountLimitSelection) -> Bool {
        let rank = state == .limitNearlySpent || state == .limitAheadOfPace
        let heroIsLongLimit = selection.hero?.id == .secondaryWindow
            || selection.hero?.id == .monthly
        return rank && !heroIsLongLimit
    }

    /// The §2.2a runway verdict (advisory voice, v5.1/REV-34) — two lines under the progress
    /// bar. Line 1 (state-coloured) answers "am I safe?" directly; line 2 (muted, clock-first
    /// fixed token order, D-28) lists the numbers behind it. The template is selected by state +
    /// forecast shape (finite/∞ runway, runway<reset); the **colour is the state's own dot** —
    /// never a recomputed threshold (§13/§5 own classification, the view only maps
    /// state→treatment). `~` marks forecast-derived estimates only (runway, margin, the D-29
    /// stops clock — never the exact reset clock). Runway-∞ is the §11 near-zero-burn threshold.
    /// Null-window / idle placeholders carry a `—` detail line. `stale` drives the D-30
    /// dollarless degrade on the accruing detail (the verdict itself survives staleness, R33-1).
    /// The null branch forks on `freezeReason` (REV-37 — STEP_41; REV-41/D-38 — STEP_49): a
    /// `.credentialExpired` freeze reads "Claude sign-in expired — open Claude Code to reconnect.";
    /// a `.rateLimited` freeze reads "Reconnecting…"; an expired-on-stale or D-26-obsolete null
    /// reads the unknown `—`; a fresh provider-null keeps "No active session" / "No active window"
    /// — which since REV-80 / D-101 is Claude Enterprise's absent `five_hour` and Codex both-null
    /// only; a consumer not-started window carries `0%` and takes the calm rows below.
    /// The resets-first branch forks once more (REV-51/D-46 — STEP_71): reached with a non-green
    /// `state`, it takes the de-escalation row ("Was on track to run out — safe if this pace
    /// holds") and keeps the held colour, because `state` carries §13.4's 3-poll hysteresis while
    /// `forecast` carries none.
    static func headerVerdict(tool: Tool, state: AppState, snapshot: QuotaSnapshot?,
                              forecast: Forecast?, nullWindowObsolete: Bool = false,
                              freezeReason: AdapterHealth? = nil,
                              stale: Bool = false, staleAsOf: Date? = nil,
                              selection: AccountLimitSelection? = nil,
                              now: Date) -> HeaderVerdict? {
        // STEP_176: the verdict describes the selected limit. Computed here when the caller did
        // not (tests and the menu bar), from exactly the inputs `header` uses.
        let selection = selection ?? selectLimit(tool: tool, state: state, snapshot: snapshot,
                                                 forecast: forecast, staleAsOf: staleAsOf, now: now)
        // **A long-limit rank does not colour the five-hour verdict** (REV-96 §2.4 — STEP_194).
        // Rank 5b is red and rank 10 amber *about the weekly or the monthly*; while the primary
        // window keeps the hero, line 1 is still a sentence about the primary window, and
        // painting "Safe at this pace" red would contradict the words in it. The long limit's
        // colour lives in the strip under it, in the tab dot and in the menu bar — the three
        // places that are about the account rather than about the next five hours.
        let scopedToPrimary = longLimitScopesPrimary(tool: tool, state: state, snapshot: snapshot,
                                                     selection: selection)
        let colour = dot(for: scopedToPrimary ? .healthy : state)
        let util = snapshot?.primaryUsedPct
        let reset = snapshot?.primaryResetsAt
        let clock = reset.map { Fmt.clockDay($0, from: now) }
        let countdown = reset.flatMap { Fmt.countdown(to: $0, from: now) }
        // E-08's cards are prose, so they take the **spaced** countdown the anatomy uses (§5.3) —
        // `countdown` above is the compact menu-bar form that line 2's own tokens carry.
        // (REV-75/D-90 — STEP_130.)
        let countdownSpaced = reset.flatMap { Fmt.countdown(to: $0, from: now, spaced: true) }
        let grainWord = windowGrain(seconds: snapshot?.primaryWindowSeconds) ?? "5-hour"
        /// One helper for every E-08 fill below, so no return site assembles prose (rule 4).
        func detail(_ variant: LiveVariant, _ values: [String: String?] = [:],
                    missing: LiveDropReason) -> ExplanationLive {
            ExplanationRegistry.liveLine(.verdictDetail, variant: variant, tool: tool,
                                         values: values, missing: missing)
        }

        // REV-38 / D-34 (both tools since STEP_47, REV-40/D-36): the period-quota family owns
        // the verdict whenever the monthly layout is active (monthly limit present, no populated
        // 5-hour window — a populated window resumes the standard rows below). Checked above the
        // spend-control row: with null windows a reached spend control *is* the monthly block,
        // and its verdict names the monthly recovery ("Monthly limit reached — resets Aug 1" /
        // "Spend limit reached — resets Aug 1"), not the windowed copy.
        if let monthly = monthlyLayoutLimit(snapshot) {
            return monthlyVerdict(snapshot: snapshot, monthly: monthly,
                                  staleAsOf: staleAsOf, freezeReason: freezeReason, now: now)
                .tagged(.monthly)
        }
        // Codex spend-control: not a §2.2a row — preserve the STEP_27 "Spend limit reached" copy.
        if state == .spendControl {
            return HeaderVerdict(line1: "Spend limit reached", colour: colour, line2: "—",
                                 family: .spendControl)
        }
        // Null 5-hour window (Claude) / null windows (Codex): no runway geometry. Checked before
        // idle so a stale-kept window whose reset has passed (util degraded to nil, state
        // idle-fallback) still reads "No active session" per the §9.3 stale-keep amendment.
        // D-26 (STEP_38): once local activity postdates the snapshot, that negative claim is
        // falsified — withdraw it and render the §2.2a unknown form (the "—" placeholder:
        // absence of a window is a claim, "—" is the absence of one). No quota state is
        // inferred from JSONL in its place.
        if state == .nullWindow || util == nil {
            // REV-41 / D-38 (STEP_49): an expired sign-in reads as itself, not as staleness or a
            // throttle — waiting cannot recover it (only Claude Code refreshes the token), so the
            // line names the one action that fixes it. Auth-state honesty, in the same family as
            // the setup prompt / re-auth ask — not polling mechanics (§1.4 / §10 ban untouched).
            // Wins over both the rate-limited and generic-unknown forms (more specific).
            if case .credentialExpired = freezeReason {
                return HeaderVerdict(line1: "Claude sign-in expired — open Claude Code to reconnect.",
                                     colour: .grey, line2: "—", family: .signInExpired)
            }
            // REV-37 / D-33 (STEP_41): a rate-limited freeze is *reconnecting*, not idle — it wins
            // over the generic unknown form (a throttle is more specific than "stale"). "Session
            // state", never transport wording — the §1.4 / §10 copy ban keeps "throttled"/"rate
            // limited" out of the UI.
            if case .rateLimited = freezeReason {
                return HeaderVerdict(line1: "Reconnecting…", colour: .grey, line2: "—",
                                     family: .reconnecting)
            }
            if nullWindowObsolete {
                return HeaderVerdict(line1: "—", colour: .grey, line2: "—", family: .unknown)
            }
            return HeaderVerdict(line1: tool == .codex ? "No active window" : "No active session",
                                 colour: colour, line2: "—", family: .nullWindow)
        }
        // Idle / fallback with data present (e.g. stale-kept valid window): grey placeholder —
        // the forecast buffer is cleared so there is no runway to state.
        if state == .idleFallback {
            // STEP_166 item 2: the D-33 fork also wins here. A throttled freeze past the TTL with
            // a still-valid cached window used to fall through to the bare dashes (two bare
            // dashes under a grey header, twice on 2026-09-06) — "Reconnecting…" is the honest
            // line; the kept percent and `as of` stamp stay beneath it. Same copy, same family.
            if case .rateLimited = freezeReason {
                return HeaderVerdict(line1: "Reconnecting…", colour: .grey, line2: "—",
                                     family: .reconnecting)
            }
            return HeaderVerdict(line1: "—", colour: .grey, line2: "—", family: .idle)
        }
        // Over quota (util ≥ 100) — §7.1 case variants (§2.2a). The util test overrides the state
        // so a credits-accruing account sitting at exactly 100% (classified bad-timing) still reads
        // the over-quota line.
        if state == .overQuota || (util ?? 0) >= 100 {
            return overQuotaVerdict(tool: tool, snapshot: snapshot, colour: colour,
                                    clock: clock, countdown: countdown, stale: stale, now: now)
                .tagged(.overQuota)
        }
        // A promoted monthly meter over a populated, calm primary (STEP_176 — REV-92 §2.2 "a more
        // urgent monthly constraint can take precedence"): the monthly family owns the verdict
        // exactly as on the monthly layout. The layout branch above already handled the no-window
        // case, so this fires only for the promotion.
        if selection.hero?.id == .monthly, let monthly = snapshot?.monthlyLimit {
            return monthlyVerdict(snapshot: snapshot, monthly: monthly,
                                  staleAsOf: staleAsOf, freezeReason: freezeReason, now: now)
                .tagged(.monthly)
        }
        // **The "Tight — N% of the weekly left" row is gone** (REV-96 §2.4/§3.7 — STEP_194).
        // It existed because a weekly could only speak by taking the whole header, so a weekly
        // past 85 % replaced a perfectly good five-hour verdict with one about a different clock.
        // The strip under the verdict says the same thing without displacing anything, and the
        // one case where a weekly really does own the header — it is what stopped you — is the
        // over-quota branch above, which names it and carries this row's anatomy.
        // Low-allowance shape (D-60/D-64, REV-59 §5 — STEP_88): every remaining branch below is
        // runway-derived, and on this shape there is no runway and no burn to derive one from. The
        // row is **removed**, not filled: `Measuring…` would promise a number we will never
        // usefully deliver, and `Nothing burning` would assert a measured calm on a meter that a
        // single turn can move by a fifth. Placed here, after the monthly, spend-control,
        // null-window, idle, over-quota and weekly branches, so everything the user can still act
        // on — above all "Stopped — quota returns at […]" — survives untouched.
        if snapshot?.isLowAllowanceShape == true { return nil }
        // Not-started window (D-123, amending REV-80 / D-101 — STEP_207): the same removal, for
        // the same reason, on the second shape that has no runway. See `verdictRemovedAsNotStarted`.
        if verdictRemovedAsNotStarted(snapshot: snapshot, selection: selection) { return nil }

        // Runway-driven: exhaustion-before-reset (warning states) vs resets-first (healthy) vs
        // burn≈0 (runway → ∞). The comparison reads Forecast outputs, not gate thresholds.
        // Dual-horizon since REV-65/D-69: the exhaustion arm also requires the §11.3 pace clock
        // (used% > elapsed% of the window, grace 2%) — the burn average spans minutes, and against
        // a weekly window `runway < reset` alone is unlosable (live 2026-08-13: "stop in ~4h46m"
        // at 5% weekly used, 6.9 days to reset). One derivation on the snapshot, shared with
        // StateEngine rank 9 and the §1.3 ◔ slot — never re-derived here (Baseline §19).
        let paceExceeded = snapshot?.paceExceeded(now: now)
        // The clock's other hand, for the anatomy's Pace row (STEP_110) — same derivation.
        let paceElapsed = snapshot?.paceElapsedPct(now: now)
        let runway = forecast?.runwayMinutes
        let minutesToReset = reset.map { $0.timeIntervalSince(now) / 60 }
        // Everything the anatomy needs, gathered once so it can only ever read the locals the
        // verdict itself was decided from (D-73: one branch walk, never a re-derivation).
        let anatomyInputs = AnatomyInputs(
            util: util, reset: reset, minutesToReset: minutesToReset, runway: runway,
            burn: forecast?.burnRatePerMin, burnSpan: forecast?.burnSpanMinutes,
            paceExceeded: paceExceeded, paceElapsed: paceElapsed,
            windowLength: snapshot?.primaryWindowLength, now: now)
        // D-113 (STEP_172): the arm's test moved to `exhaustionRunwayMinutes`, which the §1.3 `◔`
        // slot reads too — one decision, so the bar and this row cannot disagree (Baseline §19).
        if let runway = exhaustionRunwayMinutes(state: state, snapshot: snapshot,
                                                forecast: forecast, now: now) {
            // Exhaustion before reset — one row for the whole family, colour follows state
            // (a copy split would flap on the boundary and duplicate what colour encodes).
            // Credits **off** (no backstop): a crossing is a hard block, not a charge — say
            // so (§2.2a, REV-29; advisory rewrite v5.1). Keeps the state colour: forcing the
            // spec note's typical amber would downgrade an At-risk red.
            let runwayText = Fmt.durationHM(runway)
            // A spent cap is `noBackstop` for every forecast question (REV-102 §2.2).
            let moneyState = MoneyModel.moneyState(snapshot: snapshot)
            let noBackstop = tool == .claude
                && (moneyState == .noBackstop || moneyState == .capReached)
            let line1 = noBackstop
                ? "Won't make it — you'll be blocked in ~\(runwayText)"
                : "Won't make it — slow down or you'll stop in ~\(runwayText)"
            // D-29 detail: the stops clock (now + runway, forecast-derived → tilde) leads,
            // the countdown is dropped (derivable from the two clocks; still in the quota row).
            let stops = Fmt.clockDay(now.addingTimeInterval(runway * 60), from: now)
            var tokens = ["stops ~\(stops)"]
            if let clock { tokens.append("resets \(clock)") }
            tokens.append("runway ~\(runwayText)")
            return HeaderVerdict(line1: line1, colour: colour,
                                 line2: tokens.joined(separator: " · "),
                                 family: .exhaustion,
                                 anatomy: runwayAnatomy(.exhaustion, anatomyInputs),
                                 detailLive: detail(.exhaustion,
                                                    ["runway": runwayText,
                                                     "countdown": countdownSpaced,
                                                     "stops": stops], missing: .noRunway))
        }
        // Long-window calm family (REV-65/D-69): a window a day or wider answers with pace, not
        // burst grammar — "Safe at this pace", "Nothing burning" and "Measuring…" all answer a
        // burst-scale question nobody asked of a weekly budget, and the pace clock needs no burn
        // buffer, so this hero holds from poll 1 and across restarts. The exhaustion row above
        // still wins when both clocks agree; the D-46 held row still wins while a warning colour
        // is held; the stale path keeps today's grammar (a pace verdict from stale data would be
        // a confident claim — the D-35 posture).
        if !stale, (snapshot?.primaryWindowLength ?? 0) >= 86_400, snapshot?.primaryResetsAt != nil {
            // REV-66/D-70: no reset clause and no line 2 on any of these three rows — the reset
            // has a single header home, and since STEP_178 that home is the `resets in …` detail
            // line under this verdict (`heroDetailLines`, the same D-58 band the caption used to
            // apply, generalised to whichever limit is the hero). Line 2's job is the numbers
            // *behind* the verdict, of which these rows have none beyond that reset. Removed, not
            // dashed: `—` is the unknown placeholder. The monthly family keeps its reset clause —
            // its detail line carries the organisation-and-pace note, not a date.
            if colour != .green {
                return HeaderVerdict(line1: "Was on track to run out — safe if this pace holds",
                                     colour: colour, line2: nil, family: .held,
                                     anatomy: runwayAnatomy(.heldLongWindow, anatomyInputs))
            }
            if paceExceeded == true, let util {
                return HeaderVerdict(line1: "Above pace — \(Fmt.percent(util)) used",
                                     colour: colour, line2: nil, family: .longWindowPace,
                                     anatomy: paceAnatomy(abovePace: true, anatomyInputs))
            }
            return HeaderVerdict(line1: "On pace", colour: colour, line2: nil,
                                 family: .longWindowPace,
                                 anatomy: paceAnatomy(abovePace: false, anatomyInputs))
        }
        if let runway, runway > 0, let minutesToReset, minutesToReset > 0 {
            let runwayText = Fmt.durationHM(runway)
            // Resets first. Three cases, held-state first (REV-51 / D-46, STEP_71): §13.4's
            // de-escalation hysteresis adopts a calmer state only after 3 confirming polls, so
            // this branch is reachable while a *warning* colour is still held — the forecast has
            // no memory, the state has three polls of it, and the two are guaranteed to disagree
            // for the length of every de-escalation. Naming the danger the colour is still
            // carrying keeps copy and colour one statement; "Safe at this pace" in amber asserted
            // safety in the colour of danger (live 2026-07-21, calm poll 2 of 3). Gates on the
            // *colour*, not `state == .healthy`: a future state mapping to green takes the green
            // copy automatically, and any new warning state inherits the held row. This also
            // **pre-empts D-31** — "barely" is a copy variant within green, and a held warning is
            // not green; the collision is the normal path, since a de-escalation passes through
            // small margins on its way up. Otherwise Healthy/green at any margin, split below
            // `thinMarginMinutes` (D-31) by the margin it is about.
            let margin = abs(runway - minutesToReset)
            let line1: String
            if colour != .green {
                line1 = "Was on track to run out — safe if this pace holds"
            } else if margin < thinMarginMinutes {
                line1 = "Safe, barely — reset beats you by ~\(Fmt.durationHM(margin))"
            } else if scopedToPrimary {
                // **Scoped** (REV-96 §3.7): with a strip under it saying the weekly is tight,
                // an unqualified "reset comes first" reads as *you are fine*, which is exactly
                // what the strip is there to deny. Naming the window the sentence is about turns
                // a contradiction into two facts that fit together.
                line1 = "Safe at this pace — \(grainWord) reset comes first"
            } else {
                line1 = "Safe at this pace — reset comes first"
            }
            var tokens: [String] = []
            if let clock { tokens.append("resets \(clock)") }
            if let countdown { tokens.append("in \(countdown)") }
            tokens.append("runway ~\(runwayText)")
            let family: VerdictFamily = colour != .green ? .held : .resetsFirst
            // The D-46 held row shares `resetsFirst`'s card: both say the reset arrives first,
            // and D-90 lists the held row under that variant rather than giving it its own.
            return HeaderVerdict(line1: line1, colour: colour,
                                 line2: tokens.joined(separator: " · "),
                                 family: family,
                                 anatomy: runwayAnatomy(family == .held ? .held : .resetsFirst,
                                                        anatomyInputs),
                                 detailLive: detail(.resetsFirst,
                                                    ["runway": runwayText,
                                                     "countdown": countdownSpaced], missing: .noRunway))
        }
        var resetTokens: [String] = []
        if let clock { resetTokens.append("resets \(clock)") }
        if let countdown { resetTokens.append("in \(countdown)") }
        // Burn not measurable yet (§11.2a, REV-35): cold start (< 2 polls), or a flat reading whose
        // span is too short for the endpoint's whole-percent quantization to resolve. State the
        // reset and claim nothing — "Nothing burning" below asserts a *measured* zero, and asserting
        // it here is how the app came to say it while two subagents burned ~0.5 %/min underneath.
        if forecast?.burnRatePerMin == nil {
            let line2 = resetTokens.joined(separator: " · ")
            return HeaderVerdict(line1: "Measuring…", colour: colour,
                                 line2: line2.isEmpty ? "—" : line2, family: .measuring,
                                 detailLive: line2.isEmpty ? nil : detail(.measuring, missing: .noBurn))
        }
        // Resets first, burn ≈ 0 (runway → ∞): a measured zero — no runway/margin token.
        return HeaderVerdict(line1: "Nothing burning", colour: colour,
                             line2: (["no burn"] + resetTokens).joined(separator: " · "),
                             family: .nothingBurning,
                             anatomy: runwayAnatomy(.nothingBurning, anatomyInputs),
                             detailLive: detail(.nothingBurning, missing: .noBurn))
    }

    /// Over-quota verdict + detail (Baseline §7.1 / UI Spec §2.2a). The **blocked** row is the
    /// merged D-31 template (STEP_39): §7.1 cases 2 and 3, any measured > 100 without credits,
    /// and every Codex over-quota read one advisory string — "Stopped — quota returns at [t]" —
    /// live and stale alike, with the `blocked · resets [t] · in [countdown]` detail. This
    /// retires "Quota spent — resets [t]" and "Over quota — new requests blocked". The
    /// **accruing** row (credits on, case 1; v5.1/STEP_40) reads "$ Running on credits — every
    /// token costs now" — the `$` is the §1.6 glyph as a verdict prefix (`moneyPrefix`), never
    /// part of the string. Its detail is the D-30 money mirror, **live only**: `$[used] this
    /// window · resets [t]` (the `+$[rate]/hr` token is omitted — no credits spend-rate
    /// derivation exists; the spec forbids approximating it). Stale/restored degrades dollarless
    /// to `over quota · resets [t] · in [countdown]` while the verdict survives (R33-1 extended:
    /// util ≥ 100 with credits on is the same monotone fact as the block).
    private static func overQuotaVerdict(tool: Tool, snapshot: QuotaSnapshot?, colour: StatusDot,
                                         clock: String?, countdown: String?,
                                         stale: Bool, now: Date = Date()) -> HeaderVerdict {
        // **Which limit stopped you** (REV-96 §3.7 — STEP_194). The five-hour window used to be
        // the only thing "Stopped" could be about, so the line never had to say. A spent weekly
        // renders a five-hour window with room directly under it, and "Stopped — quota returns at
        // 6:40 pm" then names the reset of a window that is not the one holding you: on the
        // tester's block that clock was three days early.
        let episode = snapshot?.blockEpisode
        let blockingIsSecondary = episode?.limit == .secondary
        let bothWindowsSpent = blockingIsSecondary && (snapshot?.primaryUsedPct ?? 0) >= 100
        // The blocking limit's own reset — a weekly's is days out, so it is named as a date.
        let blockClock: String? = blockingIsSecondary
            ? snapshot?.secondaryResetsAt.map(Fmt.monthDay) : clock
        let blockCountdown: String? = blockingIsSecondary
            ? snapshot?.secondaryResetsAt.flatMap { Fmt.countdown(to: $0, from: now, spaced: true) }
            : countdown

        func blocked() -> HeaderVerdict {
            // No known reset time (rare: block flag with a null window) → degrade gracefully,
            // never fabricate a clock.
            let line1: String
            if bothWindowsSpent {
                line1 = blockClock.map { "Stopped — both windows spent, resets \($0)" }
                    ?? "Stopped — both windows spent"
            } else if blockingIsSecondary {
                line1 = blockClock.map { "Stopped — weekly spent, resets \($0)" }
                    ?? "Stopped — weekly spent"
            } else {
                line1 = clock.map { "Stopped — quota returns at \($0)" }
                    ?? "Stopped — new requests blocked"
            }
            var tokens = ["blocked"]
            if bothWindowsSpent {
                // Both clocks, so the two can be compared — the five-hour frees nothing while the
                // weekly holds, and that is the whole point of naming them together.
                if let clock { tokens.append("5-hour resets \(clock)") }
                if let blockClock { tokens.append("weekly \(blockClock)") }
                if let blockCountdown { tokens.append("in \(blockCountdown)") }
            } else if blockingIsSecondary {
                if let blockCountdown { tokens.append("in \(blockCountdown)") }
            } else {
                if let clock { tokens.append("resets \(clock)") }
                if let countdown { tokens.append("in \(countdown)") }
            }
            // A weekly block is the one case where the header is about a limit the reader was
            // not watching, so it shows its work: Shape B's rows, and E-08's "Two resets" card,
            // whose words — *the five-hour reset won't free anything up* — were written for the
            // retired Weekly-elevated row and are exactly right here.
            let weeklyBlock = blockingIsSecondary
            return HeaderVerdict(line1: line1, colour: colour,
                                 line2: tokens.joined(separator: " · "),
                                 // E-08·overQuota (D-90). Set here rather than at the call site:
                                 // `.tagged(.overQuota)` carries one family for two cards, and
                                 // only this branch knows which of them it is.
                                 anatomy: weeklyBlock
                                     ? weeklyAnatomy(snapshot: snapshot,
                                                     util: snapshot?.primaryUsedPct, now: now)
                                     : nil,
                                 detailLive: weeklyBlock
                                     ? ExplanationRegistry.liveLine(
                                         .verdictDetail, variant: .weeklyElevated, tool: tool,
                                         values: ["wkReset": blockClock, "reset": clock,
                                                  "grain": DisplayFormatter.windowGrain(
                                                      seconds: snapshot?.primaryWindowSeconds)
                                                      ?? "5-hour"],
                                         missing: .noReset)
                                     : ExplanationRegistry.liveLine(
                                         .verdictDetail, variant: .overQuota, tool: tool,
                                         values: ["reset": blockClock ?? clock], missing: .noReset))
        }
        if tool == .codex { return blocked() }
        // Case 1 is credits **paying** — on, and under their cap. A spent cap charges nothing, so
        // it is an ordinary block (REV-102 §2.3); `heroDetailLines` adds the line that says so.
        if snapshot?.extraUsage?.isEnabled == true,
           MoneyModel.moneyState(snapshot: snapshot) != .capReached {                   // Case 1
            // Org-paid credits are a monthly meter, and a weekly block names the weekly's reset
            // — the five-hour clock frees nothing while the weekly holds.
            let orgManaged = snapshot?.extraUsage?.managedByOrganization == true
            let resetToken = blockingIsSecondary ? blockClock.map { "weekly resets \($0)" }
                                                 : clock.map { "resets \($0)" }
            var tokens: [String] = []
            if stale {
                tokens.append("over quota")
                if let resetToken { tokens.append(resetToken) }
                if let blockCountdown { tokens.append("in \(blockCountdown)") }
            } else {
                if let extra = snapshot?.extraUsage, let used = extra.usedCredits {
                    tokens.append(orgManaged ? "\(creditsUsedOfCap(used, extra)) this month"
                                             : "\(creditsUsed(used, extra)) this window")
                }
                if let resetToken { tokens.append(resetToken) }
            }
            return HeaderVerdict(line1: "Running on credits — every token costs now",
                                 colour: colour,
                                 line2: tokens.isEmpty ? "—" : tokens.joined(separator: " · "),
                                 moneyPrefix: true,
                                 moneySymbol: Fmt.moneyGlyphSymbol(snapshot?.extraUsage?.currency),
                                 // E-08·onCredits — the other half of `.tagged(.overQuota)`, and
                                 // Claude's alone (the Codex cell is `—`; this branch is already
                                 // past the Codex short-circuit above).
                                 detailLive: tokens.isEmpty ? nil
                                     : ExplanationRegistry.liveLine(
                                         .verdictDetail, variant: .onCredits, tool: tool,
                                         values: ["reset": clock], missing: .noReset))
        }
        return blocked()                                                          // Cases 2 & 3
    }

    // MARK: Monthly (period-quota) layout — REV-38 / D-34, UI Spec v5.5 Part 2 (STEP_44)

    /// §5 placeholder constants (dogfood-tuned), locked 2026-07-16 (P1-15). E8: the day-scale
    /// slot rule's urgency gate — runway ≤ this many days may show `◔~Nd` (≈ 20% of the period,
    /// mirroring the minute rule's < 60-min gate). E6: the pace-forecast amber gate — projected
    /// exhaustion ≥ `monthlyForecastMinLeadDays` before reset AND the confidence half
    /// (≥ `monthlyConfidenceMinDaysElapsed` elapsed OR used ≥ `monthlyConfidenceMinUsedPct`).
    /// Red at ≥ `monthlyRedUsedPct` or reached.
    static let monthlyRunwaySlotDays = 7.0
    static let monthlyForecastMinLeadDays = 2.0
    static let monthlyConfidenceMinDaysElapsed = 7.0
    static let monthlyConfidenceMinUsedPct = 25.0
    static let monthlyRedUsedPct = 90.0

    /// §2.4 monthly burn-pill placeholders (REV-47 §2.2, E6-style — dogfood-tuned, shared with
    /// the Codex monthly fork). The tiers are **break-even anchored**: `r = liveRate ÷ (remaining
    /// ÷ hours-to-reset)`, i.e. 1.0 is exactly the rate that exhausts the budget at the reset, so
    /// the same numbers work in dollars and credits without a per-unit table. Red needs `r ≥ 1`
    /// *and* a consummation risk — already deep in the meter, or exhausting within
    /// `monthlyPillRedHours`.
    static let monthlyPillBreakEvenLow = 0.5
    static let monthlyPillBreakEvenHigh = 1.0
    static let monthlyPillRedHours = 48.0

    /// E5 — the near-cap "Request limit increase" deep link (ChatGPT settings → Usage), the
    /// monthly layout's one interactive affordance. Recommendation-only, read-only launch —
    /// the STEP_35 external-link pattern; the limit itself is workspace-admin-controlled.
    static let requestLimitIncreaseURL = URL(string: "https://chatgpt.com/#settings/Usage")

    /// D-61 — the tier note's companion upgrade link on the §11.3 low-allowance shape (STEP_89).
    /// Points at ChatGPT's in-app plan modal, which is the control OpenAI's own account menu opens
    /// from "Upgrade plan"; on a plan that lasts about one working session it is the most
    /// actionable thing this card can offer. Read-only launch, same STEP_35 pattern as the two
    /// links above — the app never touches the subscription.
    static let upgradeCodexPlanURL = URL(string: "https://chatgpt.com/#pricing")

    /// The monthly layout owns hero / verdict / menu bar / dot when a monthly limit exists and
    /// no 5-hour window is populated. Detection is data-driven (Codex `individualLimit != null`,
    /// D-34; Claude active spend meter, D-36) — never plan-driven; window precedence: a
    /// populated window resumes the standard grammar on every surface (the string builders key
    /// off `primary != nil`, never the monthly source), while the Monthly *section* keys on
    /// `monthlyLimit` alone and renders either way.
    static func monthlyLayoutLimit(_ snapshot: QuotaSnapshot?) -> MonthlyLimit? {
        guard snapshot?.primaryUsedPct == nil else { return nil }
        return snapshot?.monthlyLimit
    }

    /// The pool is consummated: the backend block flag, or a used% at/over the ceiling.
    ///
    /// **The rule moved to Core in STEP_193** (`QuotaSnapshot.monthlyReached`) so the state engine
    /// classifies the same fact this card renders — before that, a Claude monthly at 100 % read
    /// "Spend limit reached" here while `StateEngine` sat on rank 12 and nothing fired. Kept as a
    /// call site rather than deleted: its eight readers take a `MonthlyLimit` in hand, and the
    /// monthly-layout selection can hold one the snapshot does not.
    static func monthlyReached(snapshot: QuotaSnapshot?, monthly: MonthlyLimit) -> Bool {
        snapshot?.spendControlReached == true || (monthly.usedPercentExact ?? 0) >= 100
    }

    /// E6 confidence half: enough of the cycle observed (or enough of the pool spent) for the
    /// single-reading pace to support a forecast claim.
    static func monthlyConfidenceMet(_ monthly: MonthlyLimit, now: Date) -> Bool {
        if let days = monthly.daysElapsedInCycle(now: now),
           days >= monthlyConfidenceMinDaysElapsed { return true }
        return (monthly.usedPercentExact ?? 0) >= monthlyConfidenceMinUsedPct
    }

    /// The E6 amber gate: confident pace projecting exhaustion at least
    /// `monthlyForecastMinLeadDays` before the reset.
    static func monthlyForecastGateMet(_ monthly: MonthlyLimit, now: Date) -> Bool {
        guard monthlyConfidenceMet(monthly, now: now),
              let runway = monthly.runwayDays(now: now) else { return false }
        let daysToReset = monthly.resetsAt.timeIntervalSince(now) / 86_400
        return daysToReset - runway >= monthlyForecastMinLeadDays
    }

    /// The forecast dot for the monthly layout (D-34: colour = pace forecast with the E6
    /// gate; red at ≥ 90% or reached). Computed here, not in StateEngine — display-only, the
    /// money-glyph precedent: the state stays rank-12 Null-window (Baseline §13 item 12, "no
    /// new state") and dominant-agent arbitration is untouched. One derivation feeds the
    /// menu-bar dot, the tab dot, the hero colour, and the verdict colour (§19).
    static func monthlyForecastDot(snapshot: QuotaSnapshot?, monthly: MonthlyLimit,
                                   now: Date) -> StatusDot {
        let used = monthly.usedPercentExact ?? 0
        if monthlyReached(snapshot: snapshot, monthly: monthly) || used >= monthlyRedUsedPct {
            return .red
        }
        if monthlyForecastGateMet(monthly, now: now) { return .amber }
        return .green
    }

    /// The dot on the §11.3 low-allowance shape (D-60 — STEP_88), painted from the
    /// used percentage rather than from the state.
    ///
    /// Why the display owns the colour here: the shape has no forecast, so §13's rate-derived
    /// ranks are unreachable and the state machine has no red left to offer between 85% and 100% —
    /// At risk and Bad timing are exactly the ranks that were gated off. The state stays Elevated
    /// (amber, rank 9) is unchanged; only the rendered colour follows the
    /// meter, so 97% of a month reads as the emergency it is.
    ///
    /// This is the money-glyph / monthly-layout precedent, not a new mechanism: `monthlyForecastDot`
    /// already repaints the dot while the state stays rank-12 Null-window. Display-only —
    /// §15.1 default-tab selection reads the state, never this.
    /// Thresholds come from `Fmt.thresholdDot` so there is one boundary definition, not two.
    static func lowAllowanceDot(_ usedPct: Double) -> StatusDot {
        switch Fmt.thresholdDot(usedPct) {
        case .red:   return .red
        case .amber: return .amber
        default:     return .green
        }
    }

    /// The used percentage to repaint from, or `nil` when the repaint must not happen: off the
    /// shape, while stale (staleness owns the colour — a green repaint would hide it), or over a
    /// hard block (already red, and the state machine is never demoted by a display rule).
    static func lowAllowanceRepaintPct(snapshot: QuotaSnapshot?, state: AppState,
                                       stale: Bool) -> Double? {
        guard !stale, !state.isHardBlock, snapshot?.isLowAllowanceShape == true else { return nil }
        return snapshot?.primaryUsedPct
    }

    /// E8 day-scale time slot (locked 2026-07-16, P1-15 — the §1.3 structural port): `◔~Nd`
    /// only when (1) pace is trustworthy — E6 confidence half met and the reading fresh (D-35
    /// suspends pace while stale, so ◔ never renders stale); (2) projected exhaustion before
    /// reset; (3) runway ≤ `monthlyRunwaySlotDays`. Otherwise the `↻Nd` reset slot. A reached
    /// pool always shows the reset slot — its runway is spent, not urgent.
    static func monthlyMenuBarSlot(snapshot: QuotaSnapshot?, monthly: MonthlyLimit,
                                   stale: Bool, now: Date) -> String? {
        let daysToReset = monthly.resetsAt.timeIntervalSince(now) / 86_400
        if !stale, !monthlyReached(snapshot: snapshot, monthly: monthly),
           monthlyConfidenceMet(monthly, now: now),
           let runway = monthly.runwayDays(now: now),
           runway < daysToReset, runway <= monthlyRunwaySlotDays {
            return "◔~\(Fmt.dayScale(runway))"
        }
        guard daysToReset > 0 else { return nil }
        return "↻\(Fmt.dayScale(daysToReset))"
    }

    /// One amount grammar per unit (REV-40/D-36 — one formatter path branching on unit): whole
    /// credits for Codex; exponent-scaled money for the Claude Enterprise spend meter.
    /// `public` since STEP_194: the App target's notification presenter prints the monthly
    /// meter's amounts in event 9 and the spend-control body, and a second money formatter there
    /// would be a second `$`-vs-ISO rule to keep in step (D-36).
    public static func monthlyAmount(_ value: Double, unit: QuotaUnit) -> String {
        switch unit {
        case .credits:
            return Fmt.credits(value)
        case let .money(currency, exponent):
            return Fmt.money(minor: value, exponent: exponent, currency: currency)
        }
    }

    /// The `[used] of [limit]` token shared by the verdict detail, the D-35 stale line and the
    /// Used row — `2,377 of 5,000` (credits) / `$69.16 of $120.00` (money).
    static func usedOfLimitText(_ monthly: MonthlyLimit) -> String {
        "\(monthlyAmount(monthly.usedAmount, unit: monthly.unit))"
            + " of \(monthlyAmount(monthly.limitAmount, unit: monthly.unit))"
    }

    /// The §2.2a pace token, unit-branched: `~158 credits/day` / `~$3.96/day`.
    static func paceToken(_ pace: Double, unit: QuotaUnit) -> String {
        switch unit {
        case .credits: return "~\(Fmt.credits(pace)) credits/day"
        case .money: return "~\(monthlyAmount(pace, unit: unit))/day"
        }
    }

    /// The §2.4 live burn token on the monthly layout, the pace token's per-hour twin:
    /// `~14 credits/hr` / `~$4.10/hr` (REV-47 §2.2).
    static func hourlyToken(_ rate: Double, unit: QuotaUnit) -> String {
        switch unit {
        case .credits: return "~\(Fmt.credits(rate)) credits/hr"
        case .money: return "~\(monthlyAmount(rate, unit: unit))/hr"
        }
    }

    /// Whether a raw amount disappears at the unit's display resolution — the D-42 "hides at $0"
    /// test, kept unit-agnostic. Both grammars render one raw unit as their last digit (whole
    /// credits; `Fmt.money` shows exactly `exponent` fraction digits of the minor unit), so the
    /// test is the same in either: below half a raw unit there is nothing to show.
    private static func roundsToZero(_ value: Double) -> Bool {
        value.rounded() == 0
    }

    /// The §2.2a period-quota verdict family (REV-38; D-35 stale forms; money variants
    /// REV-40/D-36). The caller guarantees the monthly layout is active — with a populated
    /// 5-hour window the standard minute-based family owns the verdict (precedence, D-34).
    /// The `——` unknown form is *not* a row here: a month that rolled over unseen had its
    /// `monthlyLimit` degraded to nil in Core (`degradingExpiredWindows`, the R33-7 analogue)
    /// before this point, and falls to the standard stale-null branch.
    static func monthlyVerdict(snapshot: QuotaSnapshot?, monthly: MonthlyLimit,
                                       staleAsOf: Date?, freezeReason: AdapterHealth?,
                                       now: Date) -> HeaderVerdict {
        let money: Bool = { if case .money = monthly.unit { return true }; return false }()
        let usedOfLimit = usedOfLimitText(monthly)
        let resetDate = Fmt.monthDay(monthly.resetsAt)
        let daysToReset = max(0, monthly.resetsAt.timeIntervalSince(now) / 86_400)

        // Reached — rank 2 keeps its verdict live and stale alike (R33-1 extended: the monthly
        // `reset_at` is the block's recovery timestamp). Stale swaps the day countdown for the
        // honest as-of stamp. Money reads "Spend limit reached" — claude.ai's own wording
        // (REV-40); credits keeps "Monthly limit reached".
        if monthlyReached(snapshot: snapshot, monthly: monthly) {
            var tokens = ["blocked", "resets \(resetDate)"]
            tokens.append(staleAsOf.map { "as of \(asOfStamp($0, now: now))" }
                ?? "↻ \(Fmt.dayScale(daysToReset))")
            let title = money ? "Spend limit reached" : "Monthly limit reached"
            return HeaderVerdict(line1: "\(title) — resets \(resetDate)",
                                 colour: .red, line2: tokens.joined(separator: " · "))
        }
        // Stale (D-35): the kept percent is a *lower bound* for the whole month — quota is
        // monotone within the period — but a pace projected from stale data would be a
        // confident claim, so the forecast rows are unreachable from here. Line 1 names the
        // freeze (D-33 / D-38): "Claude sign-in expired…" for `.credentialExpired`, "Reconnecting…"
        // for a rate-limited freeze — session-state honesty, never "throttled"/"rate limited"
        // (§1.4/§10 copy ban).
        if let staleAsOf {
            // D-38 (STEP_49) wins over "Reconnecting…" (D-33) which wins over the generic stale
            // form — an expired sign-in is more specific than a throttle, which is more specific
            // than "stale". line2 (lower-bound stamp) is identical across all three.
            let line1: String
            if case .credentialExpired = freezeReason {
                line1 = "Claude sign-in expired — open Claude Code to reconnect."
            } else if case .rateLimited = freezeReason {
                line1 = "Reconnecting…"
            } else {
                line1 = "No fresh reading — showing last known"
            }
            return HeaderVerdict(
                line1: line1,
                colour: .grey,
                line2: "as of \(asOfStamp(staleAsOf, now: now)) · \(usedOfLimit) · lower bound")
        }
        let colour = monthlyForecastDot(snapshot: snapshot, monthly: monthly, now: now)
        let pace = monthly.pacePerDay(now: now)
        // E-08's two monthly cards (D-90). `[pace]` is the bare per-day amount — the template
        // owns the tilde and the words "a day", so `paceToken` (which supplies both) is not what
        // fills it. Only these two of `monthlyVerdict`'s five returns carry a card: the reached
        // row is a block and the stale row is a freeze, and D-90 names neither; the "Nearly at
        // the monthly limit" row is left inert because `monthlyOnPace`'s sentence — "the month
        // ends before you reach [limit]" — is exactly the claim its own forecast gate did *not*
        // meet, and inventing a third variant is a spec change, not an implementation.
        let tool = snapshot?.tool ?? .claude
        let limitText = monthlyAmount(monthly.limitAmount, unit: monthly.unit)
        let paceText = pace.map { monthlyAmount($0, unit: monthly.unit) }
        // Money never carries a pool token — spend scope is unverified, seat vs org (P2-11).
        let detail = [pace.map { paceToken($0, unit: monthly.unit) }, usedOfLimit,
                      money ? nil : "workspace pool"].compactMap { $0 }.joined(separator: " · ")
        // Forecast exhaustion before reset (E6 gate) — red already when ≥ 90%.
        if monthlyForecastGateMet(monthly, now: now), let runway = monthly.runwayDays(now: now) {
            let lead = Fmt.dayScale(daysToReset - runway)
            return HeaderVerdict(
                line1: "At this pace, runs out in ~\(Fmt.dayScale(runway)) — \(lead) before reset",
                colour: colour, line2: detail,
                detailLive: ExplanationRegistry.liveLine(
                    .verdictDetail, variant: .monthlyRunsOut, tool: tool,
                    values: ["pace": paceText, "limit": limitText, "days": lead],
                    missing: .noPace))
        }
        if (monthly.usedPercentExact ?? 0) >= monthlyRedUsedPct {
            return HeaderVerdict(line1: "Nearly at the monthly limit — resets \(resetDate)",
                                 colour: colour, line2: detail)
        }
        return HeaderVerdict(
            line1: "On pace — resets \(resetDate) (\(Fmt.dayScale(daysToReset)))",
            colour: colour, line2: detail,
            detailLive: ExplanationRegistry.liveLine(
                .verdictDetail, variant: .monthlyOnPace, tool: tool,
                values: ["pace": paceText, "limit": limitText], missing: .noPace))
    }


    /// The near-cap condition (E5): ≥ 90% used in the monthly layout, block not yet
    /// consummated. Shared by the recommendation copy and its deep link so they cannot drift.
    /// "Consummated" is `monthlyReached` — the flag *or* used ≥ 100% (REV-40: Claude has no
    /// reached flag until P1-16, so a used-out meter must not read "nearly reached").
    static func monthlyNearCap(_ snapshot: QuotaSnapshot?) -> MonthlyLimit? {
        guard let monthly = monthlyLayoutLimit(snapshot),
              !monthlyReached(snapshot: snapshot, monthly: monthly),
              (monthly.usedPercentExact ?? 0) >= monthlyRedUsedPct else { return nil }
        return monthly
    }

    /// Display label for a raw `plan_type` (UI Spec §0.4 Codex table; Claude values analogous).
    /// Unknown values show raw — never crash, never enum (PATTERNS.md §Naming conventions).
    /// **D-58 (REV-59) — a window is named by the width the provider reported**, in OpenAI's own
    /// vocabulary. Its surfaces are themselves duration-keyed (the CLI's `/status` shows "5h limit"
    /// and "Weekly limit"; the account menu shows "Monthly"), so adopting the provider's words and
    /// deriving from the width are the same act — the two goals never compete.
    ///
    /// Two hard prohibitions. **Never** infer the grain from `plan_type` (D-34 rejected plan-string
    /// branching once already, and the observed plan-string space is far wider than the values our
    /// code tests). **Never** infer it from position: OpenAI has returned the *weekly* window as
    /// `primary` with `secondary: null` (openai/codex #32707), so `primary` does not mean "short".
    ///
    /// `nil` is the load-bearing case and means **no grain claim at all** — the row falls back to
    /// `Used` and headers carry no scope. It is what stops an unrecognised width producing an
    /// invented name. (It also made Claude structurally immune until REV-80 / D-101 — the Claude
    /// adapter now sets 18 000 s on every snapshot and participates in the width-keyed rules on
    /// purpose; `windowGrain(18_000)` already read "5-hour", so no label moved.) Baseline §4; delta `docs/REV59_codex_consumer_window_grain.md` §4.
    public static func windowGrain(seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        switch seconds {
        case 300 * 60:    return "5-hour"
        case 10_080 * 60: return "Weekly"
        case 43_200 * 60: return "Monthly"
        default:
            // A width we have no name for renders as a literal duration: days from a week up
            // (`14-day`), hours below it (`72-hour`) — the boundary sits exactly where the named
            // grain `Weekly` already is. A width that is a whole number of neither yields no
            // claim rather than a rounded one; rounding here would be the same class of error as
            // the fixed label this decision replaces.
            if seconds % 86_400 == 0, seconds >= 7 * 86_400 { return "\(seconds / 86_400)-day" }
            if seconds % 3600 == 0 { return "\(seconds / 3600)-hour" }
            return nil
        }
    }

    /// The §2.3 row label for a window of this width. Claude keeps the fixed label it has always
    /// had — the STEP_85 lesson, since `quotaRows` is shared — while an unnamed Codex width makes
    /// no claim at all (D-58).
    static func quotaRowLabel(grain: String?, tool: Tool?) -> String {
        if let grain { return "\(grain) left" }
        return tool == .codex ? "Left" : "5-hour left"
    }

    /// The §2.5a header's SCOPE half — one member of the window-grain set (Baseline §4), which
    /// REV-59 turned from a fixed literal into this lookup. `nil` ⇒ the header carries no scope.
    static func windowGrainScope(_ grain: String?) -> String? {
        grain.map { "this \($0.lowercased()) window" }
    }

    // MARK: Live-line values (UI Spec Part 3 §5.2 rule 4 — REV-75/D-88, STEP_130)

    /// The noun E-04·pace calls the window by — "*[elapsed]% of the [period] gone*". A *period*,
    /// not a grain: `windowGrain` yields adjectives (`Weekly` / `Monthly`) and "of the weekly
    /// gone" is not English. Only the two widths the pace line can actually reach are named; any
    /// other reads `window`, which is true of every width and claims nothing.
    static func windowPeriodNoun(seconds: Int?) -> String {
        switch seconds {
        case 7 * 86_400:  return "week"
        case 30 * 86_400: return "month"
        default:          return "window"
        }
    }

    /// E-01's live line — **one derivation, two consumers**: the primary quota row and the D-58
    /// caption both carry E-01, and Baseline §19 forbids the second copy.
    ///
    /// `[start]` comes from `QuotaSnapshot.primaryWindowStart`, the app's single window-anchor
    /// derivation (REV-60), never a fresh `resetsAt − 5h`. It reads as a clock below the D-59
    /// 48-hour band (`4:00 pm`, `11:29 pm yesterday`) and as a date at or above it, where a wall
    /// clock a fortnight back means nothing. The clock takes `clockDay`'s **suffix** grammar via
    /// `Fmt.clockPastInSentence`, not §2.8's prefix one: this value sits inside a clause, and
    /// "started at yesterday 11:29 pm" is not English (caught on the live tab, 2026-08-22).
    ///
    /// The unanchored shape takes `.notStarted` on both tools (REV-80 / D-101 gave the Claude
    /// cell the same string; before that it was `—` and self-dropped as `.noTemplate`). Never
    /// gated on `tool ==`, because this builder is shared (the STEP_85 lesson).
    static func primaryWindowLive(snapshot: QuotaSnapshot?, now: Date) -> ExplanationLive {
        guard let snapshot else { return .dropped(.noWindow) }
        if snapshot.primaryWindowIsUnanchored {
            return ExplanationRegistry.liveLine(.primaryWindow, variant: .notStarted,
                                                tool: snapshot.tool, missing: .noWindow)
        }
        guard let start = snapshot.primaryWindowStart else { return .dropped(.noWindow) }
        let startText = snapshot.primaryWindowLength >= 48 * 3600
            ? Fmt.monthDay(start) : Fmt.clockPastInSentence(start, from: now)
        return ExplanationRegistry.liveLine(
            .primaryWindow, variant: .live, tool: snapshot.tool,
            values: ["start": startText,
                     "reset": snapshot.primaryResetsAt.map { Fmt.clockDay($0, from: now) }],
            missing: .noReset)
    }

    static func planDisplayName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "plus":                                        return "Plus"
        case "pro", "prolite":                              return "Pro"
        case "max":                                         return "Max"
        case "team":                                        return "Team"
        case "business", "self_serve_business_usage_based": return "Business"
        case "enterprise", "enterprise_cbp_usage_based":    return "Enterprise"
        case "education", "edu", "k12":                     return "Education"
        case "free", "guest":                               return "Free"
        // Observed live 2026-08-11 (REV-59). Absent from the table until then, so a `go` account
        // fell through to the raw-value row and wore a lowercase badge.
        case "go":                                          return "Go"
        default:                                            return raw
        }
    }

    /// The account-quota rows (used % + reset for each window the provider sent). Threshold dots:
    /// green < 60, amber 60–85, red > 85 (UI Spec §2.3).
    ///
    /// **The window names come from the reported width, not from constants** (D-58 — REV-59). The
    /// fixed `5-hour` / `Weekly` labels described a shape *no consumer Codex account this project
    /// has ever observed actually has*: `free` and `go` report one 43,200-minute primary and no
    /// secondary, so the card asserted a five-hour window on a 30-day one — wrong by a factor of
    /// 144 — over two `Weekly —` rows for a window that does not exist on the tier.
    ///
    /// This builder is **shared with Claude** (the STEP_85 lesson), so every change here gates on
    /// the snapshot's own width being present. Claude sets 18 000 s on every snapshot since
    /// REV-80 / D-101 (it populated the field for no account before that), so it takes the same
    /// `5-hour` label and — on its overnight not-started shape — the same `— (no window open)`
    /// reset row Codex does, over the always-show four rows it has always had (a live weekly must
    /// still render beside a not-started primary).
    /// `scopedLimits` are the model-scoped weekly sub-buckets rendered as first-class rows
    /// (STEP_134, D-94). **The caller decides whether to pass them**, because this builder is
    /// shared by both tabs and each provider treats its sub-buckets differently: `claude()` passes
    /// the snapshot's, `codex()` passes none and keeps rendering its own in the collapsed §2.7
    /// section, so no limit is ever drawn twice. Same reasoning as `accountQuotaNote`'s call-site
    /// gate — the shape test belongs where the shape is known (the STEP_85 lesson).
    static func quotaRows(state: AppState, snapshot: QuotaSnapshot?, now: Date,
                          scopedLimits: [AdditionalRateLimit] = []) -> [LabeledRow] {
        var rows: [LabeledRow] = []
        let grain = windowGrain(seconds: snapshot?.primaryWindowSeconds)
        let primary = snapshot?.primaryUsedPct
        // Values are **remaining** (REV-77 / D-97) — bare numbers equal to the hero digit for
        // digit; the label carries the word. The dot still reads utilization: the thresholds
        // never moved. Every percentage row opens its card with the rule 8 bridge line.
        rows.append(LabeledRow(label: quotaRowLabel(grain: grain, tool: snapshot?.tool),
                               value: primary.map(Fmt.percentLeft) ?? "—",
                               dot: primary.map(Fmt.thresholdDot),
                               explanation: .primaryWindow,
                               explanationLive: primaryWindowLive(snapshot: snapshot, now: now),
                               explanationBridge: ExplanationRegistry.bridgeLine(utilization: primary)))
        // §2.3 (STEP_27): "Resets at" reads red in *any* warning state (amber or red tier)
        // when the reset is more than 90 minutes away — the far reset is what makes the
        // warning dangerous, in every warning, not only bad-timing.
        let inWarning = [.amber, .red].contains(dot(for: state))
        let resetFar = snapshot?.primaryResetsAt
            .map { $0.timeIntervalSince(now) > 90 * 60 } ?? false
        let resetDot: StatusDot? = inWarning && resetFar ? .red : nil
        // An unanchored window has no reset because none has started (REV-57 §6). A bare `—` reads
        // as *missing data* — the same complaint the not-applicable `Weekly` rows attract — so this
        // one case says why. Gated on the snapshot's own verdict, never on "has a percent but no
        // reset": that shape also describes a Claude window whose `resets_at` failed to parse
        // (`ClaudeAccountAdapter.parseReset`), which is a real open window we simply cannot date,
        // and `quotaRows` is shared by both tools.
        let noWindow = snapshot?.primaryWindowIsUnanchored == true
        // The row changes form with the *distance*, not the width: a wall-clock time is meaningless
        // a month out, so in the D-59 day band it becomes `Resets in  30 days · Sep 10`. The
        // absolute date is what the user cross-checks against OpenAI's own menu — and what keeps
        // "Monthly" honest for a window that rolls from first use, since `Sep 10` is visibly not a
        // month boundary. Below the band the row is untouched (`Resets at  10:12 pm · 1h 52m`).
        let dayBand = noWindow
            ? nil : snapshot?.primaryResetsAt.flatMap { reset in
                Fmt.daysLong(reset, from: now).map { "\($0) · \(Fmt.monthDay(reset))" }
            }
        rows.append(LabeledRow(label: dayBand == nil ? "Resets at" : "Resets in",
                               value: dayBand ?? (noWindow
                                   ? "— (no window open)"
                                   : resetShort(snapshot?.primaryResetsAt, now: now)),
                               dot: resetDot, explanation: .reset))
        // D-58 clause 3 — **render the windows you were sent.** A window the provider did not send
        // produces no rows, never a dash: `Weekly resets —` reads as *we failed to fetch this*
        // where the truth is *this tier has no such window* (spike R5). Encoded as a fact about the
        // payload, never as "free and Go have one window" — if a secondary appears on `go` next
        // month it renders with no code change. Without a known grain we cannot tell an absent
        // window from an unread one, so the always-show pair stands (STEP_32).
        let hasSecondary = snapshot?.secondaryUsedPct != nil || snapshot?.secondaryResetsAt != nil
        guard grain == nil || hasSecondary else { return rows }
        let secondary = snapshot?.secondaryUsedPct
        // E-02's live line answers the one question the two rows never do out loud: *which* window
        // is the tighter one — unless the weekly has a tier to report, in which case it reports
        // that instead (REV-96 §3.9). The variant comes from the same assessment the row's suffix
        // and the header strip were drawn from, so the card and the verdict cannot name different
        // drivers (Baseline §19).
        rows.append(LabeledRow(label: "Weekly left", value: secondary.map(Fmt.percentLeft) ?? "—",
                               dot: secondary.map(Fmt.thresholdDot),
                               explanation: .secondaryWindow,
                               explanationLive: ExplanationRegistry.liveLine(
                                   .secondaryWindow,
                                   variant: secondaryLiveVariant(state: state, snapshot: snapshot,
                                                                  now: now),
                                   tool: snapshot?.tool ?? .claude,
                                   values: ["left": primary.map { Fmt.percentNumber(Fmt.remaining($0)) },
                                            "wkLeft": secondary.map { Fmt.percentNumber(Fmt.remaining($0)) },
                                            "grain": grain ?? "5-hour"],
                                   missing: .noSecondary),
                               explanationBridge: ExplanationRegistry.bridgeLine(utilization: secondary)))
        // Model-scoped weekly limits sit directly under the all-models weekly figure — the
        // grouping claude.ai's own Usage page uses, and the one that lets the two percentages be
        // compared at a glance (STEP_134/D-94). Same thresholds as the row above: a scoped limit
        // is a weekly limit, and two weekly rows that coloured by different rules would be a
        // puzzle. **Rendered only when the provider sent one** (D-58 clause 3) — a `—` here would
        // read as a fetch failure where the truth is that this account has no scoped limit; the
        // STEP_32 always-show rule governs the four rows it already covers, not this one.
        //
        // E-22 is the key STEP_134 deferred ("pending an E-number"): the card names the comparison
        // the row exists to make — the higher of the two weekly percentages is the binding one.
        for limit in scopedLimits {
            guard let name = limit.name ?? limit.id else { continue }
            rows.append(LabeledRow(label: "\(name) left",
                                   value: limit.usedPercent.map(Fmt.percentLeft) ?? "—",
                                   dot: limit.usedPercent.map(Fmt.thresholdDot),
                                   explanation: .scopedLimit,
                                   explanationBridge: ExplanationRegistry.bridgeLine(
                                       utilization: limit.usedPercent)))
        }
        rows.append(LabeledRow(label: "Weekly resets",
                               value: snapshot?.secondaryResetsAt.map(Fmt.monthDay) ?? "—",
                               explanation: .weeklyReset))
        // A scoped limit's own reset row, only when it is a *different* deadline. Live, the scoped
        // and all-models resets land within a second of each other (12:59:59.577098 vs
        // .577548 on 2026-08-22), so the row is normally absent and `Weekly resets` speaks for
        // both — one element, one fact. The test is `resetJitterTolerance`, the constant that
        // already defines when two readings of a reset are the same boundary; a bare equality
        // check would print a duplicate row over a sub-second difference.
        for limit in scopedLimits {
            guard let name = limit.name ?? limit.id, let reset = limit.resetsAt else { continue }
            let weekly = snapshot?.secondaryResetsAt
            let differs = weekly.map {
                abs(reset.timeIntervalSince($0)) > QuotaSnapshot.resetJitterTolerance
            } ?? true
            guard differs else { continue }
            // No `explanation:` — this row has never been drawn on a real account, and a card for
            // a shape nobody has seen would be designing for a corner case (E-22's spec note).
            rows.append(LabeledRow(label: "\(name) resets", value: Fmt.monthDay(reset)))
        }
        return rows
    }


    /// E-07's live line: the subtraction the concept text only describes, with the user's own
    /// numbers — the flagship of REV-75/D-89.
    ///
    /// **Dropped whenever the window's unattributed slice rounds above zero** (user ruling,
    /// 2026-08-22). The sentence reads "the account says [total]% used, this Mac explains
    /// ≈[local]%, so ≈[off]% came from elsewhere" — a *subtraction* — and the three shares
    /// reconcile to the total only once the residual is gone (REV-56/D-52: the residual is the
    /// span the app was quit for, never guessed into either bucket). Printing all three anyway
    /// would put arithmetic on screen that the reader can check and find short, which is the one
    /// thing a card in the verdict tier must not do (§5.2 rule 7). Concept text alone is the
    /// honest render, and rule 4 already says a dropped line leaves no trace.
    static func offMachineLive(_ split: WindowAttribution?, tool: Tool) -> ExplanationLive {
        guard let split, split.hasUsage else { return .dropped(.noAttribution) }
        guard Int(split.unattributedPct.rounded()) == 0 else { return .dropped(.noAttribution) }
        guard Int(split.offMachinePct.rounded()) > 0 else {
            // The row reads "none this window" — its own variant, not a drop.
            return ExplanationRegistry.liveLine(.offMachine, variant: .none, tool: tool,
                                                missing: .noAttribution)
        }
        return ExplanationRegistry.liveLine(
            .offMachine, variant: .live, tool: tool,
            values: ["total": Fmt.percentNumber(split.totalUsedPct),
                     "local": Fmt.percentNumber(split.localPct),
                     "off": Fmt.percentNumber(split.offMachinePct)],
            missing: .noAttribution)
    }

    /// The monthly-layout burn pill (REV-47 §2.2) — **break-even anchored**, so it is
    /// unit-agnostic: `r = liveRate ÷ (remaining ÷ hours-to-reset)`, where 1.0 is exactly the
    /// rate that exhausts the budget at the reset. A nil rate is *unknown*, not calm: pill and
    /// dot both go grey `—` (§11.2a). A measured rate that rounds away at display resolution is
    /// `none`. Red needs `r ≥ 1` **and** a consummation risk (already ≥ `monthlyRedUsedPct`, or
    /// exhausting within `monthlyPillRedHours`) — a hot rate early in a big budget is amber.
    /// The pill (now) and the §2.3 Pace row (cycle average) may disagree; that is by design.
    static func monthlyBurnTier(_ monthly: MonthlyLimit, ratePerHour: Double?,
                                now: Date) -> (String, StatusDot) {
        guard let rate = ratePerHour else { return ("—", .grey) }
        if roundsToZero(rate) { return ("none", .green) }
        let remaining = monthly.limitAmount - monthly.usedAmount
        guard remaining > 0 else { return ("high", .red) }   // meter spent: any rate is over
        let hoursToReset = monthly.resetsAt.timeIntervalSince(now) / 3600
        guard hoursToReset > 0 else { return ("—", .grey) }  // no cycle left to normalize against
        let ratio = rate / (remaining / hoursToReset)
        let label = ratio < monthlyPillBreakEvenLow ? "low"
            : (ratio < monthlyPillBreakEvenHigh ? "mid" : "high")
        guard ratio >= monthlyPillBreakEvenHigh else { return (label, .green) }
        let exhaustionHours = remaining / rate
        let red = (monthly.usedPercentExact ?? 0) >= monthlyRedUsedPct
            || exhaustionHours < monthlyPillRedHours
        return (label, red ? .red : .amber)
    }

    /// Appends the always-on freshness age stamp (§2.2a, D-21) to an already-built source-tag base
    /// whose confidence is inline (burn `Total: … (exact)` / local `Source: … JSONL`). Amber past
    /// `PollBackoffPolicy.freshnessAmberAge` (two base ticks — one missed poll; D-112); no age
    /// while stale-kept (`asOf` nil) — the account tag already carries "as of".
    static func freshnessTag(base: String, asOf: Date?, now: Date) -> SourceTag {
        guard let asOf else { return SourceTag(base: base) }
        let age = max(0, now.timeIntervalSince(asOf))
        return SourceTag(base: base, age: Fmt.relativeAge(age), ageIsAmber: age >= PollBackoffPolicy.freshnessAmberAge)
    }
    // STEP_197 removed three helpers that lived here: `surfaceShareValue` (the §2.6 share
    // rows, gone with D-71/D-96), `localSourceRow` (the burn card's `Local source` line, gone
    // with D-67) and the private `workSplit` alias they shared. All three had been dead since
    // REV-92 deleted their surfaces. The daily local report now names the apps instead
    // (`DisplayFormatter+LocalActivity.surfaceRows`), and `SurfaceWorkSplit` is read directly.

    /// The §2.4 pill and its dot, banded against **this window's** even pace (REV-74/D-82 —
    /// STEP_123). `windowSeconds` is `QuotaSnapshot.primaryWindowLength`, i.e. the provider-reported
    /// width with the five-hour fallback, so an account that reports no width (every Claude account)
    /// keeps the STEP_27 numbers to the digit.
    static func burnTier(_ rate: Double, windowSeconds: TimeInterval) -> (String, StatusDot) {
        let t = burnTierThresholds(windowSeconds: windowSeconds)
        if rate < t.none { return ("none", .grey) }
        if rate < t.mid { return ("low", .green) }
        if rate < t.high { return ("mid", .amber) }
        return ("high", .red)
    }

    /// The three band edges in %/min for a window of `windowSeconds`. Kept separate from the tier
    /// itself so a test can compare them to the STEP_27 literals by exact equality.
    static func burnTierThresholds(windowSeconds: TimeInterval)
        -> (none: Double, mid: Double, high: Double) {
        let minutes = max(1, windowSeconds) / 60
        return (burnTierPaceMultiples.none * 100 / minutes,
                burnTierPaceMultiples.mid * 100 / minutes,
                burnTierPaceMultiples.high * 100 / minutes)
    }

    // MARK: Local session (UI Spec §2.5 Claude / §2.6 Codex)


    /// The recapped window's own accounting (UI Spec §2.5a, REV-56/D-52 — STEP_83): the exact
    /// total the section never named, decomposed into the three shares that sum back to it. Every
    /// value already exists on `WindowAttribution` — this is display work, no engine involved.
    ///
    /// **Points-of-quota, integer resolution.** REV-28 put the off-machine share in points so it
    /// tied to the header's 5-hour-used %; on this grain that header reads `—`, so the tie was
    /// severed and `Quota used` restores it — one stated denominator, one set of units. No decimal:
    /// the provider quantizes utilization to whole percent (§11.2a), so every figure here already
    /// carries ±1 point and must not look more exact than its input.
    ///
    /// **`none` is not `—`** (§11.2a): a measured zero says the app watched and nothing happened;
    /// `—` says the app cannot answer. `Not observed` — the app's own limitation, deliberately not
    /// a label on the user's usage — renders only when nonzero, and STEP_84 will resolve most of
    /// what it currently absorbs by attributing the leading slice through elimination.
    private static func windowAccountingRows(_ attr: WindowAttribution?) -> [LabeledRow] {
        func share(_ pct: Double?) -> String {
            guard let pct else { return "—" }
            let points = Int(pct.rounded())
            return points == 0 ? "none" : "≈\(points)% (est.)"
        }
        // `≥` when the app stopped watching before the window closed (REV-56 §4.1 — STEP_84):
        // the total is then the highest reading it happened to see, and the window may have ended
        // anywhere above it. One character, standard meaning — and it stops the block reading as a
        // closed sum. Rejected: `5% (last seen 3:57 pm)` (verbose in a 340pt card, and it invites
        // the reader to compute the gap) and a silent floor (a caveat living only in the source).
        var rows = [LabeledRow(
            label: "Quota used",
            value: attr.map { ($0.closeObserved ? "" : "≥") + Fmt.percent($0.totalUsedPct) } ?? "—")]
        rows.append(LabeledRow(label: "This machine", value: share(attr?.localPct)))
        rows.append(LabeledRow(label: "Elsewhere", value: share(attr?.offMachinePct)))
        if let attr, !roundsToZero(attr.unattributedPct) {
            rows.append(LabeledRow(label: "Not observed", value: share(attr.unattributedPct)))
        }
        return rows
    }

    /// One row per model, total tokens descending; provider prefix stripped for display,
    /// `nil` model → "unknown". Zero-token models are dropped. Subagent usage folds into its
    /// model's row (their JSONL carries the parent model). Per-model breakdown lives here only (§2.5a).
    private static func modelRows(_ totals: [SQLiteStore.ModelTokenTotals], tool: Tool) -> [LabeledRow] {
        totals
            .map { (label: modelDisplayName($0.model), total: modelTokenSum($0, tool: tool)) }
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }
            .map { LabeledRow(label: $0.label, value: Fmt.tokens($0.total)) }
    }

    /// Both rules live in `KvotarCore.DisplayedTokens` since STEP_109 so the History window
    /// shares them; these stay as thin wrappers so no call site moved.
    private static func modelTokenSum(_ t: SQLiteStore.ModelTokenTotals, tool: Tool) -> Int {
        DisplayedTokens.sum(t, tool: tool)
    }

    private static func totalTokens(_ totals: [SQLiteStore.ModelTokenTotals], tool: Tool) -> Int {
        DisplayedTokens.total(totals, tool: tool)
    }

    /// Display name for a model string — strip the `claude-` provider prefix (`claude-opus-4-8` →
    /// `opus-4-8`); `nil`/empty → "unknown"; anything without the prefix stays verbatim.
    static func modelDisplayName(_ model: String?) -> String {
        guard let model, !model.isEmpty else { return "unknown" }
        let prefix = "claude-"
        return model.hasPrefix(prefix) ? String(model.dropFirst(prefix.count)) : model
    }


    /// Codex Credits / spend (§2.4) — Enterprise only. STEP_27 completes the specced rows: Plan
    /// (display-mapped), Credit balance ("unavailable" when null — confirmed null in every D1
    /// capture, never fabricated), Spend control, Est. token value · today / · 30-day.
    /// `slimmed` (monthly layout, REV-38/D-34 §2.4 amendment): Plan + Spend control only — the
    /// quota story lives in the Monthly section, wallet credit balance ≠ the monthly user limit
    /// (conflating them was the pre-REV-38 confusion), and the est. rows stay in Local session.
    /// The Spend-control row gains its recovery time from the monthly `reset_at` when reached
    /// (R33-1 extension).
    static func codexCreditsSpend(snapshot: QuotaSnapshot?, attribution: LocalAttribution?,
                                  slimmed: Bool = false) -> CreditsSpendSection? {
        guard let snapshot, let plan = snapshot.planType, plan.lowercased() == "enterprise" else { return nil }
        var rows: [LabeledRow] = [LabeledRow(label: "Plan", value: planDisplayName(plan))]
        if slimmed {
            if let reached = snapshot.spendControlReached {
                let recovery = snapshot.monthlyLimit
                    .map { " · resets \(Fmt.monthDay($0.resetsAt))" } ?? ""
                rows.append(LabeledRow(label: "Spend control",
                                       value: reached ? "Limit reached\(recovery)"
                                                      : "Active · not reached",
                                       dot: reached ? .red : nil))
            }
            return CreditsSpendSection(rows: rows)
        }
        rows.append(LabeledRow(
            label: "Credit balance",
            value: snapshot.creditsBalance.map { "\(Fmt.dollarValue($0)) remaining" } ?? "unavailable"))
        if let reached = snapshot.spendControlReached {
            rows.append(LabeledRow(label: "Spend control",
                                   value: reached ? "Reached" : "Active · not reached",
                                   dot: reached ? .red : nil))
        }
        if let est = attribution?.estValue {
            rows.append(LabeledRow(label: "Est. token value · today",
                                   value: "\(Fmt.dollarValue(est.today)) est."))
            rows.append(LabeledRow(label: "Est. token value · 30-day",
                                   value: "\(Fmt.dollarValue(est.thirtyDay)) est."))
        }
        return CreditsSpendSection(rows: rows)
    }


    /// Display name for a project path — the trailing folder, e.g. `/a/b/kvotar` → `kvotar`.
    static func projectName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// The always-on Usage-credits card (UI Spec §2.4a, REV-29). Claude only; suppressed (`nil`)
    /// only when the account exposes **no** `extra_usage` object (Enterprise / no pay-as-you-go).
    /// Data-driven state model (§2.4a.1) × forecast-driven imminence, colours and rows per §2.4a.2.
    /// The card owns all credit dollars now (the D-08 header alert is retired). `monthly_limit` and
    /// prepaid `amount` are cents; `used_credits` is decimal dollars — never ÷100 the used side.
    /// §2.4a.2 — "Manage in Claude web ↗" opens the Claude usage settings (credits on/off, prepaid
    /// balance, spend limit). Read-only app: we only launch the page; the toggles live server-side.
    /// The `/new` prefix is what makes the `#settings/usage` fragment route to the Usage tab.
    static let manageCreditsURL = URL(string: "https://claude.ai/new#settings/usage")

    static func creditsCard(snapshot: QuotaSnapshot?, forecast: Forecast?,
                            pollAsOf: Date?, staleAsOf: Date?, now: Date) -> CreditsCardSection? {
        guard let extra = snapshot?.extraUsage else { return nil }   // absent ⇒ suppress card
        if extra.managedByOrganization {
            return orgManagedCreditsCard(extra, snapshot: snapshot, pollAsOf: pollAsOf,
                                         staleAsOf: staleAsOf, now: now)
        }
        let moneyState = MoneyModel.moneyState(snapshot: snapshot)
        let imminent = !extra.isEnabled
            && MoneyModel.isImminent(snapshot: snapshot, forecast: forecast, now: now)

        // Status row (always) — text + colour cue per §2.4a.2.
        let statusText: String
        let statusDot: StatusDot
        switch moneyState {
        case .armed:        statusText = "On · not charging";              statusDot = .neutral
        // The member's own cap is spent: on, and nothing left to charge (REV-102 §2.2).
        case .capReached:   statusText = "On · not charging";              statusDot = .neutral
        case .charging:     statusText = "On · charging";                  statusDot = .red
        case .lastObserved: statusText = "Off · was on earlier this window"; statusDot = .neutral
        case .noBackstop:   statusText = "Off";  statusDot = imminent ? .amber : .neutral
        case .blocked:      statusText = "Off";  statusDot = .neutral
        case .absent:       statusText = "Off";  statusDot = .neutral   // unreachable (guarded above)
        }

        var rows: [LabeledRow] = []
        // This month (cond: on OR last-observed) — "$X of $Y", red when charging.
        let used = extra.usedCredits ?? 0
        if extra.isEnabled || moneyState == .lastObserved {
            let value: String
            if moneyState == .lastObserved {
                value = "\(creditsUsed(used, extra)) (last observed)"
            } else {
                value = creditsUsedOfCap(used, extra)
            }
            rows.append(LabeledRow(label: "This month", value: value,
                                   dot: moneyState == .charging ? .red : nil))
        }
        // Auto-reload (cond: is_enabled OR a prepaid wallet is present, AND the prepaid call ok).
        if let prepaid = snapshot?.prepaid, extra.isEnabled || prepaid.amountCents != nil,
           let on = prepaid.autoReloadOn {
            rows.append(LabeledRow(label: "Auto-reload", value: on ? "On" : "Off",
                                   dot: on ? .amber : nil))
        }
        // Prepaid balance (cond: prepaid call ok AND amount > 0).
        if let cents = snapshot?.prepaid?.amountCents, cents > 0 {
            rows.append(LabeledRow(label: "Prepaid balance",
                                   value: prepaidBalance(cents: cents, snapshot: snapshot)))
        }

        // Sub-line (one, conditional): NO-BACKSTOP backstop sentence, or Off: [disabled_reason].
        var subLine: String?
        var subLineSeverity: HintSeverity?
        if moneyState == .noBackstop {
            if imminent, let eta = MoneyModel.etaTo100Minutes(snapshot: snapshot, forecast: forecast) {
                subLine = "Blocks in ~\(Fmt.durationHM(eta)) — usage credits are off"
                subLineSeverity = .warning
            } else if imminent {
                // Imminent via the ≥98% no-burn fallback — no eta number to state.
                subLine = "Hard-block at 100% — usage credits are off"
                subLineSeverity = .warning
            } else {
                subLine = "Hard-block at 100% — usage credits are off"
                subLineSeverity = .info
            }
        } else if !extra.isEnabled, let reason = extra.disabledReason, !reason.isEmpty {
            // Pass the raw string through — the enum is unconfirmed (P2-3), never switched on.
            subLine = "Off: \(reason)"
            subLineSeverity = .info
        }

        return CreditsCardSection(
            moneyState: moneyState,
            // E-12's live line says what the *user's* setting means for them, which the row's
            // bare `On` / `Off` does not: `off` names the stop at 100%, `on` names the balance the
            // work is paid from. Claude only — the Codex cells are `—`, so the template self-drops
            // there even though this card never renders on that tab (rule 4's mechanism, not a
            // second tool test).
            status: LabeledRow(label: "Usage credits", value: statusText, dot: statusDot,
                               explanation: .usageCredits,
                               explanationLive: ExplanationRegistry.liveLine(
                                   .usageCredits, variant: extra.isEnabled ? .on : .off,
                                   tool: snapshot?.tool ?? .claude,
                                   values: extra.isEnabled
                                       ? ["balance": snapshot?.prepaid?.amountCents
                                           .map { prepaidBalance(cents: $0, snapshot: snapshot) }]
                                       : [:],
                                   missing: .noBalance)),
            rows: rows, subLine: subLine, subLineSeverity: subLineSeverity,
            manageURL: manageCreditsURL,
            sourceTag: creditsSourceTag(prepaid: snapshot?.prepaid,
                                        pollAsOf: pollAsOf, staleAsOf: staleAsOf, now: now))
    }

    /// The card on a seat whose organization pays (Claude Team — REV-102 §2.3 / D-125, STEP_220).
    /// Same card, three differences: the title says who set it, the month's figure carries its
    /// reset, and there is no Manage link and no prepaid rows — the member can neither toggle nor
    /// top up. At the cap the status is **neutral**: on this seat a spent cap stops the extra
    /// charge, not the work (owner ruling; REV-102 §4 if the tester's reset says otherwise).
    private static func orgManagedCreditsCard(_ extra: ExtraUsage, snapshot: QuotaSnapshot?,
                                              pollAsOf: Date?, staleAsOf: Date?,
                                              now: Date) -> CreditsCardSection {
        let moneyState = MoneyModel.moneyState(snapshot: snapshot)
        // The `spend` payload carries no reset; the cycle is the calendar month UTC (§8.0.4).
        let resetsAt = MonthlyLimit.nextCalendarMonthStartUTC(after: now)
        let statusText: String
        let statusDot: StatusDot
        var subLine: String?
        switch moneyState {
        case .charging:
            statusText = "Charging now"; statusDot = .red
            subLine = "Paid by your organization at API rates."
        case .capReached:
            statusText = resetsAt.map { "Spent for \(creditsMonthName(endingAt: $0))" } ?? "Spent"
            statusDot = .neutral
            subLine = "You stop when a window runs out."
        case .armed:
            statusText = "On · not charging"; statusDot = .neutral
        default:
            // Never the raw `disabled_reason` here — that pass-through is the self-serve card's
            // (STEP_222): a member cannot act on the organization's reason string.
            statusText = "Off"; statusDot = .neutral
        }
        // The switched-off shape sends no amounts and nothing is cached (STEP_222, owner ruling
        // 2026-09-21): the row states the reset alone rather than a fabricated `€0.00`.
        let amounts = extra.usedCredits == nil && extra.monthlyLimit == nil
            ? nil : creditsUsedOfCap(extra.usedCredits ?? 0, extra)
        let reset = resetsAt.map { "resets \(Fmt.monthDay($0))" }
        let month = LabeledRow(label: "This month",
                               value: [amounts, reset].compactMap { $0 }.joined(separator: " · "),
                               dot: moneyState == .charging ? .red : nil)
        return CreditsCardSection(
            title: "Usage credits · set by your organization",
            moneyState: moneyState,
            status: LabeledRow(label: "Usage credits", value: statusText, dot: statusDot,
                               explanation: .usageCredits,
                               explanationLive: ExplanationRegistry.liveLine(
                                   .usageCredits, variant: .orgManaged,
                                   tool: snapshot?.tool ?? .claude,
                                   values: ["limit": creditsCap(extra)], missing: .noBalance)),
            rows: [month], subLine: subLine, subLineSeverity: subLine == nil ? nil : .info,
            manageURL: nil,
            sourceTag: sourceTag(base: "Credits: Claude account", asOf: pollAsOf,
                                 staleAsOf: staleAsOf, now: now))
    }

    /// "September" — the month a cycle ending at `reset` belongs to, read in UTC like the reset.
    static func creditsMonthName(endingAt reset: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMMM"
        return f.string(from: reset.addingTimeInterval(-1))
    }

    /// §2.4a.4 mixed-provenance stamp: the `extra_usage` rows ride the quota poll; balance +
    /// auto-reload ride the second `/prepaid/credits` call and age independently. Dual stamp when
    /// the prepaid call succeeded, collapsing to the single Claude-account stamp when it did not.
    private static func creditsSourceTag(prepaid: PrepaidCredits?, pollAsOf: Date?,
                                         staleAsOf: Date?, now: Date) -> SourceTag {
        let credits = sourceTag(base: "Credits: Claude account", asOf: pollAsOf,
                                staleAsOf: staleAsOf, now: now)
        guard let prepaid, staleAsOf == nil else { return credits }
        // Append the prepaid leg's own age (it refreshes on a slower cadence than the quota poll).
        let age = prepaid.asOf.map { Fmt.relativeAge(max(0, now.timeIntervalSince($0))) }
        let balanceStamp = age.map { "Balance/reload: prepaid · \($0)" } ?? "Balance/reload: prepaid"
        let combined = "\(credits.base) · \(balanceStamp)"
        return SourceTag(base: combined, age: credits.age, ageIsAmber: credits.ageIsAmber)
    }

    /// Recommendation copy + hint severity shown only in a warning state (Baseline §15). Exact
    /// §2.6 (Claude) / §2.8 (Codex) templates as of STEP_27; each degrades gracefully when an
    /// input is missing (never fabricates a number). Never references polling mechanics.
    ///
    /// Claude over-quota follows the §7.1 three-case matrix: case 1 (credits accruing) overrides
    /// every warning state at util ≥ 100 — "you'll be blocked" copy is wrong while billing to
    /// credits; cases 2 (last observed) and 3 (hard block) render on the over-quota state.
    /// The smallest primary-surface rate (%/min) the multi-surface card prints (STEP_192): the
    /// least value `Fmt.oneDecimal` renders as something other than `0.0`. Below it the card is the
    /// two-surface sentence alone — no rate, and no pace sentence hanging off it.
    static let multiSurfaceMinNamedRate = 0.05

    static func recommendation(tool: Tool, state: AppState, snapshot: QuotaSnapshot?,
                               forecast: Forecast?, attribution: LocalAttribution?,
                               fastBurnDelta: Double?,
                               now: Date) -> (text: String, severity: HintSeverity)? {
        // **The reset a block quotes is the blocking limit's** (REV-96 §2.1 — STEP_195). The
        // five-hour reset frees nothing while a weekly holds, and quoting it told a reader
        // blocked for three days that new requests resume "in 226 min" under a header already
        // saying `resets Sep 12 · in 3d`. Outside a block the primary's reset is the subject of
        // every row here and is unchanged.
        let reset = snapshot?.blockEpisode?.limitResetsAt ?? snapshot?.primaryResetsAt
        let resetMinutes = reset.flatMap { $0 > now ? Int($0.timeIntervalSince(now) / 60) : nil }
        // D-63: the hint strings follow D-59's magnitude rule — whole days at ≥ 48h. `Fmt.daysLong`
        // is D-59's single source of magnitude, so this line and the §2.3 reset row can never
        // disagree about one reset. Long form rather than the compact `29d`: these are sentences,
        // not slots (§2.6/§2.8).
        let resetLong = reset.flatMap { Fmt.daysLong($0, from: now) }
        // Below 48h the block banners speak in hours — `7h 24m`, `48m`, the form every other
        // surface uses (STEP_223). The minute form was written when only a five-hour window could
        // reach these sentences; once the banner quoted the **blocking** limit's reset (STEP_195)
        // a weekly block read "resets in 444 min". The at-risk sentence keeps its spelled-out
        // "58 minutes".
        let resetPhrase = resetLong
            ?? reset.flatMap { Fmt.countdown(to: $0, from: now, spaced: true) }
        let resetPhraseSpelled = resetLong ?? resetMinutes.map { "\($0) minutes" }
        let resetsClause = resetPhrase.map { " Window resets in \($0)." } ?? ""
        // The banner names the limit the episode says is blocking (STEP_223). A primary is called
        // five-hour only where it is one — Codex plans report 7- and 30-day primaries — and with
        // no episode to read it stays "the window".
        let blockedLimitName: String = {
            switch snapshot?.blockEpisode?.limit {
            case .secondary: return "the weekly"
            case .monthly: return "the monthly limit"
            case .primary:
                let grain = windowGrain(seconds: snapshot?.primaryWindowSeconds)
                    ?? (tool == .claude ? "5-hour" : nil)
                return grain == "5-hour" ? "the 5-hour window" : "the window"
            case nil: return "the window"
            }
        }()
        let extra = snapshot?.extraUsage

        // REV-38 E5 — monthly near-cap (§2.8 Codex / §2.6 Claude, REV-40), recommendation-only:
        // no new notification kind, no state change; fires in the monthly layout below the
        // reached rank. The deep link rides the display state's `recommendationURL` (same
        // `monthlyNearCap` predicate). The affordance is per-tool: Codex self-serves a limit
        // increase; the Claude Enterprise seat cannot (`can_toggle`/`can_purchase_credits`
        // false) — its copy is admin-facing and its link is Manage-in-Claude-web.
        if let monthly = monthlyNearCap(snapshot), let used = monthly.usedPercentExact {
            switch tool {
            case .codex:
                let days = Fmt.dayScale(max(0, monthly.resetsAt.timeIntervalSince(now) / 86_400))
                return ("Monthly workspace limit nearly reached — \(Fmt.percentLeft(used)) left with "
                    + "\(days) until reset. You can request a limit increase from ChatGPT "
                    + "settings → Usage.", .warning)
            case .claude:
                // §2.6 v5.6 template — admin-facing, no self-service framing.
                return ("Monthly spend limit nearly reached — ask your workspace admin. "
                    + "Resets \(Fmt.monthDay(monthly.resetsAt)).", .warning)
            }
        }

        // Claude case 1 — credits active and accruing (§2.6 v4.1). `charging` is the one test the
        // card and the glyph read (REV-102 §2.2): either window spent, and a spent cap is not it.
        if tool == .claude, let extra, MoneyModel.moneyState(snapshot: snapshot) == .charging {
            let amounts = creditAmountsClause(extra) ?? "Charges are accruing"
            return ("Operating on usage credits. \(amounts) · still accruing.\(resetsClause)",
                    .warning)
        }

        switch state {
        case .atRisk:
            var text = "Finish your current task and pause new prompts."
            if let reset, let phrase = resetPhraseSpelled {
                text += " Quota resets at \(Fmt.clock(reset)) — \(phrase) away."
            }
            return (text, .danger)
        case .badTiming:
            let pct = snapshot?.primaryUsedPct.map { "\(Fmt.percentLeft($0)) left" } ?? "your current usage"
            // D-63: `Fmt.countdown` yields the compact `29d` above 48h, which would put "29 days"
            // and "29d" in the same popover for one reset. Prefer the spelled-out day form here.
            let until = resetLong ?? reset.flatMap { Fmt.countdown(to: $0, from: now, spaced: true) }
            let untilClause = until.map { " and \($0) until reset" } ?? ""
            // Copy-only, 2026-08-28 dogfood: the "Finish your current task and avoid starting
            // anything heavy" tail is gone — the header verdict and the At-risk card already say it.
            return ("With \(pct)\(untilClause), you risk hitting the limit before your quota "
                + "refreshes.", .danger)
        case .overQuota:
            if tool == .codex {
                return ("New Codex requests are blocked until \(blockedLimitName) resets"
                    + (resetPhrase.map { " in \($0)" } ?? "") + ".", .danger)
            }
            // Claude case 2 — credits used earlier this window, toggle now off (§7.1).
            if let extra, !extra.isEnabled, let used = extra.usedCredits, used > 0 {
                let amounts = creditsUsedOfCap(used, extra)
                return ("Credits were used earlier this window (\(amounts) · last observed). "
                    + "New requests are now blocked.\(resetsClause)", .danger)
            }
            // Claude case 3 — hard block, no credits.
            return ("New requests are blocked until \(blockedLimitName) resets"
                + (resetPhrase.map { " in \($0)" } ?? "")
                + ". Any task currently running can complete.", .danger)
        case .spendControl:
            // §2.8 REV-38: in the monthly layout the copy names the recovery — the block
            // finally has a real reset date (`individual_limit.reset_at`).
            if tool == .codex, let monthly = monthlyLayoutLimit(snapshot) {
                let days = Fmt.dayScale(max(0, monthly.resetsAt.timeIntervalSince(now) / 86_400))
                return ("Monthly workspace limit reached. New requests are blocked until the "
                    + "limit resets \(Fmt.monthDay(monthly.resetsAt)) — \(days) away.", .danger)
            }
            // Claude reaches Spend control only on a seat with no windows (Enterprise — REV-102:
            // a windowed seat's spend meter is usage credits, never a limit). The Codex copy below
            // names the wrong tool, so this arm says the fact and the one action a seat has.
            if tool == .claude, let monthly = snapshot?.monthlyLimit {
                return ("Monthly spend limit reached — ask your workspace admin. Resets "
                    + "\(Fmt.monthDay(monthly.resetsAt)).", .danger)
            }
            return ("Spend control limit reached. New Codex requests may be blocked until "
                + "credits are replenished.", .danger)
        case .fastBurnSpike:
            switch tool {
            case .claude:
                // "[N] subagents running on [model] are driving fast usage." — needs both.
                if let attribution, attribution.subagentCount > 0, let model = attribution.model {
                    let n = attribution.subagentCount
                    return ("\(n) subagent\(n == 1 ? "" : "s") running on \(model) are driving "
                        + "fast usage. If unexpected, check Claude Code for a runaway tool loop.",
                        .warning)
                }
                return ("Usage is climbing quickly. If unexpected, check Claude Code for a "
                    + "runaway tool loop.", .warning)
            case .codex:
                // D-119 (STEP_189): the figure is named by what produced it — the rise between
                // two consecutive polls — not by a cadence the poll clock no longer keeps.
                let jump = fastBurnDelta.map {
                    "Usage jumped +\(Fmt.percent($0)) since the last check."
                }
                    ?? "Usage is climbing quickly."
                let pace = forecast?.runwayMinutes
                    .map { " At this pace the window exhausts in ~\(Fmt.runwayLong($0, from: now))." }
                    ?? ""
                return ("\(jump) If unexpected, check Codex for a runaway loop.\(pace)", .warning)
            }
        case .offMachineBurn:
            switch tool {
            case .claude:
                return ("Claude Code is idle on this machine. Usage may be from Claude Desktop "
                    + "here, claude.ai, mobile, or Claude Code on another machine.", .warning)
            case .codex:
                var text = "Codex is idle on all local surfaces. Usage is likely from another "
                    + "machine or Codex Web."
                if let pct = snapshot?.primaryUsedPct, let reset {
                    text += " \(Fmt.percentLeft(pct)) left · resets at \(Fmt.clock(reset))."
                }
                return (text, .warning)
            }
        case .multiSurface:
            // "[A] and [B] are both active. [Primary] is the primary driver at ~X% / min."
            // Helper buckets are filtered out before anything is named (D-96) — a helper is not a
            // surface, so "Subagent · Meitner and Desktop are both active" was two errors in one
            // sentence. Since D-99 the *state* is filtered too: `PollCoordinator` counts the same
            // split. STEP_192 (2026-09-13 dogfood: "Desktop and Unknown are both active. Desktop
            // is the primary driver at ~0.0% / min") narrows it three ways: only surfaces *burning
            // now* are named (`activeSurfaces`, the 8-minute idle gap — the whole-window split had
            // an idle-since-16:24 Desktop as "primary" on the weekly hero; `Unknown` is never in
            // that list); every active surface is named — two "are both active", three-plus "are
            // all active" — so the unnamed fallback below is unreachable from state and survives
            // only as a guard; and the rate + pace sentences render only when the primary's rate
            // survives one-decimal rounding — a weekly window's %/min is ~0.01, and "primary
            // driver at 0.0% / min" is a contradiction.
            let active = SurfaceWorkSplit(attribution?.surfaceShares ?? [])
                .activeSurfaces(now: now)
            guard active.count >= 2 else {
                return ("Multiple Codex surfaces are active simultaneously.", .warning)
            }
            let names = active.map(\.label)
            var text = active.count == 2
                ? "\(names[0]) and \(names[1]) are both active."
                : "\(names.dropLast().joined(separator: ", ")) and \(names.last!) are all active."
            if let rate = forecast?.burnRatePerMin,
               rate * active[0].fraction >= multiSurfaceMinNamedRate {
                let primaryRate = Fmt.oneDecimal(rate * active[0].fraction)
                text += " \(active[0].label) is the primary driver at ~\(primaryRate)% / min."
                if let runway = forecast?.runwayMinutes {
                    text += " At this combined pace the window exhausts in "
                        + "~\(Fmt.runwayLong(runway, from: now))."
                }
            }
            return (text, .warning)
        default:
            return nil
        }
    }

    /// "$X.XX of $Y.YY used this month" when both credit amounts are known; the used amount
    /// alone when the limit is missing; nil with no amounts.
    private static func creditAmountsClause(_ extra: ExtraUsage) -> String? {
        guard let used = extra.usedCredits else { return nil }
        guard extra.monthlyLimit != nil else { return creditsUsed(used, extra) }
        return "\(creditsUsedOfCap(used, extra)) used this month"
    }

    // MARK: Usage-credits money (REV-102 §2.5 — STEP_219)
    //
    // The credits' own currency and exponent, read in one place so the used side and the cap
    // cannot be formatted by two rules. `used_credits` is major units, `monthly_limit` and the
    // prepaid `amount` minor units (§7.1); no currency ⇒ USD, no exponent ⇒ 2.

    static func creditsUsed(_ used: Decimal, _ extra: ExtraUsage) -> String {
        Fmt.money(major: used, exponent: extra.currencyExponent ?? 2, currency: extra.currency)
    }

    /// "[used] of [cap]", or the used amount alone where the account reports no cap.
    static func creditsUsedOfCap(_ used: Decimal, _ extra: ExtraUsage) -> String {
        guard let cap = extra.monthlyLimit else { return creditsUsed(used, extra) }
        let capText = Fmt.money(minor: Double(cap), exponent: extra.currencyExponent ?? 2,
                                currency: extra.currency)
        return "\(creditsUsed(used, extra)) of \(capText)"
    }

    /// The cap alone, or nil where the account reports none.
    static func creditsCap(_ extra: ExtraUsage) -> String? {
        extra.monthlyLimit.map { Fmt.money(minor: Double($0), exponent: extra.currencyExponent ?? 2,
                                           currency: extra.currency) }
    }

    /// The wallet states its own currency; the credits' is the fallback for an older payload.
    static func prepaidBalance(cents: Int, snapshot: QuotaSnapshot?) -> String {
        Fmt.money(minor: Double(cents), exponent: 2,
                  currency: snapshot?.prepaid?.currency ?? snapshot?.extraUsage?.currency)
    }

    // MARK: Reset formatting

    /// "9:47 pm · 1h 52m" for the account-quota "Resets at" row (spaced per §2.3, STEP_27).
    static func resetShort(_ reset: Date?, now: Date) -> String {
        guard let reset else { return "—" }
        let clock = Fmt.clock(reset)
        if let cd = Fmt.countdown(to: reset, from: now, spaced: true) { return "\(clock) · \(cd)" }
        return clock
    }
}

/// §2.4 label thresholds as **multiples of the window's even pace** — 100 % ÷ window minutes, the
/// rate that spends the window exactly at its reset (`burnTierPaceMultiples`, UI Spec §5).
///
/// STEP_27 wrote these as fixed numbers — "none" below 0.1 %/min ("Idle / between prompts") — and
/// they were right, for the only window width the app then had. *(The split bar's existence stopped
/// depending on the rate at the same time; it is driven by cumulative window usage.)*
///
/// **REV-74/D-82 (STEP_123): the fixed numbers were always the five-hour reading of these
/// multiples** — 0.1 ÷ 0.333 = 0.3, 1 ÷ 0.333 = 3, 3 ÷ 0.333 = 9 — and nothing said so, so a weekly
/// window got five-hour bands: 0.1 %/min there is six percent an hour, the week's allowance in
/// seventeen hours, and the pill called it "none" beside a displayed `0.1% / min`. Evaluated in the
/// order `multiple × 100 ÷ windowMinutes` because that ordering returns *exactly* 0.1 / 1.0 / 3.0 at
/// 18 000 s (pinned by `testFiveHourThresholdsAreExactlyTheSTEP27Numbers`), so no five-hour string
/// can move. Dogfood-tune the weekly `high` multiple only (REV-74 §5).
private let burnTierPaceMultiples = (none: 0.3, mid: 3.0, high: 9.0)

/// The `% / hr` boundary (`burnUnitHourFrom`, UI Spec §5 — REV-74/D-83): one day, the same
/// long-window boundary the REV-65 pace hero keys on. At or above it the burn card and the verdict
/// anatomy render the rate per hour; below it, per minute as before.
let burnUnitHourFrom: TimeInterval = 86_400

/// Pure value formatting helpers.
///
/// `public` for the few members the App target's notification presenter needs (`daysLong`,
/// `percent`, `monthDay` — STEP_194): the presenter owns §4 copy
/// and did its own countdown arithmetic, which is how D-59's day band reached the popover but not
/// the alerts (STEP_99). Everything else here stays internal — this is a seam for the shared
/// magnitude rule, not an invitation to format popover strings from outside the module.
public enum Fmt {
    /// `public` since STEP_194 — event 9's body states what is left of a long limit, and the
    /// alert and the popover must round the same figure the same way.
    public static func percent(_ value: Double) -> String { percentNumber(value) + "%" }

    /// What is left of a quota whose utilization is `util`: `100 − util`, floored at 0 (REV-77 /
    /// D-97). **The only place the screen subtracts** — every displayed quota percentage (menu
    /// bar, gauge, hero, bar, Account-quota rows) goes through it; every *read* of utilization
    /// (`thresholdDot`, the state ranks, pace, forecast) keeps the raw figure.
    static func remaining(_ util: Double) -> Double { max(0, 100 - util) }

    /// `remaining` as the displayed string — `42%` for a utilization of 58, `0%` for anything at
    /// or past 100. Rates, deltas, shares and the monthly money row keep calling `percent`.
    static func percentLeft(_ util: Double) -> String { percent(remaining(util)) }

    /// The bare rounded number `percent` prints, sign stripped. The §5.2 live templates write
    /// their own sign after the placeholder — `[used]% used`, `≈[off]%` — so filling one with
    /// `percent` renders `40%%`. Defined here, with `percent` calling *it*, so a row and the card
    /// that explains the row can never round the same figure differently (STEP_130).
    static func percentNumber(_ value: Double) -> String { "\(Int(value.rounded()))" }

    static func oneDecimal(_ value: Double) -> String { String(format: "%.1f", value) }

    static func thresholdDot(_ pct: Double) -> StatusDot {
        if pct > 85 { return .red }
        if pct >= 60 { return .amber }
        return .green
    }

    /// Est. token value is a plain dollar amount (not cents), e.g. `8.2` → "$8.20". **Always
    /// USD** — it is Kvotar's estimate from the public USD price list, not a provider-reported
    /// amount, so it never goes through `money` (REV-102 §2.5).
    static func dollarValue(_ value: Double) -> String { String(format: "$%.2f", value) }

    /// Compact tokens/min: `350` → "350", `3300` → "3.3k" (prototype burn-line style).
    static func tokRate(_ value: Double) -> String {
        value >= 1_000 ? String(format: "%.1fk", value / 1_000) : "\(Int(value.rounded()))"
    }

    /// Compact token count for the §2.5a card (REV-44): `980_000` → "980k", `1_200_000` → "1.2M",
    /// `1_680_000_000` → "1.68B", `540` → "540". `k` rounds to whole thousands; `M` keeps one
    /// decimal; `B` keeps two (STEP_109 — the History window's 30-day Claude total on the dogfood
    /// machine is 1.68B, which used to render as "1681.4M").
    static func tokens(_ count: Int) -> String {
        let n = Double(count)
        if n >= 1_000_000_000 { return String(format: "%.2fB", n / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", n / 1_000) }
        return "\(count)"
    }

    /// Lowercased 12-hour clock, e.g. "9:47 pm". POSIX locale so am/pm is stable across regions.
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f.string(from: date).lowercased()
    }

    /// §2.2a clock token with the D-29 cross-midnight clause: a clock landing on the next local
    /// calendar day appends ` tomorrow` ("stops ~12:41 am tomorrow"). One formatter for the
    /// stops clock and the reset clock so the grammar cannot diverge; calendar-day comparison in
    /// the user's local timezone. Past clocks never gain the suffix (an expired window degrades
    /// before it could render one).
    static func clockDay(_ date: Date, from now: Date) -> String {
        // Inside the D-59 day band a clock time is not the fact the user needs, and "tomorrow" is
        // simply false: this rendered `6:47 pm tomorrow` for the live `go` account's reset **30
        // days** out, because every future date that is not today used to earn the word. Name the
        // date instead, which is also what the §2.3 row shows for the same reset. Claude is
        // untouched — its resets are always under 48 hours, so it never reaches this branch, and
        // "tomorrow" keeps meaning tomorrow wherever it still appears (STEP_87, REV-59).
        if daysUntil(date, from: now) != nil { return monthDay(date) }
        let base = clock(date)
        guard date > now, !Calendar.current.isDate(date, inSameDayAs: now) else { return base }
        return "\(base) tomorrow"
    }

    /// The past-facing twin of `clockDay` in **`clockDay`'s own suffix grammar** — `11:29 pm`,
    /// `11:29 pm yesterday` — for a clock that sits inside a sentence (E-01's live line: "*This
    /// one started at [start]…*"). `clockDayPast` below is the *prefix* form the §2.8 line has
    /// used since STEP_112, and "started at yesterday 11:29 pm" is not English; the two grammars
    /// exist because the two sites are a standalone stamp and a clause. Anything older than
    /// yesterday reads as a date — unreachable on a sub-day window, and a guess otherwise.
    static func clockPastInSentence(_ date: Date, from now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return clock(date) }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
           cal.isDate(date, inSameDayAs: yesterday) {
            return "\(clock(date)) yesterday"
        }
        return monthDay(date)
    }

    /// The past-facing twin of `clockDay` for the "Since you last looked" line (§2.8 — STEP_112):
    /// `3:12 pm` on the same local day, `yesterday 11:40 pm` on the previous one, `Aug 14, 11:40 pm`
    /// beyond. `clockDay` is future-facing (` tomorrow`, the D-59 day band) and never earns a
    /// past-day word, so a sibling rather than a change to it — its callers and pins stand.
    static func clockDayPast(_ date: Date, from now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return clock(date) }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
           cal.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(clock(date))"
        }
        return "\(monthDay(date)), \(clock(date))"
    }

    /// "Jun 12" for weekly-reset dates.
    /// `public` since STEP_194 — the block and nearly-spent bodies name a weekly or monthly
    /// reset, which is a date at this magnitude (D-59), in the popover's own wording.
    public static func monthDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    /// "Aug 1, 02:00" — the monthly reset instant, local time (Part 2 §2.1 Resets row). 24-hour:
    /// the value is a calendar-month boundary, and 02:00 reads as one where "2:00 am" reads as
    /// an appointment.
    static func monthDayTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: date)
    }

    /// Full local reset instant for accessibility/help while the visible row stays compact.
    static func fullResetDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return f.string(from: date)
    }

    /// Whole-credit amount with grouping: `2376.91…` → "2,377" (Part 2 §2.1 Used row / §2.2a
    /// pace token — OpenAI's UI shows whole credits; fractions are transport noise here).
    static func credits(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.locale = Locale(identifier: "en_US_POSIX")
        // POSIX defines no grouping — set it explicitly so "5000" renders "5,000" everywhere.
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }

    /// The currencies that have a symbol of their own (REV-102 §2.5 / D-125 — STEP_219; owner
    /// ruling 2026-09-21: these four and no more). Everything else prints its ISO code, so a
    /// `$` never stands for the wrong dollar. A `nil` code is USD — the provider sent none.
    static func currencySymbol(_ code: String?) -> String? {
        switch isoCode(code) {
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY": return "¥"
        default: return nil
        }
    }

    /// Providers are not consistent about case (`usd` has been seen beside `USD`).
    private static func isoCode(_ code: String?) -> String { (code ?? "USD").uppercased() }

    /// The §1.6 money glyph is the account's currency symbol; a currency without one keeps `$`.
    static func moneyGlyphSymbol(_ code: String?) -> String { currencySymbol(code) ?? "$" }

    /// Every provider-reported amount renders here, in the provider's currency, **symbol first**
    /// and never converted (REV-102 §2.5): `6916`@2 EUR → "€69.16". A currency with no symbol
    /// of its own takes the ISO-code form ("69.16 CHF"). Fraction digits follow the exponent;
    /// grouping as `credits`. Minor units scaled by `10^exponent` — the `spend` money objects
    /// (Baseline §8.0.4), `extra_usage.monthly_limit` and the prepaid `amount` (§7.1).
    public static func money(minor: Double, exponent: Int, currency: String?) -> String {
        money(value: minor / pow(10, Double(max(0, exponent))), exponent: exponent,
              currency: currency)
    }

    /// The same, for an amount already in major units — `extra_usage.used_credits` is a decimal
    /// (`3.20` → "$3.20", §7.1 / OQ#1; STEP_27 fixed the cents misreading that showed "$0.03").
    public static func money(major: Decimal, exponent: Int, currency: String?) -> String {
        money(value: NSDecimalNumber(decimal: major).doubleValue, exponent: exponent,
              currency: currency)
    }

    private static func money(value: Double, exponent: Int, currency: String?) -> String {
        let digits = max(0, exponent)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        let text = f.string(from: NSNumber(value: value))
            ?? String(format: "%.\(digits)f", value)
        if let symbol = currencySymbol(currency) { return "\(symbol)\(text)" }
        return "\(text) \(isoCode(currency))"
    }

    /// Day-granularity slot value (E8, locked P1-15): whole days at ≥ 48h ("17d"), whole hours
    /// below ("31h") — month-scale precision never claims minutes.
    static func dayScale(_ days: Double) -> String {
        days >= 2 ? "\(Int(days.rounded()))d" : "\(Int((days * 24).rounded()))h"
    }

    /// "1h38m" / "43m" from a minutes value (rounded). No tilde — the runway verdict owns the
    /// "~" and adds it exactly once per token (§2.2a; avoids the prototype's `~~38m` bug).
    static func durationHM(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        let h = m / 60
        let mm = m % 60
        return h > 0 ? "\(h)h\(String(format: "%02d", mm))m" : "\(mm)m"
    }

    /// Compact relative age for a freshness stamp (§2.2a, D-21): "12s ago" (< 60s), "4m ago"
    /// (< 60m), "2h ago" beyond. The caller owns the amber threshold (2 min).
    static func relativeAge(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s ago" }
        let m = s / 60
        if m < 60 { return "\(m)m ago" }
        return "\(m / 60)h ago"
    }

    /// "1h52m" / "58m" until `date`; `nil` once the target is in the past. `spaced: true` gives
    /// the popover form "1h 52m" (§2.3); the compact default is the menu-bar form (§1.1).
    /// Whole days until `date`, **rounding up** — `nil` below the 48-hour day band. D-59's single
    /// source of magnitude, so the compact `30d` slot and the spelled-out `30 days` row can never
    /// disagree about the same reset.
    ///
    /// The boundary is 48 hours rather than 24 deliberately: `1d` is ambiguous between 24 and 47
    /// hours, while `31h` is unambiguous and no wider. Rounding is **up** because a countdown must
    /// never promise relief sooner than it arrives, whether the user is rationing or blocked.
    static func daysUntil(_ date: Date, from now: Date) -> Int? {
        let total = date.timeIntervalSince(now)
        guard total >= 48 * 3600 else { return nil }
        return Int(ceil(total / 86_400))
    }

    /// "30 days" — the spelled-out day form for the §2.3 reset row and the header subtitle, where
    /// the compact `30d` of the menu-bar slot would read as a typo rather than a duration.
    public static func daysLong(_ date: Date, from now: Date) -> String? {
        daysUntil(date, from: now).map { "\($0) days" }
    }

    /// D-63: a *runway* projection ("the window exhausts in ~…") in the same magnitude band as a
    /// reset countdown — spelled-out days at ≥ 48h, the existing minute form below. Projecting the
    /// minutes onto a date reuses `daysLong`/`daysUntil` rather than restating D-59's 48-hour
    /// boundary and round-up rule, so a runway and a reset can never disagree about a duration.
    /// No tilde — the call site owns the "~" and adds it exactly once (see `durationHM`).
    static func runwayLong(_ minutes: Double, from now: Date) -> String {
        daysLong(now.addingTimeInterval(minutes * 60), from: now) ?? "\(Int(minutes.rounded())) min"
    }

    /// A **measured, past** span — how long a limit block locked you out (STEP_120): `7m`,
    /// `3h 25m`, `7d`. Sibling of `countdown`, not a variant of it, for two reasons that both bite:
    /// `countdown` measures to a future instant and returns `nil` once it has passed, and it
    /// *truncates* minutes, which renders a 405-second lockout as `6m` where the corpus says 7.
    /// The 48-hour day band is D-59's, reused rather than restated, so a lockout and a reset
    /// countdown can never disagree about the magnitude of the same duration.
    static func span(seconds: Int) -> String {
        guard seconds > 0 else { return "0m" }
        if seconds >= 48 * 3600 { return "\(Int((Double(seconds) / 86_400).rounded()))d" }
        let minutes = Int((Double(seconds) / 60).rounded())
        let h = minutes / 60
        guard h > 0 else { return "\(minutes)m" }
        // A whole number of hours drops the minute term: `1h`, never `1h 0m`.
        return minutes % 60 == 0 ? "\(h)h" : "\(h)h \(minutes % 60)m"
    }

    /// A long limit's reset inside the **five-second reminder** (REV-97 §2.7 — STEP_198):
    /// `4d`, `48h`, `59m`. The day band is D-59's, unchanged and reused rather than restated, so
    /// a reminder and a reset countdown can never disagree about a span of two days or more;
    /// below it the hours are whole and **rounded up**, on the same never-promise-relief-early
    /// rule `daysUntil` follows. Minutes appear only under one hour.
    ///
    /// **Confined to the reminder by rule.** REV-96 §5 item 6 refused a second duration grammar
    /// because two forms for one span can contradict each other; this one cannot, because it
    /// applies only below D-59's band and rounds the same direction. What it buys is width: the
    /// widest reminder costs 2.0 pt (9 pt rows) / 2.5 pt (single tool) over today's widest
    /// string, where the full `↻47h59m` form would cost 19 / 23 pt. The steady phase and the
    /// §2.5 held block both keep `countdown` below, minutes and all.
    ///
    /// **Dormant since STEP_203** (REV-98 §2.4 / §3.6, owner ruling 2026-09-15). Variant D's
    /// headline is provider, limit and remaining percent — the reset moved to the popover — so
    /// this form has no caller. It is kept rather than deleted: the rule it encodes is still the
    /// right one if a long limit's reset ever returns to the bar, and re-deriving it would mean
    /// re-arguing D-59's band a third time. Nothing renders it today.
    static func compactReset(to date: Date, from now: Date) -> String? {
        let total = date.timeIntervalSince(now)
        guard total > 0 else { return nil }
        if let days = daysUntil(date, from: now) { return "\(days)d" }
        if total >= 3_600 { return "\(Int(ceil(total / 3_600)))h" }
        return "\(Int(ceil(total / 60)))m"
    }

    static func countdown(to date: Date, from now: Date, spaced: Bool = false) -> String? {
        let total = Int(date.timeIntervalSince(now))
        guard total > 0 else { return nil }
        // D-59 (REV-59): the unit follows the distance, not the tool — which is why 30 days used
        // to render `719h59m`, the clue that first told the 2026-07-31 spike the window was not
        // five hours. This **generalizes E8**, which already locked "whole days ≥ 48h" for the
        // Enterprise monthly slot; it does not invent a rule. Below the band the arithmetic is
        // untouched, so no Claude string moves: every Claude reset it renders is sub-day.
        if let days = daysUntil(date, from: now) { return "\(days)d" }
        let minutes = total / 60
        let h = minutes / 60
        let m = minutes % 60
        guard h > 0 else { return "\(m)m" }
        return spaced ? "\(h)h \(m)m" : "\(h)h\(String(format: "%02d", m))m"
    }
}
