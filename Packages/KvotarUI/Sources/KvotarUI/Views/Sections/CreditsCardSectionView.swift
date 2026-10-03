import SwiftUI

/// Usage-credits card (UI Spec §2.4a, REV-29) — Claude only, always shown when the account exposes
/// an `extra_usage` object. Status row (colour-cued by money state) + conditional This-month /
/// Auto-reload / Prepaid-balance rows + an optional backstop / disabled-reason sub-line + the
/// mixed-provenance source stamp. Real billed money, not est. token value (§2.4a.3). Pure rendering.
struct CreditsCardSectionView: View {
    let section: CreditsCardSection

    var body: some View {
        SectionCard(title: section.title) {
            VStack(alignment: .leading, spacing: 4) {
                RowView(row: section.status)
                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                    RowView(row: row)
                }
                if let subLine = section.subLine {
                    Text(subLine)
                        .font(.caption)
                        .foregroundStyle(subLineColour)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // §2.4a.2 — the card's one interactive affordance: opens Claude usage settings in the
                // browser (credits on/off, balance, spend limit). The app stays read-only; it only
                // launches the page. `Link` routes through the default openURL action on macOS.
                if let url = section.manageURL {
                    Link(destination: url) {
                        Text("Manage in Claude web ↗")
                            .font(.caption)
                            .foregroundStyle(Theme.blue)
                    }
                    .buttonStyle(.plain)
                }
                SourceTagView(tag: section.sourceTag)
            }
        }
    }

    /// §2.4a.2: the imminent backstop sub-line is amber (warning); the calm backstop line and the
    /// `Off: [reason]` line are muted (info).
    private var subLineColour: Color {
        switch section.subLineSeverity {
        case .warning: return StatusDot.amber.color
        case .danger:  return StatusDot.red.color
        case .info, .none: return Theme.textTertiary
        }
    }
}
