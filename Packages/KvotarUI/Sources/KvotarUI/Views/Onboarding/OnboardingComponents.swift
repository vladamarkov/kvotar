import SwiftUI
import KvotarCore

/// Presentation pieces used only by the first-run window (UI Spec Part 3 §3a). Popover tokens,
/// popover type scale; nothing here carries logic. Kept apart from `Components.swift` because the
/// popover has no buttons, dots or checkboxes of its own and must not grow them by accident.

/// Fixed window size (§3a).
enum OnboardingLayout {
    static let width: CGFloat = 480
    static let height: CGFloat = 440
    static let sidePadding: CGFloat = 28
}

/// The five progress dots under the screen — the current one filled, the rest hollow.
struct OnboardingDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Theme.textPrimary : Theme.border)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// The filled primary action (Continue / Allow & continue / Open Kvotar).
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.card)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Theme.textPrimary.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 7))
    }
}

/// The quiet secondary action (Skip / Back).
struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(configuration.isPressed ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
    }
}

/// A checkmarked proof point (screen 1) or list line (screen 5).
struct OnboardingCheckLine: View {
    let text: String
    var symbol = "checkmark"
    var tint: Color = Theme.green

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A bordered card with a bold title and a one-line explanation (screen 3's three slots).
struct OnboardingCard: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.sectionFill, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A rendering of the status item on a dark menu-bar strip. Always dark — the real item is drawn
/// on the system bar, and the window's appearance must not recolour it — so the strip forces
/// `.dark` on `MenuBarItemView`, which otherwise follows the window (§3a screen 3).
struct OnboardingMenuBarStrip: View {
    let render: MenuBarRender
    /// Draw neighbouring glyphs and the clock, with the Kvotar item outlined (screen 3); off for
    /// the compact per-tool pill (screen 2).
    var showsNeighbours = true

    var body: some View {
        HStack(spacing: 14) {
            if showsNeighbours { Spacer(minLength: 0) }
            MenuBarItemView(render: render)
                .frame(height: 22)
                .padding(.horizontal, 2)
                .overlay {
                    if showsNeighbours {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.55), lineWidth: 1)
                    }
                }
            if showsNeighbours {
                Image(systemName: "wifi").font(.system(size: 12))
                Image(systemName: "battery.75percent").font(.system(size: 13))
                Text("Mon 09:41").font(.system(size: 12.5))
            }
        }
        .foregroundStyle(Color.white.opacity(0.9))
        .padding(.horizontal, showsNeighbours ? 12 : 8)
        .frame(height: 26)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13), in: RoundedRectangle(cornerRadius: 6))
        .environment(\.colorScheme, .dark)
    }
}

/// A plain macOS checkbox row with the window's type scale (screen 5).
struct OnboardingCheckbox: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
        }
        .toggleStyle(.checkbox)
    }
}
