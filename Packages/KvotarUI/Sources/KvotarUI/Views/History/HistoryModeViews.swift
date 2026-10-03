import SwiftUI
import KvotarCore

// The three History mode views (STEP_160 — REV-84 / D-108): Summary, Explore usage and Hard
// blocks, each rendering one precomputed `HistoryExperience` payload. Views hold no logic
// (PATTERNS.md): every string, grouping and fraction arrives typed; the only arithmetic here is
// a fraction times a width, and the only state read is `HistoryViewModel`'s transient selection.
//
// Wide/narrow pairings use `ViewThatFits` with a `minWidth` on the flexible half: the two-column
// variant's ideal width then exceeds 560 pt's content box, so the narrow window stacks without a
// second layout pass (the measured-GeometryReader split was rejected for the old layout because
// it paints one column and then jumps — the same reasoning holds here).

/// One compact stat tile — the REV-84 §4.1 hero facts and the Hard-blocks known-consequence
/// card. The successor shape to the retired facts row: label, figure, muted caption.
struct StatTileView: View {
    let stat: HistoryExperience.Stat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HistoryEyebrow(text: stat.label)
            Text(stat.figure)
                .font(HistoryTheme.statFigure)
                .monospacedDigit()
                .foregroundStyle(HistoryTheme.text)
            if let caption = stat.caption {
                Text(caption)
                    .font(HistoryTheme.small)
                    .monospacedDigit()
                    .foregroundStyle(HistoryTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(HistoryTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(HistoryTheme.line, lineWidth: 1)
        }
    }
}

/// The tinted verdict card both conclusion-led modes open with (the prototype's
/// `.kh-verdict`, STEP_162): eyebrow over the 22-pt conclusion on the provider-soft tint —
/// blue by default, green only under the Codex filter (the prototype's rule; `All` and
/// Claude both read blue).
struct VerdictCardView: View {
    let eyebrow: String
    let conclusion: String
    var tint: Tool = .claude

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !eyebrow.isEmpty { HistoryEyebrow(text: eyebrow) }
            Text(conclusion)
                .font(HistoryTheme.h2)
                .tracking(-0.44)
                .foregroundStyle(HistoryTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HistoryTheme.softTint(tint))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(HistoryTheme.verdictBorder(tint), lineWidth: 1)
        }
    }
}

/// The Codex-green verdict tint applies only under the Codex filter (prototype rule).
private func verdictTint(_ provider: HistoryExperience.Provider) -> Tool {
    if case .tool(.codex) = provider { return .codex }
    return .claude
}

/// Variant A's compact provider label: a coloured dot plus the provider name. Colour is only
/// supplementary; the text always names the account.
struct HistoryProviderTag: View {
    let tool: Tool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(HistoryTheme.accent(tool))
                .frame(width: 7, height: 7)
            Text(tool.tabLabel)
                .font(Font.system(size: 12, weight: .semibold))
                .foregroundStyle(HistoryTheme.secondary)
        }
    }
}

/// The allowance panel (`Has your allowance changed?` on Summary, `Allowance history` on Hard
/// blocks): one REV-72 verdict per provider with its earned figure row, then the recorded
/// changes in the D-81 grammar.
struct AllowancePanelView: View {
    let panel: HistoryExperience.AllowancePanel
    /// A week-scoped arrival lifts the changes recorded in that week (STEP_183).
    var scope: HistoryViewModel.Scope? = nil

    var body: some View {
        HistoryPanel(title: panel.title) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(panel.evidence.enumerated()), id: \.offset) { _, highlight in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(highlight.lede)
                            .font(HistoryTheme.body)
                            .foregroundStyle(HistoryTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let row = highlight.row {
                            RowView(row: row)
                        }
                    }
                }
                if !panel.changes.isEmpty {
                    if !panel.evidence.isEmpty { Divider() }
                    ForEach(Array(panel.changes.enumerated()), id: \.offset) { _, ranked in
                        RankedRowView(ranked: ranked)
                            .padding(.horizontal, 6)
                            .background(scope?.contains(ranked.at) == true
                                        ? HistoryTheme.soft : Color.clear)
                            .padding(.horizontal, -6)
                    }
                }
            }
        }
    }
}

// MARK: - Weekly recap (UI Spec §6.2)

