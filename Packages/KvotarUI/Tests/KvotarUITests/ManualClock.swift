import Foundation

/// A clock that moves only when a test moves it (STEP_277). The hover tests used to shrink the
/// timers to 20 ms and sleep 60 ms, hoping they had fired; on a busy CI runner they had not.
///
/// The timers it drives are `@MainActor` tasks and so are the tests, so between steps `advance`
/// yields the main actor a few times: a timer just armed reaches its sleep, and a timer just woken
/// finishes, before the test looks again.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Int: Sleeper] = [:]
    private var nextID = 0

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = lock.withLock { () -> Int in nextID += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Outcome { case wait, wake, cancelled }
                let outcome: Outcome = lock.withLock {
                    // Checked under the lock the cancel handler takes, so a cancel that ran first
                    // is seen here rather than leaving a sleeper nobody resumes.
                    if Task.isCancelled { return .cancelled }
                    if deadline <= current { return .wake }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .wait
                }
                switch outcome {
                case .wait: break
                case .wake: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Lets armed timers reach their sleep, moves time forward by `duration`, waking each sleeper
    /// due on the way in deadline order, and lets each woken timer finish.
    @MainActor
    func advance(by duration: Duration) async {
        await Self.drain()
        let target = now.advanced(by: duration)
        while let (id, sleeper) = nextDue(by: target) {
            lock.withLock {
                current = sleeper.deadline
                _ = sleepers.removeValue(forKey: id)
            }
            sleeper.continuation.resume()
            await Self.drain()
        }
        lock.withLock { current = target }
    }

    @MainActor
    func advance(_ milliseconds: Int) async {
        await advance(by: .milliseconds(milliseconds))
    }

    private func nextDue(by target: Instant) -> (Int, Sleeper)? {
        lock.withLock {
            sleepers.filter { $0.value.deadline <= target }
                .min { $0.value.deadline < $1.value.deadline }
                .map { ($0.key, $0.value) }
        }
    }

    @MainActor
    private static func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
