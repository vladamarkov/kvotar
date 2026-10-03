import XCTest
import Foundation
import KvotarCore
@testable import KvotarCLI

// STEP_140 (REV-77 / D-97): the CLI human status column prints **remaining**, like every app
// surface; the JSON `utilization_pct` field keeps its name and its used-based meaning — the
// machine contract (REV-77 §8, no `remaining_pct` added).
final class StatusRenderTests: XCTestCase {

    private func row(usedPct: Double?) -> StatusReport.Row {
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        let snapshot = usedPct.map {
            QuotaSnapshot(tool: .claude, primaryUsedPct: $0,
                          primaryResetsAt: now.addingTimeInterval(3_600),
                          secondaryUsedPct: nil, secondaryResetsAt: nil,
                          rateLimitReached: false)
        }
        let status = ToolStatus(tool: .claude, snapshot: snapshot, polledAt: now,
                                state: .healthy, isStale: false)
        return StatusReport.Row(from: status, now: now)
    }

    func testHumanColumnPrintsRemaining() {
        XCTAssertEqual(row(usedPct: 58).utilText, "42%")
        XCTAssertEqual(row(usedPct: 0).utilText, "100%")
        XCTAssertEqual(row(usedPct: 106).utilText, "0%", "over quota floors at 0% left")
        XCTAssertEqual(row(usedPct: nil).utilText, "––", "nil placeholder unchanged")
    }

    func testJSONKeepsUsedBasedUtilization() throws {
        let report = StatusReport.ok(rows: [row(usedPct: 58)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(report), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"utilization_pct\":58"), json)
        XCTAssertFalse(json.contains("remaining_pct"), "no new JSON field — machine contract")
        XCTAssertFalse(json.contains("utilText"), "human cells stay out of the JSON")
    }
}
