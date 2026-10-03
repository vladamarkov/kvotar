import Foundation
import KvotarCore

// STEP_176 — REV-92 / D-114, Baseline §15.2: the selection, the Other Limits rows and the two
// header facts. Pure functions over the snapshot, the §13 state (with its §13.4 hold), the
// primary-series forecast, freshness and an injected clock. No new threshold, no new state machine,
// no notification: the state ranks the primary window and Weekly-elevated as they always have, and
// the only line applied to a window the engine does not rank — a model window — is the existing
// weekly one.

extension DisplayFormatter {

    /// The §13 states that are warnings *about the primary window* — ranks 4–9. The two
    /// long-limit ranks are deliberately absent: rank 5b and rank 10 are warnings about the
    /// weekly or the monthly, and letting either claim the hero would put a five-hour number
    /// under a sentence about the week.
    static let primaryWarningStates: Set<AppState> = [
        .elevated, .atRisk, .badTiming, .fastBurnSpike, .offMachineBurn, .multiSurface,
    ]

    /// The line a **model allowance** is promoted at (Baseline §15.2). It used to read
    /// `StateEngine.weeklyElevatedUtil`, borrowing the weekly's rank-10 gate; since STEP_194 that
    /// gate is gone and this reads its own symbol, pinned at the same 85 %. Deliberately **not**
    /// the new `longLimitNearlySpentPct` — a model window is neither a secondary window nor a
    /// monthly pool, so REV-96 does not tier it, and following the borrow to 90 % would silently
    /// stop a model allowance warning between 85 and 90.
    static var promotionLineUsedPct: Double { StateEngine.modelWindowWarnLinePct }

    // MARK: The long limits (REV-96 §2.2/§2.4, §3.7 — STEP_194)

    /// `day 4 of 7` — where a period is in its own calendar. One derivation, read by the row meta
    /// and by the verdict anatomy (Baseline §19), so the two can never disagree about which day
    /// of the week it is. `nil` on a period under a day wide, which has no days to count.
    static func periodDayIndex(elapsedPct: Double, periodSeconds: Int) -> (day: Int, of: Int)? {
        let days = Int((Double(periodSeconds) / 86_400).rounded())
        guard days >= 2 else { return nil }
        let clamped = min(100, max(0, elapsedPct))
        let day = min(days, Int(floor(clamped / 100 * Double(days))) + 1)
        return (day, days)
    }

    /// The tier word a long-limit row's value ends with (UI Spec §2.3 per REV-96 §3.7).
    /// A monthly pool is *reached*, not *spent* — you do not spend a budget someone else set.
    ///
    /// **The amber rung is named for its consequence** (REV-98 §2.5(b) — STEP_201). `ahead of
    /// pace` was the one rung of the ladder whose plain-English sense inverted its meaning:
    /// painted amber beside a ⚠ it asked the reader to learn a private vocabulary before the
    /// warning parsed. The other four words are unchanged — only the one that read as good news
    /// moves, and the *rank* keeps its name (Baseline §13, STEP_200: renaming a state is a
    /// migration-shaped change for a copy problem).
    static func longLimitSuffix(_ assessment: LongLimitAssessment) -> String {
        let monthly = assessment.limit == .monthly
        switch assessment.tier {
        case .onPace: return "on pace"
        case .aheadOfPace: return "runs out early"
        case .nearlySpent: return monthly ? "nearly reached" : "nearly spent"
        case .spent: return monthly ? "reached" : "spent"
        }
    }

    /// The period a long limit is measured against, as the strip's sentence says it —
    /// `won't last the week` / `won't last the month`. It follows `longLimitName`, not the
    /// reported width: a Codex secondary window is named `Weekly` whatever seconds the provider
    /// states, and one surface must not call a period by two names.
    static func longLimitPeriodWord(_ limit: BlockEpisode.Limit) -> String {
        switch limit {
        case .secondary: return "week"
        case .monthly: return "month"
        case .primary: return "window"
        }
    }

    /// The dot a **tiered** row wears (REV-98 §2.5(a) — STEP_201). One derivation behind the dot,
    /// the value's ink, the row's words and the §2.2 strip, so a limit can no longer be green in
    /// the list and amber in the sentence eight lines above it — which is exactly what shipped:
    /// a weekly reading `● 48 % · ahead of pace` in green under an amber strip about that limit,
    /// because the dot came from `Fmt.thresholdDot` and everything else came from the tier.
    ///
    /// `fallback` is what the row wore before tiers existed — the threshold dot on a percentage
    /// window, the REV-38 forecast dot on a monthly meter — and it is taken in exactly two cases:
    /// a limit with **no assessment** (unanchored, or reset-less), and a **stale** reading, whose
    /// tier is already withheld from the row's words for the D-35 reason.
    ///
    /// **Model allowances are not tiered and keep the threshold dot.** REV-96 tiers a secondary
    /// window and a monthly pool and nothing else, so the section knowingly runs two colour
    /// rules; §2.5(a) states that rather than hiding it.
    static func tieredCue(_ assessment: LongLimitAssessment?, stale: Bool,
                          fallback: StatusDot) -> StatusDot {
        guard !stale, let tier = assessment?.tier else { return fallback }
        switch tier {
        case .onPace: return .green
        case .aheadOfPace: return .amber
        case .nearlySpent, .spent: return .red
        }
    }

    /// How a strip and a row name the limit they are about: `Weekly`, `Monthly spend` (Claude),
    /// `Monthly usage` (Codex). The two monthly forms mirror the section names the candidates
    /// already carry (`Monthly spend limit` / `Monthly usage limit`) — REV-96 §3.7 writes only
    /// the Claude one, because the mockup has no Codex monthly strip.
    static func longLimitName(_ limit: BlockEpisode.Limit, tool: Tool) -> String {
        switch limit {
        case .secondary: return "Weekly"
        case .monthly: return tool == .claude ? "Monthly spend" : "Monthly usage"
        case .primary: return "5-hour"
        }
    }

    // MARK: Selection (Baseline §15.2 order)

