import Foundation

/// Shared constants and the live on/off flag for diagnostics capture (§10.7a, REV-52 / STEP_72).
///
/// A **separate** setting from `DebugMode`. Extended capture is always off by default and becomes
/// active only with an explicit expiry no more than 24 hours in the future.
public enum DiagnosticsCapture {
    /// `settings` key persisting the on/off state. Stored as TEXT `"1"` / `"0"`; absent ⇒ off.
    public static let settingsKey = "diagnostics_capture_enabled"
    public static let expiresAtSettingsKey = "diagnostics_capture_expires_at"
    public static let maximumDuration: TimeInterval = 24 * 60 * 60

    /// Darwin notification name posted after the setting is flipped. Payload-less and
    /// level-triggered — the receiver always re-reads the row, so coalesced or dropped duplicates
    /// are harmless (the `DebugMode` contract, verbatim).
    public static let darwinNotificationName = "com.vladimirmarkovic.kvotar.capture-changed"

    /// Interprets a stored settings value as the on/off flag (`"1"` ⇒ on; anything else ⇒ off).
    public static func isEnabled(_ storedValue: String?) -> Bool {
        storedValue == "1"
    }

    public static func isAuthorized(
        storedValue: String?, expiresAtValue: String?, now: Date = Date()
    ) -> Bool {
        guard storedValue == "1",
              let raw = expiresAtValue,
              let interval = TimeInterval(raw) else { return false }
        return interval > now.timeIntervalSince1970
    }

    // MARK: - Live flag

    // Read on the poll path by the capture decorators, which are **not** async — they must never
    // await an actor to answer "is capture on?". Same lock-guarded static as `Logger`'s debug flag
    // (§10.1), for the same reason.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _isEnabled = false
    private nonisolated(unsafe) static var _expiresAt: Date?

    public static var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isEnabled && (_expiresAt.map { $0 > Date() } ?? false)
    }

    public static var expiresAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _isEnabled ? _expiresAt : nil
    }

    public static func setEnabled(
        _ enabled: Bool, expiresAt: Date? = nil, now: Date = Date()
    ) {
        lock.lock()
        if enabled {
            let requested = expiresAt ?? now.addingTimeInterval(maximumDuration)
            let ceiling = now.addingTimeInterval(maximumDuration)
            _expiresAt = min(requested, ceiling)
            _isEnabled = (_expiresAt ?? now) > now
        } else {
            _isEnabled = false
            _expiresAt = nil
        }
        lock.unlock()
    }
}

/// The build channel this binary was produced for (REV-52 §5). Read from the host bundle's
/// `KvotarChannel` Info.plist key, which `project.yml` fills from the `KVOTAR_CHANNEL`
/// build setting (default `release`).
///
/// It may seed debug logging in an internal beta, but never diagnostics capture. No cadence,
/// threshold, engine, or display behavior may depend on the channel.
public enum BuildChannel: String, Sendable {
    case release
    case beta

    public static func current(bundle: Bundle = .main) -> BuildChannel {
        let raw = bundle.infoDictionary?[ProductIdentity.buildChannelInfoKey] as? String
        return BuildChannel(rawValue: raw?.lowercased() ?? "") ?? .release
    }

    /// What an **absent** settings row should be seeded to on first launch. Absent-only: a user's
    /// explicit choice is never overwritten on a later launch.
    /// Off in every channel. STEP_136 (2026-08-22) turned this on for the pre-alpha tester group;
    /// P1-31 reverted it on 2026-09-07 for the first public build — a stranger installing from a
    /// website is not a consenting tester. Capture opens only through the explicit 24-hour consent.
    public var seedsDiagnosticsOn: Bool { false }
    public var seedsDebugOn: Bool { self == .beta }
}
