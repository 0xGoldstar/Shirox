#if os(iOS)
import XCTest
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
}
#endif