    /// Selects the account limit the header describes. `stale` is the §9.3 stale path (past-TTL
    /// or launch restore): statuses are withheld there except the known-block exception, and the
    /// hero keeps the primary identity so the D-33 unknown form renders exactly as today.
    static func selectLimit(tool: Tool, state: AppState, snapshot rawSnapshot: QuotaSnapshot?,
                            forecast: Forecast?, staleAsOf: Date? = nil,
                            now: Date) -> AccountLimitSelection {
        guard let raw = rawSnapshot else { return .empty }
        let snapshot = raw.degradingExpiredWindows(now: now)
        let stale = staleAsOf != nil
        let blocked = state.isHardBlock
        let freshness: LimitAvailability = staleAsOf.map { .stale(asOf: $0) } ?? .fresh

        // --- 1. Candidates: only what the provider sent. A missing window creates no row. ---
        let primaryGrain = windowGrain(seconds: snapshot.primaryWindowSeconds)
        let primaryTitle = primaryGrain ?? (tool == .codex ? "Window" : "5-hour")
        let primary: AccountLimitCandidate? = {
            // The primary *slot* exists whenever the hero would otherwise be the `——` placeholder:
            // a null or expired primary keeps its identity (unknown value) so the stale/null gates
            // render as today — except on the monthly layout, which has always owned the hero.
            // Only the monthly layout has ever moved the hero off the primary slot when it is
            // empty (REV-38/D-34); every other empty primary — Codex both-null, Claude Enterprise
            // absent `five_hour` without a meter, the R33-7 expired window, the D-26 withdrawal
            // — keeps the slot and renders `——`. A Codex "weekly-only" account is not this case:
            // its weekly *is* the primary window. The secondary and the model windows then sit in
            // Other Limits with their live values, exactly as the §2.3 rows do today.
            let hasValue = snapshot.primaryUsedPct != nil
            if !hasValue, snapshot.monthlyLimit != nil { return nil }
            let unanchored = snapshot.primaryWindowIsUnanchored
            let (status, reason): (LimitStatus, LimitStatusReason)
            if blocked, hasValue {
                (status, reason) = (.critical, .blocked)
            } else if !hasValue {
                (status, reason) = (.unknown, stale ? .stale : .noValue)
            } else if stale {
                (status, reason) = (.unknown, .stale)
            } else if unanchored {
                (status, reason) = (.notStarted, .unanchored)
            } else if primaryWarningStates.contains(state) {
                (status, reason) = (dot(for: state) == .red ? .critical : .warning, .state(state))
            } else {
                (status, reason) = (.healthy, .state(state))
            }
            return AccountLimitCandidate(
                id: .primaryWindow, scope: .account, unit: .percent, name: primaryTitle,
                periodSeconds: snapshot.primaryWindowSeconds, periodLabel: primaryGrain,
                usedPercent: snapshot.primaryUsedPct, resetsAt: snapshot.primaryResetsAt,
                status: status, statusReason: reason,
                cue: snapshot.primaryUsedPct.map(Fmt.thresholdDot) ?? .grey,
                availability: unanchored ? .unanchored : freshness, source: snapshot.source)
        }()

        // The long limits, assessed once for this render (REV-96 §2.2 — STEP_194). The same
        // derivation `StateEngine` ranked on, so the row, the strip and the state colour cannot
        // disagree about the tier (Baseline §19).
        let secondaryTier = snapshot.longLimit(.secondary, now: now)
        let monthlyTier = snapshot.longLimit(.monthly, now: now)

        let secondary: AccountLimitCandidate? = snapshot.secondaryUsedPct.map { used in
            let (status, reason): (LimitStatus, LimitStatusReason)
            if stale, !blocked {
                (status, reason) = (.unknown, .stale)
            } else if let tier = secondaryTier?.tier {
                // Straight from the assessment — no second threshold here, which is what the old
                // `state == .weeklyElevated` fork amounted to once the weekly gained real tiers.
                switch tier {
                case .spent: (status, reason) = (.critical, .exhausted)
                case .nearlySpent: (status, reason) = (.critical, .state(.limitNearlySpent))
                case .aheadOfPace: (status, reason) = (.warning, .state(.limitAheadOfPace))
                case .onPace: (status, reason) = (.healthy, .state(state))
                }
            } else if used >= 100 {
                // No assessment (an unanchored or reset-less weekly) and still at the ceiling:
                // the position is a fact even where the calendar is not.
                (status, reason) = (.critical, .exhausted)
            } else {
                (status, reason) = (.healthy, .state(state))
            }
            return AccountLimitCandidate(
                id: .secondaryWindow, scope: .account, unit: .percent, name: "Weekly",
                periodSeconds: 7 * 86_400, periodLabel: "Weekly", usedPercent: used,
                resetsAt: snapshot.secondaryResetsAt, status: status, statusReason: reason,
                cue: tieredCue(secondaryTier, stale: stale, fallback: Fmt.thresholdDot(used)),
                availability: freshness, source: snapshot.source)
        }

        let monthly: AccountLimitCandidate? = snapshot.monthlyLimit.map { m in
            let unit: LimitUnit
            switch m.unit {
            case .credits: unit = .credits
            case .money(let currency, let exponent): unit = .money(currency: currency, exponent: exponent)
            }
            let name = tool == .claude ? "Monthly spend limit" : "Monthly usage limit"
            let forecastDot = monthlyForecastDot(snapshot: snapshot, monthly: m, now: now)
            let (status, reason): (LimitStatus, LimitStatusReason)
            if state == .spendControl || monthlyReached(snapshot: snapshot, monthly: m) {
                (status, reason) = (.critical, .blocked)
            } else if stale {
                (status, reason) = (.unknown, .stale)
            } else if let tier = monthlyTier?.tier, tier >= .nearlySpent {
                // The nearly-reached line is the assessment's, not the REV-38 forecast dot's —
                // the dot answers "will this run out early", the line answers "is it nearly gone".
                (status, reason) = (.critical, .state(.limitNearlySpent))
            } else if monthlyTier?.tier == .aheadOfPace {
                (status, reason) = (.warning, .state(.limitAheadOfPace))
            } else {
                switch forecastDot {
                case .red: (status, reason) = (.critical, .monthlyForecast)
                case .amber: (status, reason) = (.warning, .monthlyForecast)
                default: (status, reason) = (.healthy, .monthlyForecast)
                }
            }
            return AccountLimitCandidate(
                id: .monthly, scope: .account, unit: unit, name: name,
                periodSeconds: nil, periodLabel: "Monthly", usedPercent: m.usedPercentExact,
                usedAmount: m.usedAmount, limitAmount: m.limitAmount, resetsAt: m.resetsAt,
                status: status, statusReason: reason,
                // The tier owns the dot where there is one; the REV-38 forecast dot is the
                // fallback, not a second opinion — it answers "will this run out early", which
                // the amber tier now answers from the pace clock (REV-98 §2.5(a)).
                cue: tieredCue(monthlyTier, stale: stale, fallback: forecastDot),
                availability: freshness, source: snapshot.source)
        }

        var models: [AccountLimitCandidate] = []
        for limit in snapshot.additionalRateLimits {
            guard let handle = limit.id ?? limit.name else { continue }
            let display = limit.name ?? handle
            func window(_ w: AdditionalRateLimit.Window, slot: AccountLimitID.ModelWindowSlot)
                -> AccountLimitCandidate {
                let grain = windowGrain(seconds: w.windowSeconds)
                // A window with a width, 0 % and no anchor is the not-started shape — the adapter
                // dropped the placeholder deadline (REV-57 twin); Claude's scoped limits carry no
                // width and never read as unanchored.
                let unanchored = w.usedPercent == 0 && w.resetsAt == nil && w.windowSeconds != nil
                let (status, reason): (LimitStatus, LimitStatusReason)
                if stale, !blocked {
                    (status, reason) = (.unknown, .stale)
                } else if let used = w.usedPercent {
                    if used >= 100 { (status, reason) = (.critical, .exhausted) }
                    else if used >= promotionLineUsedPct {
                        (status, reason) = (.warning, .threshold(usedPercent: used, line: promotionLineUsedPct))
                    } else if unanchored { (status, reason) = (.notStarted, .unanchored) }
                    else { (status, reason) = (.healthy, .state(state)) }
                } else {
                    (status, reason) = (.unknown, .noValue)
                }
                return AccountLimitCandidate(
                    id: .modelWindow(allowance: handle, slot: slot), scope: .model(name: display),
                    unit: .percent, name: display, periodSeconds: w.windowSeconds,
                    periodLabel: grain, usedPercent: w.usedPercent, resetsAt: w.resetsAt,
                    status: status, statusReason: reason,
                    cue: w.usedPercent.map(Fmt.thresholdDot) ?? .grey,
                    availability: unanchored ? .unanchored : freshness, source: snapshot.source)
            }
            // A window is a candidate when it carries a value or a reset. A width alone is what
            // an *expired* window keeps (Core's per-window degradation, the plan's property) —
            // that is a window that ended, not one to list as unknown.
            func isCandidate(_ w: AdditionalRateLimit.Window) -> Bool {
                w.usedPercent != nil || w.resetsAt != nil
            }
            if isCandidate(limit.primary) { models.append(window(limit.primary, slot: .primary)) }
            if let secondary = limit.secondary, isCandidate(secondary) {
                models.append(window(secondary, slot: .secondary))
            }
        }

        let all = ([primary, secondary, monthly].compactMap { $0 } + models)
            .sorted { $0.id.sortKey < $1.id.sortKey }

        // --- 2–6. The hero. ---
        let hero: AccountLimitCandidate?
        let reason: HeroReason
        if blocked, let episode = snapshot.blockEpisode,
                  let blocking = candidate(for: episode.limit, primary: primary,
                                           secondary: secondary, monthly: monthly) {
            // **The limit that stops you takes the hero** (REV-96 §2.4 — STEP_194), read off the
            // same episode the engine classified from. Before this the hero was the primary in
            // Over quota and the monthly in Spend control, whatever was actually spent — so a
            // user stopped by a spent weekly saw an `81 % left` five-hour hero above a red
            // "Stopped" verdict, with the limit that had stopped them a row further down.
            hero = blocking
            reason = .blocked(limitIdentified: true)
        } else if state == .spendControl {
            // No episode to key on — a flag with no reset anywhere. Today's behaviour, unchanged:
            // spend control *is* the monthly block where a meter exists (REV-38 R33-1 extension);
            // otherwise the primary window carries it (the June-13 windowed block).
            hero = monthly ?? primary
            reason = .blocked(limitIdentified: monthly != nil)
        } else if state == .overQuota {
            // `rateLimitReached` is unscoped: the identity is rank 3's own reading (the primary),
            // and it is only *identified* when the primary itself reads 100 %.
            hero = primary ?? monthly
            reason = .blocked(limitIdentified: (snapshot.primaryUsedPct ?? 0) >= 100)
        } else if stale || state == .idleFallback || state == .nullWindow {
            // The gates are preserved: no promotion from frozen or absent data. The monthly
            // layout keeps its hero (D-35 lower bound); everything else keeps the primary slot.
            hero = primary ?? monthly ?? secondary
            reason = primary != nil ? .primaryDefault : (monthly != nil ? .monthlyDefault
                : (secondary != nil ? .secondaryDefault : .none))
        } else if primaryWarningStates.contains(state), let primary {
            hero = primary
            reason = .stateWarning
        // **The urgency promotion is retired here** (REV-96 §2.4 — STEP_194). The §15.2 step
        // that let a hot weekly take the header over a calm primary could only ever select the
        // weekly, and §2.4 answers the same question differently: the five-hour keeps the hero
        // while every limit is below 100 %, and a long limit in amber or red renders as a strip.
        // The one limit that still takes the header is the one that stopped you, above.
        } else if let primary {
            hero = primary
            reason = .primaryDefault
        } else if let monthly {
            // No primary window and a meter: the monthly layout (REV-38/D-34, Baseline §13 item
            // 12) — the meter is the hero, its verdict family, its menu-bar slot and its D-35
            // stale grammar all hang off it, and a populated window takes the hero *back* by the
            // same precedence, which is also why the meter is never in the promotion pool above.
            // REV-92 §2.2's "weekly normally the hero, monthly below it" on this shape is a
            // visible-composition change and is deferred to STEP_178, recorded in the task file.
            hero = monthly
            reason = .monthlyDefault
        } else if let secondary {
            hero = secondary
            reason = .secondaryDefault
        } else {
            hero = nil
            reason = .none
        }
        let others = all.filter { $0.id != hero?.id }
        return AccountLimitSelection(hero: hero, heroReason: reason, others: others)
    }

