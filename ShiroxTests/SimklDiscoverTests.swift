import XCTest
@testable import Shirox

/// Simkl's free files — trending, DVD releases and the calendar — as `SimklDiscoverItem`s.
/// Fixtures are trimmed copies of the live files (2026-09-25).
final class SimklDiscoverTests: XCTestCase {
    private func decode(_ json: String) throws -> [SimklDiscoverItem] {
        try SimklDiscoverItem.decodeList(Data(json.utf8))
    }

    func testATrendingAnimeKeepsItsTrackerIDs() throws {
        let item = try XCTUnwrap(decode(#"""
        [{"title":"The Exiled Heavy Knight Knows How to Game the System",
          "title_romaji":"Tsuihou Sareta Tensei Juu Kishi wa Game Chishiki de Musou Suru",
          "poster":"20/20276613600d378d41","fanart":"16/16365735cca3c0acee",
          "ids":{"simkl_id":2573730,"slug":"tsuihou","mal":"59741","anilist":"180136","tvdb":"453028"},
          "release_date":"07/02/2026","rank":4602,
          "ratings":{"simkl":{"rating":7,"votes":188},"mal":{"rating":6.8,"votes":16613}},
          "runtime":"25m","status":"ongoing","anime_type":"tv","total_episodes":26,
          "overview":"Born into a prestigious family.","genres":["Action","Adventure","Fantasy"]}]
        """#).first)
        XCTAssertEqual(item.ids, SimklDiscoverItem.IDs(simkl: 2573730, mal: 59741, anilist: 180136, tvdb: 453028))
        XCTAssertEqual(item.title, "The Exiled Heavy Knight Knows How to Game the System")
        XCTAssertEqual(item.titleRomaji, "Tsuihou Sareta Tensei Juu Kishi wa Game Chishiki de Musou Suru")
        XCTAssertEqual(item.poster, "20/20276613600d378d41")
        XCTAssertEqual(item.fanart, "16/16365735cca3c0acee")
        XCTAssertEqual(item.overview, "Born into a prestigious family.")
        XCTAssertEqual(item.rating, 7)
        XCTAssertEqual(item.runtime, 25)
        XCTAssertEqual(item.totalEpisodes, 26)
        XCTAssertEqual(item.rank, 4602)
        XCTAssertEqual(item.genres, ["Action", "Adventure", "Fantasy"])
        XCTAssertNil(item.airDay, "Trending entries aren't dated")
    }

    func testAMovieReadsItsRuntimeAndDropsRepeatedGenres() throws {
        let item = try XCTUnwrap(decode(#"""
        [{"title":"The End of Oak Street","poster":"20/2036989114a175eae4","fanart":"19/19818287730a769e81",
          "ids":{"simkl_id":2123791,"imdb":"tt27165187","tmdb":"1101383"},"release_date":"08/12/2026",
          "rank":17470,"ratings":{"simkl":{"rating":6.22,"votes":725}},"runtime":"1h 40m",
          "status":"ended","overview":"A cosmic event.","genres":["Action","Action","Adventure"]}]
        """#).first)
        XCTAssertEqual(item.runtime, 100)
        XCTAssertEqual(item.genres, ["Action", "Adventure"])
        XCTAssertEqual(item.ids, SimklDiscoverItem.IDs(simkl: 2123791, mal: nil, anilist: nil))
    }

    func testACalendarEntryHasItsListedDayAndZeroMeansUnranked() throws {
        let items = try decode(#"""
        [{"title":"Primeval Overlord","poster":"20/20438493d0702459ce",
          "date":"2026-09-24T00:00:00+09:00","release_date":"2026-07-30","rank":0,
          "ratings":{"simkl":{"rating":null,"votes":null}},
          "ids":{"simkl_id":3200766,"slug":"taigu-shenzun","tmdb":"330275","mal":"64710"},
          "episode":{"episode":20},"anime_type":"ona"},
         {"title":"Ted Lasso","poster":"11/116270662d150894ff","date":"2026-09-24T00:00:00-04:00",
          "rank":194,"ids":{"simkl_id":1359610},"episode":{"season":4,"episode":1}}]
        """#)
        XCTAssertEqual(items.map(\.airDay), ["2026-09-24", "2026-09-24"],
                       "The day as Simkl lists it, not moved into another time zone")
        XCTAssertNil(items[0].rank, "The calendar's 0 means unranked")
        XCTAssertNil(items[0].rating)
        XCTAssertEqual(items[0].ids.mal, 64710)
        XCTAssertNil(items[0].ids.anilist)
        XCTAssertEqual(items[1].rank, 194)
    }

    /// The calendar's episode number marks premieres; a release date, in either of Simkl's
    /// spellings, marks new releases.
    func testTheEpisodeAndTheReleaseDate() throws {
        let items = try decode(#"""
        [{"title":"New Show","date":"2026-09-26T00:00:00-04:00","release_date":"2026-09-26","rank":0,
          "ids":{"simkl_id":1},"episode":{"season":1,"episode":1}},
         {"title":"A Movie","release_date":"08/12/2026","ids":{"simkl_id":2}},
         {"title":"An Anime","date":"2026-09-26T00:00:00+09:00","ids":{"simkl_id":3},"episode":{"episode":20}}]
        """#)
        XCTAssertEqual(items.map(\.episode), [1, nil, 20])
        XCTAssertEqual(items.map(\.released), ["2026-09-26", "2026-08-12", nil])
    }

    /// Calendar v2: each airing joined with its title's details, on the viewer's own day — its
    /// times are UTC.
    func testCalendarVersionTwo() throws {
        let json = #"""
        {"calendar":[
           {"simkl_id":3200766,"date":"2026-09-23T15:00:00Z","finale_type":null,"episode":{"episode":20,"title":"Episode 20"}},
           {"simkl_id":1882859,"date":"2026-09-24T04:00:00Z","episode":{"season":2,"episode":1}},
           {"simkl_id":999,"date":"2026-09-24T04:00:00Z","episode":{"episode":1}}],
         "metadata":{
           "3200766":{"title":"Primeval Overlord","title_romaji":"Taigu Shenzun","poster":"20/2043","fanart":null,
                      "ids":{"simkl_id":3200766,"mal":"64710","anilist":"180001"},"release_date":"2026-07-29T15:00:00Z",
                      "rank":null,"ratings":{"simkl":{"rating":null}},"runtime":"10m","total_episodes":40,
                      "genres":["Action","Fantasy"]},
           "1882859":{"title":"Craft Games","poster":"12/1247","ids":{"simkl_id":1882859},"rank":23032,"genres":["Comedy"]}}}
        """#
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let items = try SimklDiscoverItem.decodeList(Data(json.utf8), timeZone: tokyo)
        XCTAssertEqual(items.map(\.ids.simkl), [3200766, 1882859], "An airing without details is skipped")
        XCTAssertEqual(items.map(\.airDay), ["2026-09-24", "2026-09-24"], "15:00 UTC on the 23rd is the 24th in Tokyo")
        XCTAssertEqual(items.map(\.episode), [20, 1])
        XCTAssertEqual(items[0].ids, .init(simkl: 3200766, mal: 64710, anilist: 180001))
        XCTAssertEqual(items[0].genres, ["Action", "Fantasy"])
        XCTAssertEqual(items[0].released, "2026-07-29")
        XCTAssertEqual(items[0].runtime, 10)
        XCTAssertNil(items[0].rank)
        XCTAssertEqual(items[1].rank, 23032)
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(try SimklDiscoverItem.decodeList(Data(json.utf8), timeZone: newYork).map(\.airDay),
                       ["2026-09-23", "2026-09-24"], "The same airings on New York's days")
    }

    /// Where its TVDB logo comes from: a show's TVDB series, a movie's TVDB movie.
    func testAShowOrMovieKeepsItsTVDBId() throws {
        let items = try decode(#"""
        [{"title":"Lanterns","ids":{"simkl_id":1247732,"imdb":"tt26545992","tmdb":"95350","tvdb":"376098"}},
         {"title":"Project Hail Mary","ids":{"simkl_id":2014312,"tvdb":346729}},
         {"title":"No TVDB","ids":{"simkl_id":1}}]
        """#)
        XCTAssertEqual(items.map(\.ids.tvdb), [376098, 346729, nil])
    }

    func testAnEntryWithoutASimklIdIsSkipped() throws {
        let items = try decode(#"[{"title":"No id","ids":{"slug":"x"}},{"title":"Kept","ids":{"simkl_id":7}}]"#)
        XCTAssertEqual(items.map(\.title), ["Kept"])
    }

    func testRuntimeReadings() {
        XCTAssertEqual(SimklDiscoverItem.minutes(from: "25m"), 25)
        XCTAssertEqual(SimklDiscoverItem.minutes(from: "1h 45m"), 105)
        XCTAssertEqual(SimklDiscoverItem.minutes(from: "2h"), 120)
        XCTAssertNil(SimklDiscoverItem.minutes(from: ""))
        XCTAssertNil(SimklDiscoverItem.minutes(from: "soon"))
    }

    func testListPaths() {
        XCTAssertEqual(SimklFeedList.trending(.tv, .today).path(full: false), "/discover/trending/tv/today_100.json")
        XCTAssertEqual(SimklFeedList.trending(.movie, .week).path(full: true), "/discover/trending/movies/week_500.json")
        XCTAssertEqual(SimklFeedList.trending(.anime, .month).path(full: false), "/discover/trending/anime/month_100.json")
        XCTAssertEqual(SimklFeedList.dvdReleases.path(full: true), "/discover/dvd/releases_500.json")
        XCTAssertEqual(SimklFeedList.calendar(.anime).path(full: true), "/calendar/v2/anime.json")
        XCTAssertEqual(SimklFeedList.calendar(.tv).path(full: false), "/calendar/v2/tv.json")
        XCTAssertEqual(SimklFeedList.calendar(.movie).path(full: false), "/calendar/v2/movie_release.json")
    }

    /// The calendar falls back to its v1 file, until Simkl retires it; nothing else has a fallback.
    func testOnlyTheCalendarHasAFallback() {
        XCTAssertEqual(SimklFeedList.calendar(.anime).fallbackPath(full: true), "/calendar/anime.json")
        XCTAssertEqual(SimklFeedList.calendar(.movie).fallbackPath(full: false), "/calendar/movie_release.json")
        XCTAssertEqual(SimklFeedList.premieres(.tv).fallbackPath(full: false), "/calendar/tv.json")
        XCTAssertNil(SimklFeedList.trending(.tv, .today).fallbackPath(full: false))
        XCTAssertNil(SimklFeedList.top(.tv).fallbackPath(full: false))
        XCTAssertNil(SimklFeedList.dvdReleases.fallbackPath(full: true))
    }

    /// Top Rated comes from Simkl's API with the user's token; New Premieres and New Releases
    /// read files other rows already load.
    func testTheTopAndDerivedLists() {
        XCTAssertEqual(SimklFeedList.top(.anime).path(full: false), "/anime/best/all")
        XCTAssertEqual(SimklFeedList.top(.tv).path(full: true), "/tv/best/all")
        XCTAssertEqual(SimklFeedList.top(.movie).path(full: false), "/movies/genres/all/movies/all/all/rank")
        XCTAssertEqual(SimklFeedList.top(.movie).query, [URLQueryItem(name: "limit", value: "60")])
        XCTAssertEqual(SimklFeedList.top(.tv).query, [])
        XCTAssertTrue(SimklFeedList.top(.tv).needsToken)
        XCTAssertFalse(SimklFeedList.trending(.tv, .week).needsToken)
        XCTAssertFalse(SimklFeedList.premieres(.tv).needsToken)
        XCTAssertFalse(SimklFeedList.newReleases.needsToken)
        XCTAssertEqual(SimklFeedList.top(.anime).refreshInterval, 86400)
        XCTAssertEqual(SimklFeedList.premieres(.tv).refreshInterval, 21600)
        XCTAssertEqual(SimklFeedList.newReleases.refreshInterval, 86400)
        XCTAssertEqual(SimklFeedList.premieres(.tv).path(full: false), SimklFeedList.calendar(.tv).path(full: false))
        XCTAssertEqual(SimklFeedList.premieres(.anime).path(full: true), "/calendar/v2/anime.json")
        XCTAssertEqual(SimklFeedList.newReleases.path(full: false), "/discover/trending/movies/month_100.json")
        XCTAssertEqual(SimklFeedList.newReleases.path(full: true), "/discover/trending/movies/month_500.json")
        XCTAssertEqual(SimklFeedList.top(.tv).title, "Top Rated")
        XCTAssertEqual(SimklFeedList.premieres(.tv).title, "New Premieres")
        XCTAssertEqual(SimklFeedList.newReleases.title, "New Releases")
        XCTAssertEqual(SimklFeedList.top(.movie).kind, .movie)
        XCTAssertEqual(SimklFeedList.premieres(.anime).kind, .anime)
        XCTAssertEqual(SimklFeedList.newReleases.kind, .movie)
    }

    /// Simkl regenerates Today hourly, the calendar every 6 hours, the rest daily.
    func testHowLongEachListKeeps() {
        XCTAssertEqual(SimklFeedList.trending(.tv, .today).refreshInterval, 3600)
        XCTAssertEqual(SimklFeedList.trending(.tv, .week).refreshInterval, 86400)
        XCTAssertEqual(SimklFeedList.trending(.anime, .month).refreshInterval, 86400)
        XCTAssertEqual(SimklFeedList.dvdReleases.refreshInterval, 86400)
        XCTAssertEqual(SimklFeedList.calendar(.movie).refreshInterval, 21600)
    }

    func testRowTitlesAndKinds() {
        XCTAssertEqual(SimklFeedList.trending(.tv, .today).title, "Trending Today")
        XCTAssertEqual(SimklFeedList.trending(.movie, .week).title, "Trending This Week")
        XCTAssertEqual(SimklFeedList.trending(.anime, .month).title, "Trending This Month")
        XCTAssertEqual(SimklFeedList.dvdReleases.title, "Popular on DVD & Digital")
        XCTAssertEqual(SimklFeedList.calendar(.tv).title, "Airing Today")
        XCTAssertEqual(SimklFeedList.calendar(.movie).title, "Coming Soon")
        XCTAssertEqual(SimklFeedList.dvdReleases.kind, .movie)
        XCTAssertEqual(SimklFeedList.calendar(.anime).kind, .anime)
        XCTAssertEqual(SimklFeedList.trending(.tv, .week).kind, .tv)
    }
}
