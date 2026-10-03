import SwiftUI

// One preview per Claude state (UI Spec v4.5 §1.2). Each injects a stub AppViewModel with the
// Claude tab active. Over quota has three copy cases (§4.1).

@MainActor
private func claudePreview(_ state: ClaudeDisplayState) -> some View {
    PopoverView().environmentObject(AppViewModel.previewModel(claude: state, activeTab: .claude))
}

#Preview("Claude · Healthy") { claudePreview(.healthy) }
#Preview("Claude · Elevated") { claudePreview(.elevated) }
#Preview("Claude · Limit ahead of pace") { claudePreview(.limitAheadOfPace) }
#Preview("Claude · At risk") { claudePreview(.atRisk) }
#Preview("Claude · Bad timing") { claudePreview(.badTiming) }
#Preview("Claude · Credits active at 100%") { claudePreview(.creditsActiveAtLimit) }
#Preview("Claude · Over quota (credits active)") { claudePreview(.overQuotaCreditsActive) }
#Preview("Claude · Over quota (credits off)") { claudePreview(.overQuotaCreditsOff) }
#Preview("Claude · Over quota (hard block)") { claudePreview(.overQuotaHardBlock) }
#Preview("Claude · Fast burn spike") { claudePreview(.fastBurnSpike) }
#Preview("Claude · Off-machine burn") { claudePreview(.offMachineBurn) }
#Preview("Claude · Null window") { claudePreview(.nullWindow) }
#Preview("Claude · Ent monthly (on pace)") { claudePreview(.entMonthly) }
#Preview("Claude · Ent monthly (idle today)") { claudePreview(.entMonthlyIdleDay) }
#Preview("Claude · Ent monthly (near cap)") { claudePreview(.entMonthlyNearCap) }
#Preview("Claude · Ent monthly (reached · ASSUMED P1-16)") { claudePreview(.entMonthlyReached) }
#Preview("Claude · Ent monthly (stale)") { claudePreview(.entMonthlyStale) }
#Preview("Claude · Idle retrospective (window accounting)") { claudePreview(.idleRetrospective) }
#Preview("Claude · Layout stress (retrospective)") { claudePreview(.stressRetrospective) }
#Preview("Claude · Stale (as of)") { claudePreview(.stale) }
#Preview("Claude · Reconnecting (rate-limited)") { claudePreview(.reconnecting) }
#Preview("Claude · Sign-in expired") { claudePreview(.signinExpired) }
#Preview("Claude · Sign-in expired (monthly)") { claudePreview(.entMonthlySigninExpired) }
#Preview("Claude · Idle / fallback") { claudePreview(.idle) }
#Preview("Claude · Loading") { claudePreview(.loading) }

// Single-tool machine (D-68 — STEP_105): Codex undetected → tabless popover, Claude content
// fills it. The dev machine has both tools, so this preview is the honest stand-in.
#Preview("Popover · Claude only (tabless)") {
    PopoverView().environmentObject(AppViewModel.previewSingleToolModel(detected: .claude))
}
