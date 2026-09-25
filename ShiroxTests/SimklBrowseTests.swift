import XCTest
@testable import Shirox

/// The Simkl browse grid: genres come from the list itself, most common first.
final class SimklBrowseTests: XCTestCase {
    private func entry(_ simkl: Int, _ genres: [String]) -> SimklDiscoverItem {
        SimklDiscoverItem(title: "Title \(simkl)", titleRomaji: nil, ids: .init(simkl: simkl, mal: nil, anilist: nil),
                          poster: nil, fanart: nil, overview: nil, genres: genres, rating: nil, runtime: nil,
                          totalEpisodes: nil, rank: nil, airDay: nil)
    }

    func testGenresMostCommonFirstThenByName() {
        let items = [entry(1, ["Drama", "Comedy"]), entry(2, ["Drama"]), entry(3, ["Action", "Drama"]),
                     entry(4, ["Comedy"]), entry(5, ["Horror", "Action"])]
        XCTAssertEqual(SimklBrowse.genres(in: items), ["Drama", "Action", "Comedy", "Horror"])
        XCTAssertEqual(SimklBrowse.genres(in: items, limit: 2), ["Drama", "Action"])
    }

    func testFilteringByGenre() {
        let items = [entry(1, ["Drama"]), entry(2, ["Comedy"]), entry(3, ["Drama", "Comedy"])]
        XCTAssertEqual(SimklBrowse.filter(items, genre: "Comedy").map(\.ids.simkl), [2, 3])
        XCTAssertEqual(SimklBrowse.filter(items, genre: nil).map(\.ids.simkl), [1, 2, 3])
    }

    func testEachKindsListsInTheMenu() {
        XCTAssertEqual(SimklBrowse.lists(for: .tv), [
            .trending(.tv, .today), .trending(.tv, .week), .trending(.tv, .month),
            .calendar(.tv), .premieres(.tv), .top(.tv),
        ])
        XCTAssertEqual(SimklBrowse.lists(for: .movie), [
            .trending(.movie, .today), .trending(.movie, .week), .trending(.movie, .month),
            .newReleases, .dvdReleases, .calendar(.movie), .top(.movie),
        ])
    }

    /// Switching kind keeps the same sort of list: Top Rated stays Top Rated, New Premieres
    /// becomes New Releases, Airing Today becomes Coming Soon.
    func testSwitchingKindKeepsTheSameSortOfList() {
        XCTAssertEqual(SimklBrowse.equivalent(.trending(.tv, .month), in: .anime), .trending(.anime, .month))
        XCTAssertEqual(SimklBrowse.equivalent(.top(.tv), in: .movie), .top(.movie))
        XCTAssertEqual(SimklBrowse.equivalent(.premieres(.tv), in: .movie), .newReleases)
        XCTAssertEqual(SimklBrowse.equivalent(.newReleases, in: .anime), .premieres(.anime))
        XCTAssertEqual(SimklBrowse.equivalent(.calendar(.tv), in: .movie), .calendar(.movie))
        XCTAssertEqual(SimklBrowse.equivalent(.dvdReleases, in: .tv), .trending(.tv, .week))
        XCTAssertEqual(SimklBrowse.equivalent(.dvdReleases, in: .movie), .dvdReleases)
        for kind in MediaKind.simklKinds {
            for list in SimklBrowse.lists(for: kind) {
                XCTAssertTrue(SimklBrowse.lists(for: kind).contains(SimklBrowse.equivalent(list, in: kind)))
            }
        }
    }
}
