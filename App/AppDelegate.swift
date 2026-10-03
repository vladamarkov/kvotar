import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import KvotarCore
import ClaudeAdapter
import CodexAdapter
import KvotarUI

/// Assembles the running app (Build Step 15): owns the single `AppViewModel`, builds the status
/// item + popover, and starts the poll coordinator. The app is `LSUIElement` (accessory —
/// no Dock icon); all UI lives in the menu bar.
///
/// This is the composition root (STEP_25): concrete adapters are constructed only here and
/// injected into `PollCoordinator`, and the §9.2 PID lock gates the whole launch — a second
/// instance shows only the "already running" popover and never polls or opens the store.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = AppViewModel()

    private var menuBarController: MenuBarController?
    /// The History window (STEP_109) — one instance, created on first open.
    private var historyWindow: HistoryWindowController?
    /// The quota window (REV-99 §2.1, STEP_204) — the popover's content in an `NSWindow`, so the
    /// app is findable when macOS hides the status item. One instance, created on first open.
    private var quotaWindow: QuotaWindowController?
    /// The open/close parity both quota surfaces share, and the one entry point that decides
    /// which of them a caller gets. **No caller names a surface** (REV-99 §2.3a).
    private var surfaceLifecycle: QuotaSurfaceLifecycle?
    private var surfacePresenter: QuotaSurfacePresenter?
    /// The first-run window (STEP_143) — one instance, created on first open.
    private var onboardingWindow: OnboardingWindowController?
    /// `settings.onboarding_completed` as read at launch; the gate (`OnboardingGate`) consults it
    /// when the first tool is known to be detected. Flipped true by Skip / Open Kvotar.
    private var onboardingCompleted = false
    /// The four notification-group switches (STEP_144), read at launch and kept current by
    /// `setNotificationGroup` — the menu is built synchronously, so it reads this cache, not the
    /// store. Absent ⇒ `NotificationGroup.defaultEnabled`.
    private var notificationGroups: [NotificationGroup: Bool] = [:]
    private var coordinator: PollCoordinator?
    private var presenter: UserNotificationPresenter?
    /// The OS notification permission as last read (D-103, STEP_150). The context menu is built
    /// synchronously, so it reads this cache; `refreshNotificationAuthorization()` keeps it
    /// current at launch, wake, after the one-time request and before every menu open.
    private var notificationAuthorization: UNAuthorizationStatus = .notDetermined
    /// Banners / Alerts / None and the sound switch, read beside the permission (D-127, STEP_225).
    /// `.alert` until the first read, so nothing hints before we know.
    private var notificationAlertStyle: UNAlertStyle = .alert
    private var notificationSound: UNNotificationSetting = .enabled
    private var pidLocks: [PIDLock] = []
    /// Sparkle (REV-83, STEP_152). Created only after both §9.2 locks are held — a rejected
    /// second instance never starts an updater.
    private var updaterService: UpdaterService?
    /// The second-instance conflict window (REV-99 §2.5 — STEP_205). Only the *legacy AgentPilot*
    /// collision reaches it: another Kvotar is handed off to and never shown anything.
    private var conflictWindow: NSWindow?
    /// A hand-off that arrived before the presenter existed (REV-99 §2.5 — STEP_205).
    private let handoffInbox = HandoffInbox()
    private var handoffObserverRegistered = false
    /// What this process's own launch event says (REV-99 §2.4). Resolved once at the top of
    /// launch, because the §9.2 guard and `applyLaunchSource` must not read it twice and disagree.
    private var launchDecision: LaunchSource.Decision = .stayQuiet
    private var wakeObserver: NSObjectProtocol?
    /// Retained so the §10.7 debug-mode Darwin observer can re-read the setting on notification.
    private var store: SQLiteStore?
    private var debugObserverRegistered = false
    /// §10.7a diagnostics capture (STEP_72) — twin of the debug observer.
    private var captureObserverRegistered = false
    private var diagnosticsExpiryTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    /// STEP_177: time-zone and clock-change observers (default center), removed at terminate.
    private var calendarObservers: [NSObjectProtocol] = []
    /// Version + channel stamp, resolved once and reused for `app_lifecycle_events`.
    private let appVersion = ForecastLogRecorder.currentAppVersion()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The launch event, read once (REV-99 §2.4 / §2.5 — STEP_205). The §9.2 guard below needs
        // it now, `applyLaunchSource` needs it at the end of this method, and two reads that could
        // disagree would make a login-launched second copy post a hand-off.
        resolveLaunchSource()
        // The hand-off observer goes up **before** the lock (REV-99 §2.5). Any process that can
        // see the lock therefore posted after we were already listening, so a request cannot fall
        // into the gap between taking the lock and wiring the UI. A copy that is about to lose the
        // lock tears its own observer down before it posts — otherwise it hands off to itself.
        registerHandoffObserver()

        // §9.2 process guard — before any polling, store, or UI wiring. A failed lock *path*
        // (Application Support unavailable) degrades to running unguarded rather than not at all.
        if let lockPath = try? PIDLock.defaultPath() {
            let kvotarLock = PIDLock(path: lockPath)
            if case .alreadyRunning = kvotarLock.acquire() {
                actOnSecondInstance(.kvotarInstance)
                return
            }
            pidLocks.append(kvotarLock)

            // Released AgentPilot builds only understand their legacy PID path. Holding the same
            // operational lock with Kvotar's live PID prevents either product from polling while
            // the other is active. The legacy database, settings, and logs remain untouched.
            if let legacyPath = PIDLock.legacyCompatibilityPath() {
                let legacyLock = PIDLock(path: legacyPath)
                if case .alreadyRunning = legacyLock.acquire() {
                    pidLocks.forEach { $0.release() }
                    pidLocks.removeAll()
                    actOnSecondInstance(.legacyAgentPilot)
                    return
                }
                pidLocks.append(legacyLock)
            }
        } else {
            Logger.error("PID lock path unavailable — continuing without single-instance guard",
                         component: .appLifecycle)
        }

        // Register the icon explicitly (STEP_152 follow-up). A locally rebuilt `LSUIElement` app
        // is not always known to LaunchServices, so `NSApp.applicationIconImage` falls back to
        // the generic tile — which is what Sparkle's sheets and update window draw. The About
        // panel already works around the same symptom for its own icon (D-86).
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            // Sparkle asks `NSImage(named: .applicationIcon)` first, so the name must resolve
            // to this image — `setName` fails only if AppKit already cached one under it.
            let named = icon.setName(NSImage.applicationIconName)
            NSApp.applicationIconImage = icon
            Logger.info("App icon registered", component: .appLifecycle,
                        metadata: ["named": String(named)])
        }

        // Auto-update (REV-83 / D-105, STEP_152) — after the process guard, so only the instance
        // that will keep running checks the feed. Daily scheduled check plus the menu item; the
        // preference lives with Sparkle (UserDefaults), not in `settings`.
        let updaterService = UpdaterService()
        self.updaterService = updaterService
        updaterService.start()

        let popover = NSPopover()
        popover.behavior = .transient
        // Hug the SwiftUI content: the hosting controller reports its fitting size as the preferred
        // content size, so the popover resizes per state instead of reserving a fixed 480px height
        // (which left short states — Codex null-window — with a large empty area).
        let hosting = NSHostingController(rootView: PopoverView().environmentObject(viewModel))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        // The two quota surfaces and the one presenter between them (REV-99 §2.2/§2.3a —
        // STEP_204). The lifecycle is shared so the window and the popover cannot disagree about
        // what an open or a close does; the presenter is the only thing that picks a surface.
        let lifecycle = QuotaSurfaceLifecycle(viewModel: viewModel)
        self.surfaceLifecycle = lifecycle

        let menuBarController = MenuBarController(viewModel: viewModel, popover: popover,
                                                  lifecycle: lifecycle)
        self.menuBarController = menuBarController

        let quotaWindow = QuotaWindowController(viewModel: viewModel, lifecycle: lifecycle)
        self.quotaWindow = quotaWindow
        // One menu, two doors: the window's `⋯` button builds the §1a menu through the same
        // builder the right-click uses, so the inventory cannot drift between them.
        quotaWindow.buildMenu = { [weak menuBarController] in
            menuBarController?.contextMenu() ?? NSMenu()
        }

        let surfacePresenter = QuotaSurfacePresenter(popover: menuBarController,
                                                     window: quotaWindow)
        self.surfacePresenter = surfacePresenter
        menuBarController.onToggleRequested = { [weak surfacePresenter] in
            surfacePresenter?.togglePopover()
        }
        menuBarController.onPresent = { [weak surfacePresenter] destination in
            surfacePresenter?.present(destination)
        }
        // Detection (REV-99 §2.6/§2.7 — STEP_206). Two wires, both from here: the presenter's
        // routing input, so every way in lands on a surface the user can see, and the notice,
        // which the controller must not own — it stays `UserNotifications`-free.
        surfacePresenter.isItemKnownHidden = { [weak menuBarController] in
            menuBarController?.isItemKnownHidden ?? false
        }
        // **Open in Window** (STEP_208 — D-122 amendment): the one §1a row that names a surface,
        // because naming one is its whole purpose. Everything else names a destination.
        menuBarController.onOpenQuotaWindow = { [weak surfacePresenter] in
            surfacePresenter?.presentWindow()
        }
        menuBarController.onHiddenItemChanged = { [weak self] _, notice in
            guard notice else { return }
            self?.postHiddenItemNotice()
        }
        // The presenter exists, so a hand-off can be answered — and a request that arrived while
        // the observer was up but the surfaces were not drains right here (REV-99 §2.5). A
        // hand-off *is* a reopen; it arrives through a different door.
        handoffInbox.attach { [weak surfacePresenter] in
            Logger.info("Hand-off received — showing the quota window", component: .appLifecycle)
            surfacePresenter?.presentWindow()
        }

        // First launch imports a consistent read-only backup of AgentPilot's store into Kvotar's
        // namespace. Existing non-empty Kvotar storage always wins, so future updates are no-ops.
        let migrationReady: Bool
        do {
            let migration = try LegacyDataMigrator().migrateIfNeeded()
            Logger.info("Legacy data migration checked", component: .appLifecycle,
                        metadata: ["outcome": migration.outcome.rawValue])
            migrationReady = true
        } catch {
            Logger.error("Legacy data migration failed; persistence disabled",
                         component: .appLifecycle, metadata: ["error": "\(error)"])
            migrationReady = false
        }

        // Open the shared database; the coordinator still runs (in-memory only) if it fails, so
        // the menu bar and popover work even without persistence.
        let store: SQLiteStore?
        do {
            store = migrationReady ? try SQLiteStore(path: try SQLiteStore.defaultPath()) : nil
        } catch {
            store = nil
            Logger.error("Store unavailable — running without persistence",
                         component: .appLifecycle, metadata: ["error": "\(error)"])
        }
        self.store = store

        // Real notification delivery (Baseline §16). "Open Kvotar" names no surface — the
        // presenter opens whichever one the user can actually see (REV-99 §2.3a).
        let presenter = UserNotificationPresenter()
        presenter.onOpen = { [weak surfacePresenter] in surfacePresenter?.present() }
        // The hidden-item notice's own action (REV-99 §2.7 — STEP_206): the window, explicitly.
        presenter.onOpenWindow = { [weak surfacePresenter] in surfacePresenter?.presentWindow() }
        presenter.onAuthorizationResolved = { [weak self] in
            Task { @MainActor in self?.refreshNotificationAuthorization() }
        }
        // The authorization request no longer fires here (REV-79 / D-100 — STEP_143): the
        // first-run window's screen 4 owns it, and an already-onboarded install requests it
        // once the first tool is known to be detected (see `onFirstToolDetected` below).
        self.presenter = presenter
        #if DEBUG
        // Diagnostics only (STEP_233): a scripted weekly through a throwaway engine with no
        // store, delivered by the real presenter. See `NotificationFixture`.
        if let fixture = NotificationFixture.fromEnvironment {
            Task { await fixture.play(presenter: presenter) }
        }
        #endif
        // §4.2 project-name opt-out (STEP_27): honor the settings key now; the toggle UI is
        // Step 30. Absent key ⇒ included by default.
        if let store {
            Task {
                let value = try? await store.readSetting(key: "notification_project_name_enabled")
                if value == "false" { presenter.includeProjectName = false }
            }
            // §17.1 `menu_bar_display_mode` (STEP_29): absent/unknown row reads as `.bothStacked`
            // — which is also how a retired mode lands here (D-98: `adaptive`, `compact_glyph`,
            // `hidden`). Migration `v21_retire_menu_bar_modes` rewrites the row itself.
            Task {
                let raw = try? await store.readSetting(key: MenuBarDisplayMode.settingsKey)
                if let mode = raw.flatMap(MenuBarDisplayMode.init(rawValue:)), mode != .bothStacked {
                    viewModel.setMenuBarDisplayMode(mode)
                }
            }
            // §17.1 `onboarding_completed` (REV-79 / D-100 — STEP_143): absent ⇒ the first-run
            // window opens on the first launch that finds a tool. Read before the first poll can
            // land — the coordinator starts last in this method.
            Task {
                let raw = (try? await store.readSetting(key: OnboardingSettings.completedKey)) ?? nil
                onboardingCompleted = raw == OnboardingSettings.completedValue
                for group in NotificationGroup.allCases {
                    let value = (try? await store.readSetting(key: group.settingsKey)) ?? nil
                    notificationGroups[group] = NotificationGroup.isEnabled(value, for: group)
                }
            }
            // §2.8 "Since you last looked" (REV-68/D-75 — STEP_112): the per-tool snapshot of
            // what each tab showed at its last display survives a relaunch through `settings`.
            // Seed the in-memory slot (fills only an empty one), and give the view model its
            // two seams — the fire-and-forget persist (same shape as the glance write below;
            // `writeSetting` skips no-op writes) and the `quota_series` boundary read.
            Task { [weak viewModel] in
                for tool in Tool.allCases {
                    let key = LastOpenSnapshot.settingsKey(tool)
                    if let json = (try? await store.readSetting(key: key)) ?? nil {
                        viewModel?.seedLastOpenSnapshot(tool: tool, json: json)
                    }
                }
            }
            viewModel.onPersistLastOpenSnapshot = { tool, json in
                Task {
                    try? await store.writeSetting(key: LastOpenSnapshot.settingsKey(tool), value: json)
                }
            }
            // The long-limit warning episode (REV-98 §2.3 — STEP_202). Without these two rows a
            // relaunch and a re-entry are the same event, and a warning that has been true for
            // four days replays its first-hour burst every time the app starts. Only the two long
            // limits are read: `.primary` is the five-hour window, which never keys an episode.
            // The write seam is wired **before** the read, so a seed that drops a recovered or
            // malformed row can actually clear it.
            viewModel.onPersistReminderEpisode = { tool, limit, value in
                Task {
                    try? await store.writeSetting(
                        key: ReminderEpisode.settingsKey(tool: tool, limit: limit), value: value)
                }
            }
            Task { [weak viewModel] in
                for tool in Tool.allCases {
                    for limit in [BlockEpisode.Limit.secondary, .monthly] {
                        let key = ReminderEpisode.settingsKey(tool: tool, limit: limit)
                        if let raw = (try? await store.readSetting(key: key)) ?? nil {
                            viewModel?.seedReminderEpisode(tool: tool, limit: limit,
                                                           storedValue: raw)
                        }
                    }
                }
            }
            viewModel.loadWindowOutcome = { tool, before in
                (try? await store.previousWindowOutcome(tool: tool, before: before)) ?? nil
            }
            // §2.8 trigger 6 (STEP_146): the window facts since the last look. Plan changes are
            // not read here — they are not window facts and the line does not carry them.
            viewModel.loadWindowFacts = { tool, since in
                let kinds: [HistoryReport.AccountChange.Kind] =
                    [.windowAdded, .windowRemoved, .windowWidthChanged, .earlyReset]
                let rows = (try? await store.discontinuityEvents(
                    tool: tool, since: since, until: Date(),
                    types: kinds.map(\.rawValue))) ?? []
                return rows.compactMap { row in
                    HistoryReport.AccountChange.Kind(rawValue: row.eventType).map {
                        HistoryReport.AccountChange(at: row.at, kind: $0, windowType: row.windowType,
                                                    oldValue: row.oldValue, newValue: row.newValue)
                    }
                }
            }
            // Debug logging may still use the internal beta default. Extended diagnostics never
            // does: it requires a visible, expiring authorization on every build.
            Task { [weak self, appVersion] in
                let channel = BuildChannel.current()
                if (try? await store.readSetting(key: DebugMode.settingsKey)) == nil {
                    try? await store.writeSetting(
                        key: DebugMode.settingsKey, value: channel.seedsDebugOn ? "1" : "0")
                }
                if (try? await store.readSetting(key: DiagnosticsCapture.settingsKey)) == nil {
                    try? await store.writeSetting(key: DiagnosticsCapture.settingsKey, value: "0")
                }
                let debugRaw = (try? await store.readSetting(key: DebugMode.settingsKey)) ?? nil
                Logger.setDebugModeEnabled(DebugMode.isEnabled(debugRaw))
                let captureRaw =
                    (try? await store.readSetting(key: DiagnosticsCapture.settingsKey)) ?? nil
                let expiryRaw =
                    (try? await store.readSetting(key: DiagnosticsCapture.expiresAtSettingsKey)) ?? nil
                let authorized = DiagnosticsCapture.isAuthorized(
                    storedValue: captureRaw, expiresAtValue: expiryRaw)
                let expiry = expiryRaw.flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                DiagnosticsCapture.setEnabled(authorized, expiresAt: expiry)
                if authorized, let expiry {
                    self?.scheduleDiagnosticsExpiry(at: expiry)
                } else {
                    try? await store.writeSetting(key: DiagnosticsCapture.settingsKey, value: "0")
                    try? await store.writeSetting(
                        key: DiagnosticsCapture.expiresAtSettingsKey, value: nil)
                    try? await store.deleteCapturedPayloads()
                }
                // The run's identity line (STEP_135). Emitted here rather than at the top of
                // launch because this is the first moment the debug/capture flags and the schema
                // are known — and rotation no longer marks a launch, so the banner is what tells a
                // reader which process wrote the lines around it.
                Logger.launchBanner(
                    appVersion: appVersion,
                    channel: channel.rawValue,
                    databasePath: try? SQLiteStore.defaultPath(),
                    schemaMigration: (try? await store.latestSchemaMigration()) ?? nil)
                // §17.1 app_lifecycle_events — written regardless of the capture setting: this is
                // app-lifecycle fact, and it is the frame every other series is read against.
                try? await store.writeLifecycleEvent(.launch, appVersion: appVersion)
            }
        }

        // Interim display-mode picker (right-click submenu; Step 30's settings window absorbs
        // it). Applies immediately, persists across launches. Every mode leaves a status item to
        // right-click, so no mode needs a confirmation (D-98 — Hidden, which did, is retired).
        menuBarController.onSelectMode = { [weak self] mode in
            guard let self else { return }
            self.viewModel.setMenuBarDisplayMode(mode)
            if let store {
                Task {
                    try? await store.writeSetting(key: MenuBarDisplayMode.settingsKey,
                                                  value: mode.rawValue)
                }
            }
            Logger.info("Menu bar display mode changed", component: .appLifecycle,
                        metadata: ["mode": mode.rawValue])
        }

        // Launch-at-login toggle (STEP_30, right-click menu). `SMAppService` owns the registration
        // state, so the checkmark reads `.status` directly — no settings key to keep in sync.
        menuBarController.isLaunchAtLoginEnabled = { SMAppService.mainApp.status == .enabled }
        menuBarController.onToggleLaunchAtLogin = { Self.toggleLaunchAtLogin() }

        // Check for Updates… + Check for updates automatically (D-105b/d, STEP_152). Same shape
        // as the login item: Sparkle owns the state, the menu reads it live.
        menuBarController.onCheckForUpdates = { [weak updaterService] in
            updaterService?.checkForUpdates()
        }
        menuBarController.canCheckForUpdates = { [weak updaterService] in
            updaterService?.canCheckForUpdates ?? true
        }
        menuBarController.isAutomaticUpdateChecksEnabled = { [weak updaterService] in
            updaterService?.automaticallyChecksForUpdates ?? false
        }
        menuBarController.onToggleAutomaticUpdateChecks = { [weak updaterService] in
            guard let updaterService else { return }
            updaterService.automaticallyChecksForUpdates.toggle()
        }

        // Notify me ▸ (STEP_144): the same four switches as the first-run window's screen 4.
        menuBarController.isNotificationGroupEnabled = { [weak self] in
            self?.isNotificationGroupEnabled($0) ?? $0.defaultEnabled
        }
        menuBarController.onToggleNotificationGroup = { [weak self] group in
            guard let self else { return }
            self.setNotificationGroup(group, enabled: !self.isNotificationGroupEnabled(group))
        }
        // Denied by macOS (D-103, STEP_150): the hint row above the switches, and the pane it
        // points at. The read lands asynchronously, so a change in System Settings shows on the
        // open after the one that triggered the refresh; launch and wake cover the common case.
        menuBarController.isNotificationPermissionDenied = { [weak self] in
            guard let self else { return false }
            return NotificationPermissionHint.reading(status: self.notificationAuthorization,
                                                      alertStyle: self.notificationAlertStyle) == .off
        }
        menuBarController.areNotificationsBanners = { [weak self] in
            guard let self else { return false }
            return NotificationPermissionHint.reading(status: self.notificationAuthorization,
                                                      alertStyle: self.notificationAlertStyle) == .banners
        }
        menuBarController.onContextMenuWillOpen = { [weak self] in
            self?.refreshNotificationAuthorization()
        }
        menuBarController.onOpenNotificationSettings = {
            NSWorkspace.shared.open(NotificationPermissionHint.settingsURL)
        }
        refreshNotificationAuthorization()

        // First-run window (UI Spec Part 3 §3a, REV-79 / D-100 — STEP_143). The window is
        // view-only; everything it must not own arrives as closures: the key write, the OS
        // permission request, the login-item registration (same `SMAppService` as the
        // right-click checkmark, so the two never disagree) and the popover.
        let onboardingWindow = OnboardingWindowController(
            viewModel: viewModel,
            actions: OnboardingActions(
                complete: { [weak self, weak store, weak viewModel] in
                    // STEP_146: a dismissal with no tool detected closes the window but leaves
                    // the automatic showing owed — the key is written only once a tool is found.
                    let detected = viewModel?.detectedTools ?? []
                    guard OnboardingGate.shouldPersistCompletion(detectedTools: detected) else {
                        Logger.info("First-run window dismissed without a tool — key not written",
                                    component: .appLifecycle)
                        return
                    }
                    self?.onboardingCompleted = true
                    Logger.info("onboarding_completed written", component: .appLifecycle,
                                metadata: ["tools": detected.map(\.rawValue).joined(separator: ",")])
                    guard let store else { return }
                    Task {
                        try? await store.writeSetting(key: OnboardingSettings.completedKey,
                                                      value: OnboardingSettings.completedValue)
                    }
                },
                requestNotifications: { [weak presenter] in presenter?.requestAuthorization() },
                isLaunchAtLoginEnabled: { SMAppService.mainApp.status == .enabled },
                setLaunchAtLogin: { Self.setLaunchAtLogin($0) },
                openPopover: { [weak surfacePresenter] in surfacePresenter?.present() },
                isNotificationGroupEnabled: { [weak self] in
                    self?.isNotificationGroupEnabled($0) ?? $0.defaultEnabled
                },
                setNotificationGroup: { [weak self] in self?.setNotificationGroup($0, enabled: $1) }))
        self.onboardingWindow = onboardingWindow
        menuBarController.onOpenWelcome = { [weak onboardingWindow] in onboardingWindow?.show() }

        // Save Diagnostics… (D-47, STEP_73): assemble the bundle off the main path, then reveal it
        // in Finder with the file selected — the next action is an obvious drag into a chat window.
        // The app never transmits; export is a human act.
        menuBarController.onSaveDiagnostics = { [weak self] in
            self?.saveDiagnosticsBundle()
        }
        menuBarController.onConfigureExtendedDiagnostics = { [weak self] in
            self?.configureExtendedDiagnostics()
        }

        // §17.1 popover_opens glance log (STEP_52): one row per open with what was shown, read
        // from the render inputs after the default tab settles. Fire-and-forget `try?` — a
        // failed write (WARN in the store) must never block the popover.
        // STEP_177: every open also refreshes the daily local report — outside the store
        // guard, so a store-less run still reads (the read itself is a no-op without one).
        // STEP_204: on the shared lifecycle, so an open in the window records the same row as an
        // open in the popover — and a D-68 setup card still records none.
        lifecycle.onOpen = { [weak self, weak viewModel] in
            self?.coordinator?.popoverOpened()
            guard let store = self?.store, let glance = viewModel?.glance() else { return }
            Task {
                try? await store.writePopoverOpen(
                    openedAt: Date(), tab: glance.tab.rawValue,
                    claudeState: glance.claudeState, claudeUsedPct: glance.claudeUsedPct,
                    codexState: glance.codexState, codexUsedPct: glance.codexUsedPct)
            }
        }

        // Composition root: the only place concrete adapter types are constructed. The RPC
        // client is passed alongside the codex adapter so the coordinator can reap the
        // app-server child on quit (STEP_24).
        // §10.7a diagnostics capture (STEP_72). The sink gates on the live flag and writes
        // fire-and-forget, so the capture decorators below never slow a poll. Nil when the store
        // is unavailable — capture is evidence, never a reason to degrade the running app.
        let diagnostics: DiagnosticsSink? = store.map { LiveDiagnosticsSink(store: $0) }
        // The RPC path has no HTTP seam, so capture is an injected observer; `method` is already
        // the stable endpoint name (`account/read`, `account/rateLimits/read`).
        // Codex Desktop's bundle identifier is the one handle that survives the app being renamed
        // or moved; the binary path underneath it has changed three times (Baseline §8.6).
        // Resolving an identifier needs LaunchServices, which CodexAdapter and KvotarCore must not
        // import, so the composition root resolves it and the packages stay pure.
        let codexLocator = DefaultCodexBinaryLocator(appBundleURL: {
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: CodexBinaryCandidates.bundleIdentifier)
        })
        let codexRPC = CodexRPCClient(locator: codexLocator,
                                      onResponse: diagnostics.map { sink in
            { method, data in
                sink.capture(tool: .codex, endpoint: method, body: data, httpStatus: nil)
            }
        })
        // Capture attaches as **decorators** — one wrapper covers Claude usage, profile and
        // prepaid (all three go through `fetcher.get`), and the adapters themselves are untouched,
        // which is why their suites stay unmodified (STEP_72 regression assertion).
        let claudeFetcher: HTTPFetcher = diagnostics.map {
            CapturingHTTPFetcher(wrapping: URLSessionFetcher(), sink: $0)
        } ?? URLSessionFetcher()
        let codexWham: CodexHTTPFetcher = diagnostics.map {
            CapturingCodexHTTPFetcher(wrapping: CodexURLSessionFetcher(), sink: $0)
        } ?? CodexURLSessionFetcher()
        let claudeAdapter = ClaudeAccountAdapter(
            tokenProvider: KeychainTokenProvider(),
            fetcher: claudeFetcher)
        let coordinator = PollCoordinator(
            viewModel: viewModel, store: store, presenter: presenter,
            claude: claudeAdapter,
            codex: CodexAccountAdapter(rpc: codexRPC, wham: CodexWhamHTTPClient(fetcher: codexWham)),
            codexRPC: codexRPC,
            diagnostics: diagnostics)
        self.coordinator = coordinator
        // First-run "Re-check" button → force an immediate re-poll of that tool (STEP_30).
        viewModel.onRecheck = { [weak coordinator] tool in coordinator?.recheck(tool: tool) }
        // The onboarding gate (STEP_143): once per process, when a tool is first known to be
        // detected. Neither detected ⇒ never fires, the popover welcome stays the surface, and
        // the next launch tries again — the spec's "first later launch that finds a tool".
        coordinator.onFirstToolDetected = { [weak self, weak presenter, weak onboardingWindow] in
            guard let self else { return }
            switch OnboardingGate.decide(onboardingCompleted: self.onboardingCompleted) {
            case .openWindow:
                Logger.info("First tool detected — opening the first-run window",
                            component: .appLifecycle)
                onboardingWindow?.show()
            case .requestAuthorization:
                Logger.info("First tool detected — already onboarded, requesting notification authorization",
                            component: .appLifecycle)
                presenter?.requestAuthorization()
            }
        }

        // History window (STEP_109): the menu item and the popover footer link share one
        // controller; the report is read through the coordinator's attribution engine so it
        // prices with the popover's table. Opening from the popover closes the popover first.
        let historyWindow = HistoryWindowController(load: { [weak coordinator] in
            await coordinator?.historyReport()
        })
        self.historyWindow = historyWindow
        // The status-item menu item keeps the ordinary opening — Summary · All.
        menuBarController.onOpenHistory = { [weak historyWindow] in historyWindow?.show() }
        // The popover's footer passes nil (ordinary opening); `N more projects ›` passes a
        // destination naming its provider and the local day it was describing (STEP_178).
        // STEP_204: the footer closes the active **quota surface**, popover or window — a
        // transient popover, or a window, left behind a new key window is a stale sheet the user
        // must dismiss separately. History keeps its own controller and is not routed by the
        // presenter (REV-99 §2.3a).
        viewModel.onOpenHistory = { [weak surfacePresenter, weak historyWindow] destination in
            surfacePresenter?.closeActiveSurface()
            historyWindow?.show(destination: destination)
        }
        // Wake-from-sleep → force an immediate re-poll. A suspended `Task.sleep` otherwise leaves
        // the popover on the pre-sleep snapshot (stale % / expired countdown after a mid-sleep
        // window reset) until the next scheduled poll. Delivered on the main queue; the coordinator
        // is @MainActor, so hop onto its actor via a Task.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator?.wakeRefresh()
                self?.recordLifecycle(.wake)
                self?.refreshNotificationAuthorization()
            }
        }
        // §17.1 app_lifecycle_events (STEP_72): sleep is the only one of the four instants the app
        // did not already observe. Without the pair, an eight-hour gap in any series is unreadable
        // — laptop shut, or engine stalled?
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recordLifecycle(.sleep) }
        }
        // STEP_177: local midnight moves with the time zone and the clock, so the daily local
        // report's population moves with them — re-arm the boundary timer and re-read.
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            calendarObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.coordinator?.calendarChanged() }
            })
        }
        // §10.7 debug mode (STEP_17): the CLI's `debug --enable/--disable` writes the settings row
        // and posts this payload-less Darwin notification; re-read the row and flip the live flag so
        // diagnostic logging starts/stops without a relaunch. SQLite stays the source of truth.
        registerDebugModeObserver()
        registerCaptureObserver()
        // The bundled limits seed is no longer loaded here: its only consumer, the §11.1
        // Inferred-runway ceiling, was retired by REV-80 / D-101 (STEP_147). `LimitsDatabaseAdapter`
        // stays in Core for the §9.4 resolver and its tests.
        Task { coordinator.start() }
        Logger.info("App launched", component: .appLifecycle)

        applyLaunchSource()
    }

    // MARK: Launch source and reopen (REV-99 §2.4 / §7 — STEP_204)

    /// Read the launch Apple event **once**, at the top of launch (STEP_205). Two callers need the
    /// answer at opposite ends of `applicationDidFinishLaunching` — the §9.2 guard, which must not
    /// let a login-launched second copy post a hand-off, and `applyLaunchSource` — and two reads
    /// that could disagree is a defect waiting for a rare launch shape to find it.
    private func resolveLaunchSource() {
        let event = Self.currentLaunchEvent()
        launchDecision = LaunchSource.decide(event: event)
        Logger.info("Launch source resolved", component: .appLifecycle,
                    metadata: ["event": event.map { "\($0.eventClass)/\($0.eventID)" } ?? "none",
                               "prdt": event?.propertyData ?? "none",
                               "decision": "\(launchDecision)"])
    }

    /// A deliberate cold launch — Finder, Spotlight, `open` — shows the quota window; launch at
    /// login stays silent. The rule itself is `LaunchSource`, pure and pinned by `KvotarTests`;
    /// `resolveLaunchSource` above is the only thing that reads the Apple event.
    private func applyLaunchSource() {
        guard launchDecision == .showWindow else { return }
        // One runloop turn later, deliberately. Ordering a window front from inside
        // `applicationDidFinishLaunching` creates it and then loses it: AppKit finishes the launch
        // sequence afterwards and the accessory app's window never comes on screen (measured live
        // 2026-09-15 — the glance row was written, the window was not visible). The reopen path
        // runs well after launch and never had the problem.
        DispatchQueue.main.async { [weak self] in
            self?.surfacePresenter?.presentWindow()
        }
    }

    private static func currentLaunchEvent() -> LaunchSource.Event? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return nil }
        // `loginwindow` sends `'prdt':'lgit'` as a type code; read the string form too rather than
        // assume, since the whole login-vs-deliberate decision hangs off this one parameter.
        let property = event.paramDescriptor(forKeyword: keyAEPropData).map { descriptor -> String in
            let code = LaunchSource.code(descriptor.typeCodeValue)
            return code.isEmpty ? (descriptor.stringValue ?? "") : code
        }
        return LaunchSource.Event(eventClass: LaunchSource.code(event.eventClass),
                                  eventID: LaunchSource.code(event.eventID),
                                  propertyData: property)
    }

    /// Opening Kvotar again while it is already running — the one thing a person does when the
    /// status item is not where they expected it. Shows the window and returns `false` so AppKit
    /// does nothing further.
    ///
    /// **Regardless of `hasVisibleWindows`**: an open History window makes that flag `true`, and
    /// an open History window is not the user having found their quota.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        Logger.info("Reopen — showing the quota window", component: .appLifecycle,
                    metadata: ["hasVisibleWindows": String(hasVisibleWindows)])
        surfacePresenter?.presentWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The row must land before the process goes away, so this blocks — but the write must run
        // **off** the main actor. `Task { }` here inherits `AppDelegate`'s `@MainActor` isolation
        // and would need the very thread `semaphore.wait` is blocking: a deadlock that resolves
        // itself by timing out, silently losing every `quit` row (observed live, STEP_72).
        if let store {
            let version = appVersion
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                try? await store.writeLifecycleEvent(.quit, appVersion: version)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        calendarObservers.forEach { NotificationCenter.default.removeObserver($0) }
        calendarObservers.removeAll()
        if captureObserverRegistered {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(DiagnosticsCapture.darwinNotificationName as CFString), nil)
        }
        if debugObserverRegistered {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(DebugMode.darwinNotificationName as CFString), nil)
        }
        removeHandoffObserver()
        coordinator?.stop()
        diagnosticsExpiryTask?.cancel()
        diagnosticsExpiryTask = nil
        pidLocks.forEach { $0.release() }
        pidLocks.removeAll()
    }

    /// Subscribe to the CLI's debug-mode Darwin notification. Darwin callbacks are C function
    /// pointers that can't capture `self`, so `self` is threaded through as the opaque observer
    /// pointer and recovered in the callback (STEP_17).
    private func registerDebugModeObserver() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in delegate.reloadDebugMode() }
            },
            DebugMode.darwinNotificationName as CFString,
            nil,
            .deliverImmediately)
        debugObserverRegistered = true
    }

    /// Re-read the persisted debug flag and apply it. `Logger.setDebugModeEnabled` is lock-guarded,
    /// so effect (a) — DEBUG-level gating, read live in `Logger.log` — takes hold immediately.
    private func reloadDebugMode() {
        guard let store else { return }
        Task {
            let raw = (try? await store.readSetting(key: DebugMode.settingsKey)) ?? nil
            let enabled = DebugMode.isEnabled(raw)
            Logger.setDebugModeEnabled(enabled)
            Logger.info("Debug mode reloaded from settings", component: .appLifecycle,
                        metadata: ["enabled": "\(enabled)"])
        }
    }

    /// Subscribe to the CLI's capture Darwin notification (§10.7a, STEP_72). Same opaque-pointer
    /// mechanism as the debug observer — Darwin callbacks are C function pointers that cannot
    /// capture `self`.
    private func registerCaptureObserver() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in delegate.reloadCaptureSetting() }
            },
            DiagnosticsCapture.darwinNotificationName as CFString,
            nil,
            .deliverImmediately)
        captureObserverRegistered = true
    }

    /// Re-read the persisted capture flag and apply it live. Turning capture **off** also drops
    /// the stored payloads: off should mean gone, not merely "stop appending" (§10.7a).
    private func reloadCaptureSetting() {
        guard let store else { return }
        Task { [weak self] in
            let raw = (try? await store.readSetting(key: DiagnosticsCapture.settingsKey)) ?? nil
            let expiryRaw =
                (try? await store.readSetting(key: DiagnosticsCapture.expiresAtSettingsKey)) ?? nil
            let enabled = DiagnosticsCapture.isAuthorized(
                storedValue: raw, expiresAtValue: expiryRaw)
            let expiry = expiryRaw.flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            DiagnosticsCapture.setEnabled(enabled, expiresAt: expiry)
            if enabled, let expiry {
                self?.scheduleDiagnosticsExpiry(at: expiry)
            } else {
                try? await store.writeSetting(key: DiagnosticsCapture.settingsKey, value: "0")
                try? await store.writeSetting(
                    key: DiagnosticsCapture.expiresAtSettingsKey, value: nil)
                try? await store.deleteCapturedPayloads()
            }
            Logger.info("Diagnostics capture reloaded from settings", component: .appLifecycle,
                        metadata: ["enabled": "\(enabled)"])
        }
    }

    private func configureExtendedDiagnostics() {
        if DiagnosticsCapture.isEnabled {
            disableExtendedDiagnostics()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Enable Extended Diagnostics for 24 Hours?"
        alert.informativeText = "Kvotar will temporarily retain safety-filtered quota and account "
            + "response details. It never retains prompts, code, transcripts, tool output, "
            + "credentials, or local session files. The data is deleted automatically when the "
            + "window expires, or immediately if you turn it off."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Enable for 24 Hours")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let store else { return }

        let expiry = Date().addingTimeInterval(DiagnosticsCapture.maximumDuration)
        Task { [weak self] in
            try? await store.writeSetting(key: DiagnosticsCapture.settingsKey, value: "1")
            try? await store.writeSetting(
                key: DiagnosticsCapture.expiresAtSettingsKey,
                value: String(Int(expiry.timeIntervalSince1970)))
            DiagnosticsCapture.setEnabled(true, expiresAt: expiry)
            self?.scheduleDiagnosticsExpiry(at: expiry)
            Logger.info("Extended diagnostics authorized", component: .appLifecycle,
                        metadata: ["expiresAt": "\(Int(expiry.timeIntervalSince1970))"])
        }
    }

    private func scheduleDiagnosticsExpiry(at expiry: Date) {
        diagnosticsExpiryTask?.cancel()
        let nanoseconds = UInt64(max(0, expiry.timeIntervalSinceNow) * 1_000_000_000)
        diagnosticsExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.disableExtendedDiagnostics()
        }
    }

    private func disableExtendedDiagnostics() {
        diagnosticsExpiryTask?.cancel()
        diagnosticsExpiryTask = nil
        DiagnosticsCapture.setEnabled(false)
        guard let store else { return }
        Task {
            try? await store.writeSetting(key: DiagnosticsCapture.settingsKey, value: "0")
            try? await store.writeSetting(
                key: DiagnosticsCapture.expiresAtSettingsKey, value: nil)
            try? await store.deleteCapturedPayloads()
            Logger.info("Extended diagnostics disabled and captured payloads deleted",
                        component: .appLifecycle)
        }
    }

    /// Builds a diagnostics bundle and reveals it in Finder (REV-52 §6, STEP_73). Success needs no
    /// alert — the Finder window with the file selected *is* the confirmation; only a failure gets
    /// one, naming what went wrong so the tester can say so.
    private func saveDiagnosticsBundle() {
        guard let store else {
            Self.presentDiagnosticsFailure("The local database is unavailable, so there is nothing "
                                           + "to package.")
            return
        }
        let version = appVersion
        // What the popover was explaining, read on the main actor *before* the build task
        // (STEP_133): the view model is main-actor bound, and a snapshot taken after an await
        // would be a different render from the one the tester was looking at when they clicked.
        let explanation = viewModel.explanationSnapshot()
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            // D-127 (STEP_225): the permission alone could not explain a missed warning.
            let authorization = Self.describe(settings.authorizationStatus)
                + " · " + NotificationPermissionHint.describe(settings.alertStyle)
                + " · sound " + NotificationPermissionHint.describe(settings.soundSetting)
            let pricing = await coordinator?.pricingTableStamp() ?? nil
            let facts = DiagnosticsBundle.HostFacts(
                appVersion: version,
                channel: BuildChannel.current(),
                notificationAuthorization: authorization,
                openAtLogin: SMAppService.mainApp.status == .enabled,
                pricingVersion: pricing?.version,
                pricingUpdated: pricing?.updated)
            do {
                let url = try await DiagnosticsBundle.build(store: store, facts: facts,
                                                            explanation: explanation)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                Logger.error("Diagnostics bundle failed", component: .appLifecycle,
                             metadata: ["error": "\(error)"])
                Self.presentDiagnosticsFailure("\(error.localizedDescription)")
            }
        }
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "not determined"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private static func presentDiagnosticsFailure(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't save diagnostics"
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Fire-and-forget `app_lifecycle_events` row (§17.1).
    /// Re-reads the OS notification permission into the cache (D-103, STEP_150). Read-only —
    /// never requests. Logs only on change, so the launch line is the one that normally appears.
    private func refreshNotificationAuthorization() {
        Task { @MainActor [weak self] in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let status = settings.authorizationStatus
            guard let self, status != self.notificationAuthorization
                    || settings.alertStyle != self.notificationAlertStyle
                    || settings.soundSetting != self.notificationSound else { return }
            self.notificationAuthorization = status
            self.notificationAlertStyle = settings.alertStyle
            self.notificationSound = settings.soundSetting
            Logger.info("Notification authorization status", component: .notificationEngine,
                        metadata: ["status": Self.describe(status),
                                   "style": NotificationPermissionHint.describe(settings.alertStyle),
                                   "sound": NotificationPermissionHint.describe(settings.soundSetting)])
        }
    }

    private func recordLifecycle(_ event: AppLifecycleEvent) {
        guard let store else { return }
        let version = appVersion
        Task { try? await store.writeLifecycleEvent(event, appVersion: version) }
    }

    // MARK: The hidden item (REV-99 §2.6/§2.7 — STEP_206)

    /// One notice per launch (`hiddenItemNoticePerLaunch`), budgeted by the tracker and held in
    /// memory — it is a recovery hint, not a monitor. The *routing* input follows the live state
    /// and is not capped: a user who frees a menu-bar slot gets their popover back.
    ///
    /// **Posted directly, never through the engine** (REV-99 §3.7): no §16 arbitration, no
    /// priority, no cap, no cooldown and no `notification_events` row. The nine events are claims
    /// about quota; this one is a claim about the app.
    private func postHiddenItemNotice() {
        Logger.info("Status item may be hidden — posting the recovery notice",
                    component: .appLifecycle)
        presenter?.presentHiddenItemNotice()
    }

    // MARK: The second copy (REV-99 §2.5 — STEP_205)

    /// §9.2, rewritten: a copy that lost the lock no longer draws a grey-dot status item of its
    /// own. On the full menu bar this revision exists for, that added a **second invisible icon**
    /// and displayed nothing — the user performed the one recovery action available to them and
    /// got silence.
    ///
    /// The rule is `SecondInstanceAction`, pure and pinned by `KvotarTests`; this only carries it
    /// out. The `CRITICAL` collision record with the observed PID is `PIDLock`'s and is unchanged
    /// in every case.
    private func actOnSecondInstance(_ conflict: AlreadyRunningView.Conflict) {
        switch SecondInstanceAction.decide(conflict: conflict, launch: launchDecision) {
        case .handOffAndQuit:
            Logger.info("Already running — handing off to the running instance and quitting",
                        component: .appLifecycle)
            postHandoff()
            quitSecondInstance()
        case .quitSilently:
            // Launch at login is silent by contract (REV-99 §2.4), and that contract does not bend
            // because two copies happen to be registered.
            Logger.info("Already running — launched at login, quitting without a hand-off",
                        component: .appLifecycle)
            quitSecondInstance()
        case .showConflict:
            presentConflictWindow(conflict)
        }
    }

    /// Post the hand-off, having first stopped listening for it. We registered the observer before
    /// the lock like everybody else; posting while still subscribed hands off to ourselves.
    private func postHandoff() {
        removeHandoffObserver()
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(QuotaHandoff.darwinNotificationName as CFString),
            nil, nil, true)
    }

    /// One runloop turn later, so the post is on its way before the process goes. `applicationWill
    /// Terminate` is harmless here: this copy holds no lock, no store and no coordinator.
    private func quitSecondInstance() {
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// The legacy AgentPilot collision, in a window rather than a status-item popover — for the
    /// reason everything else in REV-99 moved: a surface hanging off the status item is
    /// unreachable exactly when the user most needs it. There is no running Kvotar to hand off to.
    ///
    /// **No close button.** The single **Quit this instance** button is the action; a closable
    /// window would leave a running process that does nothing and shows nothing, which is the
    /// state this step exists to remove. This is also the one place a login launch is not silent:
    /// the state is unusable rather than merely unread, and this is where the user learns which
    /// app to quit.
    private func presentConflictWindow(_ conflict: AlreadyRunningView.Conflict) {
        let hosting = NSHostingController(
            rootView: AlreadyRunningView(conflict: conflict, onQuit: { NSApp.terminate(nil) }))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Kvotar"
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.center()
        conflictWindow = window
        // One runloop turn later, the same deferral `applyLaunchSource` needs and for the same
        // reason: AppKit finishes the launch sequence after this method returns, and an accessory
        // app's window ordered front from inside it is created and then lost. Measured live
        // 2026-09-15 — the process stayed up, the window never appeared.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Subscribe to the hand-off a second copy posts (REV-99 §2.5). Same opaque-pointer mechanism
    /// as the debug and capture observers — Darwin callbacks are C function pointers that cannot
    /// capture `self`.
    ///
    /// Registered **before** the §9.2 lock is acquired, which is the mechanism rather than a
    /// precaution: a process that can see the lock posted after we were already listening.
    private func registerHandoffObserver() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in delegate.handoffInbox.receive() }
            },
            QuotaHandoff.darwinNotificationName as CFString,
            nil,
            .deliverImmediately)
        handoffObserverRegistered = true
    }

    private func removeHandoffObserver() {
        guard handoffObserverRegistered else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(QuotaHandoff.darwinNotificationName as CFString), nil)
        handoffObserverRegistered = false
    }

    /// Flips the launch-at-login registration (STEP_30). `SMAppService.mainApp` registers the app
    /// itself as a login item (macOS 13+); it must run from an installed bundle to take effect —
    /// a warning is expected from a dev build. Errors are logged, never surfaced as a dialog.
    // MARK: Notification groups (STEP_144)

    private func isNotificationGroupEnabled(_ group: NotificationGroup) -> Bool {
        notificationGroups[group] ?? group.defaultEnabled
    }

    /// Updates the cache and persists the row; the engine reads the row on its next cycle.
    private func setNotificationGroup(_ group: NotificationGroup, enabled: Bool) {
        notificationGroups[group] = enabled
        guard let store else { return }
        Task { try? await store.writeSetting(key: group.settingsKey, value: enabled ? "true" : "false") }
    }

    private static func toggleLaunchAtLogin() {
        setLaunchAtLogin(SMAppService.mainApp.status != .enabled)
    }

    /// Registers or unregisters to the requested state (the first-run window's screen 5 checkbox,
    /// STEP_143); a no-op when already there, so "Open Kvotar" with the box checked on an
    /// already-registered install logs nothing.
    private static func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        guard (service.status == .enabled) != enabled else { return }
        do {
            if enabled {
                try service.register()
                Logger.info("Launch at login enabled", component: .appLifecycle)
            } else {
                try service.unregister()
                Logger.info("Launch at login disabled", component: .appLifecycle)
            }
        } catch {
            Logger.error("Launch-at-login toggle failed", component: .appLifecycle,
                         metadata: ["error": "\(error)"])
        }
    }

}
