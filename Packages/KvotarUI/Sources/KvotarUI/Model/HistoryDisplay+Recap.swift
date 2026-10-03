import Foundation
import KvotarCore

/// Weekly recap — the editorial mode (STEP_182 — REV-93 §2.2 / UI Spec §6.2).
///
/// Summary was a dashboard whose best conclusions sat below its raw rows. The recap answers one
/// question instead — *what mattered in the last completed week, and is there one useful change to
/// make next week?* — and answers it about a **completed local Monday–Sunday week**, never the
/// current partial one.
///
/// Everything here is sliced from the report the other three modes already read: `days`,
/// `limitBlocks`, `accountChanges` (folded by `changeEntries`, plan names already collapsed by
/// `PlanChangeStability`) and `weeklyLimits`. **No new read, and no persisted prose** — the
/// sentences are recomputed on every open, which is what §6.2 means by never storing generated
/// text.
///
/// Since REV-104 / D-129 (STEP_228) the week says its numbers: a headline that carries its
/// percent, a `This week` table, the weekly limits that reset, and at most two observations. The
/// three free-form insight rows — windows closed, tokens over active days, early resets — are
/// retired; their facts live in those blocks.
///
/// The guards next door still hold. REV-72: never `steady`, never a stated allowance size, no
/// provider-shrink conclusion. REV-84 §3.1: no combined token figure exists anywhere, so a
/// cross-provider sentence compares direction or dates, never magnitude.
extension HistoryDisplay {

    // MARK: - Vocabulary

    static let recapLatestTitle = "Last completed week"
    static let recapActionTitle = "Next week"
    /// Lead eyebrows, one per rung — the register the confirmed companion uses.
    static let recapCapacityEyebrow = "Capacity outcome"
    static let recapAllowanceEyebrow = "Allowance change"
    static let recapPatternEyebrow = "Work pattern"
    static let recapCalmEyebrow = "Week in review"
    /// The whole-mode empty state: the horizon holds no completed week yet.
    static let recapEmptyMessage =
        "No completed week yet. The recap covers Monday to Sunday, and appears once a week has "
        + "finished."
    /// A week the fixed 30-day horizon only partly covers. Named beside every conclusion it
    /// bounds, and every whole-week conclusion is withheld while it is set (§6.2).
    static let recapClippedCoverage =
        "Only part of this week is inside the 30-day horizon, so week totals are not shown."
    /// Kvotar was not watching for the whole week — poll evidence starts at the watching date and
    /// cannot be backfilled, unlike the token corpus.
    static func recapWatchingCoverage(_ since: Date) -> String {
        "Kvotar began watching \(Fmt.monthDay(since)), so part of this week has no poll evidence."
    }

    // MARK: - Section

    static let recapTableTitle = "This week"
    static let recapNotABill = "Priced at published API rates for each model. Not a bill."
    /// A weekly line whose last reading came more than this long before the window ended is
    /// asterisked (REV-104 §5 Q1). Looser than the 240 s seen-to-the-end tolerance on purpose:
    /// that one is right for a chart and would asterisk nearly every line on a reading surface.
    static let recapLastReadingGapLimit: TimeInterval = 3_600
    /// A pattern change this large names the previous week's figure (REV-104 §2.2).
    static let recapGroundingChange = 0.5

    static func recapSection(_ report: HistoryReport, now: Date,
                             calendar: Calendar) -> HistoryExperience.RecapSection {
        let weeks = HistoryWeeks.completedWeeks(periodStart: report.periodStart,
                                                periodEnd: report.periodEnd,
                                                now: now, calendar: calendar)
        guard !weeks.isEmpty else {
            return HistoryExperience.RecapSection(emptyMessage: recapEmptyMessage)
        }
        return HistoryExperience.RecapSection(
            weeks: weeks.enumerated().map { index, week in
                recapWeek(week, isLatest: index == 0, report: report,
                          previous: weeks.dropFirst(index + 1).first, calendar: calendar)
            })
    }

    // MARK: - One week

