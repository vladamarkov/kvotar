import SwiftUI

/// Second-instance popover (Baseline §9.2 step 3): another compatible app holds the polling lock,
/// so this process must not poll or touch the database — the only affordance is quitting. Copy is
/// the §9.2 wording; the quit action is injected so the view stays AppKit-free.
public struct AlreadyRunningView: View {
    /// Which lock refused, and therefore which app the user has to act on.
    ///
    /// §9.2 named both products in one sentence because the caller discarded this distinction — but
    /// the guard has always known it. Kvotar's own lock can only be held by another Kvotar
    /// (AgentPilot writes `agentpilot.pid`, never `kvotar.pid`), and the legacy lock is reached only
    /// once Kvotar's own lock was free, which a live Kvotar would be holding — it takes both, in
    /// that order. So each case names one app, which is what the both-names copy was reaching for:
    /// a message the user can act on.
    public enum Conflict {
        /// Another Kvotar. The common case, and the only one a clean install can reach —
        /// `PIDLock.legacyCompatibilityPath` returns nil until AgentPilot's folder exists, so a Mac
        /// that never ran AgentPilot must never be told about it.
        case kvotarInstance
        /// The released AgentPilot app, still polling. Says which app to quit, not merely that one
        /// of two is running.
        case legacyAgentPilot

        var message: String {
            switch self {
            case .kvotarInstance:
                return "Kvotar is already running. Only one instance polls at a time."
            case .legacyAgentPilot:
                // Three short sentences, and deliberately no em dash. The old-name audit pins this
                // string with `^…$` against `/usr/bin/strings`, which ends a run at the first
                // non-ASCII byte — an em dash would split the sentence in two and the anchored rule
                // could never match, failing the release build (and only there, long after
                // `swift test` went green). The house em dash is worth losing on the one user-facing
                // string a packaging gate has to read back verbatim.
                // `+` of two literals is *not* folded — the compiler emits both halves separately
                // and `strings` reports two lines. A multiline literal with a line continuation is
                // one literal by construction, which is what the anchored rule needs.
                return """
                    AgentPilot is already running. Quit it before starting Kvotar. \
                    Only one app polls at a time.
                    """
            }
        }
    }

    private let conflict: Conflict
    private let onQuit: () -> Void

    /// No default for `conflict`: a new call site must say which lock refused, since guessing
    /// reintroduces exactly the ambiguity this type exists to remove.
    public init(conflict: Conflict, onQuit: @escaping () -> Void) {
        self.conflict = conflict
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(conflict.message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Quit this instance", action: onQuit)
        }
        .padding(16)
        .frame(width: 280)
        .background(Theme.card)
    }
}

#Preview("Another Kvotar") {
    AlreadyRunningView(conflict: .kvotarInstance, onQuit: {})
}

// Preview names reach the built binary as strings, so this one carries no product name — the
// old-name audit reads every string in the bundle.
#Preview("Legacy conflict") {
    AlreadyRunningView(conflict: .legacyAgentPilot, onQuit: {})
}