    /// Fresh model constraints that deserve a scoped warning while the account header remains
    /// account-wide. Stale, unknown and not-started allowances are never promoted into a warning.
    static func modelLimitWarnings(_ selection: AccountLimitSelection, now: Date)
        -> [ModelLimitWarning] {
        selection.others
            .filter { candidate in
                candidate.id.isModelWindow && candidate.status >= .warning
                    && candidate.availability == .fresh
            }
            .sorted { a, b in
                if a.status != b.status { return a.status > b.status }
                if (a.usedPercent ?? 0) != (b.usedPercent ?? 0) {
                    return (a.usedPercent ?? 0) > (b.usedPercent ?? 0)
                }
                return a.id.sortKey < b.id.sortKey
            }
            .map { candidate in
                let period = periodWord(candidate)
                let scope = [candidate.name, period].compactMap { $0 }.joined(separator: " ")
                let reset: String?
                let fullReset: String?
                if let at = candidate.resetsAt, at > now {
                    let long = (candidate.periodSeconds ?? 0) >= 86_400
                    reset = "resets " + (long ? Fmt.monthDay(at) : Fmt.clockDay(at, from: now))
                    fullReset = "Resets " + Fmt.fullResetDateTime(at)
                } else {
                    reset = "reset unknown"
                    fullReset = nil
                }
                let left = candidate.usedPercent.map { "\(Fmt.percentLeft($0)) left" } ?? "—"
                return ModelLimitWarning(
                    id: candidate.id,
                    headline: "⚠ \(scope) · \(left)",
                    detail: ["Only this model’s allowance", reset].compactMap { $0 }
                        .joined(separator: " · "),
                    status: candidate.status,
                    cue: candidate.status == .critical ? .red : .amber,
                    availability: candidate.availability,
                    resetAccessibilityText: fullReset,
                    explanationBridge: ExplanationRegistry.bridgeLine(
                        utilization: candidate.usedPercent))
            }
    }

