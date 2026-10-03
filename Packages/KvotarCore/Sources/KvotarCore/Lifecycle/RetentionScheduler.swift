import Foundation

/// Drives `SQLiteStore.runRetentionCleanup()` on the schedule from ARCHITECTURE.md §Shared
/// retention cleanup: once on launch (after the first poll) plus every 30 minutes thereafter.
///
/// The app-lifecycle driver (Step 15) calls `start()` after the first poll completes; this actor
/// runs the cleanup immediately and then on a repeating 30-minute `Task`. Cleanup failures are
/// logged by `SQLiteStore` and swallowed here so one failed sweep never stops the schedule.
public actor RetentionScheduler {

    /// Repeat interval — every 30 minutes (§17.2, ARCHITECTURE.md §Shared retention cleanup).
    static let interval: TimeInterval = 1800

    private let store: SQLiteStore
    private var task: Task<Void, Never>?

    public init(store: SQLiteStore) {
        self.store = store
    }

    /// Runs cleanup immediately, then repeats every 30 minutes until `stop()`. Idempotent — a
    /// second `start()` while already running is a no-op.
    public func start() {
        guard task == nil else { return }
        task = Task { [store] in
            while !Task.isCancelled {
                await Self.runCleanup(store)
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            }
        }
    }

    /// Cancels the repeating schedule.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// One cleanup sweep — exposed for the launch-time run and for tests.
    public func runOnce() async {
        await Self.runCleanup(store)
    }

    private static func runCleanup(_ store: SQLiteStore) async {
        do {
            try await store.runRetentionCleanup()
        } catch {
            // Already logged at ERROR by SQLiteStore; keep the schedule alive.
        }
    }
}
