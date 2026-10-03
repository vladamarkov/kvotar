import SwiftUI

/// Codex credits / spend section (UI Spec §2.4 Codex) — Enterprise: plan, credit balance,
/// spend control, est. token value (today + 30-day).
struct CreditsSpendSectionView: View {
    let section: CreditsSpendSection

    var body: some View {
        SectionCard(title: "Credits / spend") {
            VStack(spacing: 4) {
                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                    RowView(row: row)
                }
            }
        }
    }
}
