import SwiftUI
import KvotarCore

/// Combined first-run welcome (UI Spec Part 3 §3) — shown in place of the tabbed view when
/// *neither* tool is detected, so a fresh install opens to guidance rather than an empty tab bar.
/// A brief intro over both tools' first-run cards; each card carries its own Re-check. As soon as
/// either tool is detected the popover reverts to the normal tabbed layout (PopoverView branches
/// on `AppViewModel.bothUndetected`).
struct WelcomeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                KvotarMarkView(style: .brand)
                    .frame(width: 38, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Kvotar").font(.headline).foregroundStyle(Theme.textPrimary)
                    Text("Monitors your Claude and Codex quota in the menu bar. Neither is set up yet — "
                         + "sign in to either and it appears here automatically.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.top, 14)
            .padding(.bottom, 4)

            Divider().overlay(Theme.border)
            FirstRunCardView(tool: .claude)
            Divider().overlay(Theme.borderLight)
            FirstRunCardView(tool: .codex)
        }
    }
}

#Preview("Welcome (both undetected)") {
    WelcomeView()
        .environmentObject(AppViewModel())
        .frame(width: 340)
        .background(Theme.card)
}