/// The editorial recap: one centered reading column, one completed week at a time.
///
/// Not a dashboard. There is one emphasised element — the lead — and everything below it is
/// prose at reading weight, which is what `readingColumnWidth` and the absence of a fact grid
/// are for. Week navigation is transient view state on `HistoryViewModel`; the payload holds
/// every completed week in the horizon and this view picks one.
struct WeeklyRecapModeView: View {
    let section: HistoryExperience.RecapSection
    @ObservedObject var vm: HistoryViewModel

    /// The approved Variant A editorial column.
    private let readingColumnWidth: CGFloat = 690

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            column
                .frame(maxWidth: readingColumnWidth)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var column: some View {
        if let message = section.emptyMessage {
            HistoryPanel {
                Text(message)
                    .font(HistoryTheme.body)
                    .foregroundStyle(HistoryTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let week = vm.recapWeek(in: section) {
            VStack(alignment: .leading, spacing: 0) {
                navigation(week)
                lead(week)
                if let table = week.table {
                    tableBlock(table)
                }
                if let limits = week.weeklyLimits {
                    limitsBlock(limits)
                }
                ForEach(Array(week.observations.enumerated()), id: \.offset) { _, insight in
                    insightBlock(insight)
                }
                if let action = week.action {
                    actionBlock(action)
                        .padding(.top, 30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `‹ · Last completed week · Aug 31 – Sep 6 · ›`, centered exactly like Variant A.
    private func navigation(_ week: HistoryExperience.RecapWeek) -> some View {
        HStack(spacing: 12) {
            step("chevron.left", label: "Older week",
                 enabled: vm.canShowOlderRecapWeek(in: section)) {
                vm.showOlderRecapWeek()
            }
            Spacer(minLength: 0)
            VStack(alignment: .center, spacing: 3) {
                HistoryEyebrow(text: week.title)
                Text(week.span)
                    .font(Font.system(size: 19, weight: .semibold))
                    .tracking(-0.28)
                    .monospacedDigit()
                    .foregroundStyle(HistoryTheme.text)
            }
            .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            step("chevron.right", label: "Newer week",
                 enabled: vm.canShowNewerRecapWeek(in: section)) {
                vm.showNewerRecapWeek()
            }
        }
        .padding(.bottom, 34)
    }

    private func step(_ symbol: String, label: String, enabled: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? HistoryTheme.text : HistoryTheme.tertiary)
                .frame(width: 34, height: 34)
                .background(HistoryTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(HistoryTheme.line, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.32)
        .accessibilityLabel(label)
    }

    private func lead(_ week: HistoryExperience.RecapWeek) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(week.lead.eyebrow.uppercased())
                .font(HistoryTheme.eyebrow)
                .tracking(1.26)
                .foregroundStyle(HistoryTheme.redAccent)
            Text(week.lead.sentence)
                .font(HistoryTheme.editorialLead)
                .tracking(-1.08)
                .foregroundStyle(HistoryTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 9)
                .padding(.bottom, 13)
            if let grounding = week.lead.grounding {
                Text(grounding)
                    .font(Font.system(size: 16))
                    .foregroundStyle(HistoryTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let coverage = week.coverageNote {
                HistoryNote(text: coverage)
                    .padding(.top, 8)
            }
        }
        .padding(.bottom, 30)
        .overlay(alignment: .bottom) {
            Rectangle().fill(HistoryTheme.line).frame(height: 1)
        }
    }

    /// `This week`: a small table read top to bottom like the prose around it — not a tile grid
    /// (REV-104 §2.1). Every string is the formatter's; the view only lays them out.
    private func tableBlock(_ table: HistoryExperience.RecapTable) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HistoryEyebrow(text: table.title)
                .padding(.bottom, 12)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(table.columns, id: \.self) { tool in
                        HistoryProviderTag(tool: tool)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .font(HistoryTheme.body)
                            .foregroundStyle(HistoryTheme.secondary)
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            tableCell(cell)
                        }
                    }
                }
            }
            Text(table.valueNote)
                .font(HistoryTheme.body)
                .foregroundStyle(HistoryTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            if let note = table.fallbackNote {
                Text(note)
                    .font(HistoryTheme.body)
                    .foregroundStyle(HistoryTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            evidenceLink(table.link)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 27)
        .overlay(alignment: .bottom) {
            Rectangle().fill(HistoryTheme.line).frame(height: 1)
        }
    }

    private func tableCell(_ cell: HistoryExperience.RecapTableCell) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cell.text)
                .font(HistoryTheme.panelTitle)
                .monospacedDigit()
                .foregroundStyle(HistoryTheme.text)
            if let comparison = cell.comparison {
                Text(comparison)
                    .font(Font.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(HistoryTheme.secondary)
            }
        }
    }

    /// `Weekly limits that reset …`: one line per limit instance, value right-aligned, then the
    /// asterisk footnotes.
    private func limitsBlock(_ limits: HistoryExperience.RecapWeeklyLimits) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HistoryEyebrow(text: limits.title)
                .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(limits.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(line.label)
                            .foregroundStyle(HistoryTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Text(line.value)
                            .monospacedDigit()
                            .foregroundStyle(HistoryTheme.text)
                    }
                    .font(HistoryTheme.panelTitle)
                }
            }
            ForEach(Array(limits.footnotes.enumerated()), id: \.offset) { index, note in
                Text(note)
                    .font(HistoryTheme.body)
                    .foregroundStyle(HistoryTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, index == 0 ? 12 : 4)
            }
            evidenceLink(limits.link)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 27)
        .overlay(alignment: .bottom) {
            Rectangle().fill(HistoryTheme.line).frame(height: 1)
        }
    }

    private func insightBlock(_ insight: HistoryExperience.RecapInsight) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                providerLabel(insight)
                    .frame(width: 130, alignment: .leading)
                insightContent(insight)
            }
            VStack(alignment: .leading, spacing: 9) {
                providerLabel(insight)
                insightContent(insight)
            }
        }
        .padding(.vertical, 27)
        .overlay(alignment: .bottom) {
            Rectangle().fill(HistoryTheme.line).frame(height: 1)
        }
    }

    @ViewBuilder private func providerLabel(_ insight: HistoryExperience.RecapInsight) -> some View {
        if let provider = insight.provider {
            HistoryProviderTag(tool: provider)
        }
    }

    private func insightContent(_ insight: HistoryExperience.RecapInsight) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(insight.sentence)
                .font(HistoryTheme.panelTitle)
                .tracking(-0.27)
                .foregroundStyle(HistoryTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note = insight.coverageNote {
                Text(note)
                    .font(HistoryTheme.body)
                    .foregroundStyle(HistoryTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            }
            if let link = insight.link {
                evidenceLink(link)
                    .padding(.top, 10)
            }
        }
    }

    private func evidenceLink(_ link: HistoryExperience.RecapLink) -> some View {
        Button { vm.navigate(to: link.destination) } label: {
            HStack(spacing: 3) {
                Text(link.label)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
            }
            .font(Font.system(size: 13))
            .foregroundStyle(HistoryTheme.accent(link.destination.provider ?? .claude))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the supporting evidence")
    }

    private func actionBlock(_ action: HistoryExperience.RecapAction) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(HistoryTheme.warn)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 5) {
                HistoryEyebrow(text: action.title)
                Text(action.sentence)
                    .font(HistoryTheme.panelTitle)
                    .tracking(-0.27)
                    .foregroundStyle(HistoryTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let evidence = action.evidence {
                    Text(evidence)
                        .font(HistoryTheme.body)
                        .foregroundStyle(HistoryTheme.amberText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
        }
        .background(HistoryTheme.amberSoft)
        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 9,
                                          topTrailingRadius: 9,
                                          style: .continuous))
    }
}

