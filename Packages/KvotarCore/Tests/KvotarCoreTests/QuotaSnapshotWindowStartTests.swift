import XCTest
@testable import KvotarCore

/// The one window-start derivation (REV-60 — STEP_90). Six sites used to subtract their own
/// hardcoded five hours; this is the single place that answers "when did this window begin", and
/// it answers from the width the provider reported.
final class QuotaSnapshotWindowStartTests: XCTestCase {

    private let resetsAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(tool: Tool, windowSeconds: Int?) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, primaryUsedPct: 50, primaryResetsAt: resetsAt,
                      primaryWindowSeconds: windowSeconds,
                      secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: nil)
    }

    /// Claude reports no width and its windows genuinely are five hours — the fallback is right
    /// here, which is why this went unnoticed for as long as it did.
    func testAbsentWidthFallsBackToFiveHours() {
        let s = snapshot(tool: .claude, windowSeconds: nil)
        XCTAssertEqual(s.primaryWindowLength, 18_000, accuracy: 1e-9)
        XCTAssertEqual(s.primaryWindowStart, resetsAt.addingTimeInterval(-18_000))
    }

    /// A 300-minute Codex window must land byte-identically on the fallback's answer.
    func testThreeHundredMinuteWindowMatchesTheFallback() {
        let s = snapshot(tool: .codex, windowSeconds: 300 * 60)
        XCTAssertEqual(s.primaryWindowStart, resetsAt.addingTimeInterval(-18_000))
    }

    /// The live `go` shape: 43,200 minutes. Pre-REV-60 this start came out a month *after* the
    /// window it describes, so nothing could fall inside it.
    func testMonthWideWindowStartsAMonthBeforeItsReset() {
        let s = snapshot(tool: .codex, windowSeconds: 43_200 * 60)
        XCTAssertEqual(s.primaryWindowLength, 2_592_000, accuracy: 1e-9)
        XCTAssertEqual(s.primaryWindowStart, resetsAt.addingTimeInterval(-2_592_000))
        XCTAssertLessThan(try XCTUnwrap(s.primaryWindowStart), resetsAt)
    }

    /// A weekly window — the third width the corpus carries.
    func testWeeklyWindow() {
        let s = snapshot(tool: .codex, windowSeconds: 10_080 * 60)
        XCTAssertEqual(s.primaryWindowStart, resetsAt.addingTimeInterval(-604_800))
    }

    /// No anchor, no start — the null/unanchored window the attribution and off-machine paths
    /// read as "nothing to anchor to".
    func testNullWindowHasNoStart() {
        let s = QuotaSnapshot(tool: .codex, primaryUsedPct: 0, primaryResetsAt: nil,
                              primaryWindowSeconds: 43_200 * 60,
                              secondaryUsedPct: nil, secondaryResetsAt: nil,
                              rateLimitReached: nil)
        XCTAssertNil(s.primaryWindowStart)
    }
}
