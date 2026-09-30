#if os(iOS)
import XCTest
import UIKit
import SwiftUI
@testable import Shirox

final class PageCurlTests: XCTestCase {

    /// Right to left binds the page at the right edge, so it curls from the left as a manga turns.
    func testRightToLeftPutsTheSpineOnTheRight() {
        XCTAssertEqual(PageCurl.spineLocation(rightToLeft: true), .max)
        XCTAssertEqual(PageCurl.spineLocation(rightToLeft: false), .min)
    }

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

    // MARK: - UIKit's side of a curl

    /// UIKit asks for the page "after" on a leftward swipe and "before" on a rightward one — with
    /// the spine on either side, wherever the page is grabbed (driven through its own pan handler).
    /// Right to left reads the other way, so there its "before" is the next page.
    func testUIKitsBeforeAndAfterMapToReadingOrder() {
        XCTAssertEqual(PageCurl.readingOffset(uikitAfter: true, rightToLeft: false), 1)
        XCTAssertEqual(PageCurl.readingOffset(uikitAfter: false, rightToLeft: false), -1)
        XCTAssertEqual(PageCurl.readingOffset(uikitAfter: false, rightToLeft: true), 1,
                       "right to left, a swipe right turns to the next page")
        XCTAssertEqual(PageCurl.readingOffset(uikitAfter: true, rightToLeft: true), -1)
    }

    // MARK: - Starting a curl

    private let ids = [10, 11, 12]

    private func canBegin(from id: Int, velocityX: CGFloat, translationX: CGFloat,
                          rightToLeft: Bool = false) -> Bool {
        PageCurl.canBeginCurl(from: id, velocityX: velocityX, translationX: translationX,
                              rightToLeft: rightToLeft, in: ids)
    }

    /// The crash, right to left: a swipe right on the first page, meant for the next one. The pager
    /// took it for forward; UIKit turned it back — to no page. "The number of view controllers
    /// provided (0) doesn't match the number required (1) for the requested transition".
    func testRightToLeftASwipeRightOnTheFirstPageTurnsForward() {
        XCTAssertTrue(canBegin(from: 10, velocityX: 500, translationX: 12, rightToLeft: true))
        XCTAssertFalse(canBegin(from: 10, velocityX: -500, translationX: -12, rightToLeft: true))
    }

    func testLeftToRightASwipeLeftOnTheFirstPageTurnsForward() {
        XCTAssertTrue(canBegin(from: 10, velocityX: -500, translationX: -12))
        XCTAssertFalse(canBegin(from: 10, velocityX: 500, translationX: 12))
    }

    func testOnTheLastPageOnlyTurningBackStarts() {
        XCTAssertFalse(canBegin(from: 12, velocityX: -500, translationX: -12))
        XCTAssertTrue(canBegin(from: 12, velocityX: 500, translationX: 12))
        XCTAssertFalse(canBegin(from: 12, velocityX: 500, translationX: 12, rightToLeft: true))
    }

    /// Motion one way and distance the other — a finger that doubled back — must both be possible.
    func testMotionAndDistanceMustBothHaveAPage() {
        XCTAssertFalse(canBegin(from: 10, velocityX: -500, translationX: 6))
        XCTAssertTrue(canBegin(from: 11, velocityX: -500, translationX: 6))
    }

    /// A pan that hasn't moved says nothing about where it's going, so it needs a page both ways.
    func testAStillPanStartsOnlyWithAPageBothWays() {
        XCTAssertTrue(canBegin(from: 11, velocityX: 0, translationX: 0))
        XCTAssertFalse(canBegin(from: 10, velocityX: 0, translationX: 0))
    }
}

/// The pager over a turn, driven the way UIKit drives it: the delegate hears the turn begin, the
/// page view controller already reports the incoming page, and the reader re-renders meanwhile —
/// it does, constantly, as pages warm and progress saves.
@MainActor
final class PageCurlPagerTurnTests: XCTestCase {

    final class Model: ObservableObject {
        @Published var current = 0
        /// Stands for anything else in the reader that re-renders it.
        @Published var unrelated = 0
    }

    struct Harness: View {
        @ObservedObject var model: Model
        var body: some View {
            // The reader's page closure captures the reader itself, so every re-render hands the
            // pager a new one and SwiftUI updates it; capturing state here does the same.
            let unrelated = model.unrelated
            PageCurlPager(pageIDs: [0, 1, 2, 3, 4], current: $model.current, rightToLeft: false) { id, _ in
                Text("\(id) \(unrelated)")
            }
        }
    }

    private var window: UIWindow!
    private var model: Model!
    private var pager: UIPageViewController!

    override func setUp() async throws {
        model = Model()
        let host = UIHostingController(rootView: Harness(model: model))
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        flush()
        pager = Self.find(UIPageViewController.self, in: host)
        XCTAssertNotNil(pager)
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
    }