    // MARK: The caption (UI Spec §REV92 vocabulary)

    /// The small caption under the hero number naming the selected limit: `5-hour quota left`,
    /// `Weekly quota left`, `Monthly quota left` (a percentage window), `Monthly spend limit left`
    /// / `Monthly usage limit left` (a meter), or `<model> · Weekly quota left`. `nil` with no hero.
    static func limitCaption(_ hero: AccountLimitCandidate?) -> String? {
        guard let hero else { return nil }
        switch hero.id {
        case .primaryWindow, .secondaryWindow:
            return "\(hero.periodLabel ?? hero.name) quota left"
        case .monthly:
            switch hero.unit {
            case .percent: return "Monthly quota left"
            default: return "\(hero.name) left"
            }
        case .modelWindow:
            return nil
        }
    }

    /// The period word a sentence calls a window by, for the model-hero verdict: `weekly`,
    /// `5-hour`; `nil` when the width is unknown (then the sentence says only "quota").
    static func periodWord(_ candidate: AccountLimitCandidate) -> String? {
        guard let label = candidate.periodLabel else { return nil }
        return label == "Weekly" ? "weekly" : (label == "Monthly" ? "monthly" : label)
    }

    // MARK: Other Limits (UI Spec §REV92)

    /// Every non-hero limit exactly once (UI Spec §REV92). Account limits come back as plain
    /// rows in the selection's own order; model allowances are **grouped by model name**, each
    /// keeping every window it reported — a weekly-only main allowance and a model's five-hour
    /// plus weekly windows coexist, and neither implies the other. `nil` when there is nothing
    /// to list: the section is suppressed, never rendered empty.
    static func otherLimitsSection(_ selection: AccountLimitSelection, tool: Tool,
                                   state: AppState = .healthy, snapshot: QuotaSnapshot? = nil,
                                   sourceTag: SourceTag? = nil, staleAsOf: Date? = nil,
                                   now: Date) -> OtherLimitsSection? {
        let accountCandidates = selection.others.filter { !$0.id.isModelWindow }
        // In a block every limit that is *not* the blocking one is unusable, whatever its own
        // number says (REV-96 §2.4). Withheld while stale: a frozen reading cannot be used to
        // tell a reader their quota is unreachable.
        let blockingLimit: BlockEpisode.Limit? =
            staleAsOf == nil && state.isHardBlock
            ? snapshot?.blockEpisode?.limit : nil
        // The row the §2.2 strip is about (REV-96 §2.4 — STEP_195), from **the strip builder
        // itself** rather than from a second copy of its five gates. One derivation, two readers
        // (Baseline §19) — the same shape `exhaustionRunwayMinutes` gives the menu bar and the
        // verdict, and `LongLimitSurfaceAgreementTests` pins that the strip and the highlight
        // name one limit. `nil` in a block: the blocking limit has the hero, so nothing in this
        // section is the thing being talked about.
        let highlighted = longLimitStrip(tool: tool, state: state, selection: selection,
                                         snapshot: snapshot, staleAsOf: staleAsOf,
                                         now: now)?.limitID
        let rows = accountCandidates.map {
            otherLimitRow($0, label: $0.name, tool: tool, state: state, snapshot: snapshot,
                          staleAsOf: staleAsOf, blockingLimit: blockingLimit,
                          highlighted: highlighted, now: now)
        }
        // One group per model, first-seen order — `selection.others` is already in `sortKey`
        // order, so the windows inside a group keep the primary-then-secondary sequence.
        var groupOrder: [String] = []
        var grouped: [String: [AccountLimitCandidate]] = [:]
        for candidate in selection.others {
            guard case .model(let name) = candidate.scope, candidate.id.isModelWindow else { continue }
            if grouped[name] == nil { groupOrder.append(name) }
            grouped[name, default: []].append(candidate)
        }
        let groups = groupOrder.map { name in
            let candidates = grouped[name] ?? []
            let multiple = candidates.count > 1
            let modelRows = candidates.enumerated().map { index, candidate in
                let label: String
                if multiple {
                    label = candidate.periodLabel
                        ?? "Window \(index + 1)"
                } else if let period = periodWord(candidate) {
                    label = "\(name) \(period)"
                } else {
                    label = name
                }
                return otherLimitRow(candidate, label: label, tool: tool, state: state,
                                     snapshot: snapshot, staleAsOf: staleAsOf,
                                     blockingLimit: blockingLimit, highlighted: highlighted,
                                     now: now)
            }
            return OtherLimitsSection.ModelGroup(name: name, showsHeading: multiple,
                                                  rows: modelRows)
        }
        let section = OtherLimitsSection(rows: rows, modelGroups: groups, sourceTag: sourceTag)
        return section.isEmpty ? nil : section
    }

