#if os(iOS)
import XCTest
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

    /// Black on black vanishes, so only dark mode outlines the drop.
    func testOnlyDarkModeOutlinesTheDrop() {
        XCTAssertNotNil(Geometry.rim(for: .dark))
        XCTAssertNil(Geometry.rim(for: .light))
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
#endif
