import Foundation

/// Pure §9.3 startup network-retry ladder (REV-32, STEP_38) — one instance per tool, owned by
/// the poll driver. During the startup window (until the tool's first successful poll this
/// launch), a poll failing with a transient network-shaped error retries on a bounded ladder
/// (15s → 45s → 120s → 300s), then clears to normal cadence — a launch during a network blip no
/// longer waits a full base interval per attempt.
///
/// Hard boundary (§9.1 taxonomy discipline): this ladder never touches 429s. Rate-shaped
/// failures ride the §9.3 recovery path (`PollBackoffPolicy` + `FirstPollGracePolicy`); they are
/// caught before the generic failure branch and `isNetworkShaped` rejects them besides. The
/// early rungs sit below the §9.2 45s steady-state floor deliberately — the floor governs
/// steady cadence, and the Baseline names the 15s rung explicitly.
public struct StartupRetryPolicy: Sendable, Equatable {

    /// The bounded retry ladder.
    public static let rungs: [TimeInterval] = [15, 45, 120, 300]

    /// Startup window flag — true until the first successful poll this launch.
    private var active = true
    /// Next ladder rung to hand out.
    private var nextRung = 0

    public init() {}

    /// Ends the startup window permanently. Call on every successful poll.
    public mutating func succeeded() {
        active = false
    }

    /// Next retry delay for a network-shaped startup failure, or `nil` once the window is over
    /// or the ladder is exhausted (fall back to normal cadence).
    public mutating func networkFailureDelay() -> TimeInterval? {
        guard active, nextRung < Self.rungs.count else { return nil }
        defer { nextRung += 1 }
        return Self.rungs[nextRung]
    }

    /// Transient network-shaped errors only: timeout, connection lost, offline, host
    /// unreachable/not found, DNS failure. Cancellation is not retryable, and no
    /// `AccountAdapterError` (429s, auth, HTTP status, decode) ever qualifies.
    public static func isNetworkShaped(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}
