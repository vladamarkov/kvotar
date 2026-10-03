import XCTest
@testable import KvotarCore

/// REV-32 (STEP_38): startup network-retry ladder — 15s → 45s → 120s → 300s for network-shaped
/// startup failures only; never 429s (§9.1 taxonomy discipline).
final class StartupRetryPolicyTests: XCTestCase {

    func testRungsInOrderThenExhausted() {
        var policy = StartupRetryPolicy()
        XCTAssertEqual(policy.networkFailureDelay(), 15)
        XCTAssertEqual(policy.networkFailureDelay(), 45)
        XCTAssertEqual(policy.networkFailureDelay(), 120)
        XCTAssertEqual(policy.networkFailureDelay(), 300)
        XCTAssertNil(policy.networkFailureDelay(),
                     "four rungs exhausted → clear to normal cadence")
    }

    func testSuccessEndsTheStartupWindow() {
        var policy = StartupRetryPolicy()
        _ = policy.networkFailureDelay()
        policy.succeeded()
        XCTAssertNil(policy.networkFailureDelay(),
                     "after the first successful poll a network failure rides normal cadence")
    }

    func testRateLimitedIsNeverNetworkShaped() {
        let details = RateLimit429Details(statusCode: 429, headers: [:], body: nil,
                                          category: "rate_pressure")
        XCTAssertFalse(StartupRetryPolicy.isNetworkShaped(
            AccountAdapterError.rateLimited(retryAfter: 60, details: details)),
            "a 429 at launch must never enter the ladder — rate-shaped and network-shaped "
            + "failures never share one (§9.1)")
    }

    func testCancellationIsNotRetryable() {
        XCTAssertFalse(StartupRetryPolicy.isNetworkShaped(URLError(.cancelled)))
    }

    func testHTTPAndDecodeErrorsAreNotNetworkShaped() {
        XCTAssertFalse(StartupRetryPolicy.isNetworkShaped(AccountAdapterError.httpStatus(500)))
        XCTAssertFalse(StartupRetryPolicy.isNetworkShaped(AccountAdapterError.decoding("bad")))
    }

    func testTransientNetworkErrorsAreNetworkShaped() {
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed] {
            XCTAssertTrue(StartupRetryPolicy.isNetworkShaped(URLError(code)),
                          "\(code) is a transient network-shaped startup failure")
        }
    }
}
