import Foundation

/// One of the two surfaces that can carry the quota reading. Deliberately AppKit-free so the
/// presenter's routing and its close→open ordering can be tested with fakes.
@MainActor
protocol QuotaSurface: AnyObject {
    var isVisible: Bool { get }
    func open(_ destination: QuotaDestination)
    /// Hide the surface **and** run its close-side cleanup, synchronously, before returning.
    /// A no-op when the surface is not showing.
    func closeNow()
}

/// The single entry point every way into the quota reading goes through (REV-99 §2.3a —
/// STEP_204).
///
/// Before this, several shipped paths opened the *status-item popover* by name: `Set up <tool>…`
/// anchored to `statusItem.button`, and so did the quota notification's **Open Kvotar** and the
/// Welcome's last button. Each of them could therefore deliver a stranded user straight back to
/// the icon they could not find. **No caller names a surface** — they name a destination, and this
/// decides.
///
/// The order on every switch is **close → cleanup → open**, and it is explicit rather than
/// incidental: `QuotaSurfaceLifecycle` explains why a deferred cleanup would erase the §2.8 line
/// the newly opened surface had just computed.
@MainActor
final class QuotaSurfacePresenter {
    private weak var popover: (any QuotaSurface)?
    private weak var window: (any QuotaSurface)?

    /// Whether macOS is known to be hiding the status item — `HiddenItemMonitor`'s confirmed
    /// state, wired by the composition root (REV-99 §2.6 — STEP_206). **Live truth, not a
    /// launch-time fact:** an item that reappears routes to the popover again, and only the §2.7
    /// notice is capped per launch. The default keeps every test and preview that never wires a
    /// monitor on the pre-detection path.
    var isItemKnownHidden: () -> Bool = { false }

    init(popover: any QuotaSurface, window: any QuotaSurface) {
        self.popover = popover
        self.window = window
    }

    /// The presenter's own choice: whatever the user can actually see. Used by the quota
    /// notification's **Open Kvotar**, the Welcome's **Open Kvotar**, and `Set up <tool>…` from
    /// either door of the §1a menu.
    func present(_ destination: QuotaDestination = .defaultTab) {
        if window?.isVisible == true || isItemKnownHidden() {
            presentWindow(destination)
        } else {
            presentPopover(destination)
        }
    }

    /// A deliberate cold launch and every reopen: the **window**, always. The user asked for the
    /// app, not for the item — and on a full menu bar the item may be exactly what they could not
    /// find.
    func presentWindow(_ destination: QuotaDestination = .defaultTab) {
        popover?.closeNow()
        window?.open(destination)
    }

    /// The status item's left click, which toggles. It stays on the popover: a user clicking the
    /// item has demonstrably found it.
    func togglePopover() {
        if popover?.isVisible == true {
            popover?.closeNow()
        } else {
            presentPopover(.defaultTab)
        }
    }

    /// Get the active quota surface out of the way before another window takes key — the History
    /// footer link's `closePopover()`, generalised. History and the first-run window keep their
    /// own controllers and are not routed here (REV-99 §2.3a).
    func closeActiveSurface() {
        popover?.closeNow()
        window?.closeNow()
    }

    private func presentPopover(_ destination: QuotaDestination) {
        window?.closeNow()
        popover?.open(destination)
    }
}
