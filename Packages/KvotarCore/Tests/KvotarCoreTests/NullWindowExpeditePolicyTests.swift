import XCTest
@testable import KvotarCore

final class NullWindowExpeditePolicyTests: XCTestCase {

    private let base = PollBackoffPolicy.defaultBase
    private let cold = NullWindowExpeditePolicy.coldGap + 1
    private let warm = NullWindowExpeditePolicy.coldGap - 1

    /// The live 2026-07-16 case: first poll after a long sleep returns a null 5-hour window at
    /// 09:31:10, the window has populated to 2% by 09:36:12, and the app showed nothing for the
    /// whole gap. One quick look at +45s, then back to base — never a loop.
    func testColdNullWindowEarnsExactlyOneExpeditedPoll() {
        var policy = NullWindowExpeditePolicy()
        XCTAssertEqual(policy.expediteDelay(primaryWindowIsNull: true,
                                            gapSinceLastSuccess: cold,
                                            plannedDelay: base),
                       PollBackoffPolicy.minInterval)
        XCTAssertNil(policy.expediteDelay(primaryWindowIsNull: true,
                                          gapSinceLastSuccess: PollBackoffPolicy.minInterval,
                                          plannedDelay: base),
                     "still null after the expedite ⇒ fall back to base, don't poll in a loop")
        XCTAssertNil(policy.expediteDelay(primaryWindowIsNull: true,
                                          gapSinceLastSuccess: base,
                                          plannedDelay: base),
                     "and it stays spent for the rest of the hiatus")
    }

    func testWarmNullWindowIsNotExpedited() {
        var policy = NullWindowExpeditePolicy()
        XCTAssertNil(policy.expediteDelay(primaryWindowIsNull: true,
                                          gapSinceLastSuccess: warm,
                                          plannedDelay: base),
                     "a null window on a warm poll is an idle account, not a wake")
    }

    func testFirstEverPollIsNotAWake() {
        var policy = NullWindowExpeditePolicy()
        XCTAssertNil(policy.expediteDelay(primaryWindowIsNull: true,
                                          gapSinceLastSuccess: nil,
                                          plannedDelay: base),
                     "no previous success ⇒ nothing to be cold relative to (STEP_42's rule)")
    }

    func testPopulatedWindowDisarmsAndReArms() {
        var policy = NullWindowExpeditePolicy()
        _ = policy.expediteDelay(primaryWindowIsNull: true, gapSinceLastSuccess: cold,
                                 plannedDelay: base)
        XCTAssertNil(policy.expediteDelay(primaryWindowIsNull: false,
                                          gapSinceLastSuccess: PollBackoffPolicy.minInterval,
                                          plannedDelay: base),
                     "a populated window ends the hiatus")
        XCTAssertEqual(policy.expediteDelay(primaryWindowIsNull: true,
                                            gapSinceLastSuccess: cold,
                                            plannedDelay: base),
                       PollBackoffPolicy.minInterval,
                       "the next hiatus gets its own full allowance")
    }

    func testNoExpediteWhenTheLoopIsAlreadyGoingBackSooner() {
        var policy = NullWindowExpeditePolicy()
        XCTAssertNil(policy.expediteDelay(primaryWindowIsNull: true,
                                          gapSinceLastSuccess: cold,
                                          plannedDelay: 30),
                     "nothing to expedite — and the allowance is not spent")
        XCTAssertEqual(policy.expediteDelay(primaryWindowIsNull: true,
                                            gapSinceLastSuccess: cold,
                                            plannedDelay: base),
                       PollBackoffPolicy.minInterval)
    }

    /// §9.1 taxonomy discipline: this is state-shaped. It observes a window, never a status code,
    /// and it has no way to see or touch the 429 ladder — the type simply has no such input.
    func testNeverRidesTheRateLimitLadder() {
        var policy = NullWindowExpeditePolicy()
        XCTAssertNil(policy.expediteDelay(primaryWindowIsNull: false,
                                          gapSinceLastSuccess: cold,
                                          plannedDelay: base),
                     "a cold poll that returned a window is simply not this policy's business")
    }
}
