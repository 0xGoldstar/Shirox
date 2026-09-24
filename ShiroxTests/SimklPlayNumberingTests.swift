import XCTest
@testable import Shirox

final class SimklPlayNumberingTests: XCTestCase {

    private func ep(_ season: Int, _ number: Int, aired: Bool = true) -> SimklEpisode {
        SimklEpisode(season: season, episode: number, title: nil, aired: aired, img: nil, date: nil,
                     isSpecial: false, simklID: season * 100 + number)
    }

    private func ref(_ season: Int, _ number: Int) -> SimklEpisodeRef {
        SimklEpisodeRef(season: season, episode: number)
    }

    /// Season 1 has 13 episodes; season 2 three, the last not aired yet.
    private lazy var catalog: [SimklEpisode] = (1...13).map { ep(1, $0) } + [ep(2, 1), ep(2, 2), ep(2, 3, aired: false)]

    func testOffsetAndSeasonCountFromTheCatalog() {
        XCTAssertEqual(SimklPlayNumbering.offset(before: 2, in: catalog), 13)
        XCTAssertEqual(SimklPlayNumbering.seasonCount(2, in: catalog), 3)
        XCTAssertNil(SimklPlayNumbering.numbering(for: 1, in: catalog))
        XCTAssertEqual(SimklPlayNumbering.numbering(for: 2, in: catalog), ModuleSeasonNumbering(offset: 13, seasonCount: 3))
    }

    func testANumberMapsToItsSeasonAndEpisode() {
        XCTAssertEqual(SimklPlayNumbering.episode(season: 2, number: 2, in: catalog), ref(2, 2))
        // Up Next past season 1's end on a page listing every season.
        XCTAssertEqual(SimklPlayNumbering.episode(season: 1, number: 14, in: catalog), ref(2, 1))
        XCTAssertNil(SimklPlayNumbering.episode(season: 2, number: 9, in: catalog))
    }

    func testTheSearchTitleNamesTheSeasonAfterTheFirst() {
        XCTAssertEqual(SimklPlayNumbering.searchTitle("Dark", season: nil), "Dark")
        XCTAssertEqual(SimklPlayNumbering.searchTitle("Dark", season: 1), "Dark")
        XCTAssertEqual(SimklPlayNumbering.searchTitle("Dark", season: 2), "Dark Season 2")
    }

    func testOnlyAPageLongerThanTheSeasonCountsFromSeasonOne() {
        let numbering = ModuleSeasonNumbering(offset: 13, seasonCount: 3)
        XCTAssertEqual(numbering.offset(forListCount: 3), 0, "the season's own page")
        XCTAssertEqual(numbering.offset(forListCount: 16), 13, "every season on one page")
        XCTAssertEqual(ModuleSeasonNumbering(offset: 13, seasonCount: 24).offset(forListCount: 24), 0,
                       "a long season's own page is still its own page")
    }

    func testTheButtonPlaysTheResumeThenTheNextUnwatched() {
        XCTAssertEqual(SimklWatchTarget.episode(resume: ref(1, 4), watched: [], episodes: catalog), ref(1, 4))
        XCTAssertEqual(SimklWatchTarget.episode(resume: nil, watched: [ref(1, 1)], episodes: catalog), ref(1, 2))
        XCTAssertEqual(SimklWatchTarget.episode(resume: nil, watched: [], episodes: catalog), ref(1, 1))
    }

    func testTheButtonSaysWhatItPlays() {
        XCTAssertEqual(SimklWatchTarget.label(kind: .movie, episode: nil, resuming: false), "Watch Movie")
        XCTAssertEqual(SimklWatchTarget.label(kind: .movie, episode: nil, resuming: true), "Continue Movie")
        XCTAssertEqual(SimklWatchTarget.label(kind: .tv, episode: ref(1, 1), resuming: false), "Watch S1 E1")
        XCTAssertEqual(SimklWatchTarget.label(kind: .tv, episode: ref(2, 6), resuming: true), "Continue S2 E6")
    }
}
