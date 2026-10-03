import Foundation
import KvotarCore

// The verdict anatomy (UI Spec Part 3 §5.3, REV-67 / D-73, STEP_110): the verdict's own inputs,
// the comparison it made, and the flip line — what line 1 will read next and the single nearest
// condition. Everything here is fed from `AnatomyInputs`, which `headerVerdict` fills from the
// locals it decided the verdict with, so the anatomy is a projection of the same branch walk and
// can never disagree with the line above it (Baseline §19 pins that). Verdict tier (D-27): the
// comparison and flip may say "you"; the rows are data.
//
// The comparison sentences and flip lines were rewritten for a single read in STEP_129
// (REV-75/D-92) — the same pass the hover cards took in STEP_128, so the two surfaces speak one
// voice. Copy only: the rows, the values, the branch walk and the gestures are STEP_110's. Where a
// sentence now says "about", that word carries the §2.2a tilde — it is not doubled with a `~`; the
// row values and the burn thresholds keep theirs.
//
// One fact settled in planning (2026-08-16), recorded because the first draft of §5.3 said
// otherwise: from "Won't make it" the pace clock is **never** the nearer exit. That verdict means
// used% reaches 100 before the window's elapsed share does; both move linearly while burn holds,
// so used − elapsed is positive at t = 0 and at t = runway and never crosses. The only real exit
// is burn dropping below `remaining ÷ minutes-to-reset`, and that is the only flip this file
// names for the exhaustion family. No dead pace-exit path exists to maintain.

extension HeaderVerdict {
    /// Re-tags a verdict built by a helper (`monthlyVerdict`, `overQuotaVerdict`) with its family
    /// without threading a parameter through every return of those helpers. Anatomy stays nil —
    /// both are condition families in v1.
    ///
    /// **Every field is copied by hand here**, so a new one added to `HeaderVerdict` and forgotten
    /// in this initializer vanishes on exactly the two paths that go through it. `detailLive` was
    /// added in STEP_130 and both helpers set it, so the two are the only E-08 cards this function
    /// carries — dropping it would leave the monthly and over-quota rows silently unexplained.
    func tagged(_ family: VerdictFamily) -> HeaderVerdict {
        HeaderVerdict(line1: line1, colour: colour, line2: line2, moneyPrefix: moneyPrefix,
                      moneySymbol: moneySymbol,
                      family: family, anatomy: anatomy, detailLive: detailLive)
    }
}

/// The locals `headerVerdict` decided the runway-driven families from, captured once.
struct AnatomyInputs {
    let util: Double?
    let reset: Date?
    let minutesToReset: Double?
    let runway: Double?
    let burn: Double?
    let burnSpan: Double?
    let paceExceeded: Bool?
    let paceElapsed: Double?
    let windowLength: TimeInterval?
    let now: Date
}

/// Which runway-family anatomy to build — the §5.3 shape-A variants.
enum RunwayAnatomyKind {
    case exhaustion, resetsFirst, held, heldLongWindow, nothingBurning
}

extension DisplayFormatter {

    // MARK: Shape A — runway vs reset

