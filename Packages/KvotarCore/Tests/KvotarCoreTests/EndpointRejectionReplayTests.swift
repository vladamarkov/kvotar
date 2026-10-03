import XCTest
@testable import KvotarCore

/// Replay of the real field episode this step exists for (STEP_75).
///
/// Source: the first tester diagnostics bundle, `AgentPilot-diagnostics-20260722-1712-0.1.3-4-beta`
/// (2026-07-15/16, Claude Enterprise). Its `agentpilot.3.log` holds 124 successful quota polls and
/// **57 prepaid 403s** — the Pro/Max-only endpoint that hard-403s on Enterprise — logged at INFO
/// with nothing escalating anywhere. It took a human reading a week of logs to find it.
///
/// The bundle lives outside the repository and carries a tester's data, so it is not committed and
/// this test is skipped unless it is present. Run with:
///
///     KVOTAR_LIVE=1 swift test --filter EndpointRejectionReplayTests
///
/// Override the path with `KVOTAR_BUNDLE_LOG` to replay a different bundle.
final class EndpointRejectionReplayTests: XCTestCase {

    private static let defaultLogPath = NSString(string:
        "~/Downloads/AgentPilot-diagnostics-20260722-1712-0.1.3-4-beta/logs/agentpilot.3.log")
        .expandingTildeInPath

    /// One reconstructed response: the endpoint it came from, its status, and when it happened.
    private struct Observation {
        let timestamp: String
        let endpoint: String
        let status: Int
    }

    /// Only failures are logged verbatim, so a successful quota poll is reconstructed from the
    /// adapter's own completion line. That is enough for this test's purpose: it proves the
    /// interleaved 200s on a *healthy* endpoint never re-arm the broken one.
    private func parse(_ log: String) -> [Observation] {
        var observations: [Observation] = []
        for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            guard let timestamp = text.split(separator: " ").first.map(String.init) else { continue }

            if text.contains("prepaid endpoint non-2xx") {
                guard let marker = text.range(of: "status=") else { continue }
                let status = Int(text[marker.upperBound...].prefix { $0.isNumber }) ?? 0
                observations.append(Observation(timestamp: timestamp,
                                                endpoint: DiagnosticsEndpoint.claudePrepaid,
                                                status: status))
            } else if text.contains("[ClaudeAccountAdapter] Claude poll complete") {
                observations.append(Observation(timestamp: timestamp,
                                                endpoint: DiagnosticsEndpoint.claudeUsage,
                                                status: 200))
            }
        }
        return observations
    }

    func testTheFieldEpisodeWouldHaveFiredOnDayOne() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KVOTAR_LIVE"] == "1",
                          "set KVOTAR_LIVE=1 to replay the tester bundle")
        let path = ProcessInfo.processInfo.environment["KVOTAR_BUNDLE_LOG"]
            ?? Self.defaultLogPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                          "bundle not present at \(path)")

        let observations = parse(try String(contentsOfFile: path, encoding: .utf8))
        let rejections = observations.filter { $0.endpoint == DiagnosticsEndpoint.claudePrepaid }
        let successes = observations.filter { $0.endpoint == DiagnosticsEndpoint.claudeUsage }
        XCTAssertEqual(rejections.count, 57, "the bundle's 57 prepaid 403s")
        XCTAssertEqual(successes.count, 124, "…across 124 successful quota polls")

        let tracker = EndpointRejectionTracker()
        var opened: [(String, EndpointRejectionOutcome)] = []
        var cleared: [(String, EndpointRejectionOutcome)] = []
        for observation in observations {
            guard let outcome = tracker.record(tool: .claude, endpoint: observation.endpoint,
                                               httpStatus: observation.status) else { continue }
            switch outcome {
            case .opened: opened.append((observation.timestamp, outcome))
            case .cleared: cleared.append((observation.timestamp, outcome))
            }
        }

        // 57 occurrences, one row. The interleaved quota-endpoint 200s do not re-arm it, and the
        // quota endpoint itself never fires — every one of its responses was healthy.
        XCTAssertEqual(opened.count, 1, "one row from 57 identical rejections")
        XCTAssertEqual(opened.first?.1, .opened(status: 403, count: 3))
        XCTAssertEqual(opened.first?.0, "2026-07-15T13:03:34.516Z",
                       "detected at the 3rd rejection — 60 minutes in, against the week it took")

        // No clear-row: on Enterprise that endpoint hard-403s and never recovered inside the
        // bundle (the 07-17 upgrade removed the call rather than fixing it). An episode that never
        // clears writes one row, not two — two is the per-episode *bound*.
        XCTAssertTrue(cleared.isEmpty, "the endpoint never returned 2xx in this window")

        // The other half of the pair, exercised on the same real sequence: had the tester's upgrade
        // made the endpoint answer instead of removing it, recovery closes the episode with its
        // true occurrence count.
        XCTAssertEqual(tracker.record(tool: .claude, endpoint: DiagnosticsEndpoint.claudePrepaid,
                                      httpStatus: 200),
                       .cleared(status: 200, count: 57))
    }
}