    /// One `OTHER LIMITS` row. The reset line keeps the element its own row had on the retired
    /// Account-quota / Monthly sections (E-03 / E-14 / E-17), so nothing is retired by moving.
    private static func otherLimitRow(_ c: AccountLimitCandidate, label: String,
                                      tool: Tool, state: AppState,
                                      snapshot: QuotaSnapshot?, staleAsOf: Date?,
                                      blockingLimit: BlockEpisode.Limit? = nil,
                                      highlighted: AccountLimitID? = nil,
                                      now: Date) -> OtherLimitRow {
        // The limit this row is about, as the assessment knows it — `nil` on the primary window
        // and on model windows, neither of which REV-96 tiers.
        let longLimitID: BlockEpisode.Limit? = {
            switch c.id {
            case .secondaryWindow: return .secondary
            case .monthly: return .monthly
            case .primaryWindow: return .primary
            case .modelWindow: return nil
            }
        }()
        let blockedByOther = blockingLimit != nil && longLimitID != blockingLimit
        // A tier suffix is a claim about now, so a stale reading carries none (D-35), and a
        // blocked row says what blocks it rather than how its own period is going.
        let assessment = staleAsOf == nil && !blockedByOther
            ? longLimitID.flatMap { $0 == .primary ? nil : snapshot?.longLimit($0, now: now) }
            : nil
        var value = c.usedPercent.map(Fmt.percentLeft) ?? "—"
        // **The row the strip names drops its suffix** (REV-98 §2.5(c) — STEP_201). Exactly one
        // row per render is lifted onto the §2.3 chip *because* the strip states its verdict, so
        // repeating that verdict here says one thing twice and pays for it by wrapping the row to
        // two lines. Conditional for a reason: a **second** elevated limit gets no strip, and
        // dropping every suffix would silence the only verdict it has.
        if let assessment, highlighted != c.id { value += " · \(longLimitSuffix(assessment))" }
        if blockedByOther, let blockingLimit {
            value += " · blocked by the \(longLimitName(blockingLimit, tool: tool).lowercased())"
        }
        var detail: String?
        var meta: DetailLine?
        if c.id == .monthly, let used = c.usedAmount, let limit = c.limitAmount, c.unit != .percent {
            let unit: QuotaUnit = {
                if case .money(let cur, let exp) = c.unit { return .money(currency: cur, exponent: exp) }
                return .credits
            }()
            detail = "\(monthlyAmount(used, unit: unit)) of \(monthlyAmount(limit, unit: unit))"
        }
        if c.id == .monthly, let monthly = snapshot?.monthlyLimit {
            meta = monthlyMetaLine(monthly, tool: tool, snapshot: snapshot,
                                   staleAsOf: staleAsOf, now: now)
        }
        let reset: String?
        let resetAccessibilityText: String?
        if c.availability == .unanchored {
            reset = "not started"
            resetAccessibilityText = nil
        } else if let at = c.resetsAt, at > now {
            let long = (c.periodSeconds ?? 0) >= 86_400 || c.id == .monthly
            var text = "resets " + (long ? Fmt.monthDay(at) : Fmt.clockDay(at, from: now))
            // `· day 4 of 7` on the weekly (UI Spec §2.3 per REV-96 §3.7) — the pace clock's
            // other hand, spelled out. The monthly keeps its own pace clause on `meta` instead.
            if c.id == .secondaryWindow, let a = assessment,
               let index = periodDayIndex(elapsedPct: a.elapsedPct, periodSeconds: a.periodSeconds) {
                text += " · day \(index.day) of \(index.of)"
            }
            reset = text
            resetAccessibilityText = "Resets " + Fmt.fullResetDateTime(at)
        } else {
            reset = "reset unknown"
            resetAccessibilityText = nil
        }
        let element: ExplanationElement
        let resetElement: ExplanationElement?
        switch c.id {
        case .primaryWindow: element = .primaryWindow; resetElement = .reset
        case .secondaryWindow: element = .secondaryWindow; resetElement = .weeklyReset
        case .monthly: element = .monthlyUsed; resetElement = .monthlyReset
        case .modelWindow: element = .scopedLimit; resetElement = nil
        }
        return OtherLimitRow(
            id: c.id, label: label, value: value,
            // A blocked row drops its dot: a green cue beside quota that cannot be spent is a
            // claim about headroom the block has already withdrawn.
            cue: (c.usedPercent == nil || blockedByOther) ? nil : c.cue,
            detail: detail, reset: reset,
            resetAccessibilityText: resetAccessibilityText, meta: meta,
            explanation: element,
            explanationLive: otherLimitLive(c, tool: tool, state: state, snapshot: snapshot,
                                            now: now),
            explanationBridge: ExplanationRegistry.bridgeLine(utilization: c.usedPercent),
            resetExplanation: resetElement,
            isBlocked: blockedByOther,
            isHighlighted: highlighted == c.id)
    }

    /// The live line an `OTHER LIMITS` row carries — E-01's "this one started at …" on the
    /// primary window and E-02's tighter-of-the-two on the weekly, both the retired quota rows'
    /// own derivations. The monthly meter gained one in STEP_195: E-15's tier sentence, the same
    /// `longLimitCardLive` the weekly reads, so a monthly ahead of its month explains itself the
    /// way a weekly does (REV-96 §3.9). `nil` on model windows, which never had one, and on an
    /// on-pace or unassessable monthly — a card that says "nothing is wrong" is a card nobody
    /// opened for a reason.
    private static func otherLimitLive(_ c: AccountLimitCandidate, tool: Tool, state: AppState,
                                       snapshot: QuotaSnapshot?, now: Date) -> ExplanationLive? {
        switch c.id {
        case .primaryWindow:
            return primaryWindowLive(snapshot: snapshot, now: now)
        case .secondaryWindow:
            let primary = snapshot?.primaryUsedPct
            let secondary = snapshot?.secondaryUsedPct
            if let tiered = longLimitCardLive(snapshot?.longLimit(.secondary, now: now),
                                              tool: tool, snapshot: snapshot, now: now) {
                return tiered
            }
            return ExplanationRegistry.liveLine(
                .secondaryWindow,
                variant: secondaryLiveVariant(state: state, snapshot: snapshot, now: now),
                tool: tool,
                values: ["left": primary.map { Fmt.percentNumber(Fmt.remaining($0)) },
                         "wkLeft": secondary.map { Fmt.percentNumber(Fmt.remaining($0)) },
                         "grain": windowGrain(seconds: snapshot?.primaryWindowSeconds) ?? "5-hour"],
                missing: .noSecondary)
        case .monthly:
            return longLimitCardLive(snapshot?.longLimit(.monthly, now: now), tool: tool,
                                     snapshot: snapshot, now: now)
        case .modelWindow:
            return nil
        }
    }

    // MARK: The hero's detail lines (UI Spec §REV92 — the lines under the verdict)

    /// The muted lines between the verdict and the two header facts. **The reset appears exactly
    /// once on the header** (REV-66 / D-70): the D-58 rule that used to keep the caption and the
    /// verdict from both stating it is applied here unchanged, generalised from the primary
    /// window to whichever limit is the hero. A model hero gets none — its own verdict line 2
    /// already ends `· resets [date]` — and the monthly hero gets none either, its verdict line 1
    /// naming the date. What the monthly hero does get is the organisation-and-pace note, the one
    /// fact the retired Monthly section carried that nothing else on the header states.
    ///
    /// **A hero that is there because it is the block gets no reset line** (STEP_223). The line
    /// exists for the calm long-window verdict (`On pace`), which carries no reset; a block
    /// verdict always names its own, and the tester's build 16 block read `resets Sep 22` /
    /// `in 7h 24m` / `resets in 7h 24m` top to bottom.
    static func heroDetailLines(_ hero: AccountLimitCandidate?, heroReason: HeroReason, tool: Tool,
                                snapshot: QuotaSnapshot?, staleAsOf: Date?,
                                now: Date) -> [DetailLine] {
        guard let hero else { return [] }
        switch hero.id {
        case .monthly:
            guard let monthly = snapshot?.monthlyLimit else { return [] }
            // The verdict directly above already states the per-day amount and the used-of-limit
            // pair, so the hero's note carries the organisation and the pace *word* only — the
            // rate is stated once (REV-66 / D-70 applied to the meter).
            return [monthlyMetaLine(monthly, tool: tool, snapshot: snapshot,
                                    staleAsOf: staleAsOf, includeRate: false, now: now)]
        case .modelWindow:
            return []
        case .primaryWindow, .secondaryWindow:
            var lines: [DetailLine] = []
            var heroIsTheBlock = false
            if case .blocked = heroReason { heroIsTheBlock = true }
            if !heroIsTheBlock, let text = heroResetLine(hero, now: now) {
                let element: ExplanationElement = hero.id == .primaryWindow ? .reset : .weeklyReset
                lines.append(DetailLine(text: text, explanation: element))
            }
            if let spent = orgCreditsSpentLine(snapshot: snapshot, now: now) { lines.append(spent) }
            return lines
        }
    }