    static func recapWeek(_ week: HistoryWeeks.Week, isLatest: Bool, report: HistoryReport,
                          previous: HistoryWeeks.Week?,
                          calendar: Calendar = .current) -> HistoryExperience.RecapWeek {
        let span = "\(Fmt.monthDay(week.start)) – \(Fmt.monthDay(lastDay(of: week)))"
        let evidence = RecapEvidence(week: week, report: report, previous: previous,
                                     calendar: calendar)
        let candidates = recapCandidates(evidence)

        // The §6.2 ladder decides the lead: first supported rung wins.
        let leading = recapLeadOrder.compactMap { slot in
            candidates.first { $0.slot == slot && $0.lead != nil }
        }.first
        let lead = leading?.lead
            ?? HistoryExperience.RecapLead(eyebrow: recapCalmEyebrow,
                                           sentence: recapNothingRecorded(evidence),
                                           kind: .calm)

        // A recorded allowance change under a block lead has no block of its own; it takes the
        // first observation slot rather than disappearing (D-129).
        let unled = candidates.first { $0.slot == .allowance && $0.slot != leading?.slot }?.insight
        let limits = recapLimitLines(evidence)

        return HistoryExperience.RecapWeek(
            id: week.start,
            end: week.end,
            title: isLatest ? recapLatestTitle : "Week of \(Fmt.monthDay(week.start))",
            span: span,
            isLatest: isLatest,
            coverageNote: recapCoverage(evidence),
            lead: lead,
            table: recapTable(evidence),
            weeklyLimits: recapWeeklyLimits(evidence, lines: limits),
            observations: [unled].compactMap { $0 } + recapObservations(evidence, limits: limits),
            action: recapAction(evidence))
    }

    /// Which rungs may take the lead, strongest first (§6.2 *Lead priority*).
    static let recapLeadOrder: [RecapCandidate.Slot] =
        [.block, .allowance, .pattern, .calm]

    /// The last **day** of a `[start, end)` week, for the inclusive span the reader reads.
    static func lastDay(of week: HistoryWeeks.Week) -> Date {
        week.end.addingTimeInterval(-86_400)
    }

    /// Everything one week's recap is allowed to know, sliced once so the lead, the insights and
    /// the action cannot disagree about the same week.
    struct RecapEvidence {
        let week: HistoryWeeks.Week
        let report: HistoryReport
        let previous: HistoryWeeks.Week?
        var calendar: Calendar = .current

        /// Per-provider blocks that fired inside the week.
        var blocks: [(tool: Tool, blocks: [HistoryReport.LimitBlock])] {
            report.tools.map { t in
                (t.tool, t.limitBlocks.filter { inWeek($0.firedAt) })
            }
            .filter { !$0.blocks.isEmpty }
        }

        /// Recorded changes inside the week, already folded. **Early resets are left out**
        /// (owner ruling 2026-09-10): on an account whose weekly window resets early every other
        /// day they would lead every recap, which is a fact about the account and not about the
        /// week. Since D-129 an early reset is said on its own weekly line instead.
        var structuralChanges: [(tool: Tool, entries: [ChangeEntry])] {
            report.tools.map { t in
                (t.tool, HistoryDisplay.changeEntries(t.accountChanges).filter { entry in
                    guard inWeek(entry.at) else { return false }
                    if case .single(let change) = entry, change.kind == .earlyReset { return false }
                    return true
                })
            }
            .filter { !$0.entries.isEmpty }
        }

        /// Weekly limit instances that **ended** inside the week — by `endedAt`, so a weekly the
        /// provider took back early belongs to the week it ended in, not the one it was
        /// scheduled for (STEP_228). A still-open limit cannot end inside a completed week.
        var weeklyLimits: [(tool: Tool, limits: [WeeklyLimitOutcome])] {
            report.tools.map { t in
                (t.tool, t.weeklyLimits.filter {
                    inWeek($0.outcome.endedAt) && $0.outcome.completion != .current
                })
            }
            .filter { !$0.limits.isEmpty }
        }

        /// Displayed tokens, Est. token value and active days per provider, over the part of the
        /// week the report actually covers.
        var activity: [RecapActivity] {
            report.tools.compactMap { t in
                let days = t.days.filter { inWeek($0.start) && $0.tokens > 0 }
                guard !days.isEmpty else { return nil }
                return RecapActivity(tool: t.tool, days: days)
            }
        }

