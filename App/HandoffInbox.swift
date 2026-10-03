import Foundation

/// Holds a hand-off request that arrived before there was anything to open (REV-99 §2.5 —
/// STEP_205). AppKit-free, so the ordering it exists for is pinned in `KvotarTests`.
///
/// **The race is closed by ordering, not by hoping.** The running instance registers its Darwin
/// observer *before* it acquires the §9.2 lock, so any process that could see the lock posted
/// after we were already listening. That moves the problem one step along rather than removing it:
/// the two quota surfaces are built a hundred lines further down the same launch method, so a
/// request can still land with no presenter to answer it. Without this box the second copy would
/// exit after an unheard request and the user would have opened Kvotar and got nothing — the exact
/// failure REV-99 exists to remove.
///
/// A held request drains **once**: two copies launching together produce one window, not two
/// openings.
@MainActor
final class HandoffInbox {
    private var handler: (() -> Void)?
    private var pending = false

    /// A hand-off arrived. Forwarded if the app is wired, held otherwise.
    func receive() {
        if let handler {
            handler()
        } else {
            pending = true
        }
    }

    /// The app is wired. Installs the handler and drains a held request immediately.
    func attach(_ handler: @escaping () -> Void) {
        self.handler = handler
        guard pending else { return }
        pending = false
        handler()
    }

    /// For tests and for the log line: whether a request is still waiting for a handler.
    var hasPendingRequest: Bool { pending }
}
