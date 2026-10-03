import Foundation

/// The seam a second copy of Kvotar uses to ask the running one to show itself
/// (REV-99 §2.5 — STEP_205).
///
/// On a §9.2 Kvotar-vs-Kvotar lock collision the second process posts this, logs the hand-off, and
/// terminates without any UI. The running instance observes it and opens its quota window — so the
/// user, who did nothing but open Kvotar, sees Kvotar, and never learns there were two.
///
/// Darwin notifications are the existing cross-process seam (`DebugMode`, `DiagnosticsCapture`);
/// nothing new is invented here. **This one differs from both in kind:** they are level-triggered
/// nudges to re-read a settings row, and a coalesced or dropped duplicate is harmless because
/// SQLite is the source of truth. This one is an *action* with no row behind it, which is why the
/// name must not collide with theirs and why the ordering in `AppDelegate` — observer registered
/// **before** the lock is acquired — is the mechanism rather than a precaution.
public enum QuotaHandoff {
    /// Payload-less: it carries a request, not data.
    public static let darwinNotificationName = "com.vladimirmarkovic.kvotar.show-quota"
}