// MARK: - Explore quota (UI Spec §6.3)

/// Provider truth over the fixed 30 days: one full-width chart per provider, stacked on `All`,
/// each on its own 0–100 % axis and with its own factual sentence. They never share a scale and
/// there is no combined figure — two allowances are not comparable magnitudes.
struct ExploreQuotaModeView: View {
    let page: HistoryExperience.QuotaPage
    /// `Aug 12 – Sep 11` — the window header's own subtitle, so the axis and the heading name
    /// one period.
    let periodLabel: String
    @ObservedObject var vm: HistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HistoryNote(text: page.scopeNote)
            if let message = page.emptyMessage {
                HistoryPanel {
                    Text(message)
                        .font(HistoryTheme.body)
                        .foregroundStyle(HistoryTheme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(page.sections) { section in
                    HistoryPanel(title: section.title) {
                        VStack(alignment: .leading, spacing: 13) {
                            Text(section.summary)
                                .font(Font.system(size: 14))
                                .foregroundStyle(HistoryTheme.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let note = section.sparseNote { HistoryNote(text: note) }
                            QuotaChartView(section: section,
                                           selectedID: selected?.id,
                                           scope: vm.scope,
                                           periodLabel: periodLabel,
                                           onSelect: { vm.selectQuotaPoint($0) })
                        }
                    }
                }
                // One detail for the page, below every chart (§6.3) — click or keyboard, never
                // hover alone.
                if let point = selected {
                    QuotaDetailView(point: point, vm: vm)
                } else {
                    HistoryNote(text: HistoryDisplay.quotaSelectHint)
                }
            }
        }
    }

    private var selected: HistoryExperience.QuotaPoint? { vm.resolvedQuotaPoint(in: page) }
}

/// The pinned window: its own facts, then the local work recorded alongside it — labelled
/// context, never cause.
struct QuotaDetailView: View {
    let point: HistoryExperience.QuotaPoint
    @ObservedObject var vm: HistoryViewModel

