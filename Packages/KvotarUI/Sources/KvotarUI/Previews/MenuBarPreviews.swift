import SwiftUI

// Menu-bar display modes (Baseline §14.1, UI Spec §1.0). The previews render the same
// `MenuBarItemView` the live `NSStatusItem` hosts — one per mode/state, light + dark.

@MainActor
private func menuBarRow(_ render: MenuBarRender) -> some View {
    MenuBarItemView(render: render)
        .frame(height: 24)
        .padding(.horizontal, 6)
        .background(.bar)
}

#Preview("Both stacked · calm / weekly / at-risk") {
    VStack(alignment: .leading, spacing: 8) {
        menuBarRow(.stacked)             // two 9pt rows, dots (Codex spend-control red)
        menuBarRow(.stackedLongLimit)    // steady: "CL 78% ↻1h52m" amber over "CX 29% ◔~31m"
        menuBarRow(.stackedLongLimitReminding)  // the 5-second phase: "CL ⚠mo 8%"
        menuBarRow(.stackedWeeklyBlocked)       // held: "CL ⚠wk 0% ↻3d"
        menuBarRow(.stackedAtRisk)       // "CL 13% ◔~11m" red over "CX 58% ↻2h04m"
    }
    .padding()
}

#Preview("Est/null · single-tool collapse · loading") {
    VStack(alignment: .leading, spacing: 8) {
        menuBarRow(.stackedEstNull)      // "CL –– est" over "CX —— est"
        menuBarRow(.singleToolCollapse)  // D-32/D-107: one detected tool → one reduced-size row
        menuBarRow(.loading)             // "CL …" over "CX …"
    }
    .padding()
}

#Preview("Single-tool modes") {
    VStack(alignment: .leading, spacing: 8) {
        menuBarRow(.claudeOnly)          // "CL 62% ↻1h52m" + dot, 11pt (D-107), Codex ignored
        menuBarRow(.singleToolNoSlot)    // stale-keep "CL 57%" — same row, slot absent
        menuBarRow(.codexOnlyUndetected) // chosen tool undetected → nothing, and that is correct
    }
    .padding()
}

// D-78 (REV-71 §3.3) — nothing detected. The row deliberately holds *one neutral Kvotar mark and
// nothing else*: this is a first launch, and a percentage, a `——` or a tool prefix would each
// assert something about a tool the app has not found. It sits beside `.stackedEstNull`, the
// different state it must never be confused with — detected tools with no reading. The state is
// mode-independent, so one row covers all three modes.
#Preview("Nothing detected · light") {
    VStack(alignment: .leading, spacing: 8) {
        menuBarRow(.nothingDetected)
        menuBarRow(.stackedEstNull)      // for contrast: detected, no reading
    }
    .padding()
}

#Preview("Nothing detected · dark") {
    VStack(alignment: .leading, spacing: 8) {
        menuBarRow(.nothingDetected)
        menuBarRow(.stackedEstNull)
    }
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("Both stacked · dark") {
    VStack(alignment: .leading, spacing: 8) {
        menuBarRow(.stacked)
        menuBarRow(.stackedLongLimit)
        menuBarRow(.stackedAtRisk)
    }
    .padding()
    .preferredColorScheme(.dark)
}

// Per-source stale-keep freshness (§2.2a, D-21): past the §9.3 TTL each source tag drops its age
// stamp for "· as of [t]" (REV-25 removed the old "Updated X min ago" footer line entirely).
#Preview("Popover · Stale-keep freshness") {
    PopoverView().environmentObject(AppViewModel.previewStaleModel())
}
