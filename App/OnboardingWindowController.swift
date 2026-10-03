import AppKit
import SwiftUI
import KvotarCore
import KvotarUI

/// Owns the first-run window (UI Spec Part 3 §3a, REV-79 / D-100 — STEP_143). Same shape as
/// `HistoryWindowController`: one lazily created `NSWindow` per process, `show()` brings the same
/// instance forward; activation policy stays `.accessory` (the STEP_109 ruling — a window can be
/// key without a dock icon).
///
/// Fixed 480 × 440, not resizable, no frame autosave: the screens are laid out for one size.
/// Every `show()` restarts at screen 1 — the right-click **Welcome to Kvotar…** re-open is the
/// "how do I read this" reference, and it should always begin at the beginning.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let viewModel: AppViewModel
    private var actions: OnboardingActions
    private var window: NSWindow?

    init(viewModel: AppViewModel, actions: OnboardingActions) {
        self.viewModel = viewModel
        self.actions = actions
        super.init()
        // Skip and Open Kvotar both end here: the composition root's `complete` persists the key,
        // then the window closes. Wrapped once so the view never learns about the window.
        let persist = actions.complete
        self.actions.complete = { [weak self] in
            persist()
            self?.window?.close()
        }
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NotificationCenter.default.post(name: .onboardingReset, object: nil)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let root = OnboardingView(actions: actions).environmentObject(viewModel)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Kvotar"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 440))
        // Long-lived singleton: closing hides it; the next `show()` reuses the instance.
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}
