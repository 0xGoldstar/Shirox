import XCTest
@testable import Shirox

/// The Library lands on the list you left, per source and type.
final class LibraryListMemoryTests: XCTestCase {
    private let suite = "LibraryListMemoryTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private typealias Place = LibraryListMemory.Place

    func testEachSourceAndTypeRemembersItsOwnList() {
        LibraryListMemory.save(Place(status: .completed), for: .provider(.anilist), .anime, in: defaults)
        LibraryListMemory.save(Place(status: .paused), for: .provider(.anilist), .manga, in: defaults)
        LibraryListMemory.save(Place(status: .dropped), for: .provider(.mal), .anime, in: defaults)
        LibraryListMemory.save(Place(status: .planning), for: .simkl, .movie, in: defaults)

        XCTAssertEqual(LibraryListMemory.load(for: .provider(.anilist), .anime, in: defaults)?.status, .completed)
        XCTAssertEqual(LibraryListMemory.load(for: .provider(.anilist), .manga, in: defaults)?.status, .paused)
        XCTAssertEqual(LibraryListMemory.load(for: .provider(.mal), .anime, in: defaults)?.status, .dropped)
        XCTAssertEqual(LibraryListMemory.load(for: .simkl, .movie, in: defaults)?.status, .planning)
        XCTAssertNil(LibraryListMemory.load(for: .local, .anime, in: defaults))
    }

    func testACustomListIsRememberedToo() {
        LibraryListMemory.save(Place(status: .current, customList: "Favourites"), for: .local, .anime, in: defaults)
        XCTAssertEqual(LibraryListMemory.load(for: .local, .anime, in: defaults)?.customList, "Favourites")
    }

    /// A list the source can't show any more falls back to the default rather than an empty screen.
    func testAListTheSourceDoesNotHaveIsNotRestored() {
        XCTAssertNil(LibraryListMemory.restorable(Place(status: .current), source: .simkl, kind: .movie))
        XCTAssertNil(LibraryListMemory.restorable(Place(status: .repeating), source: .simkl, kind: .tv))
        XCTAssertEqual(LibraryListMemory.restorable(Place(status: .repeating), source: .provider(.anilist), kind: .anime),
                       Place(status: .repeating))
        XCTAssertNil(LibraryListMemory.restorable(nil, source: .local, kind: .anime))
    }
}
