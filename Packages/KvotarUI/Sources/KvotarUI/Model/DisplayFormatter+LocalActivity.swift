import Foundation
import KvotarCore

// STEP_177 — REV-92 / D-114, UI Spec §REV92 "Local activity" + "Estimated value": the daily local
// section as typed render data. Pure over the retained `DailyLocalReportState`, the current
// `LocalAttribution` (for the recent rate and the two rolling value horizons), the snapshot's plan
// (for the value note's grammar) and an injected clock. Nothing here re-aggregates: every token
// and dollar figure is the report's, and the report reconciles by construction.

extension DisplayFormatter {

    /// Builds the section for one tool's render.
    static func localActivitySection(tool: Tool, report state: DailyLocalReportState?,
                                     attribution: LocalAttribution?, snapshot: QuotaSnapshot?,
                                     now: Date) -> LocalActivitySection {
        let availability: LocalActivitySection.Availability
        let statusCopy: String?
        let report = state?.report
        switch state {
        case nil, .loading?:
            availability = .loading
            statusCopy = LocalActivitySection.loadingCopy
        case .available(let r)?:
            availability = r.isEmpty ? .empty : .available
            statusCopy = r.isEmpty ? LocalActivitySection.emptyCopy : nil
        case .unavailable(let retained, _)?:
            if let retained {
                availability = .staleRetained(asOf: retained.readUntil)
                statusCopy = "As of \(asOfStamp(retained.readUntil, now: now)) · couldn’t refresh"
            } else {
                availability = .unavailable
                statusCopy = LocalActivitySection.unavailableCopy
            }
        }

        // The summary describes the population; on a fresh-empty day the two lines are nil and
        // the status line says so, so `0 tokens · 0 sessions` is never printed as an observation.
        var summary: LabeledRow?
        var projects: [LocalActivitySection.ProjectRow] = []
        var moreCount = 0
        if let report, !report.isEmpty {
            summary = LabeledRow(
                label: collectorName(tool),
                value: "\(Fmt.tokens(report.totalTokens)) tokens · "
                    + sessionsPhrase(report.sessionCount, tool: tool),
                explanation: .localActivity)
            let selection = report.selection()
            projects = selection.rows.enumerated().map { index, project in
                LocalActivitySection.ProjectRow(
                    name: project.name.map(projectName) ?? LocalActivitySection.noProjectName,
                    fullName: project.name,
                    tokens: Fmt.tokens(project.tokens),
                    isMostRecent: selection.mostRecentIndex == index,
                    models: project.models.map {
                        LocalActivitySection.ModelRow(
                            name: $0.model.map(modelDisplayName)
                                ?? LocalActivitySection.unknownModelName,
                            tokens: Fmt.tokens($0.tokens))
                    })
            }
            moreCount = selection.moreCount
        }
        let surfaces = surfaceRows(tool: tool, report: report)

        // `Today` is the report's own bounded figure; the two rolling horizons stay the existing
        // `estValue` ones (Baseline §15.2). A missing input is `—`, never $0.00.
        let valueRows = [
            LabeledRow(label: "Today", value: report.map { Fmt.dollarValue($0.value) } ?? "—"),
            LabeledRow(label: "7-day",
                       value: attribution.map { Fmt.dollarValue($0.estValue.weekly) } ?? "—"),
            LabeledRow(label: "30-day",
                       value: attribution.map { Fmt.dollarValue($0.estValue.thirtyDay) } ?? "—"),
        ]

        return LocalActivitySection(
            availability: availability,
            statusCopy: statusCopy,
            summary: summary,
            recentRate: recentRateValue(attribution, now: now),
            cacheHit: report?.cacheHitRatio.map { Fmt.percent($0 * 100) } ?? "—",
            surfaces: surfaces,
            projects: projects,
            moreCount: moreCount,
            valueRows: valueRows,
            valueNote: isOrganizationPlan(snapshot?.planType)
                ? LocalActivitySection.organizationValueNote : LocalActivitySection.valueNote,
            overflowLabel: moreCount > 0
                ? "\(moreCount) more project\(moreCount == 1 ? "" : "s")" : nil,
            // The collector's own freshness, stamped from the newest event the day observed —
            // the same clock the retired local card used. An old last event dates the *evidence*,
            // never the reader: `Availability` above is what says whether the read succeeded
            // (REV-92 §3).
            sourceTag: freshnessTag(base: localSourceBase(tool), asOf: report?.lastEventAt,
                                    now: now),
            lastEventAt: report?.lastEventAt,
            readAt: report?.readUntil)
    }

