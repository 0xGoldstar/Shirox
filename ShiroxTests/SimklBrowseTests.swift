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
}