    var body: some View {
        HistoryPanel {
            VStack(alignment: .leading, spacing: 13) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            HistoryEyebrow(text: HistoryDisplay.selectedQuotaWindowEyebrow)
                            Text(point.detail.title)
                                .font(Font.system(size: 20, weight: .semibold))
                                .foregroundStyle(HistoryTheme.text)
                        }
                        Spacer(minLength: 12)
                        Text(point.label)
                            .font(HistoryTheme.h2)
                            .monospacedDigit()
                            .foregroundStyle(HistoryTheme.text)
                            .multilineTextAlignment(.trailing)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HistoryEyebrow(text: HistoryDisplay.selectedQuotaWindowEyebrow)
                        Text(point.detail.title)
                            .font(Font.system(size: 20, weight: .semibold))
                            .foregroundStyle(HistoryTheme.text)
                        Text(point.label)
                            .font(HistoryTheme.h2)
                            .monospacedDigit()
                            .foregroundStyle(HistoryTheme.text)
                    }
                }
                quotaRows
                if let note = point.detail.note { HistoryNote(text: note) }
                if let link = point.detail.blockLink {
                    Button { vm.navigate(to: link.destination) } label: {
                        HStack(spacing: 3) {
                            Text(link.label)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(HistoryTheme.small)
                        .foregroundStyle(HistoryTheme.accent(point.provider))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the recorded block")
                }
            }
        }
    }

    private var quotaRows: some View {
        VStack(spacing: 0) {
            Rectangle().fill(HistoryTheme.line).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(point.detail.rows.enumerated()), id: \.offset) { _, row in
                        quotaCell(row)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(point.detail.rows.enumerated()), id: \.offset) { _, row in
                        quotaCell(row)
                    }
                }
            }
        }
    }

    private func quotaCell(_ row: LabeledRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.value)
                .font(Font.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(HistoryTheme.text)
            Text(row.label.uppercased())
                .font(HistoryTheme.note)
                .tracking(0.66)
                .foregroundStyle(HistoryTheme.tertiary)
        }
        .padding(.top, 14)
        .padding(.trailing, 14)
    }
}

// MARK: - Explore usage (REV-84 §5)

struct ExploreModeView: View {
    let page: HistoryExperience.ExplorePage
    let pricingNote: String
    @ObservedObject var vm: HistoryViewModel
    @State private var grain: Grain

    enum Grain: CaseIterable, Hashable {
        case day, week, breakdown

        var label: String {
            switch self {
            case .day: return HistoryDisplay.byDayTitle
            case .week: return HistoryDisplay.byWeekTitle
            case .breakdown: return HistoryDisplay.breakdownTitle
            }
        }
    }

    init(page: HistoryExperience.ExplorePage, pricingNote: String,
         vm: HistoryViewModel, initialGrain: Grain = .day) {
        self.page = page
        self.pricingNote = pricingNote
        self.vm = vm
        _grain = State(initialValue: initialGrain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = page.emptyMessage {
                HistoryPanel {
                    Text(message)
                        .font(HistoryTheme.body)
                        .foregroundStyle(HistoryTheme.tertiary)
                }
            } else {
                UnderlineTabBar(items: Grain.allCases, label: \.label,
                                selection: $grain, spacing: 22,
                                showsBaseline: true, compact: true)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Explore usage grain")
                switch grain {
                case .day:
                    stripPanel
                    dayDetail
                case .week:
                    weeklyPanel
                case .breakdown:
                    breakdownPanels
                }
                HistoryNote(text: pricingNote)
            }
        }
        // An explicit destination (STEP_178) is resolved by the model on the first page that can
        // answer it; committing it here turns it into an ordinary selection, so later reloads and
        // re-focuses keep the day the reader was sent to.
        .onAppear(perform: commitDestination)
        .onChange(of: page.days.count) { _, _ in commitDestination() }
    }

