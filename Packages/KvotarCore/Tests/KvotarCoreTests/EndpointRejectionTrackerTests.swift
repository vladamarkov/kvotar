import XCTest
@testable import KvotarCore

/// §9.5 — a secondary endpoint that rejects us every single time must stop being
/// indistinguishable from a healthy one (STEP_75).
///
/// The detector is a pure decision with no I/O, so every case here is deterministic: no database,
/// no clock, no async hop.
final class EndpointRejectionTrackerTests: XCTestCase {

    private let prepaid = DiagnosticsEndpoint.claudePrepaid
    private let usage = DiagnosticsEndpoint.claudeUsage
    private let profile = DiagnosticsEndpoint.claudeProfile
    private let wham = DiagnosticsEndpoint.codexWhamUsage

    private func reject(_ tracker: EndpointRejectionTracker, _ endpoint: String,
                        _ status: Int = 403, tool: Tool = .claude) -> EndpointRejectionOutcome? {
        tracker.record(tool: tool, endpoint: endpoint, httpStatus: status)
    }

    // MARK: - The episode

    /// The shape of the 2026-07-15 field episode: 57 identical 403s must produce **one** row.
    func testFiresOnceOnTheThirdConsecutiveRejection() {
        let tracker = EndpointRejectionTracker()

        XCTAssertNil(reject(tracker, prepaid), "one rejection is ordinary transient noise")
        XCTAssertNil(reject(tracker, prepaid), "two is still not a standing condition")
        XCTAssertEqual(reject(tracker, prepaid), .opened(status: 403, count: 3))

        for occurrence in 4...57 {
            XCTAssertNil(reject(tracker, prepaid),
                         "occurrence \(occurrence) must add no row — the episode already fired")
        }
    }

    func testSuccessClearsTheEpisodeCarryingItsTotal() {
        let tracker = EndpointRejectionTracker()
        for _ in 1...57 { _ = reject(tracker, prepaid) }

        XCTAssertEqual(tracker.record(tool: .claude, endpoint: prepaid, httpStatus: 200),
                       .cleared(status: 200, count: 57),
                       "the clear-row carries every rejection in the episode, not the threshold")
    }

    func testSuccessBeforeTheThresholdWritesNothingAndRearms() {
        let tracker = EndpointRejectionTracker()
        _ = reject(tracker, prepaid)
        _ = reject(tracker, prepaid)

        XCTAssertNil(tracker.record(tool: .claude, endpoint: prepaid, httpStatus: 200),
                     "no episode was ever open, so there is nothing to clear")

        XCTAssertNil(reject(tracker, prepaid))
        XCTAssertNil(reject(tracker, prepaid))
        XCTAssertEqual(reject(tracker, prepaid), .opened(status: 403, count: 3),
                       "the run restarted from the success")
    }

    func testRecoveryThenRelapseOpensASecondEpisode() {
        let tracker = EndpointRejectionTracker()
        for _ in 1...3 { _ = reject(tracker, prepaid) }
        XCTAssertEqual(tracker.record(tool: .claude, endpoint: prepaid, httpStatus: 200),
                       .cleared(status: 200, count: 3))

        XCTAssertNil(reject(tracker, prepaid))
        XCTAssertNil(reject(tracker, prepaid))
        XCTAssertEqual(reject(tracker, prepaid), .opened(status: 403, count: 3),
                       "re-arm on 2xx means a genuine relapse is reported again")
    }

    func testAlternatingFailureAndSuccessNeverFires() {
        let tracker = EndpointRejectionTracker()
        for _ in 1...20 {
            XCTAssertNil(reject(tracker, prepaid))
            XCTAssertNil(tracker.record(tool: .claude, endpoint: prepaid, httpStatus: 200))
        }
    }

    func testADifferentRejectionRestartsTheRun() {
        let tracker = EndpointRejectionTracker()
        _ = reject(tracker, prepaid, 403)
        _ = reject(tracker, prepaid, 403)

        XCTAssertNil(reject(tracker, prepaid, 500),
                     "a different failure is a different condition — it must not inherit the run")
        XCTAssertNil(reject(tracker, prepaid, 500))
        XCTAssertEqual(reject(tracker, prepaid, 500), .opened(status: 500, count: 3))
    }

    // MARK: - Independence

    /// The property the field episode turns on: the quota endpoint kept answering 200 throughout,
    /// and must never have re-armed the broken prepaid one.
    func testEndpointsTrackIndependently() {
        let tracker = EndpointRejectionTracker()
        for _ in 1...2 {
            _ = reject(tracker, prepaid)
            XCTAssertNil(tracker.record(tool: .claude, endpoint: usage, httpStatus: 200))
        }
        XCTAssertEqual(reject(tracker, prepaid), .opened(status: 403, count: 3),
                       "a healthy endpoint polling alongside must not re-arm a broken one")
    }