        /// The preceding completed week's figures for one provider — the only comparison §6.2
        /// allows. Nil unless that week, too, is wholly inside the horizon: a clipped week
        /// against a full one manufactures a trend (REV-104 §2.3).
        func prior(_ tool: Tool) -> RecapActivity? {
            guard let previous, !previous.isClipped,
                  let t = report.tools.first(where: { $0.tool == tool }) else { return nil }
            let days = t.days.filter {
                $0.start >= previous.start && $0.start < previous.end && $0.tokens > 0
            }
            guard !days.isEmpty else { return nil }
            return RecapActivity(tool: tool, days: days)
        }

        /// The earliest watching date across the scoped providers.
        var watchingSince: Date? { report.tools.compactMap(\.watchingSince).min() }

        func inWeek(_ date: Date) -> Bool { date >= week.start && date < week.end }
    }

    /// One provider's active days over a week, and the three figures the table reads off them.
    struct RecapActivity {
        let tool: Tool
        let days: [HistoryReport.Day]

        var tokens: Int { days.reduce(0) { $0 + $1.tokens } }
        var value: Double { days.reduce(0) { $0 + $1.value } }
        var activeDays: Int { days.count }
        /// Any of the week's tokens priced at the provider fallback — the value cell's `≈`.
        var approximate: Bool { days.contains { $0.modelValues.contains(where: \.pricedAtFallback) } }
    }

    /// One fact the week supports, carrying both the shape it takes as a lead and the shape it
    /// takes as an insight — so a fact reads the same wherever the ladder places it. A `nil`
    /// `lead` is a fact that may support a recap but must never head one.
    struct RecapCandidate {
        enum Slot: Sendable, Equatable {
            case block, allowance, pattern, calm
        }

        let slot: Slot
        let lead: HistoryExperience.RecapLead?
        let insight: HistoryExperience.RecapInsight?
    }

    // MARK: - The ladder (§6.2)

    /// Every lead this week supports. Which of them leads is decided by `recapLeadOrder` above,
    /// not by the order they are gathered in.
    static func recapCandidates(_ e: RecapEvidence) -> [RecapCandidate] {
        [recapBlockRung(e), recapAllowanceRung(e), recapPatternRung(e),
         recapCalmRung(e)].compactMap { $0 }
    }

    /// Rung 1. A block is the week's strongest fact whether or not its reset was recovered — an
    /// unknown lockout is an unknown lockout, never a zero one (REV-73 §4.3).
    static func recapBlockRung(_ e: RecapEvidence) -> RecapCandidate? {
        let groups = e.blocks
        guard !groups.isEmpty else { return nil }
        let all = groups.flatMap(\.blocks)
        let timed = all.compactMap(\.lockoutSeconds)
        let names = groups.map { group -> String in
            let count = group.blocks.count
            return "\(group.tool.tabLabel) \(count) time\(count == 1 ? "" : "s")"
        }
        let sentence = groups.count == 1 && all.count == 1
            ? "\(groups[0].tool.tabLabel) ran out of its window once."
            : "Work stopped \(all.count) times — \(names.joined(separator: ", "))."
        let grounding: String
        if timed.isEmpty {
            grounding = all.count == 1
                ? "The reset could not be recovered, so the lockout is unknown."
                : "No reset could be recovered, so the lockout is unknown."
        } else if timed.count == all.count {
            grounding = "Known lockout \(Fmt.span(seconds: timed.reduce(0, +)))."
        } else {
            grounding = "Known lockout \(Fmt.span(seconds: timed.reduce(0, +))) across "
                + "\(timed.count) of \(all.count) blocks; the rest could not be recovered."
        }
        let scoped = groups.count == 1 ? groups[0].tool : nil
        return RecapCandidate(
            slot: .block,
            lead: .init(eyebrow: recapCapacityEyebrow, sentence: sentence, grounding: grounding,
                        kind: .blockConsequence),
            insight: .init(provider: scoped, sentence: "\(sentence) \(grounding)",
                           link: recapLink(e, mode: .hardBlocks, provider: scoped,
                                           label: "See the blocks")))
    }