    private func commitDestination() {
        guard vm.hasPendingDay, let entry = vm.selectedEntry(in: page) else { return }
        grain = .day
        vm.commitPendingDay(entry.id)
    }

    private var stripPanel: some View {
        HistoryPanel(title: HistoryDisplay.selectDayTitle) {
            DayStripView(
                strip: HistoryScreen.DayStrip(points: page.days.map(\.point),
                                              legend: page.legend,
                                              footer: page.stripFooter),
                vm: vm,
                entries: page.days,
                selectedID: vm.selectedEntry(in: page)?.id,
                onSelect: { vm.selectDay($0) })
        }
    }

    /// Variant A places the selected-day evidence beside its event receipt at wide width.
    @ViewBuilder private var dayDetail: some View {
        let detail = vm.selectedEntry(in: page).map {
            DayDetailView(detail: $0.detail, pricingNote: pricingNote,
                          tint: verdictTint(vm.provider))
        }
        if let detail {
            detail
        }
    }

    /// Week by week with each provider's visible 30-day total above its rows (REV-84 §5.2).
    private var weeklyPanel: some View {
        HistoryPanel(title: HistoryDisplay.weekByWeekTitle) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(page.weekly.enumerated()), id: \.offset) { index, group in
                    VStack(alignment: .leading, spacing: 8) {
                        // Groups are separated by the prototype's hairline, never a leading
                        // rule above the first one (`.kh-summary-line`).
                        if index > 0 {
                            Rectangle().fill(HistoryTheme.line).frame(height: 1)
                        }
                        if let total = page.totals.first(where: {
                            $0.provider == group.provider
                        }) {
                            // `CLAUDE TOTAL` over its figures — the payload's own title says
                            // "total", so the prototype's second eyebrow would repeat it.
                            VStack(alignment: .leading, spacing: 2) {
                                HistoryEyebrow(text: total.title)
                                Text("\(total.tokens) · \(total.value)")
                                    .font(HistoryTheme.bodySemibold)
                                    .monospacedDigit()
                                    .foregroundStyle(HistoryTheme.text)
                                Text(total.activity)
                                    .font(HistoryTheme.note)
                                    .foregroundStyle(HistoryTheme.tertiary)
                            }
                        }
                        ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                            WeekRowView(row: row, accent: HistoryTheme.accent(group.provider))
                        }
                    }
                }
                if let combined = page.combinedValue {
                    Rectangle().fill(HistoryTheme.line).frame(height: 1)
                    RowView(row: LabeledRow(label: HistoryDisplay.estValueLabel,
                                            value: combined))
                }
            }
        }
    }

    private var breakdownPanels: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                HistoryPanel(title: HistoryDisplay.projectsDimensionLabel) {
                    rankedRows(page.breakdown.projects)
                }
                .frame(minWidth: 240, maxWidth: .infinity)
                modelsPanel.frame(minWidth: 240, maxWidth: .infinity)
                HistoryPanel(title: HistoryDisplay.largestWorkTitle) {
                    rankedRows(page.breakdown.largestWork)
                }
                .frame(minWidth: 240, maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 14) {
                HistoryPanel(title: HistoryDisplay.projectsDimensionLabel) {
                    rankedRows(page.breakdown.projects)
                }
                modelsPanel
                HistoryPanel(title: HistoryDisplay.largestWorkTitle) {
                    rankedRows(page.breakdown.largestWork)
                }
            }
        }
    }

    private var modelsPanel: some View {
        HistoryPanel(title: HistoryDisplay.modelsTitle) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(page.breakdown.models.enumerated()),
                        id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 6) {
                        if page.breakdown.models.count > 1 {
                            HistoryProviderTag(tool: group.provider)
                        }
                        ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                            RankedRowView(ranked: row)
                        }
                    }
                }
            }
        }
    }

    private func rankedRows(_ rows: [HistoryScreen.RankedRow]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                RankedRowView(ranked: row)
            }
        }
    }
}

