import XCTest
@testable import KvotarCore

/// STEP_26 — the burn-tier-crossing delta signal (Baseline §13.1) and the shared quota-429
/// marker test. Thresholds are provisional tok/min values (see `BurnTierTracker`).
final class BurnTierTrackerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testCrossingUpFiresOnce() {
        var tracker = BurnTierTracker()
        // 10k tokens over the 2-min window → 5k tok/min → high. none→high crosses.
        XCTAssertTrue(tracker.record(tokens: 10_000, at: t0))
        // Same tier on the next flush → no crossing.
        XCTAssertFalse(tracker.record(tokens: 10_000, at: t0.addingTimeInterval(5)))
    }

    func testNoCrossingWhileIdle() {
        var tracker = BurnTierTracker()
        XCTAssertFalse(tracker.record(tokens: 0, at: t0), "none→none is not a crossing")
        // 100 tokens over 2 min = 50 tok/min — below the low floor (100 tok/min) → still none.
        XCTAssertFalse(tracker.record(tokens: 100, at: t0.addingTimeInterval(5)))
    }

    func testCrossingDownFiresWhenWindowDrains() {
        var tracker = BurnTierTracker()
        XCTAssertTrue(tracker.record(tokens: 10_000, at: t0))                            // none→high
        // 3 minutes later the burst has left the 2-min window → back to none.
        XCTAssertTrue(tracker.record(tokens: 0, at: t0.addingTimeInterval(180)))         // high→none
    }

    func testIntermediateTierBoundaries() {
        var tracker = BurnTierTracker()
        // 1k tokens / 2 min = 500 tok/min → low.
        XCTAssertTrue(tracker.record(tokens: 1_000, at: t0))                             // none→low
        // +3k in-window → 4k total → 2k tok/min → mid.
        XCTAssertTrue(tracker.record(tokens: 3_000, at: t0.addingTimeInterval(10)))      // low→mid
        // +100 → 4.1k → 2.05k tok/min → still mid.
        XCTAssertFalse(tracker.record(tokens: 100, at: t0.addingTimeInterval(20)))
    }

    // MARK: Quota-429 marker (shared by both parsers' detectors — working-assumption shapes)

    func testQuotaLimitMarkerMatches() {
        XCTAssertTrue(Quota429Observation.lineContainsQuotaLimitMarker(
            #"{"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Claude AI usage limit reached|1800000000"}]}}"#))
        XCTAssertTrue(Quota429Observation.lineContainsQuotaLimitMarker(
            #"{"type":"error","payload":{"message":"Rate limit exceeded (429)"}}"#))
        XCTAssertTrue(Quota429Observation.lineContainsQuotaLimitMarker(
            #"{"payload":{"type":"error","message":"usage_limit_reached"}}"#))
    }

    func testQuotaLimitMarkerRejectsOrdinaryErrors() {
        XCTAssertFalse(Quota429Observation.lineContainsQuotaLimitMarker(
            #"{"isApiErrorMessage":true,"message":"invalid api key"}"#))
        XCTAssertFalse(Quota429Observation.lineContainsQuotaLimitMarker(
            #"{"type":"error","payload":{"message":"connection reset"}}"#))
    }
}
