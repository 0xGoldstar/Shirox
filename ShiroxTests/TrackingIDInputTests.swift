import XCTest
@testable import Shirox

/// What the "Enter ID" field accepts. A wrong parse links the wrong show, so a link for another
/// service, or for manga, is refused rather than guessed at.
final class TrackingIDInputTests: XCTestCase {

    func testAPlainNumber() {
        XCTAssertEqual(TrackingIDInput.parse("28223", for: .mal), 28223)
        XCTAssertEqual(TrackingIDInput.parse("  28223 \n", for: .mal), 28223)
    }

    func testZeroNegativesAndWordsAreRefused() {
        XCTAssertNil(TrackingIDInput.parse("0", for: .mal))
        XCTAssertNil(TrackingIDInput.parse("-5", for: .mal))
        XCTAssertNil(TrackingIDInput.parse("death parade", for: .mal))
        XCTAssertNil(TrackingIDInput.parse("", for: .mal))
    }

    func testEachServicesLinks() {
        XCTAssertEqual(TrackingIDInput.parse("https://myanimelist.net/anime/28223/Death_Parade", for: .mal), 28223)
        XCTAssertEqual(TrackingIDInput.parse("https://anilist.co/anime/20931/Death-Parade/", for: .anilist), 20931)
        XCTAssertEqual(TrackingIDInput.parse("https://simkl.com/anime/37145/death-parade", for: .simkl), 37145)
    }

    func testLinksWithoutSchemeOrWithWwwAndQuery() {
        XCTAssertEqual(TrackingIDInput.parse("myanimelist.net/anime/28223", for: .mal), 28223)
        XCTAssertEqual(TrackingIDInput.parse("https://www.myanimelist.net/anime/28223?q=1", for: .mal), 28223)
    }

    func testAnotherServicesLinkIsRefused() {
        XCTAssertNil(TrackingIDInput.parse("https://myanimelist.net/anime/28223", for: .anilist))
    }

    func testAMangaLinkIsRefused() {
        XCTAssertNil(TrackingIDInput.parse("https://anilist.co/manga/30002", for: .anilist))
    }
}
