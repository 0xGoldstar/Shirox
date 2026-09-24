import XCTest
@testable import Shirox

@MainActor
final class SimklTitleCatalogTests: XCTestCase {

    func testDecodesTVShowDetails() throws {
        let details = try XCTUnwrap(SimklCatalog.decodeDetails(Data("""
        {"title":"Game of Thrones","year":2011,"type":"show",
         "ids":{"simkl":17465,"slug":"game-of-thrones","tmdb":"1399"},
         "poster":"57/5742576cd8f59fcb0","fanart":"65/651708e80d87bb93","runtime":52,
         "certification":"TV-MA","overview":"Seven noble families…","genres":["Drama","Fantasy"],
         "network":"HBO","status":"ended","total_episodes":73}
        """.utf8)))
        XCTAssertEqual(details.simklID, 17465)
        XCTAssertEqual(details.title, "Game of Thrones")
        XCTAssertEqual(details.year, 2011)
        XCTAssertEqual(details.genres, ["Drama", "Fantasy"])
        XCTAssertEqual(details.runtime, 52)
        XCTAssertEqual(details.status, "ended")
        XCTAssertEqual(details.network, "HBO")
        XCTAssertEqual(details.certification, "TV-MA")
        XCTAssertEqual(details.totalEpisodes, 73)
    }

    func testDecodesMovieDetails() throws {
        let details = try XCTUnwrap(SimklCatalog.decodeDetails(Data("""
        {"title":"Inception","year":2010,"ids":{"simkl":472214},"poster":"14/14017865947c9d3d0d",
         "fanart":"27/2745964f37d66f1bb","runtime":148,"certification":"PG-13",
         "overview":"Cobb, a skilled thief…","genres":["Action"]}
        """.utf8)))
        XCTAssertEqual(details.simklID, 472214)
        XCTAssertEqual(details.runtime, 148)
        XCTAssertNil(details.network)
        XCTAssertNil(details.totalEpisodes)
    }

    /// Like the anime lookup: an unknown id is `200 []`, not a 404.
    func testAnUnknownIdIsNil() throws {
        XCTAssertNil(try SimklCatalog.decodeDetails(Data("[]".utf8)))
    }

    func testDecodesEpisodesAndMarksSpecials() throws {
        let episodes = try SimklCatalog.decodeEpisodes(Data("""
        [{"title":"Days Gone Bye","season":1,"episode":1,"type":"episode","aired":true,
          "img":"33/33039065126ec2470","date":"2010-10-31T05:00:00.000Z","ids":{"simkl_id":310766}},
         {"title":"Behind The Dead","type":"special","aired":false,"img":null,"date":null,
          "ids":{"simkl_id":2527432}}]
        """.utf8))
        XCTAssertEqual(episodes.count, 2)
        XCTAssertEqual(episodes[0].ref, SimklEpisodeRef(season: 1, episode: 1))
        XCTAssertTrue(episodes[0].aired)
        XCTAssertTrue(episodes[1].isSpecial)
        XCTAssertNil(episodes[1].ref)
        XCTAssertEqual(episodes[1].simklID, 2527432)
    }

    /// Simkl's sizes: fanart `_mobile` (960×540) for a phone hero, episode stills `_c` (210×118).
    func testImageURLsFollowSimklsPattern() throws {
        let details = try XCTUnwrap(SimklCatalog.decodeDetails(Data("""
        {"title":"X","ids":{"simkl":1},"poster":"57/5742576cd8f59fcb0","fanart":"65/651708e80d87bb93"}
        """.utf8)))
        XCTAssertEqual(details.fanartURL, "https://wsrv.nl/?url=https://simkl.in/fanart/65/651708e80d87bb93_mobile.webp&q=90")
        XCTAssertEqual(details.posterURL, "https://wsrv.nl/?url=https://simkl.in/posters/57/5742576cd8f59fcb0_m.webp&q=90")
        let episode = SimklEpisode(season: 1, episode: 1, title: nil, aired: true, img: "33/330390",
                                   date: nil, isSpecial: false, simklID: 1)
        XCTAssertEqual(episode.imageURL, "https://wsrv.nl/?url=https://simkl.in/episodes/33/330390_c.webp&q=90")
    }

    func testCatalogCacheRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SimklCatalogCache(directory: directory)
        let details = try XCTUnwrap(SimklCatalog.decodeDetails(Data(#"{"title":"X","ids":{"simkl":5}}"#.utf8)))
        cache.store(details, kind: .tv)
        cache.store(episodes: [SimklEpisode(season: 1, episode: 2, title: "E", aired: true, img: nil,
                                            date: nil, isSpecial: false, simklID: 12)], simklID: 5)
        XCTAssertEqual(cache.details(.tv, simklID: 5), details)
        XCTAssertNil(cache.details(.movie, simklID: 5))
        XCTAssertEqual(cache.episodes(simklID: 5)?.first?.simklID, 12)
    }

    func testSearchPathsPerKind() {
        XCTAssertEqual(SimklCatalog.searchPath(for: .anime), "/search/anime")
        XCTAssertEqual(SimklCatalog.searchPath(for: .tv), "/search/tv")
        XCTAssertEqual(SimklCatalog.searchPath(for: .movie), "/search/movie")
    }

    /// Each search is one request of the user's daily budget.
    func testTheSameSearchIsAnsweredFromTheSession() throws {
        let items = try SimklCatalog.decodeSearch(Data(#"[{"title":"Dark","ids":{"simkl_id":9}}]"#.utf8))
        SimklCatalog.rememberSearch(items, query: "Dark ", kind: .tv)
        XCTAssertEqual(SimklCatalog.rememberedSearch("dark", kind: .tv), items)
        XCTAssertNil(SimklCatalog.rememberedSearch("dark", kind: .movie))
    }
}
