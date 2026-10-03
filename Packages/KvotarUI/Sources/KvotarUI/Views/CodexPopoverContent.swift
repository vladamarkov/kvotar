import SwiftUI

/// Codex tab body (UI Spec §REV92) — the twin of the Claude tab plus the two Codex-only notes
/// and the Enterprise credits/spend card. Pure rendering.
struct CodexPopoverContent: View {
    let state: CodexDisplayState
    /// The "Since you last looked" line for this tab (§2.8 row 0 — STEP_112); nil = absent.
    var deltaLine: String? = nil
    var onDismissDeltaLine: () -> Void = {}
    /// Opens History at this provider's own local day, on the project breakdown.
    var onOpenProjects: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state.phase {
            case .loading:
                LoadingCardView(tool: .codex)
            case .idle:
                IdleCardView(tool: .codex)
            case .firstRun:
                FirstRunCardView(tool: .codex)
            case .content:
                // Row 0 (REV-68/D-75): only on the open where the §2.8 gate passed; above the
                // header, gone on click or with the popover, never re-computed while open.
                if let deltaLine {
                    DeltaLineView(text: deltaLine, onDismiss: onDismissDeltaLine)
                }
                if let header = state.header {
                    HeaderSectionView(header: header, dot: state.dot, tool: .codex)
                }
                // Both notes describe the account's own allowance, so they sit with the header
                // rather than with a limits list a single-limit account never draws (STEP_178).
                if state.quotaNote != nil || state.nullWindowNote != nil {
                    SectionCard {
                        if let note = state.quotaNote {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let url = state.quotaNoteURL {
                            Link(CodexDisplayState.upgradeLinkLabel, destination: url)
                                .font(.caption)
                                .foregroundStyle(Theme.blue)
                        }
                        if let note = state.nullWindowNote {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                // Recommendation directly under the header (§0.6 v4.6). The near-cap deep link
                // (E5, REV-38) rides along when present.
                if let recommendation = state.recommendation {
                    RecommendationSectionView(text: recommendation,
                                              severity: state.recommendationSeverity,
                                              linkURL: state.recommendationURL,
                                              linkLabel: "Request limit increase ↗")
                }
                if let otherLimits = state.otherLimits {
                    OtherLimitsSectionView(section: otherLimits)
                }
                if let local = state.localActivity {
                    LocalActivitySectionView(section: local, onOpenProjects: onOpenProjects)
                    LocalValueSectionView(section: local)
                }
                if let credits = state.creditsSpend {
                    CreditsSpendSectionView(section: credits)
                }
            }
        }
        // What every explainable element on this tab needs to resolve its card (STEP_111): the
        // copy column, the D-58 grain word for the E-01 `[Width]`, and the freeze reason.
        .environment(\.explanationContext,
                     ExplanationContext(tool: .codex, grain: state.windowGrain,
                                        freeze: state.sourceFreeze))
    }
}