    /// Rung 2. A plan change or a window added, removed or re-widened — the changes that alter
    /// the allowance a limit belongs to. The §2.8 grammar holds: never a size, never an
    /// accusation.
    static func recapAllowanceRung(_ e: RecapEvidence) -> RecapCandidate? {
        let groups = e.structuralChanges
        guard let first = groups.first, let entry = first.entries.first else { return nil }
        let parts = changeParts(entry)
        let sentence = "\(first.tool.tabLabel) recorded \(parts.lead.lowercased()) · "
            + "\(parts.value)."
        let total = groups.reduce(0) { $0 + $1.entries.count }
        let grounding = total > 1
            ? "\(total) recorded changes this week."
            : "One recorded change this week."
        let scoped = groups.count == 1 ? first.tool : nil
        return RecapCandidate(
            slot: .allowance,
            lead: .init(eyebrow: recapAllowanceEyebrow, sentence: sentence, grounding: grounding,
                        kind: .allowanceChange),
            insight: .init(provider: scoped, sentence: "\(sentence) \(grounding)",
                           link: recapLink(e, mode: .hardBlocks, provider: scoped,
                                           label: "See allowance history")))
    }

    /// Rung 3. This week against the same provider's own preceding completed week, outside the
    /// ±5 % band the surface already uses, **with its percent** (REV-104 §2.2): `Local token use
    /// fell 86% on Claude and 43% on Codex.` Withheld on a clipped week and against a clipped
    /// one — a partial week compared against a full one manufactures a trend (REV-73).
    static func recapPatternRung(_ e: RecapEvidence) -> RecapCandidate? {
        guard !e.week.isClipped else { return nil }
        var moved: [(now: RecapActivity, prior: RecapActivity, ratio: Double)] = []
        for entry in e.activity {
            guard let prior = e.prior(entry.tool), prior.tokens > 0 else { continue }
            let ratio = Double(entry.tokens) / Double(prior.tokens)
            guard ratio >= directionUpRatio || ratio <= directionDownRatio else { continue }
            moved.append((entry, prior, ratio))
        }
        guard !moved.isEmpty else { return nil }
        let clauses = moved.map { m -> (verb: String, rest: String) in
            (m.ratio >= 1 ? "rose" : "fell",
             "\(recapChangePercent(m.ratio))% on \(m.now.tool.tabLabel)")
        }
        // Two providers moving the same way share one verb: `fell 86% on Claude and 43% on
        // Codex` reads as a week where `fell … and fell …` reads as a list.
        let body: String
        if clauses.allSatisfy({ $0.verb == clauses[0].verb }) {
            body = clauses[0].verb + " " + clauses.map(\.rest).joined(separator: " and ")
        } else {
            body = clauses.map { "\($0.verb) \($0.rest)" }.joined(separator: " and ")
        }
        let groundings = moved
            .filter { abs(1 - $0.ratio) >= recapGroundingChange }
            .compactMap { recapGrounding(e, prior: $0.prior, fell: $0.ratio < 1) }
        return RecapCandidate(
            slot: .pattern,
            lead: .init(eyebrow: recapPatternEyebrow, sentence: "Local token use \(body).",
                        grounding: groundings.isEmpty ? nil : groundings.joined(separator: " "),
                        kind: .usagePattern),
            insight: nil)
    }

    /// `86` for a ratio of 0.14 and `12` for 1.12 — the size of the move, direction said in words.
    static func recapChangePercent(_ ratio: Double) -> String {
        Fmt.percentNumber(abs(ratio - 1) * 100)
    }

    /// A big move names its base (REV-104 §2.2): `Sep 14 – Sep 20 was unusually heavy for Claude —
    /// 917.0M, 760.1M of it on Sep 14 and Sep 15.` The two biggest days are named only when they
    /// carried most of it — that is what makes the base unusual rather than merely larger.
    static func recapGrounding(_ e: RecapEvidence, prior: RecapActivity, fell: Bool) -> String? {
        guard let previous = e.previous else { return nil }
        let span = "\(Fmt.monthDay(previous.start)) – \(Fmt.monthDay(lastDay(of: previous)))"
        var sentence = "\(span) was unusually \(fell ? "heavy" : "light") for "
            + "\(prior.tool.tabLabel) — \(Fmt.tokens(prior.tokens))"
        let top = prior.days.sorted { $0.tokens > $1.tokens }.prefix(2)
        let topTokens = top.reduce(0) { $0 + $1.tokens }
        if fell, top.count == 2, Double(topTokens) >= Double(prior.tokens) / 2 {
            let names = top.map(\.start).sorted().map(Fmt.monthDay).joined(separator: " and ")
            sentence += ", \(Fmt.tokens(topTokens)) of it on \(names)"
        }
        return sentence + "."
    }