    /// Shape A. `nil` (line inert) whenever burn is unmeasured — a held row can be reached with an
    /// empty forecast because the state carries §13.4's hysteresis and the forecast carries
    /// nothing, and an anatomy with no burn row would be showing work it did not do.
    static func runwayAnatomy(_ kind: RunwayAnatomyKind, _ i: AnatomyInputs) -> VerdictAnatomy? {
        guard let util = i.util, let burn = i.burn else { return nil }
        let remaining = max(0, 100 - util)
        var rows: [LabeledRow] = []
        rows.append(LabeledRow(label: "Remaining", value: "\(Fmt.percent(remaining)) of window"))
        let burnLabel = i.burnSpan.map { "Burn (last \(Fmt.durationHM($0)))" } ?? "Burn"
        rows.append(LabeledRow(label: burnLabel, value: Fmt.burnRate2(burn, window: i.windowLength)))
        if let runway = i.runway, runway > 0 {
            let stops = Fmt.clockDay(i.now.addingTimeInterval(runway * 60), from: i.now)
            rows.append(LabeledRow(label: "Runway at this burn",
                                   value: "~\(Fmt.durationHM(runway)) → stops ~\(stops)"))
        } else {
            rows.append(LabeledRow(label: "Runway at this burn", value: "∞"))
        }
        if let reset = i.reset, let cd = Fmt.countdown(to: reset, from: i.now, spaced: true) {
            rows.append(LabeledRow(label: "Reset",
                                   value: "\(Fmt.clockDay(reset, from: i.now)) — \(cd) away"))
        } else {
            rows.append(LabeledRow(label: "Reset", value: "—"))
        }
        if let elapsed = i.paceElapsed {
            let e = min(100, max(0, elapsed))
            let tag: String
            if i.paceExceeded == true {
                tag = "over pace"
            } else if util > e {
                // Inside the 2% grace the clock is deliberately silent (§11.3) — say why, never
                // "under pace" when the numbers beside it read the opposite.
                tag = "window just started"
            } else {
                tag = "under pace"
            }
            rows.append(LabeledRow(label: "Pace",
                                   value: "\(Fmt.percent(util)) used at \(Fmt.percent(e)) of the window — \(tag)"))
        }

        let comparison: String
        let flip: String?
        let cdSpaced = i.reset.flatMap { Fmt.countdown(to: $0, from: i.now, spaced: true) }
        switch kind {
        case .exhaustion:
            guard let runway = i.runway, let m = i.minutesToReset, m > 0 else { return nil }
            comparison = "At this speed you run out in about \(Fmt.durationHM(runway)) — before the reset, which is \(cdSpaced ?? "some time") away."
            // The burn threshold below which runway ≥ reset: remaining ÷ minutes-to-reset. The
            // next verdict is the D-46 held row, never "Safe" — the colour is held for
            // `deEscalationCalmPolls` after the danger passes.
            flip = "Turns to *Was on track to run out — safe if this pace holds* if you slow down below ~\(Fmt.burnRate2(remaining / m, window: i.windowLength))."
        case .resetsFirst, .held:
            guard let runway = i.runway, let m = i.minutesToReset, m > 0 else { return nil }
            let margin = abs(runway - m)
            comparison = "At this speed you have about \(Fmt.durationHM(runway)) left — the reset, \(cdSpaced ?? "some time") away, comes first by about \(Fmt.durationHM(margin))."
            if kind == .held {
                let next = margin < thinMarginMinutes ? "Safe, barely" : "Safe at this pace"
                flip = "Reads *\(next)* once this pace holds a few more minutes"
            } else if i.paceExceeded == true {
                flip = "Turns to *Won't make it* if you speed up past ~\(Fmt.burnRate2(remaining / m, window: i.windowLength))."
            } else if let elapsed = i.paceElapsed {
                let e = min(100, max(0, elapsed))
                if util > e {
                    flip = "Can't turn into a warning yet — the window just started."
                } else {
                    flip = "Can't turn into a warning yet — you're under pace: \(Fmt.percent(util)) used with \(Fmt.percent(e)) of the window gone."
                }
            } else {
                flip = nil   // unanchored window: no pace claim, no honest next condition
            }
        case .heldLongWindow:
            // Long-window held row (D-69 branch): its calm successor is the pace family, not the
            // burst grammar. Runway may be nil here (burn ≈ 0 with a live colour hold).
            if let runway = i.runway, let m = i.minutesToReset, m > 0 {
                comparison = "At this speed you have about \(Fmt.durationHM(runway)) left — the reset, \(cdSpaced ?? "some time") away, comes first by about \(Fmt.durationHM(abs(runway - m)))."
            } else {
                comparison = "Nothing is burning, so the reset comes first."
            }
            let next = i.paceExceeded == true ? "Above pace" : "On pace"
            flip = "Reads *\(next)* once this pace holds a few more minutes"
        case .nothingBurning:
            comparison = "Nothing is burning, so the reset comes first."
            flip = "Changes as soon as usage is measured again."
        }
        return VerdictAnatomy(rows: rows, comparison: comparison, flip: flip)
    }

    // MARK: Shape B — weekly

