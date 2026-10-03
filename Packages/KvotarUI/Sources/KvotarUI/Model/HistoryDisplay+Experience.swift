import Foundation
import KvotarCore

/// `HistoryReport → HistoryExperience` (STEP_159 — REV-84 / D-108; four modes STEP_182 — REV-93 /
/// D-115): the entry point and the Explore-usage and Hard-blocks builders. Pure static mapping, no
/// I/O, `now` and `calendar` injected. Where a rule survives unchanged (REV-72 quota-change guards,
/// REV-73 block derivation and row grammar, the D-81 change grammar, hover bodies), the existing
/// helper is called rather than re-implemented.
///
/// The two new modes live beside this file — `HistoryDisplay+Recap` and `HistoryDisplay+Quota` —
/// because they answer different questions from different evidence, and one 1,500-line extension
/// would have hidden that. **Summary's builders were deleted with its payload** (STEP_182): the
/// conclusion ladder, the hero facts and the activity-peak sentence have no successor here, and
/// the recap's ladder is a different one over a different period.
///
/// **Provider-safe geometry (REV-84 §3.1).** On `All`, every local-activity fraction is normalised
/// against **that provider's own** busiest bucket — day, week and hour — so the two lanes never
/// share a scale and no drawn height implies a cross-provider token comparison.
extension HistoryDisplay {

    // MARK: - Vocabulary (REV-84 — new surface copy)

    /// The lower explorer's heading (REV-84 §5.3): explicitly 30-day, so day selection cannot
    /// silently change what its rows mean.
    static let breakdownTitle = "30-day breakdown"
    /// Selected-day status forms (REV-84 §5.1). Sentence case — these are statuses, not the
    /// lowercase hover notes the strip keeps.
    static let partialDayStatus = "Partial day"
    static let noActivityDayStatus = "No activity"
    /// The clipped oldest week's row note (REV-84 §5.2).
    static let partialWeekNote = "Partial week"
    /// The once-per-detail honesty sentence (REV-84 §5.1): a recorded warning is evidence, its
    /// absence is not headroom.
    static let evidenceNoteSentence =
        "Warnings are shown only when Kvotar recorded them; no warning here does not guarantee headroom."
    /// The below-floor investigative note (REV-84 §6) — Hard blocks only. Summary must never
    /// borrow it as a conclusion; the ban is fixture-pinned.
    static let blockSampleNote = "Not enough recorded blocks to call a typical time."
    /// The spoken form of the strip's block dot (STEP_160): mid-sentence after a provider name
    /// (`Claude hit the limit`); the legend's `Hit the limit` covers the unnamed case.
    static let limitHitA11yFact = "hit the limit"
    /// The allowance panel's heading inside the Hard-blocks investigation (STEP_160). Summary's
    /// question form retired with Summary (STEP_182); recap owns that question now.
    static let allowanceHistoryTitle = "Allowance history"
    /// The Hard-blocks consequence measure's semantic label (REV-84 §6 item 1).
    static let knownConsequenceLabel = "Known consequence"
    /// The selected-day measure label the Explore detail keeps from the retired hero facts.
    static let localTokensStatLabel = "Local tokens"
    /// Section headings the views mount over model content (copy stays model-owned).
    static let weekByWeekTitle = "Week by week"
    static let selectDayTitle = "Select a day"
    static let modelsTitle = "Models"
    static let projectsDimensionLabel = "Projects"
    static let blockHistoryTitle = "Block history"
    static let byDayTitle = "By day"
    static let byWeekTitle = "By week"
    static let recordedIncidentsTitle = "Recorded incidents"
    static let activityAroundBlocksTitle = "Activity around blocks"
    static let possiblePatternTitle = "Possible pattern"
    static let whatHappenedTitle = "What happened"
    static let selectedQuotaWindowEyebrow = "Selected quota window"
    /// The selected-day card's eyebrow and its model-row heading (STEP_163 — the prototype's
    /// `.kh-explore-detail`). Headings only: the day's own copy stays model-owned.
    static let selectedDayEyebrow = "Selected day"
    static let modelBreakdownEyebrow = "Model breakdown"
    /// The eyebrow over a selected day's project rows (STEP_178) — where the popover's
    /// `N more projects ›` lands.
    static let projectBreakdownEyebrow = "Project breakdown"
    /// `All providers` / the tool's tab label — the eyebrow's subject.
    static func providerDisplayName(_ provider: HistoryExperience.Provider) -> String {
        switch provider {
        case .all: return "All providers"
        case .tool(let tool): return tool.tabLabel
        }
    }
    /// The week-direction gate (UI Spec Part 3 §6.2 pins ±5%): a completed week against the same
    /// provider's own preceding completed week. At or inside the band the week reads as level and
    /// the recap says nothing about direction.
    static let directionUpRatio = 1.05
    static let directionDownRatio = 0.95

    /// The four §13 destinations in user vocabulary (REV-84 §5.1). Display-owned: Core stores
    /// raw state strings and the reader types them; every word here is this package's.
    static func criticalStateLabel(_ state: HistoryReport.CriticalObservation.State) -> String {
        switch state {
        case .atRisk: return "At risk"
        case .badTiming: return "Bad timing"
        case .overQuota: return "Over quota"
        case .spendControl: return "Spend control"
        }
    }