    /// Rung 4 — the calm factual summary. Per-provider tokens and active days, never a combined
    /// token figure (§6.1: the field for one does not exist). Withheld on a clipped week, whose
    /// totals would be a fraction presented as a week.
    static func recapCalmRung(_ e: RecapEvidence) -> RecapCandidate? {
        guard !e.week.isClipped else { return nil }
        let activity = e.activity
        guard !activity.isEmpty else { return nil }
        let clauses = activity.map { entry in
            "\(entry.tool.tabLabel) \(Fmt.tokens(entry.tokens)) over "
                + "\(entry.activeDays) active day\(entry.activeDays == 1 ? "" : "s")"
        }
        let sentence = clauses.joined(separator: "; ") + "."
        let quiet = e.blocks.isEmpty && e.structuralChanges.isEmpty
        return RecapCandidate(
            slot: .calm,
            lead: .init(eyebrow: recapCalmEyebrow, sentence: sentence,
                        grounding: quiet
                            ? "Nothing was blocked and no allowance change was recorded."
                            : nil,
                        kind: .calm),
            insight: nil)
    }

    // MARK: - This week (REV-104 §2.3)

    /// One column per provider with activity; `Tokens`, `Est. token value`, `Active days`.
    /// Comparisons only against a whole previous week. Nil on a clipped week, whose totals
    /// would be a fraction presented as a week — the coverage note says so instead.
    static func recapTable(_ e: RecapEvidence) -> HistoryExperience.RecapTable? {
        guard !e.week.isClipped else { return nil }
        let activity = e.activity
        guard !activity.isEmpty else { return nil }
        let priors = activity.map { e.prior($0.tool) }

        let tokens = zip(activity, priors).map { now, prior in
            HistoryExperience.RecapTableCell(
                text: Fmt.tokens(now.tokens),
                comparison: prior.flatMap { p in
                    p.tokens > 0
                        ? "\(recapArrow(Double(now.tokens), Double(p.tokens))) vs \(Fmt.tokens(p.tokens))"
                        : nil
                })
        }
        let values = zip(activity, priors).map { now, prior in
            HistoryExperience.RecapTableCell(
                text: (now.approximate ? "≈" : "") + recapDollars(now.value),
                comparison: prior.flatMap { p in
                    p.value > 0 ? recapArrow(now.value, p.value) : nil
                })
        }
        let days = activity.map { HistoryExperience.RecapTableCell(text: "\($0.activeDays)") }

        // The one combined figure the recap allows (§6.1): value, never tokens, once, under
        // the not-a-bill note — and only where there are two values to combine.
        let valueNote = activity.count > 1
            ? "Together about \(recapDollars(activity.reduce(0) { $0 + $1.value })) · \(recapNotABill)"
            : recapNotABill
        let approximate = activity.filter(\.approximate).map(\.tool.tabLabel)
        let fallbackNote = approximate.isEmpty ? nil
            : "\(approximate.joined(separator: " and ")) "
                + "\(approximate.count == 1 ? "includes" : "include") models priced at a fallback rate."
        let scoped = activity.count == 1 ? activity[0].tool : nil
        return HistoryExperience.RecapTable(
            title: recapTableTitle,
            columns: activity.map(\.tool),
            rows: [
                .init(label: "Tokens", cells: tokens),
                .init(label: estValueLabel, cells: values),
                .init(label: "Active days", cells: days),
            ],
            valueNote: valueNote,
            fallbackNote: fallbackNote,
            link: recapLink(e, mode: .exploreUsage, provider: scoped, label: "See the days"))
    }

