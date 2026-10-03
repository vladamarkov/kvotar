import Foundation
import KvotarCore

/// Explore quota — the provider-truth mode (STEP_182 — REV-93 §2.3 / UI Spec §6.3).
///
/// Every other block on this surface reads the local token corpus. This one reads what Claude and
/// Codex themselves said about the account: `QuotaWindowOutcomes.compute` (Core, STEP_181) already
/// folded thirty days of `quota_series` readings into the windows they describe, with each
/// window's own recorded width and an explicit statement of how much of it Kvotar watched. What is
/// left is the display contract — the shape to draw, the sentence above it, the segment breaks and
/// the pinned detail — and none of it is arithmetic SwiftUI is allowed to repeat.
///
/// **The retrospective `% used` exception.** Every live surface in the app shows `% left`
/// (REV-77 / D-97). This chart shows consumption ending at a limit, so its axis and its copy read
/// `% used` and 100 % sits at the top (§6.1). No surface mixes the two, and nothing here prints an
/// unlabeled percentage.
extension HistoryDisplay {

    // MARK: - Vocabulary

    /// The mode's own eyebrow subject.
    static let quotaEyebrowSuffix = "quota windows"
    /// The coverage label §6.3 requires, and the sentence that stops it reading as a claim about
    /// secondary, monthly or model allowances — whose per-poll history is not stored at all.
    static let quotaScopeNote =
        "Main account window history. Secondary, monthly and model allowances are shown live in "
        + "the popover and have no recorded history here."
    /// The fresh-install state. Poll evidence cannot be backfilled, and saying so is the point.
    static let quotaFreshInstallMessage =
        "Quota history starts as Kvotar observes provider windows on this Mac. Earlier windows "
        + "cannot be recovered."
    /// Below `quotaPatternFloor` completed windows. The observed points are still drawn.
    static let quotaSparseNote = "Not enough completed windows to show a pattern yet."
    /// What the empty detail slot says before a point is pinned (STEP_183). Selection is by
    /// click or keyboard — hover previews the same facts but is never the only route (§6.3).
    static let quotaSelectHint = "Select a window to see how it ended."
    /// The context disclaimer under a local-activity row: correlation is all this can be.
    static let quotaLocalContextNote =
        "Local work is shown for context. It does not prove what moved the window."
    /// The title a section falls back to where its windows do not share one recorded width.
    static let quotaMixedWidthTitle = "main account window"
    /// Why a run of windows is drawn as separate points rather than a line. Rows written before
    /// migration `v23` carry no width, so they have no defensible start — and without a start
    /// nothing can establish that one window abuts the next. Drawing a line would assert exactly
    /// that (§6.3's interpolation ban), so the points stand alone until the recorded history
    /// catches up.
    static let quotaUnrecordedWidthNote =
        "These windows were recorded before Kvotar stored window widths, so their starts are "
        + "unknown and the points are not joined."
    /// A recovered width remains labelled as reconstructed evidence even though it is safe to
    /// draw. The database row itself is unchanged.
    static let quotaRecoveredWidthNote =
        "Earlier window lengths were recovered from provider evidence."
    static let quotaPartlyRecoveredWidthNote =
        "Earlier window lengths were recovered where provider records identify them. Remaining "
        + "unknown points are not joined."

    /// Completed windows needed before the surface stops saying it has too few. Three, the same
    /// floor `minimumQualifyingCycles` uses next door — one outcome is an anecdote and two are a
    /// pair, whatever they show.
    static let quotaPatternFloor = 3
    /// A completed window at or above this used percentage is worth naming beside the blocks.
    static let quotaHighEndingPct = 80.0

    /// The tolerance around a reset/start boundary is the same endpoint wobble the fold already
    /// treats as noise.
    static var quotaAdjacencyTolerance: TimeInterval { QuotaWindowOutcomes.anchorJitterTolerance }

    // MARK: - Page

