import Foundation

/// Shared constants for diagnostic (§10.7 "debug") mode, referenced by both the CLI (which writes
/// the setting and posts the notification) and the app (which restores the setting at launch and
/// observes the notification). Kept in Core so the poster and the observer name one string (STEP_17).
public enum DebugMode {
    /// `settings` key persisting the on/off state. Stored as TEXT `"1"` / `"0"`; absent ⇒ off.
    public static let settingsKey = "debug_mode_enabled"

    /// Darwin notification name the CLI posts after flipping the setting. Payload-less and
    /// level-triggered: the app always re-reads the row on receipt, so coalesced or dropped
    /// duplicates are harmless. SQLite is the source of truth; this is only a live-wake nudge.
    public static let darwinNotificationName = "com.vladimirmarkovic.kvotar.debug-changed"

    /// Interprets a stored settings value as the on/off flag (`"1"` ⇒ on; anything else ⇒ off).
    public static func isEnabled(_ storedValue: String?) -> Bool {
        storedValue == "1"
    }
}
