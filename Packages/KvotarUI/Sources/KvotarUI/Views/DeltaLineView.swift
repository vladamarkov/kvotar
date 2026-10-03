import SwiftUI

/// Row 0 of a tab — the "Since you last looked" band (UI Spec Part 1 §2.8 / Part 2 §2.10, D-75 —
/// STEP_112): one data-tier line, `blue-bg` band, `blue` text, 11 pt, an `✕` at the right. A click
/// anywhere on it hides it for this open; otherwise it stays, unchanged, until the popover closes.
/// Nothing here is state — the view model owns the line (`deltaLines`) and the dismissal.
struct DeltaLineView: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.blue)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.blue)
                .accessibilityLabel("Hide")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(Theme.blueBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.borderLight).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