    static func quotaPage(_ provider: HistoryExperience.Provider,
                          scope: [HistoryReport.ToolReport],
                          report: HistoryReport) -> HistoryExperience.QuotaPage {
        let eyebrow = "\(providerDisplayName(provider)) · \(quotaEyebrowSuffix)"
        let sections = scope.compactMap { quotaSection($0, report: report) }
        guard !sections.isEmpty else {
            return HistoryExperience.QuotaPage(
                eyebrow: eyebrow, scopeNote: quotaScopeNote,
                emptyMessage: quotaFreshInstallMessage)
        }
        return HistoryExperience.QuotaPage(eyebrow: eyebrow, scopeNote: quotaScopeNote,
                                           sections: sections)
    }

    /// One provider's section, or nil where the provider reported no window at all in the period.
    /// **A quiet stretch is an absent section, never a section of zeroes** — nothing here invents
    /// a window the provider never named (REV-93 §2.3).
    static func quotaSection(_ t: HistoryReport.ToolReport,
                             report: HistoryReport) -> HistoryExperience.QuotaSection? {
        let windows = t.quotaWindows.sorted { $0.resetsAt < $1.resetsAt }
        guard !windows.isEmpty else { return nil }

        let points = windows.map { quotaPoint($0, tool: t.tool, report: t, period: report) }
        let completed = windows.filter { $0.completion != .current }
        return HistoryExperience.QuotaSection(
            provider: t.tool,
            title: "\(t.tool.tabLabel) · \(quotaSectionWidth(windows))",
            summary: quotaSummary(completed),
            sparseNote: completed.count < quotaPatternFloor ? quotaSparseNote : nil,
            segments: quotaSegments(windows, tool: t.tool),
            points: points)
    }

    /// `5-hour windows` where every window in the section reported the same width, else the
    /// neutral fallback. The width vocabulary is `DisplayFormatter.windowGrain`'s — the same words
    /// the popover's rows and the block history use, so one width is never called by two names
    /// (the UI Spec's illustrative `7-day windows` would be a second name for `Weekly`).
    static func quotaSectionWidth(_ windows: [QuotaWindowOutcome]) -> String {
        let widths = Set(windows.map { $0.windowSeconds })
        guard widths.count == 1, let only = widths.first,
              let grain = DisplayFormatter.windowGrain(seconds: only) else {
            return quotaMixedWidthTitle
        }
        return "\(grain) windows"
    }

    /// The one factual sentence above a chart (§6.3): counts of **completed** windows only, no
    /// advice and no pattern language. The current window is not in `completed` and therefore
    /// cannot reach any figure here — the exclusion is by input, not by a filter that could be
    /// forgotten.
    static func quotaSummary(_ completed: [QuotaWindowOutcome]) -> String {
        guard !completed.isEmpty else { return "No completed window recorded yet." }
        let blocked = completed.filter { $0.hitLimitAt != nil }
        let noun = completed.count == 1 ? "completed window" : "completed windows"
        var sentence: String
        if blocked.isEmpty {
            sentence = completed.count == 1
                ? "The one completed window did not hit the limit."
                : "None of the \(completed.count) \(noun) hit the limit."
        } else {
            sentence = "\(blocked.count) of \(completed.count) \(noun) hit the limit."
        }
        let high = completed.filter {
            $0.hitLimitAt == nil && $0.highWaterPct >= quotaHighEndingPct
        }
        guard !high.isEmpty else { return sentence }
        let lead = high.count == 1 ? "One more" : "\(high.count) more"
        return sentence + " \(lead) ended above \(Fmt.percentNumber(quotaHighEndingPct))% used."
    }

    // MARK: - Points

