import XCTest
@testable import Shirox

final class SimklActivityStorageTests: XCTestCase {
    private let suite = "SimklActivityStorageTests"
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

    func testStampsAreSavedPerKind() {
        SimklLibraryService.saveStamps(SimklActivityStamps(all: "a1", removed: "a2"), for: .anime, in: defaults)
        SimklLibraryService.saveStamps(SimklActivityStamps(all: "t1", removed: nil), for: .tv, in: defaults)
        XCTAssertEqual(SimklLibraryService.savedStamps(for: .anime, in: defaults), SimklActivityStamps(all: "a1", removed: "a2"))
        XCTAssertEqual(SimklLibraryService.savedStamps(for: .tv, in: defaults), SimklActivityStamps(all: "t1", removed: nil))
        XCTAssertNil(SimklLibraryService.savedStamps(for: .movie, in: defaults))
    }

    /// Before shows and movies, anime saved Simkl's top-level `all`. It was saved when the copy was
    /// last brought up to date, so a delta from it misses nothing — and needs no full re-read.
    func testAnimeStartsFromTheOldTopLevelStamp() {
        defaults.set("t0", forKey: SimklLibraryService.legacyActivityKey)
        XCTAssertEqual(SimklLibraryService.savedStamps(for: .anime, in: defaults), SimklActivityStamps(all: "t0", removed: nil))
        XCTAssertNil(SimklLibraryService.savedStamps(for: .tv, in: defaults))
    }

    func testSavedStampsWinOverTheOldOne() {
        defaults.set("t0", forKey: SimklLibraryService.legacyActivityKey)
        SimklLibraryService.saveStamps(SimklActivityStamps(all: "a1", removed: "a2"), for: .anime, in: defaults)
        XCTAssertEqual(SimklLibraryService.savedStamps(for: .anime, in: defaults)?.all, "a1")
    }

    func testListPathsPerKind() {
        XCTAssertEqual(SimklLibraryService.listPath(for: .anime), "/sync/all-items/anime/all")
        XCTAssertEqual(SimklLibraryService.listPath(for: .tv), "/sync/all-items/shows/all")
        XCTAssertEqual(SimklLibraryService.listPath(for: .movie), "/sync/all-items/movies/all")
    }

    /// A Shows copy saved at the current version must not vouch for an anime copy from before it.
    func testCacheVersionIsTrackedPerKind() {
        XCTAssertEqual(SimklLibraryService.cacheVersionKey(.anime), "simkl_cache_version")
        XCTAssertNotEqual(SimklLibraryService.cacheVersionKey(.tv), SimklLibraryService.cacheVersionKey(.anime))
        XCTAssertNotEqual(SimklLibraryService.cacheVersionKey(.tv), SimklLibraryService.cacheVersionKey(.movie))
    }
}
