import XCTest
@testable import Shirox

@MainActor
final class LibrarySourceSwitcherTests: XCTestCase {

    func testSimklPillExactlyWhenSignedIn() {
        XCTAssertEqual(LibrarySourceSwitcher.sources(anilist: true, mal: true, simkl: true),
                       [.local, .provider(.anilist), .provider(.mal), .simkl])
        XCTAssertEqual(LibrarySourceSwitcher.sources(anilist: true, mal: false, simkl: false),
                       [.local, .provider(.anilist)])
        XCTAssertEqual(LibrarySourceSwitcher.sources(anilist: false, mal: false, simkl: true),
                       [.local, .simkl])
    }

    /// One pill is no choice; the switcher hides itself then.
    func testSignedOutOfEverythingIsOnlyMyLibrary() {
        XCTAssertEqual(LibrarySourceSwitcher.sources(anilist: false, mal: false, simkl: false), [.local])
    }

    func testUpToThreePillsAllShowNames() {
        XCTAssertTrue(LibrarySourceSwitcher.showsName(of: .provider(.mal), selected: false, pillCount: 3))
        XCTAssertTrue(LibrarySourceSwitcher.showsName(of: .simkl, selected: false, pillCount: 2))
    }

    /// Four named pills are 407 pt; a 375-pt iPhone has 343 pt for the row.
    func testWithFourOnlyMyLibraryAndTheSelectedServiceShowNames() {
        XCTAssertTrue(LibrarySourceSwitcher.showsName(of: .local, selected: false, pillCount: 4))
        XCTAssertTrue(LibrarySourceSwitcher.showsName(of: .simkl, selected: true, pillCount: 4))
        XCTAssertFalse(LibrarySourceSwitcher.showsName(of: .simkl, selected: false, pillCount: 4))
        XCTAssertFalse(LibrarySourceSwitcher.showsName(of: .provider(.anilist), selected: false, pillCount: 4))
    }
}
