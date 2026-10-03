import AppKit
import SwiftUI
import KvotarCore
import KvotarUI

/// The quota window (REV-99 §2.1 — STEP_204): the popover's content in an `NSWindow`, so losing
/// the menu-bar icon stops meaning losing the app.
///
/// **No second design.** It hosts `PopoverView` — the same view, the same view model, the same
/// tabs, verdict, rows and hover cards, the same 340 pt. A window that showed something else would
/// be a second surface to spec, to test and to keep in agreement. The cost is recorded in REV-99
/// §5 item 4: a fixed-width window is unusual on macOS and this one cannot be resized.
///
/// One instance per process, on the `HistoryWindowController` pattern: `show` creates it lazily,
/// every later call brings the same window forward, closing hides it and **leaves polling
/// running**.
///
/// **Activation policy stays `.accessory`** — the STEP_109 ruling, restated as binding: a window
/// can become key without a dock icon, and flipping to `.regular` would grow a Dock icon and an
/// app menu that appear and disappear with the window. The price is that `LSUIElement` gives no
/// app menu bar, so ⌘Q and ⌘W are attached to the window by hand below.
@MainActor
final class QuotaWindowController: NSObject, NSWindowDelegate, QuotaSurface {
    private let viewModel: AppViewModel
    private let lifecycle: QuotaSurfaceLifecycle
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    /// Builds the §1a context menu. **One menu, two doors** (REV-99 §2.3): this is the same
    /// builder the right-click uses, injected so this controller never learns the inventory and
    /// the two can never drift.
    var buildMenu: (() -> NSMenu)?

    init(viewModel: AppViewModel, lifecycle: QuotaSurfaceLifecycle) {
        self.viewModel = viewModel
        self.lifecycle = lifecycle
        super.init()
    }

    // MARK: QuotaSurface

    var isVisible: Bool { window?.isVisible == true }

    func open(_ destination: QuotaDestination) {
        let window = self.window ?? makeWindow()
        self.window = window
        lifecycle.willOpen(.window, destination: destination)
        measureHeightBudget()
        // `makeKeyAndOrderFront` alone leaves a miniaturized window in the Dock (REV-99 §7).
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        lifecycle.didOpen(.window, destination: destination,
                          isVisible: { [weak window] in window?.isVisible == true })
    }

    func closeNow() {
        guard let window, window.isVisible else { return }
        // `orderOut` rather than `performClose`: this is the presenter hiding one surface to open
        // the other, and the cleanup below is the synchronous half of that swap. `windowWillClose`
        // covers the user's own close button, and `didClose` is idempotent either way.
        window.orderOut(nil)
        lifecycle.didClose(.window)
    }

    // MARK: The window

    private func makeWindow() -> NSWindow {
        let root = PopoverView().environmentObject(viewModel)
        let hosting = NSHostingController(rootView: root)
        // Hug the SwiftUI content, exactly as the popover does — the height cap lives in the one
        // scroll view inside, driven by `popoverMaxHeight`.
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Kvotar"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: PopoverView.width, height: 480))
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Kvotar.Quota")
        window.delegate = self
        addMenuButton(to: window)
        installKeyMonitor(for: window)
        observeScreenChanges(for: window)
        return window
    }

    /// The `⋯` button in the titlebar — the menu's second door.
    private func addMenuButton(to window: NSWindow) {
        let button = NSButton(title: "", target: self, action: #selector(showMenu(_:)))
        button.image = NSImage(systemSymbolName: "ellipsis",
                               accessibilityDescription: "More options")
        button.isBordered = false
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryChange)
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 20)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 20))
        container.addSubview(button)
        button.frame.origin.x = 4
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func showMenu(_ sender: NSButton) {
        guard let menu = buildMenu?() else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    /// Esc, ⌘Q and ⌘W, scoped to this window (REV-99 §2.3). `LSUIElement` gives no app menu bar,
    /// and an `NSMenu` shown only on click processes no key equivalents while closed — so the two
    /// standard shortcuts are wired here, on the same local-monitor pattern the popover's Esc
    /// already used.
    ///
    /// **Esc does not close the window.** It runs `handleEscape()` first — releasing a pinned
    /// hover card or the verdict anatomy — and only falls through when nothing was collapsed, and
    /// on a titled window it falls through to nothing. A window with a close button and ⌘W does
    /// not also need Esc, and an Esc that closed it would fire the moment a reader dismissed a
    /// hover card. The filter is this window alone, so History and the first-run window keep
    /// their own Esc untouched.
    private func installKeyMonitor(for window: NSWindow) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            if event.keyCode == 53 {
                return self.viewModel.handleEscape() ? nil : event
            }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch key {
            case "q": NSApp.terminate(nil); return nil
            case "w": window.performClose(nil); return nil
            default: return event
            }
        }
    }

    /// A display added, removed or resized, and the window being dragged onto a different screen,
    /// both change the budget. The first is the twin of `MenuBarController`'s observer, keyed on
    /// the window rather than on `popover.isShown`; the second is the one that actually fires on a
    /// drag between displays, which changes no screen parameters at all.
    private func observeScreenChanges(for window: NSWindow) {
        for (name, object) in [
            (NSApplication.didChangeScreenParametersNotification, nil as Any?),
            (NSWindow.didChangeScreenNotification, window as Any?),
        ] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isVisible else { return }
                    self.measureHeightBudget()
                }
            })
        }
    }

    /// How tall the content may grow on the screen presenting **this window**.
    /// `PopoverViewport.availableHeight` is anchored to the status button and does not apply;
    /// `PopoverViewport` still owns what the numbers mean — this only reads AppKit.
    ///
    /// The budget is never left `nil`: that would remove the scroll view's cap and let a tall
    /// quota state grow a window taller than the screen (REV-99 §2.2).
    private func measureHeightBudget() {
        if let override = PopoverHeightOverride.value {
            viewModel.popoverMaxHeight = override
            return
        }
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        viewModel.popoverMaxHeight = PopoverViewport.windowAvailableHeight(
            screenVisibleFrame: screen.visibleFrame, chromeHeight: max(0, chrome))
    }

    // MARK: NSWindowDelegate

    /// The user's own close button or ⌘W. Polling keeps running — closing the window hides a
    /// surface, it does not stop the app.
    func windowWillClose(_ notification: Notification) {
        lifecycle.didClose(.window)
    }
}
