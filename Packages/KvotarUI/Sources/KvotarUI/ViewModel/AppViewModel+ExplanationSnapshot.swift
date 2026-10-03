import Foundation
import KvotarCore

/// The diagnostics half of the explanation layer (REV-75/D-93 — STEP_133): what the popover was
/// explaining, written into the bundle a tester saves.
///
/// The layer's live line is silent when a value it needed is missing (rule 4 — the card shows its
/// concept text alone, never a placeholder). On screen that is right; in a bundle it leaves us
/// unable to tell a card that said nothing from a card that said the wrong thing. This walk
/// records each target as rendered, with the line that filled it **or the reason it was dropped**.
///
/// **It reads the rendered state; it never re-derives one.** `claudeState` / `codexState` are what
/// the popover is showing, and the drop reasons are already on them (STEP_130 stores them). The
/// only thing this file computes is the `inputs` block, and that comes from the same retained
/// render the display was built from.
///
/// **Only tagged elements are walked, and that is the privacy rule** (D-93): a row the formatter
/// left untagged is inert on screen and absent here, which is what keeps the last active project,
/// the per-model rows, the session counts, the account email and the plan badge out of the file.
/// Nothing is filtered on the way in — nothing that would need filtering can reach it.
extension AppViewModel {

    /// What the popover was explaining, or `nil` when no tab has a render (loading, idle,
    /// undetected) — the bundle then carries a manifest note instead of an empty file.
    public func explanationSnapshot(now: Date = Date()) -> ExplanationSnapshot? {
        let tools = Tool.allCases.compactMap { toolSnapshot(for: $0, now: now) }
        guard !tools.isEmpty else { return nil }
        return ExplanationSnapshot(
            takenAt: now,
            activeTab: activeTab.rawValue,
            // The timings actually in force, not the constants: a card that never opened for a
            // tester is a timing question before it is a copy question.
            peekDelayMs: Self.milliseconds(hoverPeekDelay),
            graceLeaveMs: Self.milliseconds(hoverGraceLeave),
            tools: tools)
    }

    private func toolSnapshot(for tool: Tool, now: Date)
        -> ExplanationSnapshot.ToolSnapshot? {
        guard let retained = snapshotInputs(for: tool, now: now) else { return nil }
        let extra = explanationInputs(for: tool)

        var walk: ExplanationWalk
        let verdict: HeaderVerdict?
        switch tool {
        case .claude:
            let state = claudeState
            walk = ExplanationWalk(tool: .claude, grain: nil, freeze: state.sourceFreeze)
            walk.claude(state)
            verdict = state.header?.verdict
        case .codex:
            let state = codexState
            walk = ExplanationWalk(tool: .codex, grain: state.windowGrain,
                                   freeze: state.sourceFreeze)
            walk.codex(state)
            verdict = state.header?.verdict
        }

        return ExplanationSnapshot.ToolSnapshot(
            tool: tool.rawValue,
            stale: retained.stale,
            inputs: Self.inputs(snapshot: retained.snapshot, offMachinePct: retained.offMachinePct,
                                forecast: extra?.forecast, attribution: extra?.attribution,
                                monthly: extra?.monthly,
                                monthlyRatePerHour: extra?.monthlyRatePerHour, now: now),
            entries: walk.entries,
            anatomy: verdict?.anatomy.map { source in
                ExplanationSnapshot.Anatomy(
                    family: verdict?.family.rawValue ?? VerdictFamily.unknown.rawValue,
                    rows: source.rows.map { [$0.label, $0.value] },
                    comparison: source.comparison,
                    flip: source.flip)
            })
    }

