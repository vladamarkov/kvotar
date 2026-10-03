import Foundation
import KvotarCore

/// The first-run window's launch gate (UI Spec Part 3 §3a, REV-79 / D-100 — STEP_143). Pure, so
/// `KvotarTests` can pin it without a store or a window.
///
/// Evaluated once per process, the first time any tool is known to be detected (the coordinator's
/// `onFirstToolDetected` — the first poll outcome that is not "no credential and no local
/// activity"). There is no positive detection signal at launch: `AppViewModel.detectedTools`
/// starts as both tools and only narrows on a failed first poll, so a synchronous read after
/// `coordinator.start()` would open the window on a machine with neither tool.
enum OnboardingGate {
    enum Decision: Equatable {
        /// `onboarding_completed` absent — open the window; its screen 4 owns the notification
        /// permission request.
        case openWindow
        /// Already onboarded (or skipped) — request notification authorization now. macOS never
        /// re-prompts once the user has decided, so for the ordinary relaunch this is a no-op; for
        /// a user who skipped at screen 1 it is the OS prompt they never reached.
        case requestAuthorization
    }

    static func decide(onboardingCompleted: Bool) -> Decision {
        onboardingCompleted ? .requestAuthorization : .openWindow
    }

    /// Whether Skip / Open Kvotar should write `onboarding_completed` (STEP_145). The window can
    /// be opened by hand from **Welcome to Kvotar…** on a machine with neither tool; dismissing
    /// it there must not spend the one automatic showing — the key is written only when at
    /// least one tool is detected, so the window still opens on the first later launch that
    /// finds one.
    static func shouldPersistCompletion(detectedTools: [Tool]) -> Bool {
        !detectedTools.isEmpty
    }
}
