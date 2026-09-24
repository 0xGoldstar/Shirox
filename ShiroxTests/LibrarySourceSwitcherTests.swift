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
}