    static func quotaPoint(_ window: QuotaWindowOutcome, tool: Tool,
                           report t: HistoryReport.ToolReport,
                           period: HistoryReport) -> HistoryExperience.QuotaPoint {
        let kind: HistoryExperience.QuotaPoint.Kind
        switch window.completion {
        case .current: kind = .current
        case .completedFull: kind = .completedFull
        case .completedPartial: kind = .completedPartial
        }
        let used = Fmt.percentNumber(window.highWaterPct)
        let label: String
        switch kind {
        case .completedFull: label = "Ended at \(used)% used"
        case .completedPartial: label = "Reached at least \(used)% used · Partial"
        case .current: label = "So far \(used)% used"
        }
        return HistoryExperience.QuotaPoint(
            id: window.id,
            provider: tool,
            at: window.resetsAt,
            kind: kind,
            hitLimit: window.hitLimitAt != nil,
            fraction: window.highWaterPct / 100,
            x: quotaX(window.resetsAt, period: period),
            label: label,
            accessibilityValue: quotaAccessibility(window, tool: tool, label: label),
            detail: quotaDetail(window, tool: tool, report: t))
    }

    /// Where the window's reset sits across the report period, 0…1. Geometry the view multiplies
    /// by a width — never a judgement about the window.
    static func quotaX(_ date: Date, period: HistoryReport) -> Double {
        let span = period.periodEnd.timeIntervalSince(period.periodStart)
        guard span > 0 else { return 0 }
        return date.timeIntervalSince(period.periodStart) / span
    }

    /// The spoken value §6.0 requires: provider, span, width, outcome and block state as plain
    /// text, built from the same parts as the drawn point so the two cannot drift.
    static func quotaAccessibility(_ window: QuotaWindowOutcome, tool: Tool,
                                   label: String) -> String {
        var parts = [tool.tabLabel]
        if let grain = DisplayFormatter.windowGrain(seconds: window.windowSeconds) {
            parts.append("\(grain) window")
        }
        parts.append(quotaSpan(window))
        parts.append(label)
        if window.hitLimitAt != nil { parts.append(limitHitLegendLabel) }
        switch window.ending {
        case .reachedReset: break
        case .earlyReset: parts.append(quotaEndingLabel(.earlyReset))
        case .withdrawn: parts.append(quotaEndingLabel(.withdrawn))
        }
        return parts.joined(separator: " · ")
    }

    /// `Sep 3, 2 pm – 7 pm` inside one day, `Sep 1, 2 pm – Sep 8, 2 pm` across days, and the
    /// reset alone where the width was never recorded — a window with no defensible start gets
    /// no invented one (STEP_181's rule, applied to copy).
    static func quotaSpan(_ window: QuotaWindowOutcome) -> String {
        guard let start = window.start else {
            return "resets \(Fmt.monthDay(window.resetsAt)), \(Fmt.clock(window.resetsAt))"
        }
        let startDay = Fmt.monthDay(start), endDay = Fmt.monthDay(window.resetsAt)
        if startDay == endDay {
            return "\(startDay), \(Fmt.clock(start)) – \(Fmt.clock(window.resetsAt))"
        }
        return "\(startDay), \(Fmt.clock(start)) – \(endDay), \(Fmt.clock(window.resetsAt))"
    }

    static func quotaEndingLabel(_ ending: QuotaWindowOutcome.Ending) -> String {
        switch ending {
        case .reachedReset: return "Reset as reported"
        case .earlyReset: return "Reset early"
        case .withdrawn: return "Withdrawn by the provider"
        }
    }

    // MARK: - Selected-point detail

