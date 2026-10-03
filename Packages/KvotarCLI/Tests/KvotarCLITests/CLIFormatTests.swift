import XCTest
import Foundation
import KvotarCore
@testable import KvotarCLI

/// STEP_147 (REV-80 / D-101): `kvotar status` prints the same words the popover does for a
/// not-started 5-hour window — a percent (0 used, 100 left) and `no window open`, never
/// `no active window` (which is the provider-sent-nothing case) and never a bare `—`.
final class CLIFormatTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    func testNotStartedWindowTakesTheFiveHourBranchAndSaysNoWindowOpen() {
        let snapshot = QuotaSnapshot(tool: .claude, primaryUsedPct: 0, primaryResetsAt: nil,
                                     primaryWindowSeconds: 18_000,
                                     secondaryUsedPct: 40, secondaryResetsAt: nil,
                                     rateLimitReached: false)
        let window = CLIFormat.displayWindow(snapshot, now: now)
        XCTAssertEqual(window.kind, .fiveHour)
        XCTAssertEqual(window.usedPct, 0)
        XCTAssertTrue(window.notStarted)
        XCTAssertEqual(CLIFormat.detail(window: window, hasSnapshot: true, now: now), "no window open")
    }

    func testAbsentWindowStillSaysNoActiveWindow() {
        let snapshot = QuotaSnapshot(tool: .claude, primaryUsedPct: nil, primaryResetsAt: nil,
                                     secondaryUsedPct: nil, secondaryResetsAt: nil,
                                     rateLimitReached: nil)
        let window = CLIFormat.displayWindow(snapshot, now: now)
        XCTAssertNil(window.kind)
        XCTAssertFalse(window.notStarted)
        XCTAssertEqual(CLIFormat.detail(window: window, hasSnapshot: true, now: now), "no active window")
    }

    func testOpenWindowWithoutResetStillReadsDash() {
        // A real window whose `resets_at` failed to parse: a percent, no reset, no not-started claim.
        let snapshot = QuotaSnapshot(tool: .claude, primaryUsedPct: 12, primaryResetsAt: nil,
                                     primaryWindowSeconds: 18_000,
                                     secondaryUsedPct: nil, secondaryResetsAt: nil,
                                     rateLimitReached: false)
        let window = CLIFormat.displayWindow(snapshot, now: now)
        XCTAssertFalse(window.notStarted)
        XCTAssertEqual(CLIFormat.detail(window: window, hasSnapshot: true, now: now), "—")
    }
}
