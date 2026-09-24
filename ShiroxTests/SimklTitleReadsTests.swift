import XCTest
@testable import Shirox

/// Shapes taken from Simkl's own examples for `/sync/all-items` and `/sync/activities`.
final class SimklTitleReadsTests: XCTestCase {

    private let walkingDead = """
    {"shows":[{"status":"watching","last_watched":"S01E03","watched_episodes_count":176,
      "total_episodes_count":177,"user_rating":8,
      "show":{"title":"The Walking Dead","poster":"16/16913426086fc13","year":2010,"runtime":43,
              "ids":{"simkl":2090,"slug":"the-walking-dead","imdb":"tt1520211"}},
      "seasons":[{"number":1,"episodes":[{"number":3},{"number":2}]},{"number":2,"episodes":[]}]}]}
    """

    func testDecodesAShowWithItsWatchedSeasons() throws {
        let entries = try SimklTitleReads.decodeShows(from: Data(walkingDead.utf8))
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.id, 2090)
        XCTAssertEqual(entry.media.id, 2090)
        XCTAssertEqual(entry.media.simklTitleKind, .tv)
        XCTAssertEqual(entry.status, .current)
        XCTAssertEqual(entry.progress, 176)
        XCTAssertEqual(entry.media.episodes, 177)
        XCTAssertEqual(entry.media.seasonYear, 2010)
        XCTAssertEqual(entry.media.runtime, 43)
        XCTAssertEqual(entry.score, 8)
        XCTAssertEqual(entry.media.coverImage.large,
                       "https://wsrv.nl/?url=https://simkl.in/posters/16/16913426086fc13_m.webp&q=90")
        // Sorted, and a season with nothing watched left out.
        XCTAssertEqual(entry.watchedEpisodes, [SimklSeasonWatch(season: 1, episodes: [2, 3])])
    }

    func testShowIdsSentAsStringsStillDecode() throws {
        let entries = try SimklTitleReads.decodeShows(from: Data("""
        {"shows":[{"status":"hold","show":{"title":"X","ids":{"simkl":"2090"}}}]}
        """.utf8))
        XCTAssertEqual(entries.first?.id, 2090)
        XCTAssertEqual(entries.first?.status, .paused)
    }

    func testAShowWithoutASimklIdIsSkippedNotFatal() throws {
        let entries = try SimklTitleReads.decodeShows(from: Data("""
        {"shows":[{"status":"watching","show":{"title":"X","ids":{"imdb":"tt1"}}},
                  {"status":"watching","show":{"title":"Y","ids":{"simkl":7}}}]}
        """.utf8))
        XCTAssertEqual(entries.map(\.id), [7])
    }

    func testDecodesMoviesWithTheirThreeLists() throws {
        let entries = try SimklTitleReads.decodeMovies(from: Data("""
        {"movies":[
          {"status":"plantowatch","user_rating":null,"movie":{"title":"Inception","poster":"14/14017865947c9d3d0d","year":2010,"runtime":148,"ids":{"simkl":472214}}},
          {"status":"completed","user_rating":9,"movie":{"title":"The Godfather","year":1972,"ids":{"simkl":53434}}},
          {"status":"notinteresting","movie":{"title":"Pulp Fiction","year":1994,"ids":{"simkl":"54130"}}}]}
        """.utf8))
        XCTAssertEqual(entries.map(\.status), [.planning, .completed, .dropped])
        XCTAssertEqual(entries[0].media.simklTitleKind, .movie)
        XCTAssertEqual(entries[0].media.runtime, 148)
        XCTAssertEqual(entries[0].score, 0)
        XCTAssertEqual(entries[1].score, 9)
        XCTAssertEqual(entries[2].id, 54130)
    }

    func testIdsOnlyReadCollectsEveryArray() throws {
        let ids = try SimklTitleReads.decodeSimklIDs(from: Data("""
        {"shows":[{"show":{"ids":{"simkl":297,"slug":"charmed"}}}],
         "anime":[{"show":{"ids":{"simkl":"37089"}}}],
         "movies":[{"movie":{"ids":{"simkl":53434}}}]}
        """.utf8))
        XCTAssertEqual(ids, [297, 37089, 53434])
    }

    func testActivityStampsPerKind() {
        let stamps = SimklTitleReads.activityStamps(from: Data("""
        {"all":"t0",
         "anime":{"all":"a1","removed_from_list":"a2"},
         "tv_shows":{"all":"t1","removed_from_list":"t2"},
         "movies":{"all":"m1","removed_from_list":"m2"}}
        """.utf8))
        XCTAssertEqual(stamps[.anime], SimklActivityStamps(all: "a1", removed: "a2"))
        XCTAssertEqual(stamps[.tv], SimklActivityStamps(all: "t1", removed: "t2"))
        XCTAssertEqual(stamps[.movie], SimklActivityStamps(all: "m1", removed: "m2"))
    }

    /// A group Simkl didn't send is absent — never a nil stamp that could read as "changed".
    func testAMissingGroupIsAbsent() {
        XCTAssertTrue(SimklTitleReads.activityStamps(from: Data(#"{"all":"x"}"#.utf8)).isEmpty)
    }
}