    /// What the entries above were computed *from* — so a wrong line can be told apart from a
    /// wrong input. Absent values are omitted rather than written as a dash: a key that is not
    /// there means "the render had none", which is the fact worth carrying.
    private static func inputs(snapshot: QuotaSnapshot, offMachinePct: Double?,
                               forecast: Forecast?, attribution: LocalAttribution?,
                               monthly: MonthlyAttribution?, monthlyRatePerHour: Double?,
                               now: Date) -> [String: String] {
        var values: [String: String] = [:]
        func put(_ key: String, _ value: String?) { if let value { values[key] = value } }

        put("usedPct", snapshot.primaryUsedPct.map { Fmt.percent($0) })
        put("weeklyPct", snapshot.secondaryUsedPct.map { Fmt.percent($0) })
        put("windowSeconds", snapshot.primaryWindowSeconds.map(String.init))
        put("primaryResetsAt", snapshot.primaryResetsAt.map(BundleTime.iso))
        put("secondaryResetsAt", snapshot.secondaryResetsAt.map(BundleTime.iso))
        put("primaryWindowStart", snapshot.primaryWindowStart.map(BundleTime.iso))
        put("burnPctPerMin", forecast?.burnRatePerMin.map { String(format: "%.4f", $0) })
        put("runwayMinutes", forecast?.runwayMinutes.map { String(format: "%.0f", $0) })
        put("burnSpanMinutes", forecast?.burnSpanMinutes.map { String(format: "%.0f", $0) })
        put("forecastPolls", forecast.map { "\($0.pollCount)" })
        put("offMachinePct", offMachinePct.map { Fmt.percent($0) })
        put("tokensPerMinute", attribution?.tokensPerMinute.map { String(format: "%.0f", $0) })
        put("monthlyUsed", monthly.map { String(format: "%.2f", $0.usedAmount) })
        put("monthlyLimit", snapshot.monthlyLimit.map { String(format: "%.2f", $0.limitAmount) })
        put("monthlyResetsAt", snapshot.monthlyLimit.map { BundleTime.iso($0.resetsAt) })
        put("monthlyLocal", monthly.map { String(format: "%.2f", $0.localAmount) })
        put("monthlyElsewhere", monthly.map { String(format: "%.2f", $0.offMachineAmount) })
        put("monthlyUnattributed", monthly.map { String(format: "%.2f", $0.unattributedAmount) })
        put("monthlyRatePerHour", monthlyRatePerHour.map { String(format: "%.4f", $0) })
        values["renderedAt"] = BundleTime.iso(now)
        return values
    }

    /// `Duration` → whole milliseconds. `components.attoseconds` is 1e18 per second, so 1e15 per
    /// millisecond.
    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - The walk

/// Collects one tab's tagged elements in render order.
///
/// The section vocabulary is the one `ExplanationLiveDiagnostics` (STEP_130) already prints, so
/// the bundle file and that report read as one format: `site` names the card or header slot, and
/// `label` the row inside it. Two cards can carry the same row label, so it takes both.
private struct ExplanationWalk {
    let tool: Tool
    let grain: String?
    let freeze: SourceFreeze?

    private(set) var entries: [ExplanationSnapshot.Entry] = []

    // MARK: Primitives

    /// One target. Untagged (`element == nil`) and fully inert targets are skipped — the same test
    /// the view applies, so the file holds exactly what the pointer could have opened.
    mutating func add(_ element: ExplanationElement?, site: String, label: String?, value: String,
                      live: ExplanationLive?, card: String? = nil) {
        guard let element else { return }
        let cardText = card ?? ExplanationRegistry.card(element, tool: tool, grain: grain)
        guard cardText != nil || live != nil else { return }
        entries.append(ExplanationSnapshot.Entry(
            element: element.specID,
            site: site,
            label: label,
            value: value,
            cardText: cardText,
            liveLine: live?.text,
            liveDropReason: {
                if case .dropped(let reason)? = live { return reason.rawValue }
                return nil
            }()))
    }

    mutating func rows(_ site: String, _ rows: [LabeledRow]?) {
        for row in rows ?? [] {
            add(row.explanation, site: site, label: row.label, value: row.value,
                live: row.explanationLive)
        }
    }

    /// E-09 — the one state-aware card, assembled from the terms the tag is showing. A tag that
    /// shows none of them (the local JSONL tag, the "Priced at…" note) resolves to no card and is
    /// inert, exactly as on screen.
    mutating func sourceTag(_ site: String, _ tag: SourceTag?) {
        guard let tag else { return }
        add(.sourceTag, site: site, label: nil,
            value: tag.age.map { "\(tag.base) · \($0)" } ?? tag.base, live: nil,
            card: ExplanationRegistry.sourceTagCard(tool: tool, tag: tag, freeze: freeze))
    }

    // MARK: Shared sections

