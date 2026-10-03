import XCTest
@testable import KvotarCore

/// `WindowFact.fold` — the detector's moments become the facts §4.1a tells (STEP_146).
final class WindowFactTests: XCTestCase {

    /// The 2026-08-25 Codex restructuring: the detector wrote `window_added` (secondary, weekly)
    /// **and** `window_width_changed` (primary, 7 d → 5 h) in one poll, in that order. One fact.
    func testASameInstantWidthChangeAndWindowAddedFoldToOneRestructuring() {
        let moments = [
            DiscontinuityObservation(eventType: .windowAdded, windowType: "weekly",
                                     oldValue: nil, newValue: "604800"),
            DiscontinuityObservation(eventType: .windowWidthChanged, windowType: "five_hour",
                                     oldValue: "604800", newValue: "18000"),
        ]
        XCTAssertEqual(WindowFact.fold(moments),
                       [WindowFact(kind: .restructured, before: [604_800],
                                   after: [18_000, 604_800])])
    }

    func testLoneFactsFoldToThemselvesAndEarlyResetIsNotOne() {
        XCTAssertEqual(WindowFact.fold([
            DiscontinuityObservation(eventType: .windowRemoved, windowType: "five_hour",
                                     oldValue: "18000", newValue: nil),
        ]), [WindowFact(kind: .removed, before: [18_000])])
        XCTAssertEqual(WindowFact.fold([
            DiscontinuityObservation(eventType: .windowAdded, windowType: "weekly",
                                     oldValue: nil, newValue: "604800"),
        ]), [WindowFact(kind: .added, after: [604_800])])
        XCTAssertEqual(WindowFact.fold([
            DiscontinuityObservation(eventType: .windowWidthChanged, windowType: "5_day",
                                     oldValue: "604800", newValue: "432000"),
        ]), [WindowFact(kind: .widthChanged, before: [604_800], after: [432_000])])
        XCTAssertEqual(WindowFact.fold([
            DiscontinuityObservation(eventType: .earlyReset, windowType: "weekly"),
            DiscontinuityObservation(eventType: .planChanged, oldValue: "go", newValue: "plus"),
        ]), [])
    }
}