/// Everything recorded about the selected day (REV-84 §5.1), already typed: per-provider
/// sections, the one combined dollar, merged event lists, and the honesty sentence.
struct DayDetailView: View {
    let detail: HistoryExperience.DayDetail
    let pricingNote: String
    /// The tinted event box follows the page's own accent — Codex green under the Codex
    /// filter, blue otherwise (the prototype's `.kh-limit-state` rule).
    var tint: Tool = .claude

    var body: some View {
        let events = detail.blocks + detail.observations + detail.changes
        if events.isEmpty {
            overviewPanel
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    overviewPanel.frame(minWidth: 480, maxWidth: .infinity)
                    eventsPanel.frame(minWidth: 300, idealWidth: 340)
                }
                VStack(alignment: .leading, spacing: 14) {
                    overviewPanel
                    eventsPanel
                }
            }
        }
    }

    private var overviewPanel: some View {
        HistoryPanel {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HistoryEyebrow(text: HistoryDisplay.selectedDayEyebrow)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(detail.title)
                            .font(HistoryTheme.h2)
                            .tracking(-0.44)
                            .foregroundStyle(HistoryTheme.text)
                        if let status = detail.status {
                            Text(status)
                                .font(HistoryTheme.small)
                                .foregroundStyle(HistoryTheme.tertiary)
                        }
                    }
                }
                ForEach(Array(detail.sections.enumerated()), id: \.offset) { index, section in
                    sectionView(section, isFirst: index == 0)
                }
                if let combined = detail.combinedValue {
                    RowView(row: LabeledRow(label: HistoryDisplay.estValueLabel,
                                            value: combined))
                    HistoryNote(text: pricingNote)
                }
            }
        }
    }

    private var eventsPanel: some View {
        HistoryPanel(title: HistoryDisplay.whatHappenedTitle) {
            VStack(alignment: .leading, spacing: 10) {
                eventBox
                HistoryNote(text: detail.evidenceNote)
            }
        }
    }

    /// One provider's slice of the day (the prototype's `.kh-selected-provider`): a hairline
    /// above every section but the first, the name at its head, then the three measures as
    /// soft tiles and the day's model rows — tokens only (§6.3, amended 2026-09-01).
    private func sectionView(_ section: HistoryExperience.DaySection,
                             isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !isFirst {
                Rectangle().fill(HistoryTheme.line).frame(height: 1)
            }
            Text(section.provider.tabLabel)
                .font(HistoryTheme.bodySemibold)
                .foregroundStyle(HistoryTheme.text)
            metricTiles(section)
            if !section.models.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HistoryEyebrow(text: HistoryDisplay.modelBreakdownEyebrow)
                    ForEach(Array(section.models.enumerated()), id: \.offset) { _, row in
                        RowView(row: row)
                    }
                }
            }
            // The day's projects (STEP_178) — the destination of the popover's
            // `N more projects ›`, grouped on the same path set that produced its count.
            if !section.projects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HistoryEyebrow(text: HistoryDisplay.projectBreakdownEyebrow)
                    ForEach(Array(section.projects.enumerated()), id: \.offset) { _, row in
                        RowView(row: row)
                    }
                }
            }
        }
    }

    /// Three tiles that wrap to one column when the card is narrow — the prototype's
    /// `repeat(auto-fit, minmax(110px, 1fr))`.
    private func metricTiles(_ section: HistoryExperience.DaySection) -> some View {
        let tiles = [
            (HistoryDisplay.localTokensStatLabel, section.tokens),
            (HistoryDisplay.estValueLabel, section.value),
            (section.provider == .codex ? HistoryDisplay.threadsLabel
                                        : HistoryDisplay.sessionsLabel, section.activity),
        ]
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    HistoryMetricTile(label: tile.0, figure: tile.1)
                        .frame(minWidth: 110)
                }
            }
            VStack(spacing: 7) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    HistoryMetricTile(label: tile.0, figure: tile.1)
                }
            }
        }
    }

    /// Blocks, critical observations and account changes in one chronological list (§6.3 —
    /// each already merged and provider-tagged by the model), inside the prototype's tinted
    /// left-bordered box. An absent list draws nothing, and no list draws no box.
    @ViewBuilder private var eventBox: some View {
        let events = detail.blocks + detail.observations + detail.changes
        if !events.isEmpty {
            HistoryTintedBox(tint: tint) {
                ForEach(Array(events.enumerated()), id: \.offset) { _, row in
                    RankedRowView(ranked: row)
                }
            }
        }
    }
}

