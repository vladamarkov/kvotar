import SwiftUI

// One preview per Codex state (UI Spec v4.5 §1.2). Each injects a stub AppViewModel with the
// Codex tab active.

@MainActor
private func codexPreview(_ state: CodexDisplayState) -> some View {
    PopoverView().environmentObject(AppViewModel.previewModel(codex: state, activeTab: .codex))
}

#Preview("Codex · Healthy") { codexPreview(.healthy) }
#Preview("Codex · Elevated") { codexPreview(.elevated) }
#Preview("Codex · Scoped model warning") { codexPreview(.scopedModelWarning) }
#Preview("Codex · At risk") { codexPreview(.atRisk) }
#Preview("Codex · Bad timing") { codexPreview(.badTiming) }
#Preview("Codex · Over quota") { codexPreview(.overQuota) }
#Preview("Codex · Enterprise blocked") { codexPreview(.enterpriseBlocked) }
#Preview("Codex · Null-window") { codexPreview(.nullWindow) }
#Preview("Codex · Spend control") { codexPreview(.spendControl) }
#Preview("Codex · Multi-surface") { codexPreview(.multiSurface) }
#Preview("Codex · Fast burn spike") { codexPreview(.fastBurnSpike) }
#Preview("Codex · Off-machine burn") { codexPreview(.offMachineBurn) }
#Preview("Codex · Idle / fallback") { codexPreview(.idle) }
#Preview("Codex · Loading") { codexPreview(.loading) }

// Enterprise monthly layout (REV-48/D-43 — STEP_68): the attribution split, the credits/hr pill,
// the two-section local card, and the slimmed credits card rendering last.
#Preview("Codex · Enterprise monthly") { codexPreview(.cxMonthly) }
#Preview("Codex · Enterprise monthly · idle day") { codexPreview(.cxMonthlyIdleDay) }

// Low-allowance consumer shape (REV-59/D-58…D-61 — STEP_87 → STEP_89): the width-named window,
// no Weekly rows, no burn card, no verdict, the unpublished-limit note with its upgrade link, and
// the two-row est-value section.
#Preview("Codex · Low-allowance (go)") { codexPreview(.cxLowAllowance) }
#Preview("Codex · Low-allowance blocked (go, 29d)") { codexPreview(.cxLowAllowanceBlocked) }

// Single-tool machine (D-68 — STEP_105): Claude undetected → tabless popover, Codex content
// fills it.
#Preview("Popover · Codex only (tabless)") {
    PopoverView().environmentObject(AppViewModel.previewSingleToolModel(detected: .codex))
}
