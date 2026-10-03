import AppKit
import SwiftUI
import Combine
import KvotarCore
import KvotarUI

/// Owns the single combined `NSStatusItem` (Baseline §14.1). The item hosts the same SwiftUI
/// `MenuBarItemView` the previews render (via `NSHostingView` inside the status button), showing
/// whatever `AppViewModel.menuBarRender` holds for the active §1.0 display mode — stacked rows, a
/// single tool's row, or the D-78 mark. **The item is always visible** (D-98). Click handling
/// stays on the button: left toggles the popover, right opens the context menu (Quit + the
/// interim display-mode picker; Step 30's settings window absorbs the picker).
///
/// Since STEP_204 the controller is also the **popover half of `QuotaSurface`**: it opens and
/// closes the popover on the presenter's instruction and never decides which surface a caller
/// gets. Its context-menu builder has a second door — the quota window's `⋯` button calls the
/// same `contextMenu()`, so the §1a inventory cannot drift between them.
@MainActor
final class MenuBarController: QuotaSurface {
    private let statusItem: NSStatusItem
    private let viewModel: AppViewModel
    private let popover: NSPopover
    /// The open/close parity both quota surfaces share (STEP_204) — the §15.1 default tab, the
    /// freshness stamps, the explanation layer, the §17.1 glance hook and the §2.8 lines.
    private let lifecycle: QuotaSurfaceLifecycle
    /// What the popover is currently showing, so `didOpen` knows whether to start a freshness
    /// timer (a D-68 setup card starts none).
    private var openDestination: QuotaDestination = .defaultTab
    private let hostingView: NSHostingView<AnyView>
    /// Offscreen twin, never added to the button, used only to measure (STEP_203).
    ///
    /// The width pass walks up to five phase candidates. Measuring them through the *drawn* view
    /// would push five renders through the §2.4a crossfade before the real one arrived, and the
    /// bar would fade five times per state change. The measuring host renders
    /// `MenuBarItemView.Layout.measuring`, which holds no state and runs no transition. The
    /// STEP_199 rule it replaces — "measure through the same hosting view" — was about identical
    /// *metrics*, not identical identity: `MenuBarWidthTests` and `MenuBarSnapshots` have always
    /// measured through hosting views of their own and agreed with this one to the point.
    private let measuringView = NSHostingView(rootView: AnyView(EmptyView()))
    private var lastRender: MenuBarRender?
    /// The width reserved for the current steady form. A phase edge reuses it and re-measures
    /// nothing (§2.6), and the drawn view needs the number to fit variant D's headline inside it.
    private var reserved: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()
    /// Esc while the popover is key (STEP_110, UI Spec Part 3 §5.1): installed on popover show,
    /// removed on close. Consumes the key only when the view model collapsed something (the
    /// verdict anatomy today; STEP_111's pinned card and STEP_113's coach mark chain onto the same
    /// call), otherwise passes it through so a transient popover's own Esc-to-close still works.
    private var escapeMonitor: Any?
    /// Whether macOS is hiding the item (REV-99 §2.6 — STEP_206). The controller owns the monitor
    /// because it owns the status item, and re-publishes its answer: what a hidden item *means*
    /// — the notice, and the presenter's routing — belongs to the composition root, so this class
    /// stays `UserNotifications`-free and presenter-free.
    private let hiddenItemMonitor = HiddenItemMonitor()

    /// Persists + applies a picked display mode. Injected by the AppDelegate so the
    /// controller stays store-free (composition-root rule, STEP_25).
    var onSelectMode: ((MenuBarDisplayMode) -> Void)?

