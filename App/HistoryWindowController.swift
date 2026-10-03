import AppKit
import SwiftUI
import KvotarCore
import KvotarUI

/// Owns the History window (STEP_109) — the app's first real `NSWindow`. One instance for the
/// process: `show()` creates it lazily and every later call brings the same window forward.
///
/// **Activation policy stays `.accessory`** (recorded decision, STEP_109 task 5). `LSUIElement`
/// makes this a menu-bar app with no dock icon; a window can still become key under `.accessory`,
/// and `NSApp.activate(ignoringOtherApps:)` — the same call the popover and setup card make —
/// brings it to the front. Flipping to `.regular` would grow a dock icon and an app menu on the
/// first report, which changes the app's character for something that needs neither.
///
/// The report is recomputed on every open and on every focus (`didBecomeKey`), so a first-launch
/// window fills in as the STEP_95 backfill sweep lands rows behind it — nothing waits on the sweep.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private let viewModel: HistoryViewModel
    private var window: NSWindow?

    init(load: @escaping () async -> HistoryReport?) {
        self.viewModel = HistoryViewModel(load: load)
        super.init()
    }

    func show(destination: HistoryDestination? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        // Every ordinary open starts on Summary · All with the model's own day selection
        // (REV-84 §2). Deliberately not in `windowDidBecomeKey`: re-focusing an open window is a
        // reload, not an open, and must keep the reader's place — which is also what keeps an
        // explicit destination (STEP_178) from being discarded on the next focus.
        viewModel.prepareForOpen(destination: destination)
        viewModel.reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: HistoryView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Wide enough for the STEP_115 two-column block layout to appear on first open; the
        // 560-pt minimum below still lays out in one column.
        window.setContentSize(NSSize(width: 860, height: 640))
        window.minSize = NSSize(width: 560, height: 420)
        // The window is a long-lived singleton: closing hides it, and the next `show()` brings the
        // same instance back with a fresh report. Releasing on close would leave `self.window`
        // dangling and the next open would touch a freed object.
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Kvotar.History")
        window.delegate = self
        return window
    }

    // MARK: NSWindowDelegate

    /// Focus is a reopen: whatever the sweep or the live watchers landed since the last look is
    /// picked up here.
    func windowDidBecomeKey(_ notification: Notification) {
        viewModel.reload()
    }
}
