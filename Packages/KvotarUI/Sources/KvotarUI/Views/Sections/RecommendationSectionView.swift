import SwiftUI

/// Recommendation / hint section (UI Spec §2.6 Claude / §2.8 Codex) — one contextual sentence,
/// shown only when a warning state is active. Coloured by severity (prototype `.hint-d/-w/-i`).
/// `linkURL` renders an optional action link under the sentence (the E5 near-cap "Request limit
/// increase" deep link — read-only launch, the STEP_35 external-link pattern).
struct RecommendationSectionView: View {
    let text: String
    let severity: HintSeverity
    var linkURL: URL?
    var linkLabel: String = ""

    var body: some View {
        let colors = Theme.hint(severity)
        SectionCard {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: severity == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(colors.fg)
                VStack(alignment: .leading, spacing: 4) {
                    Text(text)
                        .foregroundStyle(colors.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    if let linkURL {
                        Link(destination: linkURL) {
                            Text(linkLabel)
                                .font(.caption)
                                .foregroundStyle(Theme.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(colors.bg, in: RoundedRectangle(cornerRadius: 6))
            // STEP_180: the re-derived amber fill is the faintest of the four — a heavier tint
            // drops its own text under 4.5:1 — so the box is given its edge by a hairline in the
            // severity hue rather than by a darker fill. One rule for all four, so they match.
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(colors.fg.opacity(0.28), lineWidth: 1)
            }
        }
    }
}