    // MARK: - Entry

    /// Every mode/provider payload from one report — the switch is instant and local
    /// (REV-84 §2, four modes since REV-93). `now` and `calendar` are injected for the same
    /// determinism `screen(_:now:)` had: the recap's week boundaries are local calendar facts,
    /// and a test must be able to pin a zone without touching `Calendar.current`.
    public static func experience(_ report: HistoryReport, now: Date,
                                  calendar: Calendar = .current) -> HistoryExperience {
        var pages = [providerPages(.all, scope: report.tools, report: report)]
        pages += report.tools.map { providerPages(.tool($0.tool), scope: [$0], report: report) }
        return HistoryExperience(
            header: HistoryScreen.Header(
                title: "History",
                subtitle: "\(Fmt.monthDay(report.periodStart)) – \(Fmt.monthDay(report.periodEnd))"),
            recap: recapSection(report, now: now, calendar: calendar),
            pages: pages,
            footer: experienceFooter(report),
            pricingNote: HistoryDisplay.pricingNote,
            emptyMessage: report.tools.allSatisfy { isBlank($0) } ? emptyReportMessage : nil)
    }

    static func providerPages(_ provider: HistoryExperience.Provider,
                              scope: [HistoryReport.ToolReport],
                              report: HistoryReport) -> HistoryExperience.ProviderPages {
        let active = scope.filter { !$0.isEmpty }
        // Two token-active providers means every figure has to say whose it is — the same rule
        // the legacy tabs used, page-wide so a day detail and its strip cannot disagree.
        let tagged: Bool
        if case .all = provider { tagged = active.count >= 2 } else { tagged = false }
        let strip = experienceDayStrip(scope, weeks: scope.first?.weeks ?? [])
        return HistoryExperience.ProviderPages(
            provider: provider,
            quota: quotaPage(provider, scope: scope, report: report),
            explore: explorePage(provider, scope: scope, tagged: tagged, strip: strip,
                                 report: report),
            hardBlocks: hardBlocksPage(provider, scope: scope, tagged: tagged))
    }

    /// The body-replacing empty state for one filter position — same copy the legacy tabs used.
    static func pageEmptyMessage(_ provider: HistoryExperience.Provider) -> String {
        switch provider {
        case .all:
            return emptyReportMessage
        case .tool(let tool):
            return "No local \(tool.tabLabel) activity in the last "
                + "\(HistoryReport.periodDays) days."
        }
    }

    // MARK: - Allowance evidence (REV-84 §4.1 item 2 / §6 item 6)

    /// The allowance panel (REV-84 §4.1 item 2 / §6 item 6): one REV-72 verdict per scoped
    /// provider (named on `All`, figure row only where earned) above the recorded changes,
    /// newest first, capped with the legacy surface's honest overflow row.
    static func allowancePanel(_ scope: [HistoryReport.ToolReport], named: Bool,
                               title: String) -> HistoryExperience.AllowancePanel? {
        var evidence: [HistoryExperience.Highlight] = []
        for t in scope where !isBlank(t) {
            let summary = windowChangeSummary(t)
            evidence.append(.init(
                lede: named ? "\(t.tool.tabLabel) — \(summary.verdict)" : summary.verdict,
                row: summary.row))
        }
        let changes = allowanceChangeRows(scope, tagged: named)
        guard !evidence.isEmpty || !changes.isEmpty else { return nil }
        return HistoryExperience.AllowancePanel(title: title, evidence: evidence,
                                                changes: changes)
    }

