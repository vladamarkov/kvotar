import Foundation
import UserNotifications

/// The **Notify me ▸** denied-permission hint (UI Spec §1a, D-103 — STEP_150). Pure, so
/// `KvotarTests` can pin it without a notification center.
///
/// Tester report 2026-08-27: macOS had the app's permission denied while every group checkmark
/// was on, so "enabled" in the menu read as "will show" — and nothing did. The hint names the
/// one state where our switches cannot deliver: `.denied`. Everything else — not yet asked,
/// allowed, provisional — shows no row; the app never re-prompts (macOS asks once).
enum NotificationPermissionHint {
    /// Row title. "Off" describes the system switch, not ours — the group checkmarks below it
    /// are greyed while denied but keep their state and meaning.
    static let title = "Off in System Settings — Open…"
    /// Parent item title while denied — the state is readable before the submenu opens.
    static let deniedParentTitle = "Notify me — off in System Settings"
    static let parentTitle = "Notify me"

    /// Deep link into System Settings › Notifications (macOS 13+ pane identifier).
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    static func showsHint(for status: UNAuthorizationStatus) -> Bool {
        status == .denied
    }

    // MARK: What macOS will actually do with a warning (D-127 — STEP_225)

    /// Three readings of the user's System Settings, from the permission **and** the alert style.
    /// `off`: nothing reaches the screen — denied, or allowed with the style set to None (the
    /// menu used to read as working in that case). `banners`: warnings show, then leave after a
    /// few seconds. `fine`: alerts, not yet asked, or anything we cannot read.
    enum Reading: Equatable { case off, banners, fine }

    static func reading(status: UNAuthorizationStatus, alertStyle: UNAlertStyle) -> Reading {
        if status == .denied { return .off }
        guard status == .authorized else { return .fine }
        switch alertStyle {
        case .none: return .off
        case .banner: return .banners
        default: return .fine
        }
    }

    /// The Banners row above the four switches. The parent title stays `Notify me`: a nudge,
    /// not an alarm. Code cannot change the style; only the user can, so the row opens the pane.
    static let bannersTitle = "Warnings hide after a few seconds — Keep them on screen…"

    /// One word per setting for the log line and the diagnostics bundle.
    static func describe(_ style: UNAlertStyle) -> String {
        switch style {
        case .none: return "none"
        case .banner: return "banners"
        case .alert: return "alerts"
        @unknown default: return "unknown"
        }
    }

    static func describe(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .enabled: return "on"
        case .disabled: return "off"
        case .notSupported: return "not supported"
        @unknown default: return "unknown"
        }
    }
}
