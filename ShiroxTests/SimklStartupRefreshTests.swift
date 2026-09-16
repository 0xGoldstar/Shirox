import XCTest
@testable import Shirox

/// Simkl asks mobile apps to sync on startup or wake, throttled to once every 15-30 minutes, and
/// never to run unconditional polling timers. The throttle is the part worth pinning: an app that
/// re-checks on every activation is the "rapid-switch spam" their policy names.
final class SimklStartupRefreshTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstLaunchAlwaysChecks() {
        XCTAssertTrue(SimklLibraryService.shouldCheck(lastCheck: nil, now: now))
    }

    func testARecentCheckIsSkipped() {
        let fiveMinutesAgo = now.addingTimeInterval(-5 * 60)
        XCTAssertFalse(SimklLibraryService.shouldCheck(lastCheck: fiveMinutesAgo, now: now))
    }

    func testCheckingResumesAfterTheInterval() {
        let thirtyOneMinutesAgo = now.addingTimeInterval(-31 * 60)
        XCTAssertTrue(SimklLibraryService.shouldCheck(lastCheck: thirtyOneMinutesAgo, now: now))
    }

    /// Exactly on the boundary counts as due, so a fixed-interval wake is never starved.
    func testTheBoundaryItselfIsDue() {
        let exactly = now.addingTimeInterval(-SimklLibraryService.minimumCheckInterval)
        XCTAssertTrue(SimklLibraryService.shouldCheck(lastCheck: exactly, now: now))
    }

    /// A clock that jumps backwards must not unlock a check every activation.
    func testAFutureTimestampDoesNotUnlockChecking() {
        let future = now.addingTimeInterval(60 * 60)
        XCTAssertFalse(SimklLibraryService.shouldCheck(lastCheck: future, now: now))
    }

    /// The interval sits inside the window their policy asks for.
    func testIntervalMatchesSimklsGuidance() {
        XCTAssertGreaterThanOrEqual(SimklLibraryService.minimumCheckInterval, 15 * 60)
        XCTAssertLessThanOrEqual(SimklLibraryService.minimumCheckInterval, 30 * 60)
    }
}