    private func flush() {
        window.rootViewController?.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private var shown: Int? { (pager.viewControllers?.first as? CurlPageHost)?.pageID }

    /// UIKit starts a curl to the next page: it tells the delegate, and from then on the page view
    /// controller reports the incoming page as the one it shows.
    private func beginTurnForward() -> (previous: UIViewController, pending: UIViewController) {
        let previous = pager.viewControllers!.first!
        let pending = pager.dataSource!.pageViewController(pager, viewControllerAfter: previous)!
        pager.delegate?.pageViewController?(pager, willTransitionTo: [pending])
        pager.setViewControllers([pending], direction: .forward, animated: false)
        return (previous, pending)
    }

    func testAReRenderMidTurnLeavesTheTurningPageAlone() {
        XCTAssertEqual(shown, 0)
        let turn = beginTurnForward()

        model.unrelated += 1
        flush()
        XCTAssertEqual(shown, 1, "a re-render mid-curl yanked the page back to the one being turned away from")

        pager.delegate?.pageViewController?(pager, didFinishAnimating: true,
                                            previousViewControllers: [turn.previous], transitionCompleted: true)
        flush()
        XCTAssertEqual(model.current, 1)
        XCTAssertEqual(shown, 1)
    }

    func testACancelledTurnStaysOnItsPage() {
        let turn = beginTurnForward()
        // The finger lets go short of the turn: UIKit puts the page back and says so.
        pager.setViewControllers([turn.previous], direction: .reverse, animated: false)
        pager.delegate?.pageViewController?(pager, didFinishAnimating: true,
                                            previousViewControllers: [turn.previous], transitionCompleted: false)
        model.unrelated += 1
        flush()
        XCTAssertEqual(model.current, 0)
        XCTAssertEqual(shown, 0)
    }

    func testAJumpFromOutsideStillTurnsStraightThere() {
        model.current = 3
        flush()
        XCTAssertEqual(shown, 3)
    }

    /// Right to left, UIKit's "before" (a swipe right) is the next page and its "after" the one
    /// behind — past the start, the same page.
    func testRightToLeftSwapsWhichNeighbourUIKitGets() {
        let rtl = RTLHarness(model: model)
        let host = UIHostingController(rootView: rtl)
        window.rootViewController = host
        flush()
        let pager = Self.find(UIPageViewController.self, in: host)!
        let first = pager.viewControllers!.first!
        let before = pager.dataSource!.pageViewController(pager, viewControllerBefore: first)
        let after = pager.dataSource!.pageViewController(pager, viewControllerAfter: first)
        XCTAssertEqual((before as? CurlPageHost)?.pageID, 1)
        XCTAssertEqual((after as? CurlPageHost)?.pageID, 0)
    }

    struct RTLHarness: View {
        @ObservedObject var model: Model
        var body: some View {
            PageCurlPager(pageIDs: [0, 1, 2, 3, 4], current: $model.current, rightToLeft: true) { id, _ in
                Text("\(id)")
            }
        }
    }

    /// A curl UIKit re-aims mid-gesture — the finger drags back past where it started — asks for
    /// the page before the first (or after the last) after the start was allowed. Answering with
    /// no page threw "The number of view controllers provided (0) doesn't match the number
    /// required (1) for the requested transition"; the page itself lets the curl land where it was.
    func testPastEitherEndTheCurlIsHandedTheSamePage() {
        let first = pager.viewControllers!.first!
        let before = pager.dataSource!.pageViewController(pager, viewControllerBefore: first)
        XCTAssertEqual((before as? CurlPageHost)?.pageID, 0)

        model.current = 4
        flush()
        let last = pager.viewControllers!.first!
        let after = pager.dataSource!.pageViewController(pager, viewControllerAfter: last)
        XCTAssertEqual((after as? CurlPageHost)?.pageID, 4)
    }

    /// Landing on that same page changes nothing.
    func testACurlThatLandsOnTheSamePageStaysPut() {
        let first = pager.viewControllers!.first!
        let same = pager.dataSource!.pageViewController(pager, viewControllerBefore: first)!
        pager.delegate?.pageViewController?(pager, willTransitionTo: [same])
        pager.setViewControllers([same], direction: .reverse, animated: false)
        pager.delegate?.pageViewController?(pager, didFinishAnimating: true,
                                            previousViewControllers: [first], transitionCompleted: true)
        flush()
        XCTAssertEqual(model.current, 0)
        XCTAssertEqual(shown, 0)
    }

    /// After a finished turn the pager knows which page it shows, so a later jump lands.
    func testAJumpAfterATurnLands() {
        let turn = beginTurnForward()
        pager.delegate?.pageViewController?(pager, didFinishAnimating: true,
                                            previousViewControllers: [turn.previous], transitionCompleted: true)
        flush()
        model.current = 0
        flush()
        XCTAssertEqual(shown, 0)
    }

    private static func find<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let match = controller as? T { return match }
        for child in controller.children {
            if let match = find(type, in: child) { return match }
        }
        return nil
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