    /// Toggles launch-at-login (STEP_30). Returns the new enabled state so the menu checkmark
    /// reflects the actual `SMAppService` registration. Injected by the AppDelegate — the
    /// controller stays ServiceManagement-free (composition-root rule).
    var onToggleLaunchAtLogin: (() -> Void)?
    /// A left-click on the status item (Baseline §14.1). Routed through the presenter rather than
    /// acted on here: the popover toggles, but the *other* surface must close first (REV-99 §2.2).
    /// Injected by the AppDelegate — the controller stays presenter-free (composition-root rule).
    var onToggleRequested: (() -> Void)?
    /// `Set up <tool>…` (D-68). Names a **destination**, never a surface — the presenter decides
    /// whether the card opens in the popover or in the quota window (REV-99 §2.3a).
    var onPresent: ((QuotaDestination) -> Void)?
    /// Reads the current launch-at-login state for the menu checkmark. Injected; defaults false.
    var isLaunchAtLoginEnabled: (() -> Bool)?
    /// Writes a diagnostics bundle to the Desktop and reveals it in Finder (D-47, STEP_73).
    /// Injected by the AppDelegate — the controller stays store-free (composition-root rule).
    var onSaveDiagnostics: (() -> Void)?
    /// Shows the visible, time-limited consent flow (or turns an active window off immediately).
    var onConfigureExtendedDiagnostics: (() -> Void)?
    /// Opens the History window (STEP_109). Injected by the AppDelegate, which owns the window
    /// controller — the menu-bar controller stays window-free (composition-root rule).
    var onOpenHistory: (() -> Void)?
    /// Re-opens the first-run window (UI Spec Part 3 §3a, STEP_143). Injected by the AppDelegate,
    /// which owns the window controller.
    var onOpenWelcome: (() -> Void)?
    /// **Open in Window** (STEP_208). Names the **window**, not a destination — this is the one row
    /// in the §1a inventory whose whole point is *which surface*, so it is deliberately not routed
    /// through `present()`, which would hand back the popover the user is standing in.
    var onOpenQuotaWindow: (() -> Void)?
    /// Reads a notification group's switch for the **Notify me ▸** checkmarks (STEP_144).
    /// Injected; defaults to the group's absent-key default.
    var isNotificationGroupEnabled: ((NotificationGroup) -> Bool)?
    /// Flips a notification group (STEP_144). Injected — the controller stays store-free.
    var onToggleNotificationGroup: ((NotificationGroup) -> Void)?
    /// Whether macOS has the app's notification permission denied (D-103, STEP_150) — puts the
    /// hint row above the group checkmarks. Injected; the AppDelegate owns the cached read.
    var isNotificationPermissionDenied: (() -> Bool)?
    /// Whether warnings are allowed but set to Banners (D-127, STEP_225) — puts the
    /// keep-them-on-screen row above the group checkmarks. Ignored while denied.
    var areNotificationsBanners: (() -> Bool)?
    /// Opens System Settings › Notifications (D-103). Injected — the controller stays workspace-free.
    var onOpenNotificationSettings: (() -> Void)?
    /// Fires before every context-menu build (STEP_150): the AppDelegate refreshes its cached
    /// permission read so a change made in System Settings shows on the next open.
    var onContextMenuWillOpen: (() -> Void)?
    /// **Check for Updates…** (UI Spec Part 3 §1a, D-105d — STEP_152). Injected by the
    /// AppDelegate, which owns the updater — the controller stays Sparkle-free.
    var onCheckForUpdates: (() -> Void)?
    /// Whether a check may start now (Sparkle refuses while one is in flight). Read at menu-build
    /// time; false renders the item greyed. Injected; defaults true.
    var canCheckForUpdates: (() -> Bool)?
    /// Reads the **Check for updates automatically** checkmark (D-105b). Sparkle owns the value
    /// (UserDefaults), so the menu reads it live like **Open at Login** reads `SMAppService`.
    var isAutomaticUpdateChecksEnabled: (() -> Bool)?
    /// Flips the automatic-check preference (D-105b). Injected — the controller stays Sparkle-free.
    var onToggleAutomaticUpdateChecks: (() -> Void)?
    /// macOS started or stopped hiding the status item (REV-99 §2.6 — STEP_206), and whether this
    /// is the launch's one notice. Injected by the AppDelegate, which posts it; the controller only
    /// relays the fact and stays `UserNotifications`-free.
    var onHiddenItemChanged: ((_ isHidden: Bool, _ notice: Bool) -> Void)?

    /// Whether macOS is hiding the item right now — the presenter's `isItemKnownHidden` input.
    /// Live truth, not a launch-time fact: an item that reappears routes to the popover again.
    var isItemKnownHidden: Bool { hiddenItemMonitor.isConfirmedHidden }