    /// Shape B — **generalised from the weekly to any long limit** (REV-96 §3.9 — STEP_194).
    ///
    /// It used to have exactly one row set and one sentence, both hard-wired to a weekly past
    /// `weeklyElevatedUtil`, because that was the only thing a long limit could ever be. Now the
    /// limit can be a weekly or a monthly and the reason can be *ahead of the calendar* or *past
    /// the line*, so the shape reads the assessment and shows the hand that actually decided it:
    /// the pace rows when the calendar is the reason, the line when the position is.
    ///
    /// `nil` without a reading — the row could not have been chosen without one, but the guard
    /// keeps the anatomy honest if it ever is.
    static func weeklyAnatomy(snapshot: QuotaSnapshot?, util: Double?, now: Date) -> VerdictAnatomy? {
        guard let wk = snapshot?.secondaryUsedPct else { return nil }
        return longLimitAnatomy(snapshot?.longLimit(.secondary, now: now),
                         fallbackUsedPct: wk, tool: snapshot?.tool ?? .claude,
                         primaryUsedPct: util,
                         primaryGrain: windowGrain(seconds: snapshot?.primaryWindowSeconds),
                         now: now)
    }

    /// Shape B proper. `fallbackUsedPct` covers the one case with a reading but no assessment —
    /// an unanchored long limit, which has a position and no calendar.
    static func longLimitAnatomy(_ assessment: LongLimitAssessment?, fallbackUsedPct: Double,
                                 tool: Tool, primaryUsedPct: Double?, primaryGrain: String?,
                                 now: Date) -> VerdictAnatomy? {
        let grain = primaryGrain ?? "5-hour"
        let name = assessment.map { DisplayFormatter.longLimitName($0.limit, tool: tool) }
            ?? "Weekly"
        let used = assessment?.usedPct ?? fallbackUsedPct
        let line = StateEngine.longLimitNearlySpentPct
        // `nearlySpent` is a *position* test: the pace rows are still shown, because the reader
        // asked why, but the sentence names the line rather than the calendar.
        let pastTheLine = (assessment?.tier ?? .onPace) >= .nearlySpent || used >= line

        var rows: [LabeledRow] = [LabeledRow(label: "\(name) used", value: Fmt.percent(used))]
        if pastTheLine {
            rows.append(LabeledRow(label: assessment?.limit == .monthly
                                       ? "Nearly-reached line" : "Nearly-spent line",
                                   value: "\(Fmt.percent(line)) used"))
        }
        if let a = assessment {
            let elapsed = min(100, max(0, a.elapsedPct))
            let dayClause = DisplayFormatter
                .periodDayIndex(elapsedPct: a.elapsedPct, periodSeconds: a.periodSeconds)
                .map { " · day \($0.day) of \($0.of)" } ?? ""
            let periodWord = a.limit == .monthly ? "Month" : "Week"
            rows.append(LabeledRow(label: "\(periodWord) elapsed",
                                   value: "\(Fmt.percent(elapsed))\(dayClause)"))
            if !pastTheLine {
                rows.append(LabeledRow(label: "Even pace would be",
                                       value: "\(Fmt.percent(elapsed)) used"))
            }
            rows.append(LabeledRow(label: "\(name) resets", value: Fmt.monthDay(a.resetsAt)))
        } else {
            rows.append(LabeledRow(label: "\(name) resets", value: "—"))
        }
        if let primaryUsedPct {
            rows.append(LabeledRow(label: grain,
                                   value: "\(Fmt.percent(primaryUsedPct)) — not the driver"))
        }

        let comparison: String
        if pastTheLine {
            let primaryClause = primaryUsedPct.map {
                "; the \(grain) window at \(Fmt.percent($0)) isn't the problem"
            } ?? ""
            comparison = "\(name) is at \(Fmt.percent(used)), past the \(Fmt.percent(line)) line "
                + "— that's what sets the verdict whatever the pace\(primaryClause)."
        } else if let a = assessment {
            let elapsed = min(100, max(0, a.elapsedPct))
            let diff = Int((a.usedPct - elapsed).rounded())
            let periodWord = a.limit == .monthly ? "month" : "week"
            comparison = "You've used \(Fmt.percent(used)) of the \(periodWord) with "
                + "\(Fmt.percent(elapsed)) of it gone — \(abs(diff)) point\(abs(diff) == 1 ? "" : "s") "
                + (diff >= 0 ? "ahead of" : "under") + " even pace."
        } else {
            comparison = "\(name) is at \(Fmt.percent(used))."
        }

        let resetClause = assessment.map { " on \(Fmt.monthDay($0.resetsAt))" } ?? ""
        // The per-day budget is what a reader can act on — the flip line's own arithmetic, and
        // the same number E-02's card prints, so the two cannot disagree.
        let daysLeft = assessment.map {
            Swift.max(0, $0.resetsAt.timeIntervalSince(now)) / 86_400
        } ?? 0
        let remaining = Swift.max(0, 100 - used)
        // Nothing to budget once the limit is spent — "0% left is about 0% a day" is noise
        // where the sentence before it has already said the only thing left to say.
        let budget = daysLeft >= 1 && remaining > 0
            ? " \(Fmt.percent(remaining)) left is about \(Fmt.percent(remaining / daysLeft)) a day."
            : ""
        let flip: String
        if pastTheLine {
            flip = "Stays until the reset\(resetClause) — usage can't go down before then.\(budget)"
        } else {
            flip = "Reads *on pace* again once the calendar catches up.\(budget)"
        }
        return VerdictAnatomy(rows: rows, comparison: comparison, flip: flip)
    }

