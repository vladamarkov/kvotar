import SwiftUI
import KvotarCore

/// `LOCAL ACTIVITY · TODAY` and its `ESTIMATED VALUE` companion (UI Spec §REV92 — STEP_178).
/// One tool's observed work on this Mac for the local calendar day, ranked by project. Every
/// figure is the bounded daily report's; this view sums nothing.
///
/// Three states are deliberately distinguishable (REV-92 §3): a successful empty day says so, a
/// failed read says so, and a failed refresh over known data keeps the numbers under a dated
/// qualifier. None of them is ever a fabricated zero, and none of them silently shows yesterday.
struct LocalActivitySectionView: View {
    let section: LocalActivitySection
    /// Opens History on this provider's own local day, at the project breakdown.
    var onOpenProjects: () -> Void = {}
    /// Pointer feedback on the projects-overflow link (STEP_180). Transient view state.
    @State private var overflowHovered = false
    /// The hover-card context for the surface rows' E-06 explanation (STEP_197), read the same
    /// way `ProjectRowView` reads it for the recency marker.
    @Environment(\.explanationContext) private var explanation

    var body: some View {
        SectionCard(title: LocalActivitySection.title) {
            if let status = section.statusCopy {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let summary = section.summary {
                RowView(row: summary)
                // STEP_197: the day's local apps, directly under the collector they belong to and
                // styled as its sub-rows — the same relationship the model rows have to a project.
                if !section.surfaces.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(section.surfaces.enumerated()), id: \.offset) { _, surface in
                            SurfaceRowView(surface: surface)
                        }
                    }
                    .explainable(.localSource,
                                 site: LocalActivitySection.surfacesSite,
                                 body: card(.localSource))
                }
                RowView(row: LabeledRow(label: LocalActivitySection.recentRateLabel,
                                        value: section.recentRate))
                RowView(row: LabeledRow(label: LocalActivitySection.cacheHitLabel,
                                        value: section.cacheHit,
                                        explanation: .cacheHit))
            }
            if !section.projects.isEmpty {
                Text(LocalActivitySection.projectsHeading)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
                ForEach(Array(section.projects.enumerated()), id: \.offset) { _, project in
                    ProjectRowView(project: project)
                }
            }
            if let overflow = section.overflowLabel {
                Button(action: onOpenProjects) {
                    HStack(spacing: 4) {
                        Text(overflow)
                        Text("›")
                    }
                    .font(.caption)
                    // STEP_180: action blue, one shade heavier under the pointer (REV-92 §4).
                    .foregroundStyle(overflowHovered ? Theme.blueHover : Theme.blue)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { overflowHovered = $0 }
            }
            if let tag = section.sourceTag {
                SourceTagView(tag: tag)
            }
        }
    }

    private func card(_ element: ExplanationElement) -> String? {
        guard let explanation else { return nil }
        return ExplanationRegistry.card(element, tool: explanation.tool, grain: explanation.grain)
    }
}

/// The `LOCAL ACTIVITY · ESTIMATED VALUE` companion — `Today` / `7-day` / `30-day` in USD, on
/// **every** plan (§REV92 supersedes REV-47's Claude-monthly suppression: a list-price estimate
/// of local work answers a different question from an organisation's own money meter).
struct LocalValueSectionView: View {
    let section: LocalActivitySection

    var body: some View {
        SectionCard(title: LocalActivitySection.valueTitle) {
            ForEach(Array(section.valueRows.enumerated()), id: \.offset) { index, row in
                RowView(row: LabeledRow(label: row.label, value: row.value,
                                        explanation: index == 0 ? .estTokenValue
                                                                : .rollingHorizons))
            }
            Text(section.valueNote)
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One project: its name and tokens, its own per-event model totals beneath, and — on at most one
/// row — a neutral clock marking the newest observed event of the day. The marker is *observed
/// recency*, never foreground editor focus and never a running process, and it carries a constant
/// explanation site so a project path can never reach the diagnostics bundle through it.
/// One local app under the `Local activity · today` summary (STEP_197). Deliberately the same
/// shape as a project's model row — indent, weight and colour — because it is the same kind of
/// thing: a component of the total on the line above.
private struct SurfaceRowView: View {
    let surface: LocalActivitySection.SurfaceRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(surface.name)
                .fixedSize(horizontal: false, vertical: true)
            if surface.isMostRecent {
                Text(LocalActivitySection.recencyMarker)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel(LocalActivitySection.recencyAccessibilityLabel)
            }
            Spacer(minLength: 8)
            Text(surface.tokens)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .foregroundStyle(Theme.textSecondary)
        .padding(.leading, 12)
    }
}

private struct ProjectRowView: View {
    let project: LocalActivitySection.ProjectRow
    @Environment(\.explanationContext) private var explanation

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(project.name)
                    .font(.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(project.fullName ?? project.name)
                if project.isMostRecent {
                    Text(LocalActivitySection.recencyMarker)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel(LocalActivitySection.recencyAccessibilityLabel)
                        .explainable(.projectRecency,
                                     site: LocalActivitySection.recencySite,
                                     body: card(.projectRecency))
                }
                Spacer(minLength: 8)
                Text(project.tokens)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
            }
            ForEach(Array(project.models.enumerated()), id: \.offset) { _, model in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.name)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(model.tokens)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 12)
            }
        }
    }

    private func card(_ element: ExplanationElement) -> String? {
        guard let explanation else { return nil }
        return ExplanationRegistry.card(element, tool: explanation.tool, grain: explanation.grain)
    }
}
