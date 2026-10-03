import XCTest
@testable import KvotarCore

/// The pace clock's two hands (REV-65 §11.3; `paceElapsedPct` extracted in STEP_110 so the
/// verdict anatomy can show "87% used at 64% of the window" from the same derivation
/// `paceExceeded` fires on — Baseline §19: never two derivations of one fact).
final class QuotaSnapshotPaceClockTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(used: Double?, resetMinutes: Double?, windowSeconds: Int? = nil) -> QuotaSnapshot {
        QuotaSnapshot(tool: .claude, primaryUsedPct: used,
                      primaryResetsAt: resetMinutes.map { now.addingTimeInterval($0 * 60) },
                      primaryWindowSeconds: windowSeconds,
                      secondaryUsedPct: nil, secondaryResetsAt: nil, rateLimitReached: nil)
    }

    func testElapsedIsTheCalendarShareOfTheWindow() {
        // 100 minutes left of a 300-minute window → 200 elapsed → 66.7%.
        let e = snapshot(used: 87, resetMinutes: 100).paceElapsedPct(now: now)
        XCTAssertEqual(e ?? -1, 200.0 / 300.0 * 100, accuracy: 1e-9)
    }

    func testElapsedIsNilWithoutAPopulatedAnchoredWindow() {
        XCTAssertNil(snapshot(used: nil, resetMinutes: 100).paceElapsedPct(now: now))
        XCTAssertNil(snapshot(used: 40, resetMinutes: nil).paceElapsedPct(now: now))
    }

    func testExceededReadsTheSameHand() {
        // Over pace: 87% used at 66.7% elapsed.
        XCTAssertEqual(snapshot(used: 87, resetMinutes: 100).paceExceeded(now: now), true)
        // Under pace: 38% used at 62.7% elapsed.
        XCTAssertEqual(snapshot(used: 38, resetMinutes: 112).paceExceeded(now: now), false)
        // Inside the 2% grace the clock is silent even though used > elapsed — and the elapsed
        // hand still reports the honest 1%, which is what lets the anatomy say "window just
        // started" instead of "under pace".
        let early = snapshot(used: 5, resetMinutes: 297)
        XCTAssertEqual(early.paceExceeded(now: now), false)
        XCTAssertEqual(early.paceElapsedPct(now: now) ?? -1, 1, accuracy: 1e-9)
        // No window → no claim, on both hands.
        XCTAssertNil(snapshot(used: 40, resetMinutes: nil).paceExceeded(now: now))
    }

    func testElapsedFollowsTheReportedWidth() {
        // Weekly window, 6 days to go → 1/7 elapsed.
        let e = snapshot(used: 7, resetMinutes: 6 * 1440, windowSeconds: 604_800).paceElapsedPct(now: now)
        XCTAssertEqual(e ?? -1, 100.0 / 7.0, accuracy: 1e-9)
    }
}
