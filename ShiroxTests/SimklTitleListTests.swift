import XCTest
@testable import Shirox

final class SimklTitleListTests: XCTestCase {

    private let order = MediaListStatus.allCases

    func testMoviesHaveThreeLists() {
        XCTAssertEqual(LibrarySource.simkl.statuses(in: order, for: .movie), [.planning, .completed, .dropped])
    }

    func testShowsHaveTheFiveLists() {
        XCTAssertEqual(LibrarySource.simkl.statuses(in: order, for: .tv),
                       [.current, .planning, .completed, .dropped, .paused])
        XCTAssertEqual(LibrarySource.provider(.anilist).statuses(in: order, for: .anime), order)
    }

    func testMoviesOpenOnPlanToWatch() {
        XCTAssertEqual(LibrarySource.defaultStatus(for: .movie), .planning)
        XCTAssertEqual(LibrarySource.defaultStatus(for: .tv), .current)
        XCTAssertEqual(LibrarySource.defaultStatus(for: .anime), .current)
    }

    func testShowRowSaysWhereYouAre() {
        var entry = SimklTitleCopy.entry(simklID: 1, kind: .tv, title: "S", posterURL: nil, year: nil,
                                         runtime: nil, totalEpisodes: 73, status: .current)
        entry.watchedEpisodes = [SimklSeasonWatch(season: 1, episodes: Array(1...12)),
                                 SimklSeasonWatch(season: 2, episodes: [1, 2, 3, 4, 5])]
        entry.progress = 17
        XCTAssertEqual(SimklTitleLabels.showProgress(entry), "S2 E5 · 17 of 73")
    }

    func testShowRowBeforeAnyEpisode() {
        let entry = SimklTitleCopy.entry(simklID: 1, kind: .tv, title: "S", posterURL: nil, year: nil,
                                         runtime: nil, totalEpisodes: 73, status: .planning)
        XCTAssertEqual(SimklTitleLabels.showProgress(entry), "Not started · 0 of 73")
    }

    func testMovieRowShowsYearAndRuntime() {
        let movie = SimklTitleCopy.entry(simklID: 1, kind: .movie, title: "M", posterURL: nil, year: 1994,
                                         runtime: 154, totalEpisodes: nil, status: .completed)
        XCTAssertEqual(SimklTitleLabels.movieLine(movie.media), "1994 · 2h 34m")
        XCTAssertEqual(SimklTitleLabels.runtime(58), "58m")
        XCTAssertEqual(SimklTitleLabels.runtime(120), "2h")
    }
}
