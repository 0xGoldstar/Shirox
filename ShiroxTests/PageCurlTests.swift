#if os(iOS)
import XCTest
import UIKit
@testable import Shirox

final class PageCurlTests: XCTestCase {

    /// Right to left binds the page at the right edge, so it curls from the left as a manga turns.
    func testRightToLeftPutsTheSpineOnTheRight() {
        XCTAssertEqual(PageCurl.spineLocation(rightToLeft: true), .max)
        XCTAssertEqual(PageCurl.spineLocation(rightToLeft: false), .min)
    }

    /// Pages stay in reading order in both directions; only the spine moves.
    func testNeighboursFollowReadingOrder() {
        let ids = [10, 11, 12]
        XCTAssertEqual(PageCurl.neighbor(of: 11, offset: 1, in: ids), 12)
        XCTAssertEqual(PageCurl.neighbor(of: 11, offset: -1, in: ids), 10)
        XCTAssertNil(PageCurl.neighbor(of: 12, offset: 1, in: ids))
        XCTAssertNil(PageCurl.neighbor(of: 10, offset: -1, in: ids))
        XCTAssertNil(PageCurl.neighbor(of: 99, offset: 1, in: ids))
    }

    /// Left to right turns forward with a leftward swipe; right to left with a rightward one.
    func testASwipesDirectionFollowsTheSpine() {
        XCTAssertTrue(PageCurl.isForward(velocityX: -300, rightToLeft: false))
        XCTAssertFalse(PageCurl.isForward(velocityX: 300, rightToLeft: false))
        XCTAssertTrue(PageCurl.isForward(velocityX: 300, rightToLeft: true))
        XCTAssertFalse(PageCurl.isForward(velocityX: -300, rightToLeft: true))
    }

    /// The crash: a swipe back on the first page, or on past the last, asked UIKit to turn to no
    /// page — "The number of view controllers provided (0) doesn't match the number required (1)".
    func testThereIsNoTurnPastEitherEnd() {
        let ids = [10, 11, 12]
        XCTAssertFalse(PageCurl.canTurn(from: 10, forward: false, in: ids))
        XCTAssertFalse(PageCurl.canTurn(from: 12, forward: true, in: ids))
        XCTAssertTrue(PageCurl.canTurn(from: 11, forward: true, in: ids))
        XCTAssertTrue(PageCurl.canTurn(from: 11, forward: false, in: ids))
        XCTAssertFalse(PageCurl.canTurn(from: nil, forward: true, in: ids), "no page on screen yet")
    }
}

final class PageCurlGestureDelegateTests: XCTestCase {
    /// Why the pager forwards to the delegate it replaces: UIKit makes the page view controller the
    /// delegate of its own curl gestures, and that is where it checks there's a page to turn to.
    @MainActor
    func testUIKitAnswersTheCurlsGesturesItself() {
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        XCTAssertFalse(controller.gestureRecognizers.isEmpty)
        for recognizer in controller.gestureRecognizers {
            XCTAssertTrue(recognizer.delegate === controller)
        }
    }
}
#endif