    private mutating func header(_ header: HeaderSection?) {
        guard let header else { return }
        // A placeholder hero (`——` / `––`) carries no card — the view's own test, repeated so an
        // idle tab records no target the pointer could not have opened.
        if !header.heroText.allSatisfy({ $0 == "—" || $0 == "–" || $0 == " " }) {
            add(header.heroExplanation, site: "header hero", label: nil, value: header.heroText,
                live: header.heroLive)
        }
        // The caption names the selected limit; under a primary hero it is E-01 and carries
        // E-01's live line, which is exactly what the view attaches (STEP_178).
        if let caption = header.limitCaption, header.limit?.id == .primaryWindow {
            add(.primaryWindow, site: "caption", label: nil, value: caption,
                live: header.windowScopeLive)
        }
        if let verdict = header.verdict, let line2 = verdict.line2 {
            // E-08's card *is* its live slot (D-90), so it passes an explicit nil card and relies
            // on `detailLive`; the formatter already returns nil wherever line 2 is inert, so an
            // inert line records no drop.
            add(.verdictDetail, site: "verdict line 2", label: nil, value: line2,
                live: verdict.detailLive, card: nil)
        }
        // The §2.2 strip (STEP_195). It is a tagged element, so the bundle records what it said —
        // and nothing on the §17 never-store list rides it: the text is a limit name, a percentage
        // and a date.
        if let strip = header.longLimitStrip {
            add(strip.explanation, site: "long limit strip", label: nil, value: strip.text,
                live: strip.explanationLive)
        }
        for detail in header.heroDetails {
            guard let element = detail.explanation else { continue }
            add(element, site: "hero detail", label: nil, value: detail.text, live: nil)
        }
        for warning in header.modelWarnings {
            add(warning.explanation, site: "model warning", label: nil,
                value: "\(warning.headline) · \(warning.detail)", live: nil)
        }
        // The two header facts (STEP_176), each carrying the card that followed the quantity when
        // the burn card was retired (STEP_178): E-05 / E-21 for the burn, E-07 / E-19 for the
        // estimate. An inapplicable fact is not on screen, so it is not recorded.
        for fact in [header.accountBurn, header.notSeenLocally].compactMap({ $0 }) {
            guard fact.isApplicable else { continue }
            add(fact.explanation, site: "header fact", label: fact.label, value: fact.value,
                live: nil, card: fact.explanationBody)
        }
        sourceTag("header", header.sourceTag)
    }

    private mutating func otherLimits(_ section: OtherLimitsSection?) {
        guard let section else { return }
        for row in section.rows + section.modelGroups.flatMap(\.rows) {
            add(row.explanation, site: "other limits", label: row.label,
                value: [row.value, row.detail, row.reset].compactMap { $0 }.joined(separator: " · "),
                live: row.explanationLive)
            if let element = row.resetExplanation, let reset = row.reset {
                add(element, site: "\(row.label) reset", label: nil, value: reset, live: nil)
            }
            if let meta = row.meta, let element = meta.explanation {
                add(element, site: "\(row.label) pace", label: nil, value: meta.text, live: nil)
            }
        }
        sourceTag("other limits", section.sourceTag)
    }

    /// The daily local section (STEP_178). **Only the fixed rows are recorded** — the project
    /// names, their paths and their per-model rows never enter the bundle, which is what keeps
    /// the §17 never-store list intact now that the section carries an explanation at all. The
    /// recency marker reports a constant site for the same reason.
    private mutating func localActivity(_ section: LocalActivitySection?) {
        guard let section else { return }
        let site = "local activity"
        if let summary = section.summary {
            add(.localActivity, site: site, label: summary.label, value: summary.value, live: nil)
        }
        add(.cacheHit, site: site, label: LocalActivitySection.cacheHitLabel,
            value: section.cacheHit, live: nil)
        if section.projects.contains(where: \.isMostRecent) {
            add(.projectRecency, site: LocalActivitySection.recencySite, label: nil,
                value: LocalActivitySection.recencyMarker, live: nil)
        }
        for (index, row) in section.valueRows.enumerated() {
            add(index == 0 ? .estTokenValue : .rollingHorizons, site: "estimated value",
                label: row.label, value: row.value, live: nil)
        }
        sourceTag(site, section.sourceTag)
    }

    // MARK: Tabs

    /// Every collection on the state is walked, not an enumerated subset: the tagged-only test
    /// makes an untagged card free, and an element tagged later is picked up without a second edit.
    mutating func claude(_ state: ClaudeDisplayState) {
        header(state.header)
        otherLimits(state.otherLimits)
        localActivity(state.localActivity)
        if let credits = state.creditsCard {
            add(credits.status.explanation, site: "credits card", label: credits.status.label,
                value: credits.status.value, live: credits.status.explanationLive)
            rows("credits card", credits.rows)
            sourceTag("credits card", credits.sourceTag)
        }
    }

    mutating func codex(_ state: CodexDisplayState) {
        header(state.header)
        otherLimits(state.otherLimits)
        localActivity(state.localActivity)
        rows("credits spend", state.creditsSpend?.rows)
    }
}
