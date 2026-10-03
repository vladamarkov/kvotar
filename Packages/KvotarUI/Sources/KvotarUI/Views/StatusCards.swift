import SwiftUI
import KvotarCore

/// Pre-first-poll loading card (Baseline §13.3). Copy differs per tool. Not a failure — normal
/// startup; the popover auto-updates in place when data arrives.
struct LoadingCardView: View {
    let tool: Tool

    private var detail: String {
        switch tool {
        case .claude: return "Fetching account data. This takes a few seconds on first launch."
        case .codex:  return "Starting Codex app-server. This takes a few seconds on first launch."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.headline).foregroundStyle(Theme.textPrimary)
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 14)
    }
}

/// Idle / fallback card (Baseline §13.3, UI Spec §1.2) — no active session or account unreachable
/// after timeout. Menu bar shows `–– est`.
struct IdleCardView: View {
    let tool: Tool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("–– est")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
            // REV-15 (STEP_27): also shown when credentials exist but account data stays
            // unavailable past the first-launch grace — copy must never reference polling
            // mechanics (§10.6 / absolute rules).
            Text("No active session, or account data is temporarily unavailable. "
                 + "Local session data appears here when \(tool == .claude ? "Claude Code" : "Codex") is active.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 14)
    }
}

/// First-run / onboarding card (Baseline §13.3, UI Spec Part 3 §3) — the tool was never detected
/// (no credentials AND no local JSONL), distinct from Idle/fallback (detected but unreachable).
/// Shows detection status, what Kvotar looked for, the action to take, and a Re-check button.
/// Per-tool copy — no cross-tool reuse (D-11). The Re-check accelerates the next poll; when the
/// credential/JSONL appears the poll loop transitions this tab to live data without a restart.
struct FirstRunCardView: View {
    let tool: Tool
    @EnvironmentObject private var vm: AppViewModel

    private var title: String {
        switch tool {
        case .claude: return "Claude Code not detected"
        case .codex:  return "Codex not detected"
        }
    }

    private var action: String {
        switch tool {
        case .claude: return "Sign in to Claude Code once so its credentials exist, then re-check."
        case .codex:  return "Install Codex Desktop and sign in, then re-check."
        }
    }

    private var checked: String {
        switch tool {
        case .claude: return "Looked for the Keychain item “Claude Code-credentials” and session logs in ~/.claude/projects."
        case .codex:  return "Looked for ~/.codex/auth.json and session logs in ~/.codex/sessions."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            Text(action)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(checked)
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Re-check") { vm.recheck(tool) }
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 14)
    }
}

#Preview("First-run · Claude") {
    FirstRunCardView(tool: .claude)
        .environmentObject(AppViewModel())
        .frame(width: 340)
        .background(Theme.card)
}

#Preview("First-run · Codex") {
    FirstRunCardView(tool: .codex)
        .environmentObject(AppViewModel())
        .frame(width: 340)
        .background(Theme.card)
}