// MARK: - Hard blocks (REV-84 §6)

struct HardBlocksModeView: View {
    let page: HistoryExperience.HardBlocksPage
    @ObservedObject var vm: HistoryViewModel
    var isNarrow: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = page.emptyMessage {
                HistoryPanel {
                    Text(message)
                        .font(HistoryTheme.body)
                        .foregroundStyle(HistoryTheme.tertiary)
                }
            } else {
                hero
                chartAndHistory
                if let allowance = page.allowance {
                    AllowancePanelView(panel: allowance, scope: vm.scope)
                }
            }
        }
    }

    /// Variant A's unboxed conclusion strip: the evidence sentence and the one consequence
    /// figure share a ruled row rather than competing as two cards.
    @ViewBuilder private var hero: some View {
        if let consequence = page.consequence {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text(page.conclusion)
                        .font(Font.system(size: 24, weight: .semibold))
                        .tracking(-0.6)
                        .foregroundStyle(HistoryTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    consequenceInline(consequence)
                        .frame(minWidth: 170, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text(page.conclusion)
                        .font(Font.system(size: 24, weight: .semibold))
                        .tracking(-0.6)
                        .foregroundStyle(HistoryTheme.text)
                    consequenceInline(consequence)
                }
            }
            .padding(.vertical, 18)
            .overlay(alignment: .top) {
                Rectangle().fill(HistoryTheme.line).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(HistoryTheme.line).frame(height: 1)
            }
        } else {
            Text(page.conclusion)
                .font(Font.system(size: 24, weight: .semibold))
                .tracking(-0.6)
                .foregroundStyle(HistoryTheme.text)
                .padding(.vertical, 18)
        }
    }

    private func consequenceInline(_ consequence: HistoryExperience.Stat) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(consequence.figure)
                .font(HistoryTheme.big)
                .tracking(-0.54)
                .monospacedDigit()
                .foregroundStyle(HistoryTheme.text)
            if let caption = consequence.caption {
                Text(caption)
                    .font(HistoryTheme.small)
                    .monospacedDigit()
                    .foregroundStyle(HistoryTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    /// The hour chart beside the chronological block history at wide width (REV-84 §6
    /// items 2–3); the pattern and coverage notes stay with the chart they qualify.
    @ViewBuilder private var chartAndHistory: some View {
        let chartPanel = HistoryPanel(title: HistoryDisplay.activityAroundBlocksTitle) {
            VStack(alignment: .leading, spacing: 8) {
                if let chart = page.chart {
                    HourChartView(chart: chart, vm: vm)
                }
                if let pattern = page.patternNote {
                    HStack(spacing: 0) {
                        Rectangle().fill(HistoryTheme.warn).frame(width: 3)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(HistoryDisplay.possiblePatternTitle)
                                .font(Font.system(size: 17, weight: .semibold))
                                .foregroundStyle(HistoryTheme.text)
                            Text(pattern)
                                .font(HistoryTheme.body)
                                .foregroundStyle(HistoryTheme.amberText)
                                .fixedSize(horizontal: false, vertical: true)
                            HistoryNote(text: page.coverageNote,
                                        color: HistoryTheme.amberText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                    }
                    .background(HistoryTheme.amberSoft)
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 9,
                                                      topTrailingRadius: 9,
                                                      style: .continuous))
                } else {
                    HistoryNote(text: page.coverageNote)
                }
            }
        }
        if page.rows.isEmpty {
            chartPanel
        } else {
            let historyPanel = HistoryPanel(title: HistoryDisplay.recordedIncidentsTitle) {
                HistoryEventList(rows: page.rows, scope: vm.scope)
            }
            if page.chart != nil {
                if isNarrow {
                    VStack(alignment: .leading, spacing: 12) {
                        historyPanel
                        chartPanel
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        historyPanel.frame(maxWidth: .infinity)
                        chartPanel.frame(width: 340)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    historyPanel
                    chartPanel
                }
            }
        }
    }
}
