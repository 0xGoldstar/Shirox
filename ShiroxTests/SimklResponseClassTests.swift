import XCTest
@testable import Shirox

/// Simkl answers three different 429s that want opposite handling, and a 400 that is a lock
/// rather than a bad request. The status code alone gets every one of them wrong.
final class SimklResponseClassTests: XCTestCase {

    private func classify(_ status: Int, _ body: String, retryAfter: String? = nil) -> SimklFailure {
        SimklLibraryService.classify(status: status, body: Data(body.utf8), retryAfter: retryAfter)
    }

    func testPerSecondLimitIsABriefPause() {
        XCTAssertEqual(classify(429, #"{"error":"rate_limit","code":429}"#), .tooFast)
    }

    /// The daily allowance resets at midnight US Eastern; retrying over seconds cannot clear it.
    func testDailyLimitCarriesRetryAfter() {
        XCTAssertEqual(classify(429, #"{"error":"user_limit_exceeded","code":429}"#, retryAfter: "3600"),
                       .dailyLimit(retryAfter: 3600))
    }

    func testAnUnlabelled429IsTreatedAsTooFast() {
        XCTAssertEqual(classify(429, ""), .tooFast)
    }

    /// Despite the name: another write for this user is still running.
    func testUppercaseRateLimitOn400IsAWriteLock() {
        XCTAssertEqual(classify(400, #"{"error":"RATE_LIMIT"}"#), .writeLocked)
        XCTAssertEqual(classify(400, #"{"error":"bad_request"}"#), .other(400))
    }

    /// Refreshing cannot fix this — only a sign-in that asks for media:write.
    func testInsufficientScopeMeansTheTokenCannotWrite() {
        XCTAssertEqual(classify(403, #"{"error":"insufficient_scope","code":403}"#), .readOnlyToken)
        XCTAssertEqual(classify(403, #"{"error":"forbidden"}"#), .other(403))
    }

    func testClientIdFailureIsReportedByStatus() {
        XCTAssertEqual(classify(412, #"{"error":"client_id_failed","code":412}"#), .other(412))
    }
}
