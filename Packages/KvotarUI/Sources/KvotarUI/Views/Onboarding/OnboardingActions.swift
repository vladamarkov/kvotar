import Foundation
import KvotarCore

/// The `settings` key the first-run window writes (Baseline §17.1, REV-79 / D-100). `"1"` once the
/// user has completed or skipped the window; absent ⇒ it opens on the first launch that finds a
/// tool. Written by the window only — never by a migration.
public enum OnboardingSettings {
    public static let completedKey = "onboarding_completed"
    public static let completedValue = "1"
}

/// Everything the first-run window needs from the app that the view layer must not own
/// (composition-root rule): persistence, the OS permission request, the login-item registration
/// and the popover. Injected by `AppDelegate` through `OnboardingWindowController`; every closure
/// defaults to a no-op so previews and tests can build the view bare.
public struct OnboardingActions {
    /// Skip or Open Kvotar — closes the window; writes `onboarding_completed` only when at least
    /// one tool is detected (STEP_145), so an empty-machine dismissal keeps the automatic showing.
    public var complete: () -> Void
    /// Screen 4 **Allow & continue** — the `UNUserNotificationCenter` authorization request.
    public var requestNotifications: () -> Void
    /// Screen 5 checkbox initial state (`SMAppService.mainApp.status == .enabled`).
    public var isLaunchAtLoginEnabled: () -> Bool
    /// Screen 5 **Open Kvotar** applies the checkbox: register or unregister the login item.
    public var setLaunchAtLogin: (Bool) -> Void
    /// Screen 5 **Open Kvotar** — after the window closes.
    public var openPopover: () -> Void
    /// Screen 4 switch initial state (STEP_144) — the group's `settings` row, absent ⇒ default.
    public var isNotificationGroupEnabled: (NotificationGroup) -> Bool
    /// Screen 4 switch flipped (STEP_144) — persists `"true"` / `"false"` for the group.
    public var setNotificationGroup: (NotificationGroup, Bool) -> Void

    public init(complete: @escaping () -> Void = {},
                requestNotifications: @escaping () -> Void = {},
                isLaunchAtLoginEnabled: @escaping () -> Bool = { false },
                setLaunchAtLogin: @escaping (Bool) -> Void = { _ in },
                openPopover: @escaping () -> Void = {},
                isNotificationGroupEnabled: @escaping (NotificationGroup) -> Bool = { $0.defaultEnabled },
                setNotificationGroup: @escaping (NotificationGroup, Bool) -> Void = { _, _ in }) {
        self.complete = complete
        self.requestNotifications = requestNotifications
        self.isLaunchAtLoginEnabled = isLaunchAtLoginEnabled
        self.setLaunchAtLogin = setLaunchAtLogin
        self.openPopover = openPopover
        self.isNotificationGroupEnabled = isNotificationGroupEnabled
        self.setNotificationGroup = setNotificationGroup
    }
}