    /// What a selected point pins below the charts (§6.3). A fact with no defensible value is
    /// **omitted**, never printed as a dash: the row set is the evidence, not a fixed grid.
    static func quotaDetail(_ window: QuotaWindowOutcome, tool: Tool,
                            report t: HistoryReport.ToolReport)
        -> HistoryExperience.QuotaDetail {
        var rows: [LabeledRow] = []
        if let grain = DisplayFormatter.windowGrain(seconds: window.windowSeconds) {
            rows.append(LabeledRow(label: "Width", value: grain))
        }
        let used = Fmt.percentNumber(window.highWaterPct)
        switch window.completion {
        case .completedFull:
            rows.append(LabeledRow(label: "Used", value: "\(used)% used"))
        case .completedPartial:
            rows.append(LabeledRow(label: "Used", value: "At least \(used)% used"))
        case .current:
            rows.append(LabeledRow(label: "Used", value: "\(used)% used so far"))
        }
        rows.append(LabeledRow(label: "Coverage", value: quotaCoverage(window)))
        rows.append(LabeledRow(label: "Reset", value: quotaReset(window)))

        let local = quotaLocalWork(window, report: t)
        if let local { rows.append(local) }

        return HistoryExperience.QuotaDetail(
            title: "\(tool.tabLabel) · \(quotaSpan(window))",
            rows: rows,
            note: local == nil ? nil : quotaLocalContextNote,
            blockLink: quotaBlockLink(window, tool: tool, report: t))
    }

    /// How much of the window was watched, and off how many readings. `completedFull` earns its
    /// name two ways — the last reading landed inside `fullObservationTolerance` of the reset, or
    /// the window was seen at the ceiling, which §9.3 monotonicity makes an ending rather than a
    /// floor — so the copy names the reason rather than asserting a uniform one.
    static func quotaCoverage(_ window: QuotaWindowOutcome) -> String {
        let readings = "\(window.observationCount) reading"
            + (window.observationCount == 1 ? "" : "s")
        switch window.completion {
        case .current:
            return "Open now · \(readings)"
        case .completedFull:
            if window.hitLimitAt != nil { return "Seen at the limit · \(readings)" }
            return "Seen to the reset · \(readings)"
        case .completedPartial:
            let gap = window.resetsAt.timeIntervalSince(window.lastObservedAt)
            guard gap > 0 else { return "Partly observed · \(readings)" }
            return "Last seen \(Fmt.span(seconds: Int(gap))) before the reset · \(readings)"
        }
    }

    /// The reset instant, and what actually ended the window where that was not its own reset.
    static func quotaReset(_ window: QuotaWindowOutcome) -> String {
        let stamp = "\(Fmt.monthDay(window.resetsAt)), \(Fmt.clock(window.resetsAt))"
        switch window.ending {
        case .reachedReset: return stamp
        case .earlyReset, .withdrawn:
            return "\(stamp) · \(quotaEndingLabel(window.ending).lowercased())"
        }
    }

    /// The local work recorded on the **days this window touched** — a day total, named as one.
    /// A five-hour window sits inside a day, so calling the day's tokens the window's would
    /// overstate it by a factor nobody could check; the label says `that day` / `those days` and
    /// the note beside it says the rest.
    static func quotaLocalWork(_ window: QuotaWindowOutcome,
                               report t: HistoryReport.ToolReport) -> LabeledRow? {
        let from = window.start ?? window.resetsAt
        let to = window.resetsAt
        let days = t.days.enumerated().filter { index, day in
            let end = index + 1 < t.days.count ? t.days[index + 1].start : Date.distantFuture
            return end > from && day.start <= to
        }.map(\.element)
        guard !days.isEmpty else { return nil }
        let tokens = days.reduce(0) { $0 + $1.tokens }
        guard tokens > 0 else { return nil }
        let label = days.count == 1 ? "Local work that day" : "Local work those days"
        let span = days.count == 1
            ? Fmt.monthDay(days[0].start)
            : "\(Fmt.monthDay(days[0].start)) – \(Fmt.monthDay(days[days.count - 1].start))"
        return LabeledRow(label: label, value: "\(Fmt.tokens(tokens)) · \(span)")
    }