    /// `Usage credits spent for September — €70.00 cap, set by your organization` — the one muted
    /// line a block gains on a seat whose organization's credits are also gone (REV-102 §2.3,
    /// STEP_220). It answers "why am I stopped when credits are on" and nothing else; with no
    /// window spent the card alone carries the fact, so this line needs a block to hang under.
    /// The cap clause drops where the provider no longer states one (the switched-off shape,
    /// STEP_222).
    static func orgCreditsSpentLine(snapshot: QuotaSnapshot?, now: Date) -> DetailLine? {
        guard let extra = snapshot?.extraUsage, extra.managedByOrganization,
              snapshot?.blockEpisode != nil,
              MoneyModel.moneyState(snapshot: snapshot) == .capReached,
              let reset = MonthlyLimit.nextCalendarMonthStartUTC(after: now) else { return nil }
        let cap = creditsCap(extra).map { "\($0) cap, " } ?? ""
        return DetailLine(text: "Usage credits spent for \(creditsMonthName(endingAt: reset)) — "
                              + "\(cap)set by your organization")
    }

    /// `not started` / `resets in 6 days` / `resets in 14h 5m`, or `nil` where the verdict below
    /// already carries the reset — the D-58 band, unchanged: a window whose reset is inside the
    /// day band says it once, in the verdict.
    private static func heroResetLine(_ hero: AccountLimitCandidate, now: Date) -> String? {
        if hero.availability == .unanchored { return "not started" }
        guard let reset = hero.resetsAt else { return nil }
        if let days = Fmt.daysLong(reset, from: now) { return "resets in \(days)" }
        guard (hero.periodSeconds ?? 0) >= 86_400,
              let countdown = Fmt.countdown(to: reset, from: now, spaced: true) else { return nil }
        return "resets in \(countdown)"
    }

    /// The monthly meter's `[organisation note] · [pace]` line (E-16) — the one fact the retired
    /// Monthly section carried that neither the percentage nor the reset states. The pace clause
    /// is the retired `Pace` row's own value, unchanged; it is suspended while stale (D-35 — a
    /// pace projected from a frozen reading would be a confident claim) and absent under a day
    /// into the cycle, where there is no honest divisor yet.
    static func monthlyMetaLine(_ monthly: MonthlyLimit, tool: Tool, snapshot: QuotaSnapshot?,
                                staleAsOf: Date?, includeRate: Bool = true,
                                now: Date) -> DetailLine {
        let money: Bool = { if case .money = monthly.unit { return true }; return false }()
        var parts = [tool == .claude ? "Set by your organization"
                                     : "Workspace limit · shared across ChatGPT and Codex"]
        if monthlyReached(snapshot: snapshot, monthly: monthly) {
            parts.append(money ? "spend limit reached" : "spend control reached")
        } else if staleAsOf != nil {
            parts.append("pace suspended")
        } else if let pace = monthly.pacePerDay(now: now) {
            let rate = includeRate ? "\(paceToken(pace, unit: monthly.unit)) · " : ""
            if monthlyForecastGateMet(monthly, now: now), let runway = monthly.runwayDays(now: now) {
                let runsOut = Fmt.monthDay(now.addingTimeInterval(runway * 86_400))
                parts.append("\(rate)runs out ~\(runsOut)")
            } else {
                parts.append("\(rate)on pace")
            }
        }
        return DetailLine(text: parts.joined(separator: " · "), explanation: .monthlyPace)
    }

    // MARK: Header facts (Baseline §15.2 "scope of header facts")

