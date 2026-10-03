import XCTest
@testable import KvotarCore

/// REV-15 (STEP_27): first-launch persistent-429 grace window.
final class FirstPollGracePolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFirstRateLimitDoesNotFallBack() {
        var policy = FirstPollGracePolicy()
        XCTAssertFalse(policy.rateLimited(tool: .claude, now: t0),
                       "the endpoint routinely 429s the very first poll and recovers in seconds — "
                       + "must not flash the fallback card")
    }

    func testFallsBackOnceGraceElapses() {
        var policy = FirstPollGracePolicy(grace: 600)
        XCTAssertFalse(policy.rateLimited(tool: .claude, now: t0))
        XCTAssertFalse(policy.rateLimited(tool: .claude, now: t0.addingTimeInterval(599)))
        XCTAssertTrue(policy.rateLimited(tool: .claude, now: t0.addingTimeInterval(600)),
                      "10 min of 429s with no success → Idle/fallback (mirrors the §9.3 TTL)")
        XCTAssertTrue(policy.rateLimited(tool: .claude, now: t0.addingTimeInterval(900)),
                      "stays fallen-back while the throttle persists")
    }

    func testSuccessResetsTheWindow() {
        var policy = FirstPollGracePolicy(grace: 600)
        _ = policy.rateLimited(tool: .claude, now: t0)
        policy.succeeded(tool: .claude)
        XCTAssertFalse(policy.rateLimited(tool: .claude, now: t0.addingTimeInterval(700)),
                       "a success clears the window — a later throttle episode starts fresh")
    }

    func testToolsAreIndependent() {
        var policy = FirstPollGracePolicy(grace: 600)
        _ = policy.rateLimited(tool: .claude, now: t0)
        XCTAssertFalse(policy.rateLimited(tool: .codex, now: t0.addingTimeInterval(650)),
                       "Codex's window starts at its own first 429, not Claude's")
        XCTAssertTrue(policy.rateLimited(tool: .claude, now: t0.addingTimeInterval(650)))
    }
}
