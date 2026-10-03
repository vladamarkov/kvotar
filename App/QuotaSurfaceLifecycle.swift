import Foundation
import KvotarCore
import KvotarUI

/// Which quota surface is showing. The popover and the window **never coexist** (REV-99 §2.2):
/// three shipped mechanisms assume one surface — `AppViewModel.popoverMaxHeight` is a single
/// `@Published` value, each surface's Esc monitor filters on its own window, and
/// `popoverDidClose()` clears the §2.8 "since you last looked" lines, which must happen once per
/// reading rather than twice.
enum QuotaSurfaceKind: Equatable, Hashable {
    case popover
    case window
}

/// What a quota surface is opened *to*. Carried through the presenter unchanged, so no caller
/// has to name a surface (REV-99 §2.3a).
enum QuotaDestination: Equatable {
    case defaultTab
    /// The D-68 `Set up <tool>…` card. Transient, and the one open that fires **no** `onOpen`
    /// hook and starts **no** freshness timer: the §17.1 glance row records which *tab* was
    /// shown and a setup card is not a tab, and the card carries no freshness stamps to tick.
    case setup(Tool)
}

/// The open/close lifecycle both quota surfaces run, in one place (STEP_204).
///
/// The popover has owned these calls since STEP_110/STEP_112/STEP_177 and the window owns exactly
/// the same ones — so they are here rather than copied, on the PATTERNS.md rule that two surfaces
/// which must agree call one function.
///
/// **The close-side cleanup must run once per reading, and before the next one starts**, and that
/// is not tidiness. `AppViewModel.popoverDidClose()` erases the §2.8 lines *and* bumps
/// `deltaLineGeneration`, which makes an in-flight boundary read discard its own result on arrival
/// — deleting `Last window ended at [N]% — reset [t]`, the one line written for a rollover. The
/// popover's own cleanup is deferred twice (a `.main`-queued `didCloseNotification` whose handler
/// then hops through a `Task`), so a close followed immediately by an open would land *after* the
/// new surface had computed its line.
///
/// Two rules keep that straight. The presenter closes **synchronously** through `closedByApp`; and
/// because a popover can reopen onto *itself* — a notification's **Open Kvotar** while it is
/// already up — the surface's identity is not enough to recognise the late notification, so a
/// close the app initiated **consumes the one notification that follows it**. Everything else —
/// the user clicking away, Esc on a transient popover — is a genuine end of reading and runs.
@MainActor
final class QuotaSurfaceLifecycle {
    private let viewModel: AppViewModel

    /// Fires on every ordinary open, after the §15.1 default tab is settled. Carries two things
    /// (composition root, `AppDelegate`): the §17.1 `popover_opens` glance row and the STEP_177
    /// daily-local-report refresh.
    var onOpen: (() -> Void)?

    /// How often the per-source age stamps are re-derived while a surface stays up (D-21).
    static let freshnessInterval: TimeInterval = 30

    /// The surface currently showing, if any.
    private(set) var current: QuotaSurfaceKind?

    private var freshnessTimer: Timer?

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    /// Everything that must happen **before** a surface is shown. `selectDefaultTab()` also takes
    /// the §2.8 snapshot (`noteTabDisplayed`), so it runs exactly once per open on either surface.
    func willOpen(_ surface: QuotaSurfaceKind, destination: QuotaDestination) {
        switch destination {
        case .defaultTab:
            viewModel.selectDefaultTab()
            viewModel.refreshFreshness()
            onOpen?()
        case .setup(let tool):
            viewModel.openSetup(tool)
        }
        current = surface
    }

    /// The surface is on screen: the explanation layer starts collapsed on every open (STEP_110),
    /// and the age stamps keep ticking muted → amber → stale-keep while it stays up.
    ///
    /// `isVisible` is the **owning surface's own** liveness test. The popover's timer used to
    /// self-invalidate on `popover.isShown`; reusing that predicate from the window would stop the
    /// window's timer on its first tick.
    func didOpen(_ surface: QuotaSurfaceKind, destination: QuotaDestination,
                 isVisible: @escaping () -> Bool) {
        guard current == surface else { return }
        viewModel.releaseExplanationLayer()
        guard destination == .defaultTab else { return }
        startFreshnessTimer(isVisible: isVisible)
    }

    /// The close-side cleanup, run **once** per reading and only for the surface that is actually
    /// current. Safe to call twice, and safe to call on a surface that already gave way.
    func didClose(_ surface: QuotaSurfaceKind) {
        guard current == surface else { return }
        current = nil
        stopFreshnessTimer()
        viewModel.releaseExplanationLayer()
        viewModel.popoverDidClose()
    }

    /// A close **the app itself initiated** — the presenter swapping surfaces, or a surface
    /// reopening onto itself. Runs the cleanup now and marks the notification that will follow as
    /// already accounted for.
    ///
    /// Only the popover announces its close, so only the popover's `closeNow` goes through here;
    /// the window's `orderOut` posts nothing, and counting a notification that never arrives would
    /// swallow the user's next close instead.
    func closedByApp(_ surface: QuotaSurfaceKind) {
        guard current == surface else { return }
        pendingAppCloses[surface, default: 0] += 1
        didClose(surface)
    }

    /// The deferred, notification-driven close. **The surface's identity is not enough here**: a
    /// popover that reopens onto itself is current again by the time its own late notification
    /// arrives, so `didClose`'s guard would let it through and erase the line the reopen just
    /// computed. What distinguishes them is who closed it — a close the app initiated consumes
    /// the one notification that follows it, and anything else (the user clicking away, Esc on a
    /// transient popover) is a genuine end of reading and runs.
    func didCloseFromNotification(_ surface: QuotaSurfaceKind) {
        if let pending = pendingAppCloses[surface], pending > 0 {
            pendingAppCloses[surface] = pending - 1
            return
        }
        didClose(surface)
    }

    private var pendingAppCloses: [QuotaSurfaceKind: Int] = [:]

    private func startFreshnessTimer(isVisible: @escaping () -> Bool) {
        stopFreshnessTimer()
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: Self.freshnessInterval,
                                              repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard isVisible() else { self.stopFreshnessTimer(); return }
                self.viewModel.refreshFreshness()
            }
        }
    }

    private func stopFreshnessTimer() {
        freshnessTimer?.invalidate()
        freshnessTimer = nil
    }

    /// Test seam: whether a freshness timer is running. Nothing in the app reads it.
    var isFreshnessTimerRunning: Bool { freshnessTimer != nil }
}