    init(viewModel: AppViewModel, popover: NSPopover, lifecycle: QuotaSurfaceLifecycle) {
        self.viewModel = viewModel
        self.popover = popover
        self.lifecycle = lifecycle
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.hostingView = NSHostingView(rootView: AnyView(EmptyView()))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // The SwiftUI content ignores hits so every click lands on the button itself.
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hostingView)
            // Pinned **leading**, not leading-and-trailing (STEP_199): the item now reserves the
            // wider phase's width (§2.6), so the button can be wider than the content, and a
            // stretched hosting view would centre the row inside that slack — the string would
            // shuffle sideways at every phase edge, which is the movement the reservation exists
            // to prevent. The trailing edge is a ceiling, not an equality.
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hostingView.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: button.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }

        render()
        viewModel.$menuBarRender.sink { [weak self] render in self?.render(render) }
            .store(in: &cancellables)

        // The explanation layer's lifecycle hooks (STEP_110): every open starts collapsed, close
        // collapses whatever the user left open, and Esc collapses before it closes. Observed on
        // the popover itself so `showPopover`, `showSetup` and the transient click-outside close
        // are all covered by the same two lines.
        NotificationCenter.default.addObserver(forName: NSPopover.didShowNotification,
                                               object: popover, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.popoverDidShow() }
        }
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification,
                                               object: popover, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.popoverDidClose() }
        }
        // A display added, removed or resized while the popover is up changes its height budget
        // (STEP_179). Every ordinary open measures afresh; this covers the one case that does not
        // pass through `showPopover`.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown, let button = self.statusItem.button else { return }
                self.measurePopoverHeightBudget(from: button)
            }
        }

        // Detection (REV-99 §2.6 — STEP_206). The window is read through a closure because it
        // does not exist yet in every launch shape, and the monitor reads it and never touches it.
        hiddenItemMonitor.statusWindow = { [weak self] in self?.statusItem.button?.window }
        hiddenItemMonitor.onChange = { [weak self] hidden, notice in
            self?.onHiddenItemChanged?(hidden, notice)
        }
        hiddenItemMonitor.start()
    }

    // MARK: Height budget (Baseline §15.2 — STEP_179)

    /// How tall the popover may grow on the screen actually presenting it. Measured before every
    /// open, so moving the menu bar to a shorter display is picked up without any state to keep.
    ///
    /// The status button's bottom edge in screen coordinates is where the popover hangs from;
    /// `visibleFrame` already excludes the Dock and the menu bar. `PopoverViewport` owns what the
    /// numbers mean — this method only reads AppKit.
    private func measurePopoverHeightBudget(from button: NSStatusBarButton) {
        if let override = PopoverHeightOverride.value {
            viewModel.popoverMaxHeight = override
            return
        }
        guard let screen = button.window?.screen ?? NSScreen.main else { return }
        let anchorMinY = button.window
            .map { $0.convertToScreen(button.convert(button.bounds, to: nil)).minY }
            ?? screen.visibleFrame.maxY
        viewModel.popoverMaxHeight = PopoverViewport.availableHeight(
            screenVisibleFrame: screen.visibleFrame, anchorMinY: anchorMinY)
    }

    // MARK: Explanation-layer lifecycle (STEP_110 anatomy · STEP_111 hover cards)

    private func popoverDidShow() {
        lifecycle.didOpen(.popover, destination: openDestination,
                          isVisible: { [weak self] in self?.popover.isShown == true })
        Logger.debug("Popover shown · explanation layer reset", component: .appLifecycle)
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.popover.isShown else { return event }
            // Only key events bound for the popover's own window — the History window and any
            // other panel keep their Esc untouched.
            guard event.window === self.popover.contentViewController?.view.window else { return event }
            return self.viewModel.handleEscape() ? nil : event
        }
    }

    /// The deferred, notification-driven close. `didClose` is guarded by which surface is current
    /// (STEP_204), so when the presenter has already closed this popover synchronously to open the
    /// window, this arrives to find nothing left to do — and cannot erase the §2.8 line the window
    /// has meanwhile computed.
    private func popoverDidClose() {
        lifecycle.didCloseFromNotification(.popover)   // the §2.8 line goes with it (STEP_112)
        Logger.debug("Popover closed · explanation layer reset", component: .appLifecycle)
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    // MARK: Rendering

    private func render(_ newRender: MenuBarRender? = nil) {
        let render = newRender ?? viewModel.menuBarRender
        // Width stability (§1.0): redraw only when the content changed — never per-tick.
        guard render != lastRender else { return }
        // **Width is reserved, not re-measured** (REV-97 §2.6 — STEP_199). A phase edge changes
        // what is drawn and nothing about what the row *can* draw, so the item's length is
        // recomputed only when the steady form changes — i.e. on a state transition. Between
        // phases the item does not move by so much as a point.
        let resize = lastRender.map { MenuBarWidth.steadyForm($0) != MenuBarWidth.steadyForm(render) }
            ?? true
        lastRender = render

        if resize {
            reserved = reservedWidth(for: render)
            statusItem.length = reserved
        }
        hostingView.rootView = AnyView(
            MenuBarItemView(render: render, layout: .drawing(width: reserved))
                .allowsHitTesting(false))
    }

    /// The widest this render can get without a state transition. `MenuBarWidth` owns which
    /// renders are candidates; this only reads AppKit.
    ///
    /// Measured through `measuringView` in the `.measuring` layout — the row form, no state, no
    /// transition. Variant D's headline is *fitted to* the number this returns, so it must not be
    /// one of the things the number is measured from.
    private func reservedWidth(for render: MenuBarRender) -> CGFloat {
        var widest: CGFloat = 0
        for candidate in MenuBarWidth.phaseRenders(render) {
            measuringView.rootView = AnyView(MenuBarItemView(render: candidate)
                .allowsHitTesting(false))
            widest = max(widest, ceil(measuringView.fittingSize.width))
        }
        return widest
    }

    // MARK: Interaction

    /// Left-click toggles the popover; a secondary click opens the context menu (Baseline §14.1).
    /// Secondary = right button / two-finger tap (`.rightMouseUp`) **or** control-click, which
    /// AppKit delivers as `.leftMouseUp` with the Control modifier — the macOS convention.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isSecondary {
            showContextMenu()
        } else {
            onToggleRequested?()
        }
    }

    /// Shows the context menu via the temporary-`menu` + `performClick` pattern: assigning
    /// `statusItem.menu` makes the click open the menu with correct system positioning;
    /// tracking runs synchronously inside `performClick`, and detaching afterwards restores
    /// left-click popover toggling.
    private func showContextMenu() {
        if popover.isShown { popover.performClose(nil) }
        statusItem.menu = contextMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Builds the §1a menu. **One builder, two doors** (REV-99 §2.3): the right-click above and
    /// the quota window's `⋯` button both call this, so the inventory, its order and its copy
    /// cannot drift apart — UI Spec Part 3 §1a stays the single authority for both. Contains the
    /// interim "Menu bar display" picker (OQ-30-3 resolution) and Quit — available in every mode
    /// (§14.1).
    ///
    /// Closing the popover is deliberately *not* here: the `⋯` door hangs its menu off a window
    /// that must stay up while the menu tracks.
    func contextMenu() -> NSMenu {
        onContextMenuWillOpen?()
        let menu = NSMenu()

        // Caption row (UI Spec Part 3 §1a, D-86). No action, so menu auto-enabling greys it out
        // and it reads as a label rather than a command. It answers "what is this?" for the one
        // person who is asking — someone poking around this menu — without lengthening the app's
        // name in the menu bar, Finder, notification banners or Login Items.
        let caption = NSMenuItem(title: ProductIdentity.tagline, action: nil, keyEquivalent: "")
        menu.addItem(caption)
        menu.addItem(.separator())

        let modeItem = NSMenuItem(title: "Menu bar display", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in MenuBarDisplayMode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(selectMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = viewModel.menuBarDisplayMode == mode ? .on : .off
            modeMenu.addItem(item)
        }
        menu.addItem(modeItem)
        menu.setSubmenu(modeMenu, for: modeItem)
        menu.addItem(.separator())

        let launch = NSMenuItem(title: "Open at Login",
                                action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = (isLaunchAtLoginEnabled?() ?? false) ? .on : .off
        menu.addItem(launch)

        // Notify me ▸ (UI Spec §1a, REV-79 / D-100 — STEP_144): the four user-facing groups,
        // checkmark = enabled. Names groups only — never an engine event, cap or cooldown.
        // Denied by macOS (D-103, STEP_150): the parent title says so before the submenu opens;
        // inside, the pane link sits above the four groups, which are greyed out (checkmarks
        // kept — they still govern what fires once the user re-allows).
        let denied = isNotificationPermissionDenied?() == true
        let notifyItem = NSMenuItem(title: denied ? NotificationPermissionHint.deniedParentTitle
                                                  : NotificationPermissionHint.parentTitle,
                                    action: nil, keyEquivalent: "")
        let notifyMenu = NSMenu()
        notifyMenu.autoenablesItems = false
        if denied {
            let hint = NSMenuItem(title: NotificationPermissionHint.title,
                                  action: #selector(openNotificationSettings), keyEquivalent: "")
            hint.target = self
            notifyMenu.addItem(hint)
            notifyMenu.addItem(.separator())
        } else if areNotificationsBanners?() == true {
            // D-127 (STEP_225): same pane, same place; the switches stay enabled.
            let hint = NSMenuItem(title: NotificationPermissionHint.bannersTitle,
                                  action: #selector(openNotificationSettings), keyEquivalent: "")
            hint.target = self
            notifyMenu.addItem(hint)
            notifyMenu.addItem(.separator())
        }
        for group in NotificationGroup.allCases {
            let item = NSMenuItem(title: group.label, action: #selector(toggleNotificationGroup(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = group.rawValue
            let on = isNotificationGroupEnabled?(group) ?? group.defaultEnabled
            item.state = on ? .on : .off
            item.isEnabled = !denied
            notifyMenu.addItem(item)
        }
        menu.addItem(notifyItem)
        menu.setSubmenu(notifyMenu, for: notifyItem)
        menu.addItem(.separator())

        // Set up <tool>… (UI Spec Part 3 §1a, D-68) — present only while that tool is
        // undetected; a two-tool machine never sees either item. The menu is rebuilt on every
        // right-click, so the item disappears on the first open after the tool is detected —
        // same lifecycle as the display-mode checkmark. Opens the popover directly on that
        // tool's setup card (the diagnostic entry the deleted ghost tab used to provide).
        let undetectedTools = Tool.allCases.filter { !viewModel.detectedTools.contains($0) }
        if !undetectedTools.isEmpty {
            for tool in undetectedTools {
                let title = tool == .claude ? "Set up Claude Code…" : "Set up Codex…"
                let item = NSMenuItem(title: title, action: #selector(setUpTool(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = tool.rawValue
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // Welcome to Kvotar… (UI Spec Part 3 §1a, REV-79 / D-100 — STEP_143): re-opens the
        // first-run window at screen 1. Always present — it doubles as the "how do I read the
        // menu bar" reference after the once-only open.
        let welcome = NSMenuItem(title: "Welcome to Kvotar…", action: #selector(openWelcome),
                                 keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)
        menu.addItem(.separator())

        // Open in Window (STEP_208 — D-122 amendment): the same quota reading in the window, which
        // until now nothing in the UI announced. **No ellipsis** — it opens the surface and asks
        // nothing further; and **never disabled**, including from the window's own `⋯`, where it
        // simply brings the window forward. A rule that greys it there would be one more thing to
        // explain than the no-op it prevents.
        let quotaWindow = NSMenuItem(title: "Open in Window", action: #selector(openQuotaWindow),
                                     keyEquivalent: "")
        quotaWindow.target = self
        menu.addItem(quotaWindow)

        // History… (STEP_109): the last 30 days of the local corpus, in its own window. The
        // ellipsis is the macOS convention for an action that opens something.
        let history = NSMenuItem(title: "History…", action: #selector(openHistory),
                                 keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        // Save Diagnostics… (UI Spec Part 3 §1a, D-47). Ships in **both** channels — it is the
        // post-launch support path, not a beta affordance. The ellipsis is the macOS convention
        // for an action that does not complete on click (it opens Finder).
        let diagnostics = NSMenuItem(title: "Save Diagnostics…",
                                     action: #selector(saveDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)
        let extendedTitle = DiagnosticsCapture.isEnabled
            ? "Turn Off Extended Diagnostics…" : "Enable Extended Diagnostics for 24 Hours…"
        let extended = NSMenuItem(title: extendedTitle,
                                  action: #selector(configureExtendedDiagnostics), keyEquivalent: "")
        extended.target = self
        menu.addItem(extended)
        menu.addItem(.separator())

        // Sparkle (UI Spec Part 3 §1a, D-105b/d — STEP_152): beside About, where macOS puts it.
        // While a check is in flight the item is built with no action, so menu auto-enabling
        // greys it — the same trick as the caption row, no `autoenablesItems` change needed.
        let canCheck = canCheckForUpdates?() ?? true
        let check = NSMenuItem(title: "Check for Updates…",
                               action: canCheck ? #selector(checkForUpdates) : nil,
                               keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        let automatic = NSMenuItem(title: "Check for updates automatically",
                                   action: #selector(toggleAutomaticUpdateChecks),
                                   keyEquivalent: "")
        automatic.target = self
        automatic.state = (isAutomaticUpdateChecksEnabled?() ?? false) ? .on : .off
        menu.addItem(automatic)

        let about = NSMenuItem(title: "About Kvotar", action: #selector(showAbout),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Kvotar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = MenuBarDisplayMode(rawValue: raw) else { return }
        onSelectMode?(mode)
    }

    @objc private func toggleLaunchAtLogin() {
        onToggleLaunchAtLogin?()
    }

    @objc private func toggleNotificationGroup(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let group = NotificationGroup(rawValue: raw) else { return }
        onToggleNotificationGroup?(group)
    }

    @objc private func openNotificationSettings() {
        onOpenNotificationSettings?()
    }

    /// `Set up <tool>…` (D-68). Names the destination and lets the presenter pick the surface —
    /// before STEP_204 this anchored the popover to the status button, which could send a user
    /// who could not find the item straight back to it (REV-99 §2.3a).
    @objc private func setUpTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let tool = Tool(rawValue: raw) else { return }
        onPresent?(.setup(tool))
    }

    @objc private func saveDiagnostics() {
        onSaveDiagnostics?()
    }

    @objc private func configureExtendedDiagnostics() {
        onConfigureExtendedDiagnostics?()
    }

    @objc private func openHistory() {
        onOpenHistory?()
    }

    @objc private func openWelcome() {
        onOpenWelcome?()
    }

    @objc private func openQuotaWindow() {
        onOpenQuotaWindow?()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func toggleAutomaticUpdateChecks() {
        onToggleAutomaticUpdateChecks?()
    }

    /// The standard About panel, plus the §1a caption and the sentence that grounds it (D-86).
    /// Pass the compiled icon explicitly: relying on the panel's implicit bundle lookup left the
    /// icon blank in a locally rebuilt LSUIElement app even though `AppIcon.icns` was present.
    /// Name and "Version x.y.z (n)" still come from the bundle. The bundled `THIRD_PARTY_NOTICES`
    /// (D-105f) is no longer linked from here (user ruling 2026-09-07, build 11) — it stays in the
    /// bundle for the Sparkle and GRDB licences.
    @objc private func showAbout() {
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let description = NSMutableAttributedString(
            string: ProductIdentity.tagline + "\n" + ProductIdentity.descriptionSentence
                + "\n\nFeedback: " + ProductIdentity.supportEmail,
            attributes: secondary)
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        description.addAttribute(.paragraphStyle, value: centred,
                                 range: NSRange(location: 0, length: description.length))
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: description]
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: QuotaSurface (STEP_204)

    var isVisible: Bool { popover.isShown }

    /// Opens the popover on `destination`. A `.setup` card is transient — the next ordinary open
    /// runs `selectDefaultTab`, which clears it — and fires no glance row and starts no freshness
    /// timer; `QuotaSurfaceLifecycle` owns that exception for both surfaces.
    ///
    /// Activates the app first: the notification action can be taken while Kvotar is in the
    /// background.
    func open(_ destination: QuotaDestination) {
        guard let button = statusItem.button else { return }
        // Re-opening onto a popover that is already up (a notification's **Open Kvotar**, or
        // `Set up <tool>…`) is a surface switch too: close through `closeNow` so the cleanup is
        // synchronous. A bare `performClose` here would leave its deferred handler to land after
        // the reopen and erase the §2.8 line it had just computed.
        closeNow()
        openDestination = destination
        NSApp.activate(ignoringOtherApps: true)
        lifecycle.willOpen(.popover, destination: destination)
        measurePopoverHeightBudget(from: button)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Hides the popover **and** runs its close-side cleanup before returning. `performClose`
    /// alone defers that cleanup twice (a `.main`-queued notification whose handler then hops
    /// through a `Task`), so an open following immediately after would have its §2.8 line erased
    /// by a handler landing late.
    func closeNow() {
        guard popover.isShown else { return }
        popover.performClose(nil)
        lifecycle.closedByApp(.popover)
    }
}
