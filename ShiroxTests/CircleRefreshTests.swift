#if os(iOS)
import XCTest
import UIKit
@testable import Shirox

/// Home's circle, as sheets and the drop-off full screens use it.
@MainActor
final class CircleRefreshTests: XCTestCase {
    private typealias Geometry = RefreshCircleGeometry

    func testTheCircleFillsInOverThePull() {
        XCTAssertEqual(Geometry.progress(pull: 0), 0)
        XCTAssertEqual(Geometry.progress(pull: 10), 0, "A bounce doesn't flash it")
        XCTAssertEqual(Geometry.progress(pull: 45), 0.5)
        XCTAssertEqual(Geometry.progress(pull: 80), 1)
        XCTAssertEqual(Geometry.progress(pull: 300), 1)
    }

    func testTheArrowTurnsOverOnceThePullIsEnough() {
        XCTAssertEqual(Geometry.arrowDegrees(progress: 0), 0)
        XCTAssertEqual(Geometry.arrowDegrees(progress: 0.5), 90)
        XCTAssertEqual(Geometry.arrowDegrees(progress: 1), 180)
    }

    func testTheCircleSitsWhereTheSpinnerWould() {
        let frame = Geometry.frame(inControl: CGRect(x: 0, y: 0, width: 402, height: 60))
        XCTAssertEqual(frame.midX, 201)
        XCTAssertEqual(frame.midY, 30)
        XCTAssertEqual(frame.width, Geometry.side)
    }

    /// The refresh control keeps working; only its spinner is swapped for the circle.
    func testTheCircleTakesTheSpinnersPlaceAndFollowsTheRefresh() throws {
        let table = UITableViewController(style: .plain)
        table.title = "Circle"
        table.refreshControl = UIRefreshControl()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: table)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let scrollView = try XCTUnwrap(table.tableView)
        let control = try XCTUnwrap(table.refreshControl)

        let controller = CircleRefreshController()
        controller.attach(scrollView)
        XCTAssertTrue(controller.circleView.superview === control)
        XCTAssertTrue(standardSpinnerHidden(in: control, circle: controller.circleView))
        XCTAssertEqual(controller.circleView.frame, Geometry.frame(inControl: control.bounds))

        func pull(_ amount: CGFloat) {
            scrollView.contentOffset.y = -scrollView.adjustedContentInset.top - amount
        }
        pull(45)
        XCTAssertEqual(controller.state.progress, Geometry.progress(pull: 45))
        XCTAssertFalse(controller.state.refreshing)

        control.beginRefreshing()
        control.sendActions(for: .valueChanged)
        XCTAssertTrue(controller.state.refreshing)
        pull(0)
        XCTAssertTrue(standardSpinnerHidden(in: control, circle: controller.circleView),
                      "The standard spinner never shows beside the circle")

        control.endRefreshing()
        pull(60)
        XCTAssertFalse(controller.state.refreshing)
        XCTAssertEqual(controller.state.progress, 0, "No arrow while the list slides back over the gap")
        pull(0)
        pull(45)
        XCTAssertEqual(controller.state.progress, Geometry.progress(pull: 45), "The next pull shows it again")

        controller.detach()
        XCTAssertNil(controller.circleView.superview)
    }

    /// Everything the control draws besides the circle is hidden.
    private func standardSpinnerHidden(in control: UIRefreshControl, circle: UIView) -> Bool {
        let own = control.subviews.filter { $0 !== circle }
        return !own.isEmpty && own.allSatisfy(\.isHidden)
    }
}
#endif