    /// The recorded hard block that fired inside this window, where one did. Context, not cause:
    /// the link takes the reader to the investigation, and the copy claims nothing beyond the
    /// coincidence of instants.
    static func quotaBlockLink(_ window: QuotaWindowOutcome, tool: Tool,
                               report t: HistoryReport.ToolReport)
        -> HistoryExperience.RecapLink? {
        let from = window.start ?? window.firstObservedAt
        guard let block = t.limitBlocks.first(where: {
            $0.firedAt >= from && $0.firedAt <= window.resetsAt
        }) else { return nil }
        return HistoryExperience.RecapLink(
            label: "Recorded block · \(Fmt.monthDay(block.firedAt)), \(Fmt.clock(block.firedAt))",
            destination: HistoryDestination(
                mode: .hardBlocks, provider: tool,
                banner: "From quota window · \(tool.tabLabel) · \(quotaSpan(window))"))
    }

    // MARK: - Segments

    /// The runs a chart may draw as one connected series. **Three things break a run** and each
    /// names itself, because a line drawn through any of them would assert continuity the data
    /// does not have (§6.3, REV-64):
    ///
    /// 1. the previous window ended as something other than its own reset;
    /// 2. the reported width changed — including into or out of unknown, since an unknown width
    ///    never borrows a neighbour's (STEP_181);
    /// 3. the windows overlap unexpectedly, or the pause between them is long enough that a whole
    ///    same-width outcome could be missing. A shorter idle pause is normal for rolling windows
    ///    and does not by itself prove missing history (STEP_186).
    ///
    /// Where more than one applies, the recorded discontinuity is named first: it is a fact the
    /// provider gave us, where a gap is only an absence.
    ///
    /// Windows with **no** recorded width stay in one run — they are alike in that respect — but
    /// that run is marked `connects: false`, because nothing can establish they abut. Rule 3 is
    /// therefore unreachable for them, and deliberately so: an absent start proves nothing about
    /// a gap either way.
    static func quotaSegments(_ windows: [QuotaWindowOutcome],
                              tool: Tool) -> [HistoryExperience.QuotaSegment] {
        var segments: [HistoryExperience.QuotaSegment] = []
        var run: [QuotaWindowOutcome] = []
        var boundary: String?
        let hasUnknown = windows.contains { $0.widthEvidence == .unknown }
        let hasRecovered = windows.contains {
            $0.widthEvidence == .providerContract || $0.widthEvidence == .recordedChange
        }
        let evidenceNote: String? = switch (hasUnknown, hasRecovered) {
        case (true, true): quotaPartlyRecoveredWidthNote
        case (true, false): quotaUnrecordedWidthNote
        case (false, true): quotaRecoveredWidthNote
        case (false, false): nil
        }

        func close() {
            guard let first = run.first else { return }
            let width = DisplayFormatter.windowGrain(seconds: first.windowSeconds)
            segments.append(HistoryExperience.QuotaSegment(
                id: "\(tool.rawValue)-seg-\(segments.count)",
                widthLabel: width.map { "\($0) windows" },
                connects: first.windowSeconds != nil,
                boundaryNote: boundary,
                widthNote: segments.isEmpty ? evidenceNote : nil,
                pointIDs: run.map(\.id)))
        }

        for window in windows {
            guard let previous = run.last else {
                run = [window]
                continue
            }
            let reason = quotaBreak(previous: previous, next: window)
            if let reason {
                close()
                boundary = reason
                run = [window]
            } else {
                run.append(window)
            }
        }
        close()
        return segments
    }

    /// Why the run breaks between two consecutive windows, or nil where it does not.
    static func quotaBreak(previous: QuotaWindowOutcome,
                           next: QuotaWindowOutcome) -> String? {
        if previous.ending != .reachedReset { return quotaEndingLabel(previous.ending) }
        if previous.windowSeconds != next.windowSeconds { return "Window width changed" }
        guard let start = next.start, let width = next.windowSeconds else { return nil }
        let gap = start.timeIntervalSince(previous.resetsAt)
        if gap < -quotaAdjacencyTolerance { return "Gap in observation" }
        let couldHideAWindow = TimeInterval(width) - quotaAdjacencyTolerance
        return gap >= couldHideAWindow ? "Gap in observation" : nil
    }
}
