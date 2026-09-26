import XCTest
@testable import Shirox

/// Home's carousel artwork slides against the swipe, as it did before the iPad carousel rework.
final class HeroParallaxTests: XCTestCase {

    func testAPageAtRestIsCentred() {
        XCTAssertEqual(HeroParallax.offset(distance: 0, pageWidth: 393, isWide: false), -50)
        XCTAssertEqual(HeroParallax.offset(distance: 0, pageWidth: 1180, isWide: true), -40)
    }

    func testAPhonePosterMovesAQuarterOfTheSwipe() {
        XCTAssertEqual(HeroParallax.offset(distance: 100, pageWidth: 393, isWide: false), -75)
        XCTAssertEqual(HeroParallax.offset(distance: -100, pageWidth: 393, isWide: false), -25)
    }

    func testIPadFanartMovesHalfItsOverscanOverAPage() {
        XCTAssertEqual(HeroParallax.offset(distance: 1180, pageWidth: 1180, isWide: true), -80, accuracy: 0.001)
        XCTAssertEqual(HeroParallax.offset(distance: -1180, pageWidth: 1180, isWide: true), 0, accuracy: 0.001)
    }

    /// Whatever part of a page is on screen mid-swipe, the artwork covers it — no gap at an edge.
    func testTheArtworkAlwaysCoversTheVisiblePartOfThePage() {
        for (width, isWide) in [(CGFloat(393), false), (1180, true), (744, true), (320, false)] {
            let artworkWidth = width + HeroParallax.overscan(isWide: isWide)
            for distance in stride(from: -width, through: width, by: 1) {
                let offset = HeroParallax.offset(distance: distance, pageWidth: width, isWide: isWide)
                // The page spans 0...width in its own space; `distance` of it has slid off screen.
                let visibleStart = max(0, -distance)
                let visibleEnd = min(width, width - distance)
                XCTAssertLessThanOrEqual(offset, visibleStart, "width \(width), distance \(distance)")
                XCTAssertGreaterThanOrEqual(offset + artworkWidth, visibleEnd, "width \(width), distance \(distance)")
            }
        }
    }
}