    // MARK: Shape C — pace only (long window)

    /// Shape C. Needs the pace clock's two hands; `nil` where the window is unanchored.
    static func paceAnatomy(abovePace: Bool, _ i: AnatomyInputs) -> VerdictAnatomy? {
        guard let util = i.util, let elapsedRaw = i.paceElapsed, let length = i.windowLength,
              length > 0 else { return nil }
        let e = min(100, max(0, elapsedRaw))
        let days = max(1, Int((length / 86_400).rounded()))
        let dayIndex = min(days, Int(floor(e / 100 * Double(days))) + 1)
        var rows: [LabeledRow] = [
            LabeledRow(label: "Used", value: Fmt.percent(util)),
            LabeledRow(label: "Window elapsed",
                       value: "\(Fmt.percent(e)) (day \(dayIndex) of \(days))"),
        ]
        rows.append(LabeledRow(label: "Resets",
                               value: i.reset.map(Fmt.monthDay) ?? "—"))
        let diff = Int((util - e).rounded())
        let comparison: String
        if diff > 0 {
            comparison = "You've used \(diff) point\(diff == 1 ? "" : "s") more than the calendar would by now"
        } else if diff < 0 {
            comparison = "You've used \(-diff) point\(diff == -1 ? "" : "s") less than the calendar would by now"
        } else {
            comparison = "Level with the calendar"
        }
        let flip: String
        if abovePace {
            // The calendar catches up with a paused meter after (used − elapsed)% of the window.
            let minutes = (util - e) / 100 * length / 60
            let at = Fmt.clockDay(i.now.addingTimeInterval(minutes * 60), from: i.now)
            flip = "Reads *On pace* by about \(at) if you pause — the calendar catches up with \(Fmt.percent(util))."
        } else {
            let perDay = 100 * 86_400 / length
            flip = "Reads *Above pace* once you've used more than the calendar — \(Fmt.percent(e)) today, rising about \(Fmt.percent(perDay)) a day."
        }
        return VerdictAnatomy(rows: rows, comparison: comparison, flip: flip)
    }
}

extension Fmt {
    /// Burn for the anatomy, in the window's own unit (`window` is `primaryWindowLength`; nil ⇒
    /// five hours).
    ///
    /// **Short window** — two decimals, "0.32% / min", where the burn card's one decimal would
    /// round the flip threshold to 0.0 (STEP_110). **A window a day or wider** — per hour at one
    /// decimal, "4.0% / hr" (REV-74/D-83, STEP_123): the two-decimal form was the right number in
    /// the wrong unit, and nobody reads "0.067% / min".
    ///
    /// Either way the helper's founding rule holds — it falls to one more decimal when the shorter
    /// form would print zero for a non-zero rate, so a flip threshold is never "0.00" or "0.0".
    static func burnRate2(_ value: Double, window: TimeInterval?) -> String {
        if (window ?? 18_000) >= burnUnitHourFrom {
            let perHour = value * 60
            let one = String(format: "%.1f", perHour)
            if one == "0.0", perHour > 0 { return String(format: "%.2f", perHour) + "% / hr" }
            return one + "% / hr"
        }
        let two = String(format: "%.2f", value)
        if two == "0.00", value > 0 { return String(format: "%.3f", value) + "% / min" }
        return two + "% / min"
    }
}
