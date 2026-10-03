import SwiftUI

/// Small reusable presentation pieces shared across popover sections. Pure rendering — no logic.
/// Styling follows UI Prototype v6.1 via the adaptive `Theme` tokens.

/// A coloured status dot (menu bar and popover tabs, Baseline §14.1 / §15.1).
struct StatusDotView: View {
    let dot: StatusDot
    var diameter: CGFloat = 8

    var body: some View {
        Circle()
            .fill(dot.color)
            .frame(width: diameter, height: diameter)
    }
}

/// A popover section block (prototype `.ps`): optional uppercase title, consistent padding, a
/// hairline bottom divider, and an optional left-accent bar for danger/warning/info sections.
/// Sections stack with zero spacing so the dividers read as one unified card.
struct SectionCard<Content: View>: View {
    var title: String? = nil
    var accent: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textSecondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .overlay(alignment: .leading) {
            if let accent { Rectangle().fill(accent).frame(width: 3) }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.borderLight).frame(height: 1)
        }
    }
}

/// A single label / value row, value optionally colour-cued. A row tagged with an explanation
/// element (STEP_111) is a hover-card target: the whole row is the hover/click surface, the label
/// carries the tell (§5.1). Rows without a tag — and every row where no `ExplanationContext` is in
/// the environment (the History window) — render exactly as before.
///
/// A tagged row's card carries its live line too where the formatter filled one (REV-75/D-88 —
/// STEP_130 computes, STEP_131 draws): E-01, E-02, E-07 and E-12 all reach the card through here.
struct RowView: View {
    let row: LabeledRow
    /// `.callout` everywhere the popover already draws rows; the verdict anatomy passes `.caption`
    /// so its block reads as the verdict's footnote, not another quota card (STEP_110).
    var font: Font = .callout
    @Environment(\.explanationContext) private var explanation

    var body: some View {
        RowContent(row: row, font: font)
            .explainable(row.explanation ?? .heroPercent, site: row.label,
                         body: cardBody, live: row.explanationLive?.text,
                         bridge: row.explanationBridge?.text)
    }

    private var cardBody: String? {
        guard let element = row.explanation, let explanation else { return nil }
        return ExplanationRegistry.card(element, tool: explanation.tool, grain: explanation.grain)
    }
}

/// The row's content, split out so the label can read the hover tell set by `.explainable`.
private struct RowContent: View {
    let row: LabeledRow
    let font: Font
    @Environment(\.explanationHovered) private var hovered

    var body: some View {
        HStack(spacing: 6) {
            Text(row.label)
                .explanationLabelTell(hovered, restColour: Theme.textSecondary)
            Spacer(minLength: 8)
            if let dot = row.dot {
                StatusDotView(dot: dot, diameter: 6)
            }
            Text(row.value)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(row.dot?.color ?? Theme.textPrimary)
        }
        .font(font)
    }
}

/// The header quota bar. `progress` is what is **left** of the window (REV-77 / D-97 — UI Spec
/// §0.1 / §2.2): the bar drains as quota is spent, and at or past 100% used it is empty under a
/// red state — the v4.6 §0.5 overflow stripe is retired, since nothing is left to overflow.
/// The `106%` survives as the used figure of the hero card's bridge line.
struct ProgressBarView: View {
    let progress: Double
    let dot: StatusDot

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.meterTrack)
                Capsule()
                    .fill(dot.color)
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 5)
    }
}

/// A plan badge pill. Neutral on every `PlanBadgeKind` since STEP_180 — see `Theme.badge`.
struct PlanBadgeView: View {
    let text: String
    let kind: PlanBadgeKind

    var body: some View {
        let colors = Theme.badge(kind)
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(colors.bg, in: Capsule())
            .foregroundStyle(colors.fg)
    }
}

/// Burn-rate urgency pill: none / low / mid / high (UI Spec §2.4).
struct PillView: View {
    let label: String
    let dot: StatusDot

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.tint(dot), in: Capsule())
            .foregroundStyle(dot.color)
    }
}

/// Muted source / freshness tag under a section (Baseline §15 — every number needs a source label).
/// The always-on per-source age stamp (UI Spec v4.7 §2.2a, D-21) is appended muted, turning amber
/// past 2 minutes; the "as of" stale-keep form lives inside `base` and carries no age.
///
/// Every source tag is an E-09 hover-card target (STEP_111, UI Spec Part 3 §5.2 rule 4) — the one
/// state-aware card, assembled from the terms the tag currently shows (`exact` / `est.` / `as of`)
/// plus the freeze reason from the tab's `ExplanationContext`. A tag showing none of those terms
/// (the local JSONL tag, the "Priced at…" note) resolves to no card and stays inert.
struct SourceTagView: View {
    let tag: SourceTag
    @Environment(\.explanationContext) private var explanation

    var body: some View {
        SourceTagText(tag: tag)
            .explainable(.sourceTag, site: tag.base, body: cardBody)
    }

    private var cardBody: String? {
        guard let explanation else { return nil }
        return ExplanationRegistry.sourceTagCard(tool: explanation.tool, tag: tag,
                                                 freeze: explanation.freeze)
    }
}

/// The tag's text, split out so it can read the hover tell set by `.explainable`.
private struct SourceTagText: View {
    let tag: SourceTag
    @Environment(\.explanationHovered) private var hovered

    var body: some View {
        let base = Text(tag.base).explanationLabelTell(hovered, restColour: Theme.textTertiary)
        let content = tag.age.map { age in
            base + Text(" · \(age)")
                .foregroundStyle(tag.ageIsAmber ? StatusDot.amber.color : Theme.textTertiary)
        } ?? base
        content
            .font(.system(size: 11, weight: .regular))
            // STEP_180: past two base ticks the age turns amber and that is the whole signal —
            // the text itself reads the same either way. Spoken, the amber has to be said.
            .accessibilityValue(Text(tag.ageIsAmber ? "older than expected" : ""))
    }
}