    /// The day's local apps as rows (STEP_197 — UI Spec §REV92 / D-118).
    ///
    /// Two gates, both deliberate. **Codex only:** Claude's collector observes one surface by
    /// construction (`Claude Code`, REV-81), so a row would restate the summary label. **Two or
    /// more:** a single `Desktop 14.4M` under `Codex 14.4M` tells the one-app user — the design
    /// target — nothing they cannot already read on the line above. The report always carries the
    /// full split; this is where the decision not to show it lives.
    ///
    /// The marker goes to the app with the newest observed event, ties broken by rank so two apps
    /// sharing a last event pick deterministically — the same rule `DailyLocalReport.selection`
    /// applies to projects.
    static func surfaceRows(tool: Tool, report: DailyLocalReport?)
        -> [LocalActivitySection.SurfaceRow] {
        guard tool == .codex, let report, report.surfaces.count > 1 else { return [] }
        let newest = report.surfaces.indices.max { a, b in
            let (sa, sb) = (report.surfaces[a], report.surfaces[b])
            if sa.latestEventAt != sb.latestEventAt { return sa.latestEventAt < sb.latestEventAt }
            return a > b   // earlier rank wins a tie, so the max is the lower index
        }
        return report.surfaces.enumerated().map { index, surface in
            LocalActivitySection.SurfaceRow(
                name: surfaceDisplayName(surface.bucket),
                tokens: Fmt.tokens(surface.tokens),
                isMostRecent: index == newest)
        }
    }

    /// The stored bucket as the user sees it. Only `Unknown` is renamed — it is a bucket, not an
    /// app, and `Unknown app` says which of the two it is (STEP_197).
    static func surfaceDisplayName(_ bucket: String) -> String {
        bucket == SurfaceWorkSplit.unknownLabel
            ? LocalActivitySection.unknownSurfaceName : bucket
    }

    /// The local collector's source-tag base, unchanged from the retired local card.
    static func localSourceBase(_ tool: Tool) -> String {
        tool == .claude ? "Source: Claude Code JSONL" : "Source: Codex JSONL · originator field"
    }

    /// The recent local rate, current only while the attribution that measured it is younger
    /// than its own 2-minute horizon (`AttributionEngine.rateWindow`). A cached attribution
    /// re-rendered ten minutes later still carries the old number; showing it as current would
    /// claim a rate nothing has measured since (REV-92 §7). An unstamped attribution — fixtures
    /// predating STEP_177 — is age-unknown and reads `—` rather than fresh.
    static func recentRateValue(_ attribution: LocalAttribution?, now: Date) -> String {
        guard let attribution, let rate = attribution.tokensPerMinute,
              let computedAt = attribution.computedAt,
              now.timeIntervalSince(computedAt) <= AttributionEngine.rateWindow
        else { return "—" }
        return "~\(Fmt.tokRate(rate)) tokens/min"
    }

    /// The collector the summary names — the tool whose session files this Mac's watcher reads.
    /// Never "all local apps": Claude Desktop chat writes no JSONL (REV-81), and the explanation
    /// STEP_178 attaches states that scope.
    static func collectorName(_ tool: Tool) -> String {
        switch tool {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// `3 sessions` / `1 session` (Claude), `3 threads` / `1 thread` (Codex — the word the Codex
    /// app uses, as the legacy card already does).
    static func sessionsPhrase(_ count: Int, tool: Tool) -> String {
        let noun = tool == .claude ? "session" : "thread"
        return "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// Whether the value note names an organization's spend (UI Spec §REV92): the plan strings
    /// both providers use for a seat someone else pays for. Education is deliberately not here —
    /// a student's plan is their own.
    static func isOrganizationPlan(_ planType: String?) -> Bool {
        guard let planType else { return false }
        switch planDisplayName(planType) {
        case "Team", "Business", "Enterprise": return true
        default: return false
        }
    }
}