    /// `Quota burn` and `Not seen locally`, each scoped to the limit it was measured on. The
    /// burn is the primary-series forecast (or the monthly meter's hourly rate on a monthly hero);
    /// the not-seen estimate is the window `Elsewhere` share (or the monthly split's amount).
    /// A hero that is neither the primary nor the monthly gets the primary's facts **labelled with
    /// the primary's interval** — never re-denominated — and no estimate at all when nothing was
    /// measured on that interval. Unknown is `—`; inapplicable is hidden.
    static func headerFacts(tool: Tool, selection: AccountLimitSelection, snapshot: QuotaSnapshot?,
                            forecast: Forecast?, offMachine: WindowAttribution?,
                            monthlyRatePerHour: Double?, monthlyAttribution: MonthlyAttribution?,
                            staleAsOf: Date?, retrospective: Bool,
                            now: Date) -> (burn: HeaderFact?, notSeen: HeaderFact?) {
        guard let hero = selection.hero else { return (nil, nil) }
        let stale = staleAsOf != nil

        // Monthly hero: the meter's own units (REV-47/D-42, REV-48/D-43).
        if hero.id == .monthly, let monthly = snapshot?.monthlyLimit {
            let burn: HeaderFact?
            if !stale, let monthlyRatePerHour {
                let burnValue = boundedHourlyToken(monthlyRatePerHour, unit: monthly.unit)
                let (pill, dot) = monthlyBurnTier(monthly, ratePerHour: monthlyRatePerHour, now: now)
                burn = HeaderFact(limitID: .monthly, label: "Quota burn",
                                  value: burnDisplayValue(tier: pill, rate: monthlyRatePerHour,
                                                         token: burnValue),
                                  dot: dot, intervalLabel: "Monthly", availability: .shown,
                                  explanation: .spendRate,
                                  explanationBody: ExplanationRegistry.burnFactCard(
                                      tool: tool, period: "Monthly", monthly: true),
                                  tier: pill)
            } else {
                burn = nil
            }
            let notSeen: HeaderFact?
            if let split = monthlyAttribution, !stale, split.offMachineAmount == 0 {
                notSeen = nil
            } else if let split = monthlyAttribution, !stale {
                let amount: String
                if split.offMachineAmount > 0, split.offMachineAmount.rounded() == 0 {
                    amount = boundedMonthlyAmount(unit: monthly.unit)
                } else {
                    amount = "≈\(monthlyAmount(split.offMachineAmount, unit: monthly.unit))"
                }
                notSeen = HeaderFact(limitID: .monthly, label: "Not seen locally",
                                     value: "\(amount) (est.)", dot: .grey,
                                     intervalLabel: "Monthly", availability: .shown,
                                     explanation: .monthlyOffMachine,
                                     explanationBody: ExplanationRegistry.notSeenLocallyFactCard(
                                        period: "monthly period"))
            } else {
                notSeen = HeaderFact(limitID: .monthly, label: "Not seen locally", value: "—",
                                     dot: .grey, intervalLabel: "Monthly", availability: .unknown,
                                     explanation: .monthlyOffMachine,
                                     explanationBody: ExplanationRegistry.notSeenLocallyFactCard(
                                        period: "monthly period"))
            }
            return (burn, notSeen)
        }

        // Windowed: both facts are the primary window's, whoever the hero is.
        guard let snapshot, snapshot.primaryUsedPct != nil else {
            return (nil, nil)
        }
        if snapshot.isLowAllowanceShape {
            let why = "low-allowance shape (D-60): no rate can be stated"
            return (HeaderFact(limitID: .primaryWindow, label: "Quota burn", value: "—", dot: .grey,
                               intervalLabel: nil, availability: .inapplicable(why),
                               explanation: .burn),
                    HeaderFact(limitID: .primaryWindow, label: "Not seen locally", value: "—", dot: .grey,
                               intervalLabel: nil, availability: .inapplicable(why),
                               explanation: .offMachine))
        }
        let interval = windowGrain(seconds: snapshot.primaryWindowSeconds)
        let heroIsPrimary = hero.id == .primaryWindow
        // Name the interval when it is not the hero's own; otherwise keep the compact label.
        let burnLabel = heroIsPrimary ? "Quota burn" : "Quota burn · \(interval ?? "Window")"
        let notSeenLabel = heroIsPrimary ? "Not seen locally"
            : "Not seen locally · \(interval?.lowercased() ?? "window")"
        let window = snapshot.primaryWindowLength
        let burn: HeaderFact?
        if !stale, let forecast, burnHasDisplayEvidence(forecast, window: window),
           let rate = forecast.burnRatePerMin {
            let (pill, dot) = burnTier(rate, windowSeconds: window)
            let perHour = window >= burnUnitHourFrom
            let displayRate = perHour ? rate * 60 : rate
            let token = rate > 0 && Fmt.oneDecimal(displayRate) == "0.0"
                ? "<0.1% / \(perHour ? "hr" : "min")"
                : "\(Fmt.oneDecimal(displayRate))% / \(perHour ? "hr" : "min")"
            burn = HeaderFact(limitID: .primaryWindow, label: burnLabel,
                              value: burnDisplayValue(tier: pill, rate: rate, token: token), dot: dot,
                              intervalLabel: interval, availability: .shown,
                              explanation: .burn,
                              explanationBody: ExplanationRegistry.burnFactCard(
                                tool: tool, period: interval ?? "quota period", monthly: false),
                              tier: pill)
        } else {
            burn = nil
        }
        let notSeen: HeaderFact
        if retrospective {
            notSeen = HeaderFact(limitID: .primaryWindow, label: notSeenLabel, value: "—", dot: .grey,
                                 intervalLabel: interval,
                                 availability: .inapplicable("retrospective grain (D-51): no live window"),
                                 explanation: .offMachine)
        } else if stale {
            notSeen = HeaderFact(limitID: .primaryWindow, label: notSeenLabel, value: "—", dot: .grey,
                                 intervalLabel: interval, availability: .unknown,
                                 explanation: .offMachine,
                                 explanationBody: ExplanationRegistry.notSeenLocallyFactCard(
                                    period: interval ?? "quota period"))
        } else if let wa = offMachine, wa.offMachinePct == 0 {
            return (burn, nil)
        } else if let wa = offMachine, wa.hasUsage {
            let pct = Int(wa.offMachinePct.rounded())
            notSeen = HeaderFact(limitID: .primaryWindow, label: notSeenLabel,
                                 value: pct == 0 ? "<1% (est.)" : "≈\(pct)% (est.)", dot: .grey,
                                 intervalLabel: interval, availability: .shown,
                                 explanation: .offMachine,
                                 explanationBody: ExplanationRegistry.notSeenLocallyFactCard(
                                    period: interval ?? "quota period"))
        } else if offMachine != nil {
            return (burn, nil)
        } else {
            notSeen = HeaderFact(limitID: .primaryWindow, label: notSeenLabel, value: "—", dot: .grey,
                                 intervalLabel: interval, availability: .unknown,
                                 explanation: .offMachine,
                                 explanationBody: ExplanationRegistry.notSeenLocallyFactCard(
                                    period: interval ?? "quota period"))
        }
        return (burn, notSeen)
    }

    /// Provider utilization is quantized to whole percentage points. A rate extrapolated from a
    /// single tick is arithmetic, not a trustworthy display value, so the header waits for both
    /// time and movement. Internal runway/state evaluation remains faster and can still detect a
    /// sharp depletion event; this gate governs only the user-facing rate.
    private static func burnHasDisplayEvidence(_ forecast: Forecast,
                                               window: TimeInterval) -> Bool {
        guard let rate = forecast.burnRatePerMin else { return false }
        // A resolved zero has already passed ForecastEngine's 10m/50m flat-span proof.
        if rate == 0 { return true }
        // Legacy fixtures may omit the span even though production forecasts never do when a
        // burn exists. Preserve their explicit full-rate value rather than inventing evidence.
        guard let span = forecast.burnSpanMinutes else { return !forecast.isEstimate }
        let observedDelta = rate * span
        if window >= ForecastEngine.longWindowFrom {
            return span >= 30 && observedDelta >= 3
        }
        return span >= 10 && observedDelta >= 2
    }

    /// Visible burn vocabulary. The canonical `none` tier remains stable for delta ordering, but
    /// no positive value ever exposes that legacy key.
    private static func burnDisplayValue(tier: String, rate: Double, token: String) -> String {
        guard rate > 0 else { return "No measurable burn" }
        let label: String
        switch tier {
        case "none": label = "Very low"
        case "low": label = "Low"
        case "mid": label = "Mid"
        case "high": label = "High"
        default: label = tier
        }
        return "\(label) · \(token)"
    }

    private static func boundedHourlyToken(_ rate: Double, unit: QuotaUnit) -> String {
        guard rate > 0, rate.rounded() == 0 else { return hourlyToken(rate, unit: unit) }
        switch unit {
        case .credits: return "<1 credit/hr"
        case .money: return "<\(monthlyAmount(1, unit: unit))/hr"
        }
    }

    // MARK: The header strip (UI Spec §2.2 / REV-96 §2.4, §3.7 — STEP_194)

