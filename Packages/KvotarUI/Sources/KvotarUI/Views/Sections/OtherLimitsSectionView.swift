import SwiftUI

/// `OTHER LIMITS` (UI Spec §REV92 — STEP_178): every limit the header is *not* describing, each
/// exactly once. Account limits first as plain rows, then one group per model allowance with each
/// reported window as its own row — a weekly-only main allowance and a model's five-hour plus
/// weekly windows coexist, and neither implies the other. The section is suppressed entirely when
/// there is nothing to list, so an empty block never reads as a failed fetch.
///
/// It replaced two things at the cutover: the always-shown Account-quota row list, and the
/// collapsed `+ N model limits` disclosure that hid a model's windows behind a chevron.
struct OtherLimitsSectionView: View {
    let section: OtherLimitsSection

    var body: some View {
        SectionCard(title: "Other limits") {
            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                OtherLimitRowView(row: row)
            }
            ForEach(Array(section.modelGroups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 4) {
                    if group.showsHeading {
                        Text(group.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                        OtherLimitRowView(row: row)
                            .padding(.leading, group.showsHeading ? 12 : 0)
                    }
                }
                .padding(.top, 2)
            }
            if let tag = section.sourceTag {
                SourceTagView(tag: tag)
            }
        }
    }
}

/// One limit: its name and what is left, then its own muted detail lines.
///
/// Two states the row can be in beyond plain (REV-96 §2.4 — STEP_195). **Blocked:** another
/// limit's block makes this one unusable, so the whole row steps back to tertiary ink — the value
/// already ends `· blocked by the weekly` and the dot is already gone, and a row in full contrast
/// beside them would still read as an offer. **Highlighted:** this row is the one the strip under
/// the verdict is about, so it sits on a faint chip; the reader who reads the strip and looks down
/// the list should not have to work out which of three rows it meant.
private struct OtherLimitRowView: View {
    let row: OtherLimitRow
    @Environment(\.explanationContext) private var explanation

    /// Tertiary everywhere on a blocked row — label, value, reset and meta together, because a
    /// half-dimmed row reads as an error rather than as withdrawn quota.
    private var valueColour: Color {
        if row.isBlocked { return Theme.textTertiary }
        return row.cue?.color ?? Theme.textPrimary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                OtherLimitLabel(text: row.label, blocked: row.isBlocked)
                    .explainable(row.explanation, site: row.label,
                                 body: card(row.explanation),
                                 live: row.explanationLive?.text,
                                 bridge: row.explanationBridge?.text)
                if let reset = row.reset {
                    resetText(reset)
                }
                Spacer(minLength: 8)
                if let cue = row.cue {
                    StatusDotView(dot: cue, diameter: 6)
                }
                Text(row.value)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(valueColour)
                    .multilineTextAlignment(.trailing)
            }
            .fixedSize(horizontal: false, vertical: true)
            // `$69.16 of $120.00` — the money meter's own amounts beside its percentage.
            if let detail = row.detail {
                detailText(detail)
            }
            // `Set by your organization · ~$3.96/day · on pace` (E-16).
            if let meta = row.meta {
                if let element = meta.explanation {
                    detailText(meta.text)
                        .explainable(element, site: "\(row.label) pace", body: card(element))
                } else {
                    detailText(meta.text)
                }
            }
        }
        // The chip is drawn *behind* the row and bleeds into the section's own padding, so the
        // highlight reads as a lifted row rather than as a box someone drew inside the list.
        .background {
            if row.isHighlighted {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.rowHighlight)
                    .padding(.vertical, -2)
                    .padding(.horizontal, -7)
            }
        }
    }

    @ViewBuilder
    private func resetText(_ reset: String) -> some View {
        let text = Text("· \(reset)")
            .font(.caption2)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .help(row.resetAccessibilityText ?? reset)
            .accessibilityLabel(Text(row.resetAccessibilityText ?? reset))
        if let element = row.resetExplanation {
            text.explainable(element, site: "\(row.label) reset", body: card(element))
        } else {
            text
        }
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func card(_ element: ExplanationElement) -> String? {
        guard let explanation else { return nil }
        return ExplanationRegistry.card(element, tool: explanation.tool, grain: explanation.grain)
    }
}

private struct OtherLimitLabel: View {
    let text: String
    var blocked: Bool = false
    @Environment(\.explanationHovered) private var hovered

    var body: some View {
        Text(text)
            .font(.callout)
            .explanationLabelTell(hovered,
                                  restColour: blocked ? Theme.textTertiary : Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