    /// `↓86%` / `↑12%` / `±0%`.
    static func recapArrow(_ now: Double, _ prior: Double) -> String {
        let ratio = now / prior
        let percent = recapChangePercent(ratio)
        if percent == "0" { return "±0%" }
        return "\(ratio > 1 ? "↑" : "↓")\(percent)%"
    }

    /// Whole dollars at recap scale (`$129`, `$1,204`), cents below ten dollars (`$4.20`) where
    /// rounding would erase the figure. Est. token value is USD by definition (§6.1).
    static func recapDollars(_ value: Double) -> String {
        guard value >= 10 else { return Fmt.dollarValue(value) }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.maximumFractionDigits = 0
        return "$" + (f.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))")
    }

    // MARK: - Weekly limits (REV-104 §2.4)

    /// One line for a weekly limit instance, with what the block and the observations need.
    struct RecapLimit {
        let tool: Tool
        let limit: WeeklyLimitOutcome
        let line: HistoryExperience.RecapLimitLine
        /// The asterisk's footnote, where the last reading came long before the end.
        let footnote: String?
    }

    /// Every weekly limit that ended inside the week, oldest end first, overall before the model
    /// limits beneath it. Overall and model limits are separate lines, never added together.
    static func recapLimitLines(_ e: RecapEvidence) -> [RecapLimit] {
        e.weeklyLimits.flatMap { group -> [RecapLimit] in
            // `Claude overall` only where a model line stands beside it; a lone weekly is the
            // provider's weekly, and `Codex overall` would name a split that does not exist.
            let hasModels = group.limits.contains { $0.limit != .overall }
            return group.limits
                .sorted {
                    ($0.outcome.endedAt, $0.limit == .overall ? 0 : 1, $0.id)
                        < ($1.outcome.endedAt, $1.limit == .overall ? 0 : 1, $1.id)
                }
                .map { recapLimit(group.tool, $0, namesOverall: hasModels) }
        }
    }

    static func recapLimit(_ tool: Tool, _ limit: WeeklyLimitOutcome,
                           namesOverall: Bool) -> RecapLimit {
        let outcome = limit.outcome
        let name: String
        switch limit.limit {
        case .overall: name = namesOverall ? "\(tool.tabLabel) overall" : tool.tabLabel
        case .model(let key, let modelName): name = "\(tool.tabLabel) \(modelName ?? key)"
        }
        var label = "\(name) · \(Fmt.monthDay(outcome.endedAt))"
        // An early reset and a withdrawal are one fact to the reader: the provider ended the
        // week before its schedule.
        if outcome.ending != .reachedReset { label += " (reset early)" }

        let value: String
        var footnote: String?
        if outcome.hitLimitAt != nil {
            value = "reached the limit"
        } else if outcome.lastReadingGap > recapLastReadingGapLimit {
            value = "\(Fmt.percentNumber(outcome.highWaterPct))% used*"
            footnote = "Last reading \(recapGap(outcome.lastReadingGap)) before the reset — "
                + "final use may be a little higher."
        } else {
            value = "\(Fmt.percentNumber(outcome.highWaterPct))% used"
        }
        return RecapLimit(tool: tool, limit: limit,
                          line: .init(provider: tool, label: label, value: value),
                          footnote: footnote)
    }

    /// `15 h`, and `3 days` once hours stop being the natural unit.
    static func recapGap(_ seconds: TimeInterval) -> String {
        let hours = Int((seconds / 3_600).rounded())
        if hours < 48 { return "\(hours) h" }
        return "\(Int((seconds / 86_400).rounded())) days"
    }

    static func recapWeeklyLimits(_ e: RecapEvidence,
                                  lines: [RecapLimit]) -> HistoryExperience.RecapWeeklyLimits? {
        guard !lines.isEmpty else { return nil }
        let starred = lines.filter { $0.footnote != nil }
        // One footnote needs no pointer; several name the line each belongs to.
        let footnotes = starred.map { limit -> String in
            let note = limit.footnote ?? ""
            return starred.count == 1 ? "* \(note)" : "* \(limit.line.label): \(note)"
        }
        let providers = Set(lines.map(\.tool))
        let span = "\(Fmt.monthDay(e.week.start)) – \(Fmt.monthDay(lastDay(of: e.week)))"
        return HistoryExperience.RecapWeeklyLimits(
            title: "Weekly limits that reset \(span)",
            lines: lines.map(\.line),
            footnotes: footnotes,
            link: recapLink(e, mode: .exploreQuota,
                            provider: providers.count == 1 ? providers.first : nil,
                            label: "See the windows"))
    }

    // MARK: - Observations (REV-104 §2.5)

    /// At most two, in order, each only when its trigger holds: a limit that came close, one day
    /// that carried the week, one project that carried the week. Never an allowance size or a
    /// provider-side change (REV-72).
    static func recapObservations(_ e: RecapEvidence,
                                  limits: [RecapLimit]) -> [HistoryExperience.RecapInsight] {
        var out: [HistoryExperience.RecapInsight] = []
        if let close = recapCloseLimit(e, limits: limits) { out.append(close) }
        // Shares of a week are only shares of a whole week.
        if !e.week.isClipped {
            if let day = recapConcentratedDay(e) { out.append(day) }
            if let project = recapTopProject(e) { out.append(project) }
        }
        return out
    }

    /// `Fable was the tightest weekly limit — 61%, against 43% overall.` (a model limit 10 points
    /// or more above its overall at the same end), else the fullest line at or above 80 %.
    static func recapCloseLimit(_ e: RecapEvidence,
                                limits: [RecapLimit]) -> HistoryExperience.RecapInsight? {
        var best: (limit: RecapLimit, name: String, overall: Double, gap: Double)?
        for limit in limits {
            guard case .model(let key, let name) = limit.limit.limit,
                  let overall = limits.first(where: {
                      $0.tool == limit.tool && $0.limit.limit == .overall
                          && abs($0.limit.outcome.endedAt.timeIntervalSince(limit.limit.outcome.endedAt))
                              <= QuotaWindowOutcomes.anchorJitterTolerance
                  }) else { continue }
            let gap = limit.limit.outcome.highWaterPct - overall.limit.outcome.highWaterPct
            if gap >= 10, gap > (best?.gap ?? -1) {
                best = (limit, name ?? key, overall.limit.outcome.highWaterPct, gap)
            }
        }
        if let best {
            let pct = Fmt.percentNumber(best.limit.limit.outcome.highWaterPct)
            return .init(provider: best.limit.tool,
                         sentence: "\(best.name) was the tightest weekly limit — \(pct)%, "
                            + "against \(Fmt.percentNumber(best.overall))% overall.",
                         link: recapLink(e, mode: .exploreQuota, provider: best.limit.tool,
                                         label: "See the windows"))
        }
        guard let fullest = limits.max(by: {
            $0.limit.outcome.highWaterPct < $1.limit.outcome.highWaterPct
        }), fullest.limit.outcome.highWaterPct >= 80 else { return nil }
        let name = fullest.line.label.components(separatedBy: " · ").first ?? fullest.tool.tabLabel
        let sentence = fullest.limit.outcome.hitLimitAt != nil
            ? "\(name) reached its weekly limit."
            : "\(name) came close — \(Fmt.percentNumber(fullest.limit.outcome.highWaterPct))% "
                + "of its weekly limit used."
        return .init(provider: fullest.tool, sentence: sentence,
                     link: recapLink(e, mode: .exploreQuota, provider: fullest.tool,
                                     label: "See the windows"))
    }

    /// `Monday was 64% of Claude's value this week.` — one day at or above 40 % of a provider's
    /// Est. token value, on a week with more than one active day.
    static func recapConcentratedDay(_ e: RecapEvidence) -> HistoryExperience.RecapInsight? {
        for entry in e.activity where entry.activeDays > 1 && entry.value > 0 {
            guard let top = entry.days.max(by: { $0.value < $1.value }) else { continue }
            let share = top.value / entry.value
            guard share >= 0.4 else { continue }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = e.calendar.timeZone
            f.dateFormat = "EEEE"
            return .init(provider: entry.tool,
                         sentence: "\(f.string(from: top.start)) was "
                            + "\(Fmt.percentNumber(share * 100))% of \(entry.tool.tabLabel)'s "
                            + "value this week.",
                         link: recapLink(e, mode: .exploreUsage, provider: entry.tool,
                                         label: "See the days"))
        }
        return nil
    }

    /// `kvotar was 62% of Claude's tokens.` — one named project with at least half of a
    /// provider's tokens for the week.
    static func recapTopProject(_ e: RecapEvidence) -> HistoryExperience.RecapInsight? {
        for entry in e.activity where entry.tokens > 0 {
            var byProject: [String: Int] = [:]
            for day in entry.days {
                for row in day.projects { if let p = row.project { byProject[p, default: 0] += row.tokens } }
            }
            guard let top = byProject.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
                  Double(top.value) >= Double(entry.tokens) / 2 else { continue }
            return .init(provider: entry.tool,
                         sentence: "\(DisplayFormatter.projectName(top.key)) was "
                            + "\(Fmt.percentNumber(Double(top.value) / Double(entry.tokens) * 100))% "
                            + "of \(entry.tool.tabLabel)'s tokens.",
                         link: recapLink(e, mode: .exploreUsage, provider: entry.tool,
                                         label: "See the days"))
        }
        return nil
    }

    /// The lead of last resort: the week is inside the horizon and holds nothing at all.
    static func recapNothingRecorded(_ e: RecapEvidence) -> String {
        guard let watching = e.watchingSince else {
            return "Nothing was recorded this week."
        }
        return "Nothing was recorded this week. Kvotar has been watching since "
            + "\(Fmt.monthDay(watching))."
    }

    // MARK: - Action

    /// The at-most-one `Next week` action. **Gated on a recorded hard block** (owner ruling
    /// 2026-09-10): that is the one outcome whose consequence names a change worth making. Every
    /// softer trigger — a window that merely ended high, a busy week — would be advice the
    /// evidence does not carry, and §6.2 says to omit the action rather than invent one.
    ///
    /// It never names a plan, an allowance size or a provider-side cut (REV-72 / REV-93 §7).
    static func recapAction(_ e: RecapEvidence) -> HistoryExperience.RecapAction? {
        let groups = e.blocks
        guard !groups.isEmpty else { return nil }
        let all = groups.flatMap(\.blocks)
        let timed = all.compactMap(\.lockoutSeconds)
        let names = groups.map(\.tool.tabLabel).joined(separator: " and ")
        var sentence = all.count == 1
            ? "\(names) ran out once this week."
            : "\(names) ran out \(all.count) times this week."
        sentence += " The reset clock for the current window is on the menu bar before a long run."
        let evidence = timed.isEmpty
            ? "No reset was recovered, so the lockout is unknown."
            : "Known lockout \(Fmt.span(seconds: timed.reduce(0, +)))."
        return HistoryExperience.RecapAction(title: recapActionTitle, sentence: sentence,
                                             evidence: evidence)
    }

    // MARK: - Coverage and links

    /// The coverage limit for the week as a whole — the horizon clip first, then the watching
    /// date. Stated beside the conclusions it bounds, never as a footnote at the end.
    static func recapCoverage(_ e: RecapEvidence) -> String? {
        if e.week.isClipped { return recapClippedCoverage }
        guard let watching = e.watchingSince, watching > e.week.start else { return nil }
        return recapWatchingCoverage(watching)
    }

    /// One typed evidence link: the mode holding the support, the provider where the fact belongs
    /// to one, the exact completed week, and the removable banner the destination shows on
    /// arrival (§6.2). Every word of the banner is built here, beside the scope it describes.
    static func recapLink(_ e: RecapEvidence, mode: HistoryExperience.Mode, provider: Tool?,
                          label: String) -> HistoryExperience.RecapLink {
        let span = "\(Fmt.monthDay(e.week.start)) – \(Fmt.monthDay(lastDay(of: e.week)))"
        var parts = ["From weekly recap"]
        if let provider { parts.append(provider.tabLabel) }
        parts.append(span)
        return HistoryExperience.RecapLink(
            label: label,
            destination: HistoryDestination(
                mode: mode, provider: provider,
                scope: .week(start: e.week.start, end: e.week.end),
                banner: parts.joined(separator: " · ")))
    }
}
