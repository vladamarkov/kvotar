import AppKit
import KvotarCore
import Sparkle

/// Sparkle wiring (REV-83 / D-105, STEP_152) — the only file that imports Sparkle.
///
/// Policy (D-105b): a scheduled check on launch and every 24 h, the user is asked before an
/// update installs, nothing installs by itself. The keys live in `Info.plist`; the opt-out is
/// `automaticallyChecksForUpdates`, which Sparkle persists in UserDefaults — no `settings` row.
///
/// Presentation (D-105c): Sparkle's standard update window. This is an `LSUIElement` app, so
/// the app activates itself before the window is shown — a scheduled find would otherwise open
/// behind whatever the user is working in. The menu-bar glyph never changes for an update.
///
/// Logs go to `AppLifecycle` at info: the start, and the outcome of every check. Metadata is
/// version strings and error codes only.
@MainActor
final class UpdaterService: NSObject {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

    /// Starts the scheduler. Called once, after the §9.2 process guard — a rejected second
    /// instance never reaches this.
    func start() {
        controller.startUpdater()
        let updater = controller.updater
        Logger.info("Updater started", component: .appLifecycle,
                    metadata: ["feed": updater.feedURL?.absoluteString ?? "none",
                               "automatic_checks": String(updater.automaticallyChecksForUpdates),
                               "interval_s": String(Int(updater.updateCheckInterval))])
    }

    /// **Check for Updates…** — the manual path. Activates first so the result window is in front.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// False while a check is in flight; the menu item is built without an action then.
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    /// **Check for updates automatically** (D-105b). Sparkle owns and persists the value.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            Logger.info("Automatic update checks changed", component: .appLifecycle,
                        metadata: ["enabled": String(newValue)])
        }
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterService: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Logger.info("Update available", component: .appLifecycle,
                    metadata: ["version": item.displayVersionString, "build": item.versionString])
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Logger.info("No update found", component: .appLifecycle,
                    metadata: Self.errorMetadata(error))
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Logger.info("Update check aborted", component: .appLifecycle,
                    metadata: Self.errorMetadata(error))
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Logger.info("Installing update", component: .appLifecycle,
                    metadata: ["version": item.displayVersionString, "build": item.versionString])
    }

    nonisolated func updater(_ updater: SPUUpdater,
                             didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        var metadata = ["check": Self.checkName(updateCheck)]
        if let error { metadata.merge(Self.errorMetadata(error)) { _, new in new } }
        Logger.info("Update check finished", component: .appLifecycle, metadata: metadata)
    }

    private nonisolated static func checkName(_ check: SPUUpdateCheck) -> String {
        switch check {
        case .updates: return "manual"
        case .updatesInBackground: return "scheduled"
        case .updateInformation: return "information"
        @unknown default: return "unknown"
        }
    }

    private nonisolated static func errorMetadata(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        return ["error_domain": nsError.domain, "error_code": String(nsError.code)]
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdaterService: SPUStandardUserDriverDelegate {
    /// D-105c: a scheduled find is about to show Sparkle's window. Bring the app forward so the
    /// window is not born behind the user's other apps.
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard handleShowingUpdate else { return }
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}
