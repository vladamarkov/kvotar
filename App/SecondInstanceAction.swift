import Foundation
import KvotarUI

/// What a copy of Kvotar that lost the §9.2 lock does about it (REV-99 §2.5 — STEP_205). Pure, so
/// `KvotarTests` can pin it without AppKit, on the `LaunchSource` / `OnboardingGate` pattern.
///
/// Three outcomes, and the one that used to be the only one is gone: a second Kvotar no longer
/// draws its own grey-dot status item. On the full menu bar this revision exists for, that added a
/// **second invisible icon** and displayed nothing — the user performed the one recovery action
/// available to them and got silence.
enum SecondInstanceAction: Equatable {
    /// Ask the running instance to show its window, log at `INFO`, and quit. No UI at all.
    case handOffAndQuit
    /// Quit, posting nothing. Launch at login is silent by contract, and that contract does not
    /// bend because two copies happen to be registered.
    case quitSilently
    /// Show `AlreadyRunningView` in a window and quit on its button. There is no running Kvotar to
    /// hand off to — the lock is held by a released AgentPilot build.
    case showConflict

    /// `conflict` is which lock refused; `launch` is the decision `LaunchSource` already produced
    /// for this process's own launch event.
    ///
    /// The legacy row ignores `launch` deliberately, and it is the one place login is *not*
    /// silent: that state is unusable rather than merely unread, and this window is the only place
    /// the user learns which app to quit. The silent-login contract is about not interrupting a
    /// working app; this app is not working.
    static func decide(conflict: AlreadyRunningView.Conflict,
                       launch: LaunchSource.Decision) -> SecondInstanceAction {
        switch conflict {
        case .legacyAgentPilot:
            return .showConflict
        case .kvotarInstance:
            return launch == .showWindow ? .handOffAndQuit : .quitSilently
        }
    }
}
