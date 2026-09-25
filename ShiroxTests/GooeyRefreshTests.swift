#if os(iOS)
import XCTest
import UIKit
@testable import Shirox

/// Where the gooey drop comes from, how far it hangs, and when a pull becomes a refresh.
final class GooeyRefreshTests: XCTestCase {
    private typealias Geometry = GooeyRefreshGeometry

    func testTheDropComesFromWhateverIsAtTheTop() {
        XCTAssertEqual(Geometry.cutout(topInset: 62, isPhone: true, isPortrait: true), .dynamicIsland)
        XCTAssertEqual(Geometry.cutout(topInset: 59, isPhone: true, isPortrait: true), .dynamicIsland)
        XCTAssertEqual(Geometry.cutout(topInset: 47, isPhone: true, isPortrait: true), .notch)
        XCTAssertEqual(Geometry.cutout(topInset: 20, isPhone: true, isPortrait: true), .edge)
        // Landscape and iPad have nothing at the top centre to hide behind.
        XCTAssertEqual(Geometry.cutout(topInset: 62, isPhone: true, isPortrait: false), .edge)
        XCTAssertEqual(Geometry.cutout(topInset: 24, isPhone: false, isPortrait: true), .edge)
    }

    /// Drawn a little inside the hardware, so a black edge never peeks out around it.
    func testTheAnchorHidesUnderTheIsland() {
        let anchor = Geometry.anchorRect(for: .dynamicIsland, width: 402)
        XCTAssertEqual(anchor.midX, 201)
        XCTAssertLessThan(anchor.width, 126)
        XCTAssertGreaterThan(anchor.minY, 11)
        XCTAssertLessThan(anchor.maxY, 48)
        XCTAssertLessThanOrEqual(Geometry.anchorRect(for: .edge, width: 402).maxY, 0)
    }

    /// Black on black vanishes, so only dark mode lights the drop.
    func testOnlyDarkModeLightsTheDrop() {
        XCTAssertTrue(Geometry.glows(in: .dark))
        XCTAssertFalse(Geometry.glows(in: .light))
    }

    /// Only what hangs out of the island glows; lit from round the anchor, the glow showed over
    /// the island's top edge.
    func testOnlyWhatHangsBelowTheAnchorGlows() {
        let anchor = Geometry.anchorRect(for: .dynamicIsland, width: 402)
        XCTAssertGreaterThanOrEqual(Geometry.glowTop(anchor: anchor), anchor.maxY)
        let hanging = Geometry.dropCenterY(anchor: anchor, progress: 1, refreshing: true)
        XCTAssertLessThan(Geometry.glowTop(anchor: anchor), hanging - Geometry.dropRadius(progress: 1, refreshing: true),
                          "The hanging drop glows all the way round")
    }

    func testTheDropHangsFurtherAsThePullGrows() {
        let anchor = Geometry.anchorRect(for: .dynamicIsland, width: 402)
        let rest = Geometry.dropCenterY(anchor: anchor, progress: 0, refreshing: false)
        let half = Geometry.dropCenterY(anchor: anchor, progress: 0.5, refreshing: false)
        let full = Geometry.dropCenterY(anchor: anchor, progress: 1, refreshing: false)
        let over = Geometry.dropCenterY(anchor: anchor, progress: 1.6, refreshing: false)
        XCTAssertLessThan(rest, half)
        XCTAssertLessThan(half, full)
        XCTAssertEqual(full, over, "Past the threshold it stops moving")
        XCTAssertEqual(Geometry.dropCenterY(anchor: anchor, progress: 0, refreshing: true), full,
                       "While refreshing it waits, pinched off, where a full pull left it")
    }

    func testOnlyAReleasePastTheThresholdRefreshes() {
        XCTAssertTrue(Geometry.shouldRefresh(pull: Geometry.threshold, released: true, refreshing: false))
        XCTAssertFalse(Geometry.shouldRefresh(pull: Geometry.threshold - 1, released: true, refreshing: false))
        XCTAssertFalse(Geometry.shouldRefresh(pull: Geometry.threshold + 40, released: false, refreshing: false))
        XCTAssertFalse(Geometry.shouldRefresh(pull: Geometry.threshold + 40, released: true, refreshing: true))
        XCTAssertEqual(Geometry.progress(pull: Geometry.threshold / 2), 0.5)
        XCTAssertEqual(Geometry.progress(pull: -30), 0)
    }
}
/// The drop lives in a window above the whole app, so it has to follow the screen that was pulled.
@MainActor
final class GooeyRefreshScreenTests: XCTestCase {
    private func screen() -> (UIWindow, UIViewController, UIScrollView) {
        let root = UIViewController()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        root.view.addSubview(scrollView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = root
        window.makeKeyAndVisible()
        return (window, root, scrollView)
    }

    func testAScreenShowingIsOnScreen() {
        let (window, _, scrollView) = screen()
        defer { window.isHidden = true }
        XCTAssertTrue(GooeyRefreshCenter.isOnScreen(scrollView))
    }

    /// Another tab, or a page pushed over it.
    func testAScreenHiddenOrGoneIsNot() {
        let (window, root, scrollView) = screen()
        defer { window.isHidden = true }
        root.view.isHidden = true
        XCTAssertFalse(GooeyRefreshCenter.isOnScreen(scrollView))
        root.view.isHidden = false
        scrollView.removeFromSuperview()
        XCTAssertFalse(GooeyRefreshCenter.isOnScreen(scrollView))
    }

    func testAScreenUnderASheetIsNot() {
        let (window, root, scrollView) = screen()
        defer { window.isHidden = true }
        let sheet = UIViewController()
        let sheetList = UIScrollView()
        sheet.view.addSubview(sheetList)
        root.present(sheet, animated: false)
        defer { sheet.dismiss(animated: false) }
        // The presentation puts the sheet in the window on a later turn of the run loop.
        let deadline = Date().addingTimeInterval(2)
        while sheet.view.window == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(GooeyRefreshCenter.isOnScreen(scrollView))
        XCTAssertTrue(GooeyRefreshCenter.isOnScreen(sheetList))
    }

    /// Pulled, then the screen went mid-pull: the drop lets go rather than hanging there.
    func testAPullItsScreenTookAwayIsLetGo() {
        let (window, _, scrollView) = screen()
        defer { window.isHidden = true }
        let center = GooeyRefreshCenter.shared
        center.update(pull: 60, from: scrollView)
        XCTAssertEqual(center.pull, 60)
        center.checkSource()
        XCTAssertEqual(center.pull, 60, "Still showing, so the pull stands")
        scrollView.removeFromSuperview()
        center.checkSource()
        XCTAssertEqual(center.pull, 0)
    }
}
#endif
