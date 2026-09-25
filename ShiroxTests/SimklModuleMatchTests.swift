import XCTest
@testable import Shirox

/// Matching a module page to a Simkl show or movie by title, and guessing which season it holds.
/// A wrong match marks the wrong show, so only an exact title (and year, when both have one) counts.
final class SimklModuleMatchTests: XCTestCase {
    private func results(_ json: String) throws -> [SimklCatalogItem] {
        try SimklCatalog.decodeSearch(Data(json.utf8))
    }

    private func episode(_ season: Int, _ number: Int) -> SimklEpisode {
        SimklEpisode(season: season, episode: number, title: nil, aired: true, img: nil, date: nil,
                     isSpecial: false, simklID: season * 100 + number)
    }

    func testTitlesCompareWithoutCaseOrPunctuation() {
        XCTAssertEqual(SimklModuleMatch.normalized("Ted Lasso!"), "tedlasso")
        XCTAssertEqual(SimklModuleMatch.normalized("  ted-lasso "), "tedlasso")
        XCTAssertEqual(SimklModuleMatch.normalized("Spider-Man: No Way Home"), "spidermannowayhome")
    }

    func testAnExactTitleMatches() throws {
        let found = try results(#"[{"title":"Ted Lasso 2","year":2021,"ids":{"simkl_id":1}},{"title":"Ted Lasso","year":2020,"ids":{"simkl_id":2}}]"#)
        XCTAssertEqual(SimklModuleMatch.match(title: "Ted Lasso", aliases: "", airdate: "", in: found)?.simklID, 2)
    }

    func testAnAliasMatchesToo() throws {
        let found = try results(#"[{"title":"La Casa de Papel","year":2017,"ids":{"simkl_id":3}}]"#)
        XCTAssertEqual(SimklModuleMatch.match(title: "Money Heist", aliases: "La Casa de Papel, Money Heist: Korea",
                                              airdate: "", in: found)?.simklID, 3)
    }

    func testTheYearMustAgreeWhenBothHaveOne() throws {
        let found = try results(#"[{"title":"Dune","year":1984,"ids":{"simkl_id":4}},{"title":"Dune","year":2021,"ids":{"simkl_id":5}}]"#)
        XCTAssertEqual(SimklModuleMatch.match(title: "Dune", aliases: "", airdate: "Released: Oct 22, 2021", in: found)?.simklID, 5)
        XCTAssertEqual(SimklModuleMatch.match(title: "Dune", aliases: "", airdate: "", in: found)?.simklID, 4,
                       "No year on the page: the first exact title")
        XCTAssertNil(SimklModuleMatch.match(title: "Dune", aliases: "", airdate: "2000", in: found))
    }

    func testAYearInTheTitleIsTheYear() throws {
        let found = try results(#"[{"title":"Dune","year":1984,"ids":{"simkl_id":4}},{"title":"Dune","year":2021,"ids":{"simkl_id":5}}]"#)
        XCTAssertEqual(SimklModuleMatch.match(title: "Dune (2021)", aliases: "", airdate: "", in: found)?.simklID, 5)
    }

    func testANearTitleDoesntMatch() throws {
        let found = try results(#"[{"title":"Breaking Bad","year":2008,"ids":{"simkl_id":6}}]"#)
        XCTAssertNil(SimklModuleMatch.match(title: "Breaking", aliases: "", airdate: "", in: found))
        XCTAssertNil(SimklModuleMatch.match(title: "Breaking Bad", aliases: "", airdate: "",
                                            in: try results(#"[{"title":"Breaking Bad","ids":{}}]"#)),
                     "No Simkl id, nothing to link")
    }

    func testTheYearFromAnAirdate() {
        XCTAssertEqual(SimklModuleMatch.year(inAirdate: "Aired: Oct 2, 2020 to Jun 1, 2023"), 2020)
        XCTAssertEqual(SimklModuleMatch.year(inAirdate: "2019"), 2019)
        XCTAssertNil(SimklModuleMatch.year(inAirdate: "Unknown"))
        XCTAssertNil(SimklModuleMatch.year(inAirdate: ""))
    }

    func testOneEpisodeOrNoneIsAMovie() {
        XCTAssertEqual(SimklModuleMatch.searchKind(episodeCount: 0), .movie)
        XCTAssertEqual(SimklModuleMatch.searchKind(episodeCount: 1), .movie)
        XCTAssertEqual(SimklModuleMatch.searchKind(episodeCount: 8), .tv)
    }

    func testASeasonNamedInTheTitle() {
        XCTAssertEqual(SimklModuleMatch.namedSeason(in: "Ted Lasso Season 2"), 2)
        XCTAssertEqual(SimklModuleMatch.namedSeason(in: "Ted Lasso Season 02"), 2)
        XCTAssertEqual(SimklModuleMatch.namedSeason(in: "Ted Lasso 3rd Season"), 3)
        XCTAssertEqual(SimklModuleMatch.namedSeason(in: "Ted Lasso S3"), 3)
        XCTAssertNil(SimklModuleMatch.namedSeason(in: "Ted Lasso"))
        XCTAssertNil(SimklModuleMatch.namedSeason(in: "Blade Runner 2049"))
        XCTAssertNil(SimklModuleMatch.namedSeason(in: "Sons of Anarchy"))
        XCTAssertNil(SimklModuleMatch.namedSeason(in: "Show Season 0"))
    }

    func testTheSeasonGuess() {
        let episodes = (1...10).map { episode(1, $0) } + (1...10).map { episode(2, $0) }
        XCTAssertEqual(SimklModuleMatch.seasonGuess(title: "Show Season 2", moduleEpisodeCount: 20, simklEpisodes: episodes), 2,
                       "A season named in the title wins")
        XCTAssertNil(SimklModuleMatch.seasonGuess(title: "Show", moduleEpisodeCount: 20, simklEpisodes: episodes),
                     "More episodes than season 1 has: every season")
        XCTAssertEqual(SimklModuleMatch.seasonGuess(title: "Show", moduleEpisodeCount: 10, simklEpisodes: episodes), 1)
        XCTAssertEqual(SimklModuleMatch.seasonGuess(title: "Show", moduleEpisodeCount: 20, simklEpisodes: nil), 1,
                       "Without Simkl's list, season 1")
    }
}
