import SwiftUI

/// Claude tab body (UI Spec §REV92). Renders the loading / idle cards or the approved section
/// stack depending on `phase`. Pure rendering from the display state — no logic.
///
/// The order is the contract's: delta → header → recommendation → `OTHER LIMITS` →
/// `LOCAL ACTIVITY · TODAY` → `LOCAL ACTIVITY · ESTIMATED VALUE` → credits. The Account-quota,
/// Burn-rate, Monthly and two-part local sections were retired at the STEP_178 cutover; their
/// facts live on the header and in the two sections above.
struct ClaudePopoverContent: View {
    let state: ClaudeDisplayState
    /// The "Since you last looked" line for this tab (§2.8 row 0 — STEP_112); nil = absent.
    var deltaLine: String? = nil
    var onDismissDeltaLine: () -> Void = {}
    /// Opens History at this provider's own local day, on the project breakdown.
    var onOpenProjects: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state.phase {
            case .loading:
                LoadingCardView(tool: .claude)
            case .idle:
                IdleCardView(tool: .claude)
            case .firstRun:
                FirstRunCardView(tool: .claude)
            case .content:
                // Row 0 (REV-68/D-75): only on the open where the §2.8 gate passed; above the
                // header, gone on click or with the popover, never re-computed while open.
                if let deltaLine {
                    DeltaLineView(text: deltaLine, onDismiss: onDismissDeltaLine)
                }
                if let header = state.header {
                    HeaderSectionView(header: header, dot: state.dot, tool: .claude)
                }
                // Recommendation directly under the header (§0.6 v4.6): in critical states the
                // action is the second thing seen, not the last. The near-cap deep link
                // (E5, REV-40) rides along when present — admin-facing, the seat cannot self-serve.
                if let recommendation = state.recommendation {
                    RecommendationSectionView(text: recommendation,
                                              severity: state.recommendationSeverity,
                                              linkURL: state.recommendationURL,
                                              linkLabel: "Manage in Claude web ↗")
                }
                if let otherLimits = state.otherLimits {
                    OtherLimitsSectionView(section: otherLimits)
                }
                if let local = state.localActivity {
                    LocalActivitySectionView(section: local, onOpenProjects: onOpenProjects)
                    LocalValueSectionView(section: local)
                }
                // Usage-credits card (§2.4a): renders last on the Claude tab, below the estimated
                // value section. Present whenever the account exposes an extra_usage object; nil
                // (suppressed) only for Enterprise / no pay-as-you-go.
                if let credits = state.creditsCard {
                    CreditsCardSectionView(section: credits)
                }
            }
        }
        // What every explainable element on this tab needs to resolve its card (STEP_111): the
        // copy column and the freeze reason the source-tag card may name.
        .environment(\.explanationContext,
                     ExplanationContext(tool: .claude, freeze: state.sourceFreeze))
    }
}