    /// Recorded changes across the scope, newest first, D-81 grammar, tagged on `All` —
    /// capped at `accountChangeRowLimit` with the STEP_141 overflow row naming what it hides.
    ///
    /// **A repeated fact is said once, with its count** (user decision 2026-09-01, live pass on
    /// STEP_163). This account's Codex weekly window resets early every other day, and the
    /// panel printed `Reset early · <date> → weekly window` three times in a 280-pt column —
    /// three rows carrying one fact about the account. Rows whose provider, lead **and** value
    /// are identical collapse into one, keyed by what the reader would see, spanning oldest to
    /// newest: the read-collapse principle `PlanChangeStability.settled` already applies to
    /// flapping plan names, applied to the panel that summarises. Nothing is dropped from the
    /// substrate, the cap now counts collapsed rows, and the day-by-day evidence in Explore is
    /// untouched — a day detail is chronology, not a summary.
    static func allowanceChangeRows(_ scope: [HistoryReport.ToolReport],
                                    tagged: Bool) -> [HistoryScreen.RankedRow] {
        let entries = scope
            .flatMap { t in changeEntries(t.accountChanges).map { (tool: t.tool, entry: $0) } }
            .sorted { $0.entry.at > $1.entry.at }
        guard !entries.isEmpty else { return [] }

        // Newest-first order is preserved: a group sits where its newest occurrence sat.
        var groups: [RepeatedChange] = []
        for item in entries {
            let parts = changeParts(item.entry)
            let key = "\(item.tool.tabLabel)|\(parts.lead)|\(parts.value)"
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].dates.append(item.entry.at)
            } else {
                groups.append(RepeatedChange(key: key, tool: item.tool, lead: parts.lead,
                                             value: parts.value, dates: [item.entry.at]))
            }
        }

        var rows = groups.prefix(accountChangeRowLimit).map { group in
            HistoryScreen.RankedRow(row: LabeledRow(label: group.label, value: group.value),
                                    tag: tagged ? group.tool.tabLabel : nil,
                                    at: group.newest)
        }
        let hiddenGroups = groups.dropFirst(accountChangeRowLimit)
        if let newestHidden = hiddenGroups.first?.newest,
           let oldestHidden = hiddenGroups.compactMap(\.oldest).min() {
            let hidden = hiddenGroups.reduce(0) { $0 + $1.dates.count }
            let span = Fmt.monthDay(oldestHidden) == Fmt.monthDay(newestHidden)
                ? Fmt.monthDay(oldestHidden)
                : "\(Fmt.monthDay(oldestHidden)) – \(Fmt.monthDay(newestHidden))"
            rows.append(HistoryScreen.RankedRow(
                row: LabeledRow(label: earlierChangesLabel, value: "\(hidden) more · \(span)")))
        }
        return rows
    }

    /// One recorded fact and every date it was recorded on — the unit the panel draws.
    struct RepeatedChange {
        let key: String
        let tool: Tool
        let lead: String
        let value: String
        /// Newest first, as the entries arrived.
        var dates: [Date]

        var newest: Date? { dates.first }
        var oldest: Date? { dates.last }

        /// `Plan changed · Aug 12` once; `Reset early · 3× · Aug 27 – Sep 1` when repeated —
        /// a count of recorded observations, never a size and never an accusation (§2.8).
        var label: String {
            guard let newest, let oldest else { return lead }
            guard dates.count > 1 else { return "\(lead) · \(Fmt.monthDay(newest))" }
            let span = Fmt.monthDay(oldest) == Fmt.monthDay(newest)
                ? Fmt.monthDay(newest)
                : "\(Fmt.monthDay(oldest)) – \(Fmt.monthDay(newest))"
            return "\(lead) · \(dates.count)× · \(span)"
        }
    }

    private static func isAll(_ provider: HistoryExperience.Provider) -> Bool {
        if case .all = provider { return true }
        return false
    }

    // MARK: - Explore usage (REV-84 §5)

    static func explorePage(_ provider: HistoryExperience.Provider,
                            scope: [HistoryReport.ToolReport], tagged: Bool,
                            strip: HistoryScreen.DayStrip?,
                            report: HistoryReport) -> HistoryExperience.ExplorePage {
        let breakdown = breakdown(scope, merged: isAll(provider), tagged: tagged)
        guard scope.contains(where: { !$0.isEmpty }) else {
            return HistoryExperience.ExplorePage(breakdown: breakdown,
                                                 emptyMessage: pageEmptyMessage(provider))
        }
        let axis = scope.max { $0.days.count < $1.days.count }?.days ?? []
        var entries: [HistoryExperience.DayEntry] = []
        if let strip {
            for (column, day) in axis.enumerated() where strip.points.indices.contains(column) {
                entries.append(.init(
                    id: day.start,
                    point: strip.points[column],
                    detail: dayDetail(column: column, axis: axis, scope: scope, tagged: tagged,
                                      periodEnd: report.periodEnd)))
            }
        }
        // Newest day with activity, else today — the last column (REV-84 §5.1).
        var initial: Date?
        if !entries.isEmpty {
            var lastActive: Int?
            for column in entries.indices {
                if scope.contains(where: {
                    $0.days.indices.contains(column) && $0.days[column].tokens > 0
                }) { lastActive = column }
            }
            initial = entries[lastActive ?? entries.count - 1].id
        }
        let active = scope.filter { !$0.isEmpty }
        return HistoryExperience.ExplorePage(
            days: entries,
            initialSelection: initial,
            legend: strip?.legend ?? [],
            stripFooter: strip?.footer ?? "",
            totals: providerTotals(scope),
            combinedValue: tagged && active.count >= 2
                ? Fmt.dollarValue(active.reduce(0) { $0 + $1.value }) : nil,
            weekly: providerWeekly(scope),
            breakdown: breakdown)
    }

    /// Every useful recorded fact about one selectable day (REV-84 §5.1), provider-safe:
    /// sections, models and counts grouped by provider, the combined dollar figure once and
    /// subordinate, events merged chronologically, and the honesty sentence exactly once.
    static func dayDetail(column: Int, axis: [HistoryReport.Day],
                          scope: [HistoryReport.ToolReport], tagged: Bool,
                          periodEnd: Date) -> HistoryExperience.DayDetail {
        let day = axis[column]
        let dayStart = day.start
        let dayEnd = column + 1 < axis.count ? axis[column + 1].start : periodEnd

        var sections: [HistoryExperience.DaySection] = []
        for t in scope {
            guard t.days.indices.contains(column) else { continue }
            let d = t.days[column]
            guard d.tokens > 0 else { continue }
            sections.append(HistoryExperience.DaySection(
                provider: t.tool,
                tokens: Fmt.tokens(d.tokens),
                value: Fmt.dollarValue(d.value),
                activity: countNoun(d.sessions, tool: t.tool),
                models: modelTokenRows(totals: d.modelTotals, tool: t.tool),
                projects: d.projects.map {
                    LabeledRow(label: $0.project.map(DisplayFormatter.projectName)
                                   ?? HistoryDisplay.noProjectLabel,
                               value: Fmt.tokens($0.tokens))
                }))
        }
        let combined: String? = sections.count >= 2
            ? Fmt.dollarValue(scope.reduce(0.0) {
                $0 + ($1.days.indices.contains(column) ? $1.days[column].value : 0)
            })
            : nil

        // Events, merged chronologically across providers — never summed, only interleaved.
        var blocks: [(Date, HistoryScreen.RankedRow)] = []
        var observations: [(Date, HistoryScreen.RankedRow)] = []
        var changes: [(Date, HistoryScreen.RankedRow)] = []
        for t in scope {
            let tag = tagged ? t.tool.tabLabel : nil
            blocks += t.limitBlocks
                .filter { $0.firedAt >= dayStart && $0.firedAt < dayEnd }
                // An unrecovered reset keeps the `—` §6.1 owns and takes the warn hue
                // (STEP_163 decision 1): an unknown lockout is not a zero one.
                .map { ($0.firedAt, HistoryScreen.RankedRow(row: blockRow($0), tag: tag,
                                                            warn: $0.lockoutSeconds == nil,
                                                            at: $0.firedAt)) }
            observations += t.criticalObservations
                .filter { $0.at >= dayStart && $0.at < dayEnd }
                .map { ($0.at, HistoryScreen.RankedRow(row: observationRow($0), tag: tag,
                                                       at: $0.at)) }
            changes += changeEntries(t.accountChanges)
                .filter { $0.at >= dayStart && $0.at < dayEnd }
                .map { ($0.at, HistoryScreen.RankedRow(row: accountChangeRow($0), tag: tag,
                                                       at: $0.at)) }
        }

        return HistoryExperience.DayDetail(
            title: Fmt.monthDay(dayStart),
            status: day.isPartial
                ? partialDayStatus
                : (sections.isEmpty ? noActivityDayStatus : nil),
            sections: sections,
            combinedValue: combined,
            blocks: blocks.sorted { $0.0 < $1.0 }.map(\.1),
            observations: observations.sorted { $0.0 < $1.0 }.map(\.1),
            changes: changes.sorted { $0.0 < $1.0 }.map(\.1),
            evidenceNote: evidenceNoteSentence)
    }

    /// One recorded block as its row (REV-73 grammar, unchanged): `Aug 12 · 5-hour · 3:34 pm`
    /// → `locked out 3h 25m`, with the window and the duration dropping out together.
    static func blockRow(_ block: HistoryReport.LimitBlock) -> LabeledRow {
        var parts = [Fmt.monthDay(block.firedAt)]
        if let grain = DisplayFormatter.windowGrain(seconds: block.windowSeconds) {
            parts.append(grain)
        }
        parts.append(Fmt.clock(block.firedAt))
        let value = block.lockoutSeconds.map { "locked out \(Fmt.span(seconds: $0))" } ?? "—"
        return LabeledRow(label: parts.joined(separator: " · "), value: value)
    }

    /// One recorded critical observation: `At risk · 3:34 pm` → `8% left`. The stored figure
    /// is utilization; the displayed percent is remaining (REV-77 / D-97 — `Fmt.percentLeft`
    /// is the one place the screen subtracts). `—` where no figure was stored.
    static func observationRow(_ observation: HistoryReport.CriticalObservation) -> LabeledRow {
        LabeledRow(
            label: "\(criticalStateLabel(observation.state)) · \(Fmt.clock(observation.at))",
            value: observation.utilizationPct.map { "\(Fmt.percentLeft($0)) left" } ?? "—")
    }

    /// `5 sessions` / `1 thread` — provider-native noun, singular at one.
    static func countNoun(_ count: Int, tool: Tool) -> String {
        let noun = tool == .codex ? "thread" : "session"
        return "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// Model rows with tokens **and** Est. token value, zipped from the report's index-aligned
    /// lists (the STEP_159 Core amendment) — one pricing path, no re-derivation. Zero-token
    /// rows drop out, largest displayed count first.
    static func modelValueRows(totals: [SQLiteStore.ModelTokenTotals],
                               values: [HistoryReport.ModelValue],
                               tool: Tool) -> [HistoryScreen.RankedRow] {
        var rows: [(tokens: Int, row: LabeledRow)] = []
        for (index, modelTotals) in totals.enumerated() {
            let tokens = DisplayedTokens.sum(modelTotals, tool: tool)
            guard tokens > 0 else { continue }
            let value = values.indices.contains(index) ? values[index].value : 0
            rows.append((tokens, LabeledRow(
                label: DisplayFormatter.modelDisplayName(modelTotals.model),
                value: "\(Fmt.tokens(tokens)) · \(Fmt.dollarValue(value))")))
        }
        let top = rows.map(\.tokens).max() ?? 0
        return rows.sorted { $0.tokens > $1.tokens }.map {
            HistoryScreen.RankedRow(row: $0.row,
                                    fraction: fraction($0.tokens, of: top),
                                    accent: tool)
        }
    }

    /// Day-grain model rows: displayed tokens only (REV-84 §5.1 as amended 2026-09-01 — the
    /// day's value is the section's own figure), zero-token rows out, largest first.
    static func modelTokenRows(totals: [SQLiteStore.ModelTokenTotals],
                               tool: Tool) -> [LabeledRow] {
        totals.compactMap { modelTotals -> (tokens: Int, row: LabeledRow)? in
            let tokens = DisplayedTokens.sum(modelTotals, tool: tool)
            guard tokens > 0 else { return nil }
            return (tokens, LabeledRow(
                label: DisplayFormatter.modelDisplayName(modelTotals.model),
                value: Fmt.tokens(tokens)))
        }
        .sorted { $0.tokens > $1.tokens }.map(\.row)
    }

    /// Visible 30-day totals, one per token-active provider (REV-84 §5.2). There is no
    /// combined variant — the type has no field for one. Cache hit lives in the provider
    /// Summary's Local-tokens caption, not here (§7 as amended 2026-09-01).
    static func providerTotals(_ scope: [HistoryReport.ToolReport])
        -> [HistoryExperience.ProviderTotal] {
        scope.filter { !$0.isEmpty }.map { t in
            HistoryExperience.ProviderTotal(
                provider: t.tool,
                title: "\(t.tool.tabLabel) total",
                tokens: Fmt.tokens(t.totalTokens),
                activity: countNoun(t.sessions, tool: t.tool),
                value: Fmt.dollarValue(t.value))
        }
    }

    /// Week rows with tokens and value as separate typed fields (REV-84 §5.2), newest first,
    /// each bar against the same provider's busiest week. A zero week is a known zero —
    /// `No activity` and `$0.00` — because the local corpus is permanent.
    static func providerWeekly(_ scope: [HistoryReport.ToolReport])
        -> [HistoryExperience.ProviderWeekly] {
        scope.filter { t in t.weeks.contains { $0.tokens > 0 } }.map { t in
            let busiest = t.weeks.map(\.tokens).max() ?? 0
            let rows = t.weeks.map { week in
                HistoryExperience.WeekRow(
                    label: "\(Fmt.monthDay(week.start)) – \(Fmt.monthDay(week.end))",
                    tokens: week.tokens > 0 ? Fmt.tokens(week.tokens) : noActivityValue,
                    value: Fmt.dollarValue(week.value),
                    fraction: busiest > 0 ? Double(week.tokens) / Double(busiest) : 0,
                    note: week.isPartial ? partialWeekNote : nil)
            }
            return HistoryExperience.ProviderWeekly(provider: t.tool, rows: rows)
        }
    }

    /// The 30-day breakdown (REV-84 §5.3): projects and largest work ranked as the legacy
    /// window ranked them, models grouped per provider with tokens and value.
    static func breakdown(_ scope: [HistoryReport.ToolReport], merged: Bool,
                          tagged: Bool) -> HistoryExperience.Breakdown {
        HistoryExperience.Breakdown(
            title: breakdownTitle,
            projects: breakdownProjects(scope, merged: merged, tagged: tagged),
            models: scope.compactMap { t in
                let rows = modelValueRows(totals: t.modelTotals, values: t.modelValues,
                                          tool: t.tool)
                return rows.isEmpty
                    ? nil : HistoryExperience.ModelGroup(provider: t.tool, rows: rows)
            },
            largestWork: largestWorkRows(scope, merged: merged, tagged: tagged))
    }

    /// The corrected `ProjectGrouping` ranking (STEP_157 preserved): merged and capped on
    /// `All`, the reader's own top rows on a provider filter.
    static func breakdownProjects(_ scope: [HistoryReport.ToolReport], merged: Bool,
                                  tagged: Bool) -> [HistoryScreen.RankedRow] {
        guard merged else {
            return scope.flatMap { t -> [HistoryScreen.RankedRow] in
                let top = t.projects.map(\.tokens).max() ?? 0
                return t.projects.map {
                    HistoryScreen.RankedRow(row: projectRow($0, tool: t.tool),
                                            fraction: fraction($0.tokens, of: top),
                                            accent: t.tool)
                }
            }
        }
        return scope.flatMap { t -> [(tokens: Int, row: HistoryScreen.RankedRow)] in
            let top = t.projects.map(\.tokens).max() ?? 0
            return t.projects.map { project in
                (tokens: project.tokens,
                 row: HistoryScreen.RankedRow(row: projectRow(project, tool: t.tool),
                                              tag: tagged ? t.tool.tabLabel : nil,
                                              fraction: fraction(project.tokens, of: top),
                                              accent: t.tool))
            }
        }
        .sorted { $0.tokens > $1.tokens }
        .prefix(allRankedRowLimit)
        .map(\.row)
    }

    /// Track geometry for a ranked row (STEP_162): this row's share of the same provider's
    /// top row. Nil — no track — when the provider has no positive top.
    private static func fraction(_ tokens: Int, of top: Int) -> Double? {
        top > 0 ? Double(tokens) / Double(top) : nil
    }

    static func largestWorkRows(_ scope: [HistoryReport.ToolReport], merged: Bool,
                                tagged: Bool) -> [HistoryScreen.RankedRow] {
        guard merged else {
            return scope.flatMap { t -> [HistoryScreen.RankedRow] in
                let top = t.topSessions.map(\.tokens).max() ?? 0
                return t.topSessions.map {
                    HistoryScreen.RankedRow(row: sessionRow($0),
                                            fraction: fraction($0.tokens, of: top),
                                            accent: t.tool)
                }
            }
        }
        return scope.flatMap { t -> [(tokens: Int, row: HistoryScreen.RankedRow)] in
            let top = t.topSessions.map(\.tokens).max() ?? 0
            return t.topSessions.map { session in
                (tokens: session.tokens,
                 row: HistoryScreen.RankedRow(row: sessionRow(session),
                                              tag: tagged ? t.tool.tabLabel : nil,
                                              fraction: fraction(session.tokens, of: top),
                                              accent: t.tool))
            }
        }
        .sorted { $0.tokens > $1.tokens }
        .prefix(allRankedRowLimit)
        .map(\.row)
    }

    // MARK: - Hard blocks (REV-84 §6)

    static func hardBlocksPage(_ provider: HistoryExperience.Provider,
                               scope: [HistoryReport.ToolReport],
                               tagged: Bool) -> HistoryExperience.HardBlocksPage {
        let eyebrow = "\(providerDisplayName(provider)) · hard blocks"
        guard !scope.allSatisfy({ isBlank($0) }) else {
            return HistoryExperience.HardBlocksPage(eyebrow: eyebrow, conclusion: "",
                                                    coverageNote: coverageNote(scope),
                                                    emptyMessage: pageEmptyMessage(provider))
        }
        // Chronological merge, newest first, each row named by its provider on All — never an
        // aggregate row in the list: the conclusion strip is the aggregate (D-108).
        let rows = scope.flatMap { t in
            t.limitBlocks.map { (at: $0.firedAt,
                                 row: HistoryScreen.RankedRow(
                                    row: blockRow($0),
                                    tag: tagged ? t.tool.tabLabel : nil,
                                    // Unknown lockout → the `—` in warn (STEP_163).
                                    warn: $0.lockoutSeconds == nil,
                                    at: $0.firedAt)) }
        }
        .sorted { $0.at > $1.at }
        .map(\.row)
        return HistoryExperience.HardBlocksPage(
            eyebrow: eyebrow,
            conclusion: blocksConclusion(scope, named: tagged),
            consequence: blockConsequence(scope),
            rows: rows,
            chart: experienceHourChart(scope),
            patternNote: patternNote(scope, named: tagged),
            coverageNote: coverageNote(scope),
            allowance: allowancePanel(scope, named: tagged, title: allowanceHistoryTitle))
    }

    /// The conclusion lead: counts per provider and the last block. The lockout aggregate is
    /// the `consequence` card's job (STEP_160 split), so this never repeats it.
    static func blocksConclusion(_ scope: [HistoryReport.ToolReport], named: Bool) -> String {
        let blocks = scope.flatMap(\.limitBlocks)
        guard !blocks.isEmpty else {
            return "No recorded hard blocks in the last \(HistoryReport.periodDays) days."
        }
        var lead: String
        if named {
            lead = scope.filter { !$0.limitBlocks.isEmpty }
                .map { t in
                    "\(t.tool.tabLabel) \(t.limitBlocks.count) "
                        + "block\(t.limitBlocks.count == 1 ? "" : "s")"
                }
                .joined(separator: " · ")
        } else {
            lead = "\(blocks.count) recorded block\(blocks.count == 1 ? "" : "s")"
        }
        if let last = blocks.map(\.firedAt).max() { lead += " · last \(Fmt.monthDay(last))" }
        return lead + "."
    }

    /// The known-consequence card (REV-84 §6 item 1, carded by the companion): the total
    /// known lockout as the figure, the recovery denominator named in the caption whenever a
    /// duration is missing — never a total that silently reads as complete. `Unknown` when
    /// blocks exist but no reset was recovered; nil with no blocks.
    static func blockConsequence(_ scope: [HistoryReport.ToolReport])
        -> HistoryExperience.Stat? {
        let blocks = scope.flatMap(\.limitBlocks)
        guard !blocks.isEmpty else { return nil }
        let timed = blocks.filter { $0.lockoutSeconds != nil }
        guard !timed.isEmpty else {
            return HistoryExperience.Stat(
                label: knownConsequenceLabel, figure: "Unknown",
                caption: blocks.count == 1
                    ? "The reset could not be recovered."
                    : "No reset could be recovered.")
        }
        let total = timed.reduce(0) { $0 + ($1.lockoutSeconds ?? 0) }
        var caption: String
        if timed.count == blocks.count {
            caption = blocks.count == 1
                ? "The reset was recovered."
                : "All \(blocks.count) resets recovered."
        } else {
            caption = "\(timed.count) of \(blocks.count) resets recovered."
        }
        if timed.count > 1,
           let longest = timed.max(by: { ($0.lockoutSeconds ?? 0) < ($1.lockoutSeconds ?? 0) }),
           let seconds = longest.lockoutSeconds {
            caption += " Longest \(Fmt.span(seconds: seconds)) on "
                + "\(Fmt.monthDay(longest.firedAt))."
        }
        return HistoryExperience.Stat(label: knownConsequenceLabel,
                                      figure: Fmt.span(seconds: total), caption: caption)
    }

    /// Provider-scoped pattern claim, still behind `claimedRhythmFloor` (REV-73). Below the
    /// floor the investigative note states the sample honestly — here and only here.
    static func patternNote(_ scope: [HistoryReport.ToolReport], named: Bool) -> String? {
        let withBlocks = scope.filter { !$0.limitBlocks.isEmpty }
        guard !withBlocks.isEmpty else { return nil }
        let claims = withBlocks.compactMap { t in
            claimedRhythm(t.limitBlocks).map { (tool: t.tool, band: $0) }
        }
        guard !claims.isEmpty else { return blockSampleNote }
        return claims.map { claim in
            named
                ? "\(claim.tool.tabLabel) · \(mostOftenLabel) \(claim.band)"
                : "\(mostOftenLabel) \(claim.band)"
        }
        .joined(separator: " · ")
    }

    /// Coverage, honestly (REV-84 §6 item 5): the watching horizon, the weekly-only gap
    /// (STEP_120 / P1-18) and the unknown-reset rule, in one plain sentence pair.
    static func coverageNote(_ scope: [HistoryReport.ToolReport]) -> String {
        let horizon = scope.compactMap(\.watchingSince).min()
            .map { "Recorded since \(Fmt.monthDay($0)), when Kvotar began watching." }
            ?? "Recorded from the day Kvotar starts watching — nothing yet."
        return horizon + " Weekly-only exhaustion may not appear, and an unknown reset means "
            + "an unknown lockout, not zero."
    }

    // MARK: - Provider-safe charts (REV-84 §3.1 — independent scales)

    /// The day strip with **per-provider normalisation**: each bar's fraction is against that
    /// provider's own busiest day, so on `All` the two lanes never share a scale and no drawn
    /// height implies a token comparison. Markers, ticks, hover grammar and footer are the
    /// legacy strip's, unchanged. (The legacy `dayStrip` keeps its stacked shared axis for the
    /// old view until STEP_160 deletes it.)
    static func experienceDayStrip(_ tools: [HistoryReport.ToolReport],
                                   weeks: [HistoryReport.Week]) -> HistoryScreen.DayStrip? {
        let active = tools.filter { t in t.days.contains { $0.tokens > 0 } }
        guard !active.isEmpty, let columns = tools.map(\.days.count).max(), columns > 0
        else { return nil }

        var ownMax: [Tool: Int] = [:]
        for t in tools { ownMax[t.tool] = t.days.map(\.tokens).max() ?? 0 }

        let axisDays = tools.max { $0.days.count < $1.days.count }?.days ?? []
        let ticks = tickColumns(days: axisDays, weeks: weeks)
        let named = active.count >= 2
        let changesByTool = tools.map { changeColumns($0) }

        var points: [HistoryScreen.DayPoint] = []
        for column in 0..<columns {
            var bars: [HistoryScreen.DayBar] = []
            var markers: [Tool] = []
            var changeMarkers: [Tool] = []
            var figures: [String] = []
            var changeLines: [String] = []
            var date: String?
            var isPartial = false
            for (index, t) in tools.enumerated() where t.days.indices.contains(column) {
                let d = t.days[column]
                if date == nil {
                    date = Fmt.monthDay(d.start)
                    isPartial = d.isPartial
                }
                if d.tokens > 0 {
                    let axis = ownMax[t.tool] ?? 0
                    bars.append(HistoryScreen.DayBar(
                        tool: t.tool,
                        fraction: axis > 0 ? Double(d.tokens) / Double(axis) : 0))
                    figures.append(dayFigure(d, tool: t.tool, named: named))
                }
                if d.hitLimit { markers.append(t.tool) }
                let changes = changesByTool[index][column] ?? []
                if !changes.isEmpty { changeMarkers.append(t.tool) }
                changeLines += changes.map { changeHoverLine($0, tool: t.tool, named: named) }
            }
            var head = "**\(date ?? "")**"
            if isPartial { head += " · \(partialDayNote)" }
            var hover: String
            if figures.isEmpty {
                hover = "\(head) · \(noActivityDayValue)"
            } else if named {
                hover = ([head] + figures).joined(separator: "\n")
            } else {
                hover = "\(head) · \(figures[0])"
            }
            if !changeLines.isEmpty { hover = ([hover] + changeLines).joined(separator: "\n") }
            // The spoken sibling (STEP_160 — REV-84 §8), from the same parts so the two cannot
            // drift: plain-text date, the hover's own figures and change lines, plus the facts
            // the drawn marks carry visually — a block dot has no text in the hover, but the
            // accessibility value must say it.
            var a11yHead = date ?? ""
            if isPartial { a11yHead += " · \(partialDayStatus)" }
            var a11yParts = figures.isEmpty ? [a11yHead + " · \(noActivityDayStatus)"]
                                            : [a11yHead] + figures
            a11yParts += markers.map {
                named ? "\($0.tabLabel) \(limitHitA11yFact)" : limitHitLegendLabel
            }
            a11yParts += changeLines
            points.append(HistoryScreen.DayPoint(
                bars: bars, hitLimitTools: markers, changeTools: changeMarkers,
                tickLabel: ticks.contains(column) && axisDays.indices.contains(column)
                    ? Fmt.monthDay(axisDays[column].start) : nil,
                hoverBody: hover,
                accessibilityValue: a11yParts.joined(separator: " · ")))
        }

        var legend: [HistoryScreen.DayLegendEntry] = []
        if named {
            legend = active.map { HistoryScreen.DayLegendEntry(label: $0.tool.tabLabel,
                                                               tool: $0.tool) }
        }
        if tools.contains(where: { $0.days.contains(where: \.hitLimit) }) {
            legend.append(HistoryScreen.DayLegendEntry(label: limitHitLegendLabel, tool: nil,
                                                       marker: .limitHit))
        }
        if changesByTool.contains(where: { !$0.isEmpty }) {
            legend.append(HistoryScreen.DayLegendEntry(label: accountChangeLegendLabel, tool: nil,
                                                       marker: .accountChange))
        }
        return HistoryScreen.DayStrip(points: points, legend: legend,
                                      footer: busiestDayFooter(active, named: named))
    }

    /// The hour-of-day chart with per-provider normalisation — same gates, marks, hover and
    /// caption as the legacy chart, but each bar's fraction is against that provider's own
    /// busiest hour (REV-84 §6 item 3).
    static func experienceHourChart(_ tools: [HistoryReport.ToolReport])
        -> HistoryScreen.HourChart? {
        guard tools.contains(where: { t in
            t.limitBlocks.contains { ($0.windowSeconds ?? .max) <= shortWindowSeconds }
        }) else { return nil }
        let working = tools.filter { $0.workByHour.contains { $0 > 0 } }
        guard !working.isEmpty else { return nil }

        var ownMax: [Tool: Int] = [:]
        for t in tools { ownMax[t.tool] = t.workByHour.max() ?? 0 }
        var combined = [Int](repeating: 0, count: 24)
        for t in tools {
            for hour in 0..<24 { combined[hour] += hourWork(t, hour) }
        }
        guard combined.contains(where: { $0 > 0 }) else { return nil }
        let named = working.count >= 2

        var marks: [Int: [Tool]] = [:]
        for t in tools {
            for block in t.limitBlocks {
                marks[Calendar.current.component(.hour, from: block.firedAt), default: []]
                    .append(t.tool)
            }
        }

        var points: [HistoryScreen.HourPoint] = []
        for hour in 0..<24 {
            var bars: [HistoryScreen.DayBar] = []
            var figures: [String] = []
            for t in working where hourWork(t, hour) > 0 {
                let axis = ownMax[t.tool] ?? 0
                bars.append(HistoryScreen.DayBar(
                    tool: t.tool,
                    fraction: axis > 0 ? Double(hourWork(t, hour)) / Double(axis) : 0))
                let figure = Fmt.tokens(hourWork(t, hour))
                figures.append(named ? "\(t.tool.tabLabel) \(figure)" : figure)
            }
            let head = "**\(hourLabel(hour))**"
            var hover = figures.isEmpty
                ? "\(head) · \(noActivityDayValue)"
                : (named ? ([head] + figures).joined(separator: "\n") : "\(head) · \(figures[0])")
            let blocks = marks[hour]?.count ?? 0
            if blocks > 0 { hover += "\n\(blocks) block\(blocks == 1 ? "" : "s")" }
            points.append(HistoryScreen.HourPoint(
                bars: bars, blockTools: marks[hour] ?? [],
                tickLabel: hour % 6 == 0 ? shortHourLabel(hour) : nil,
                hoverBody: hover))
        }

        var legend: [HistoryScreen.DayLegendEntry] = []
        if named {
            legend = working.map { HistoryScreen.DayLegendEntry(label: $0.tool.tabLabel,
                                                                tool: $0.tool) }
        }
        legend.append(HistoryScreen.DayLegendEntry(label: limitHitLegendLabel, tool: nil,
                                                   marker: .limitHit))
        return HistoryScreen.HourChart(points: points, legend: legend,
                                       caption: hourCaption(marks: marks, work: combined))
    }

    private static func hourWork(_ t: HistoryReport.ToolReport, _ hour: Int) -> Int {
        t.workByHour.indices.contains(hour) ? t.workByHour[hour] : 0
    }

    // MARK: - Footer

    /// The REV-84 §8 footer: what the records are, that the horizons differ, and the pricing
    /// stamp. The legacy footer's `evidence from …` date moves into mode-level coverage notes.
    static func experienceFooter(_ report: HistoryReport) -> String {
        var parts = ["Local Claude Code and Codex records on this Mac", "evidence horizons vary"]
        if let version = report.pricingVersion {
            if let updated = report.pricingUpdated {
                parts.append("prices v\(version) (\(updated))")
            } else {
                parts.append("prices v\(version)")
            }
        }
        return parts.joined(separator: " · ")
    }
}