    func testToolsTrackIndependently() {
        let tracker = EndpointRejectionTracker()
        // Same endpoint string, two tools — the key must separate them.
        for _ in 1...2 {
            XCTAssertNil(tracker.record(tool: .claude, endpoint: profile, httpStatus: 404))
            XCTAssertNil(tracker.record(tool: .codex, endpoint: profile, httpStatus: 404))
        }
        XCTAssertEqual(tracker.record(tool: .claude, endpoint: profile, httpStatus: 404),
                       .opened(status: 404, count: 3))
        XCTAssertEqual(tracker.record(tool: .codex, endpoint: profile, httpStatus: 404),
                       .opened(status: 404, count: 3))
    }

    // MARK: - Statuses another mechanism owns (§9.1 taxonomy discipline)

    func testRateLimitsAreNeverReported() {
        let tracker = EndpointRejectionTracker()
        for endpoint in [usage, prepaid, profile, wham] {
            for _ in 1...5 {
                XCTAssertNil(tracker.record(tool: .claude, endpoint: endpoint, httpStatus: 429),
                             "the §9.3 ladder owns 429 and already records it in this table")
            }
        }
    }

    func testQuotaEndpointAuthFailuresAreNeverReported() {
        let tracker = EndpointRejectionTracker()
        for (tool, endpoint) in [(Tool.claude, usage), (Tool.codex, wham)] {
            for status in [401, 403] {
                for _ in 1...5 {
                    XCTAssertNil(tracker.record(tool: tool, endpoint: endpoint, httpStatus: status),
                                 "the re-auth path owns this and surfaces it as reauthRequired")
                }
            }
        }
    }

    /// The asymmetry that matters: the same status on a *secondary* endpoint is nobody's, which is
    /// exactly the silence this step exists to break — and is the real 2026-07-15 case.
    func testSecondaryEndpointAuthFailuresAreReported() {
        let tracker = EndpointRejectionTracker()
        _ = reject(tracker, prepaid, 403)
        _ = reject(tracker, prepaid, 403)
        XCTAssertEqual(reject(tracker, prepaid, 403), .opened(status: 403, count: 3))

        let other = EndpointRejectionTracker()
        _ = reject(other, profile, 401)
        _ = reject(other, profile, 401)
        XCTAssertEqual(reject(other, profile, 401), .opened(status: 401, count: 3))
    }

    func testAnOwnedStatusNeitherOpensNorClosesAnEpisode() {
        let tracker = EndpointRejectionTracker()
        for _ in 1...3 { _ = reject(tracker, prepaid) }          // episode open, count 3

        XCTAssertNil(tracker.record(tool: .claude, endpoint: prepaid, httpStatus: 429),
                     "a rate-limit says nothing about the standing condition")
        XCTAssertEqual(tracker.record(tool: .claude, endpoint: prepaid, httpStatus: 200),
                       .cleared(status: 200, count: 3),
                       "and it must not have been counted into the episode either")
    }

    // MARK: - Seams with no status

    func testMissingStatusIsIgnored() {
        let tracker = EndpointRejectionTracker()
        for _ in 1...10 {
            XCTAssertNil(tracker.record(tool: .codex, endpoint: "account/read", httpStatus: nil),
                         "the RPC seam has no HTTP status — there is nothing to classify")
        }
    }

    // MARK: - Vocabulary crossing

    func testDiagnosticsEndpointNamesMapToTheHealthTable() {
        XCTAssertEqual(PollHealthEndpoint(diagnosticsEndpoint: usage), .oauthUsage)
        XCTAssertEqual(PollHealthEndpoint(diagnosticsEndpoint: profile), .claudeProfile)
        XCTAssertEqual(PollHealthEndpoint(diagnosticsEndpoint: prepaid), .claudePrepaid)
        XCTAssertEqual(PollHealthEndpoint(diagnosticsEndpoint: wham), .whamUsage)
        XCTAssertNil(PollHealthEndpoint(diagnosticsEndpoint: DiagnosticsEndpoint.claudeOther))
        XCTAssertNil(PollHealthEndpoint(diagnosticsEndpoint: "account/rateLimits/read"))
    }

    func testHistoricalRawValuesAreUnchanged() {
        XCTAssertEqual(PollHealthEndpoint.oauthUsage.rawValue, "oauth_usage",
                       "46 rows in the field carry this value — it must never be renamed")
        XCTAssertEqual(PollHealthEndpoint.whamUsage.rawValue, "wham_usage")
    }
}