    /// The one line under the verdict, or `nil` when there is nothing to say.
    ///
    /// Five gates, each removing a line that would be noise or a lie:
    /// **green** says nothing; **stale** says nothing (a tier read off a frozen snapshot would be
    /// a confident claim — the D-35 posture); a limit that is **already the hero** says nothing
    /// (the verdict above is about it); a **confirmed block** says nothing (the blocking limit
    /// took the hero, and the rows carry the rest); and the worst tier wins, so there is never a
    /// second strip competing with the first.
    static func longLimitStrip(tool: Tool, state: AppState, selection: AccountLimitSelection,
                               snapshot rawSnapshot: QuotaSnapshot?, staleAsOf: Date?,
                               now: Date) -> LongLimitStrip? {
        guard staleAsOf == nil, let raw = rawSnapshot else { return nil }
        let snapshot = raw.degradingExpiredWindows(now: now)

        // A confirmed block puts the blocking limit in the hero; nothing is left for a strip.
        guard !state.isHardBlock, let assessment = snapshot.longLimit(now: now),
              assessment.isElevated, assessment.tier != .spent else { return nil }
        let heroID: AccountLimitID = assessment.limit == .monthly ? .monthly : .secondaryWindow
        guard selection.hero?.id != heroID else { return nil }

        let name = longLimitName(assessment.limit, tool: tool)
        let left: String
        if assessment.limit == .monthly, let used = assessment.usedAmount,
           let total = assessment.limitAmount, let unit = assessment.unit {
            // **A money meter states money** (REV-98 §3.4 — STEP_201; the red monthly already
            // did). The remaining *amount* is what the reader acts on: "€3.90 left" answers "can
            // I finish this" where "8% left" does not. Percentage windows keep the percent.
            left = "\(monthlyAmount(Swift.max(0, total - used), unit: unit)) left"
        } else {
            left = "\(Fmt.percent(assessment.remainingPct)) left"
        }
        let span = Fmt.daysLong(assessment.resetsAt, from: now).map { " for \($0)" } ?? ""
        // The monthly's amber tail is its forecast date where REV-38's E6 gate is met — "runs out
        // ~Sep 19" is the fact that makes an early-running budget worth a line. Everywhere else
        // the reset is the tail, named by `monthDay` like every other long reset (D-59).
        var tail = "resets \(Fmt.monthDay(assessment.resetsAt))"
        var forecastTail = false
        if assessment.limit == .monthly, assessment.tier == .aheadOfPace,
           let monthly = snapshot.monthlyLimit, monthlyForecastGateMet(monthly, now: now),
           let runway = monthly.runwayDays(now: now) {
            tail = "runs out ~\(Fmt.monthDay(now.addingTimeInterval(runway * 86_400)))"
            forecastTail = true
        }
        // **The amber rung leads with its consequence** (REV-98 §2.5(b) — STEP_201): the strip
        // says what happens rather than naming the comparison that decided it. Where the monthly's
        // forecast tail already names the day it runs out, the lead reverts to the limit's name
        // alone — "won't last the month … runs out ~Sep 19" states one fact twice (§3.4).
        let lead: String
        if assessment.tier == .aheadOfPace {
            lead = forecastTail
                ? name
                : "\(name) won't last the \(longLimitPeriodWord(assessment.limit)) at this rate"
        } else {
            lead = "\(name) \(longLimitSuffix(assessment))"
        }
        return LongLimitStrip(
            limitID: heroID,
            text: "\(lead) — \(left)\(span), \(tail)",
            cue: assessment.tier == .aheadOfPace ? .amber : .red,
            explanation: assessment.limit == .monthly ? .monthlyUsed : .secondaryWindow,
            explanationLive: longLimitCardLive(assessment, tool: tool, snapshot: snapshot,
                                               now: now))
    }

    /// Which E-02 line the weekly row carries. A tiered weekly explains its own tier
    /// (`longLimitCardLive`); otherwise the card falls back to the D-88 "which window is tighter"
    /// pair, and the *weekly* is named as the tighter one exactly when it really is — the test
    /// `state == .weeklyElevated` used to stand in for that and no longer exists.
    static func secondaryLiveVariant(state: AppState, snapshot: QuotaSnapshot?,
                                     now: Date) -> LiveVariant {
        if let tier = snapshot?.longLimit(.secondary, now: now)?.tier {
            if tier == .aheadOfPace { return .aheadOfPace }
            if tier >= .nearlySpent { return .nearlySpent }
        }
        let primaryLeft = snapshot?.primaryUsedPct.map { 100 - $0 }
        let weeklyLeft = snapshot?.secondaryUsedPct.map { 100 - $0 }
        guard let primaryLeft, let weeklyLeft else { return .primaryTighter }
        return weeklyLeft < primaryLeft ? .weeklyTighter : .primaryTighter
    }

    /// The card line for a long limit's tier (E-02 / E-15 / E-16 per REV-96 §3.9). `nil` where
    /// the limit has no assessment or is on pace — there is no tier sentence to fill, and the
    /// card falls back to the concept text alone (rule 4).
    static func longLimitCardLive(_ assessment: LongLimitAssessment?, tool: Tool,
                                  snapshot: QuotaSnapshot?, now: Date) -> ExplanationLive? {
        guard let a = assessment else { return nil }
        let variant: LiveVariant
        switch a.tier {
        case .aheadOfPace: variant = .aheadOfPace
        case .nearlySpent, .spent: variant = .nearlySpent
        case .onPace: return nil
        }
        let element: ExplanationElement = a.limit == .monthly ? .monthlyUsed : .secondaryWindow
        let elapsed = min(100, max(0, a.elapsedPct))
        // What is left, spread evenly over what is left of the period — the flip line's own
        // arithmetic, which is the number the reader can actually act on.
        let daysLeft = Swift.max(0, a.resetsAt.timeIntervalSince(now)) / 86_400
        let perDay = daysLeft >= 1 ? Fmt.percentNumber(a.remainingPct / daysLeft) : nil
        var values: [String: String?] = [
            "used": Fmt.percentNumber(a.usedPct),
            "elapsed": Fmt.percentNumber(elapsed),
            "diff": Fmt.percentNumber(Swift.max(0, a.usedPct - elapsed)),
            "line": Fmt.percentNumber(StateEngine.longLimitNearlySpentPct),
        ]
        if a.limit != .monthly {
            values["left"] = Fmt.percentNumber(a.remainingPct)
            values["perDay"] = perDay
        }
        return ExplanationRegistry.liveLine(element, variant: variant, tool: tool,
                                            values: values, missing: .noPace)
    }

    /// The candidate a `BlockEpisode.Limit` names.
    private static func candidate(for limit: BlockEpisode.Limit,
                                  primary: AccountLimitCandidate?,
                                  secondary: AccountLimitCandidate?,
                                  monthly: AccountLimitCandidate?) -> AccountLimitCandidate? {
        switch limit {
        case .primary: return primary
        case .secondary: return secondary
        case .monthly: return monthly
        }
    }

    private static func boundedMonthlyAmount(unit: QuotaUnit) -> String {
        switch unit {
        case .credits: return "<1 credit"
        case .money: return "<\(monthlyAmount(1, unit: unit))"
        }
    }
}
