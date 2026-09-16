import XCTest
@testable import Shirox

/// Simkl's developer on when to call the activities endpoint: "usually after app goes into
/// background for 30 minutes or on pull to refresh check activity — don't spam activity endpoint
/// unnecessarily, will use user requests."
///
/// That last clause is what these guard: activity checks are charged to the user's own request
/// budget, so an app that checks on every activation is spending something that isn't its own.
final class SimklActivationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private func shouldCheck(backgroundedAt: Date?, lastCheck: Date?) -> Bool {
        SimklLibraryService.shouldCheckOnActivation(
            backgroundedAt: backgroundedAt, lastCheck: lastCheck, now: now)
    }

    /// A first run, or an account just connected, has nothing to compare against.
    func testNeverCheckedAlwaysChecks() {
        XCTAssertTrue(shouldCheck(backgroundedAt: nil, lastCheck: nil))
        XCTAssertTrue(shouldCheck(backgroundedAt: ago(1), lastCheck: nil))
    }

    /// THE ONE THAT MATTERS: flicking away and straight back must not spend a request.
    func testReturningAfterAMomentDoesNotCheck() {
        XCTAssertFalse(shouldCheck(backgroundedAt: ago(2), lastCheck: ago(120)),
                       "away 2 minutes is the rapid-switch case, however old the last check is")
    }

    func testReturningAfterThirtyMinutesChecks() {
        XCTAssertTrue(shouldCheck(backgroundedAt: ago(31), lastCheck: ago(31)))
    }

    /// Exactly on the boundary counts as away long enough.
    func testTheBoundaryItselfChecks() {
        XCTAssertTrue(shouldCheck(backgroundedAt: ago(30), lastCheck: ago(30)))
    }

    /// Away time wins over time-since-last-check. An app open all day then backgrounded briefly
    /// has a very old last check, and still must not check on return.
    func testAwayTimeDecidesNotTimeSinceLastCheck() {
        XCTAssertFalse(shouldCheck(backgroundedAt: ago(1), lastCheck: ago(600)))
    }

    /// A cold launch with no background marker falls back to time since the last check.
    func testColdLaunchWithoutABackgroundMarkerUsesLastCheck() {
        XCTAssertFalse(shouldCheck(backgroundedAt: nil, lastCheck: ago(5)))
        XCTAssertTrue(shouldCheck(backgroundedAt: nil, lastCheck: ago(45)))
    }

    /// A clock that jumps backwards must not unlock a check on every activation.
    func testAFutureTimestampDoesNotUnlockChecking() {
        XCTAssertFalse(shouldCheck(backgroundedAt: now.addingTimeInterval(3600), lastCheck: ago(600)))
    }

    /// The interval matches what their developer asked for.
    func testIntervalIsThirtyMinutes() {
        XCTAssertEqual(SimklLibraryService.minimumAwayInterval, 30 * 60)
    }
}
