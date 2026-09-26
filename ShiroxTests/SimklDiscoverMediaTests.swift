import XCTest
@testable import Shirox

/// Simkl entries as the app's titles: shows and movies open the Simkl page, anime the app's own.
final class SimklDiscoverMediaTests: XCTestCase {
    private func item(simkl: Int = 1359610, mal: Int? = nil, anilist: Int? = nil, tvdb: Int? = nil,
                      title: String = "Ted Lasso",
                      rating: Double? = 8.54, runtime: Int? = 33, episodes: Int? = 44) -> SimklDiscoverItem {
        SimklDiscoverItem(title: title, titleRomaji: nil,
                          ids: .init(simkl: simkl, mal: mal, anilist: anilist, tvdb: tvdb),
                          poster: "11/116270662d150894ff", fanart: "10/100607388512169211",
                          overview: "A coach moves to England.", genres: ["Comedy", "Drama"], rating: rating,
                          runtime: runtime, totalEpisodes: episodes, rank: 194, airDay: nil)
    }

    func testAShowIsASimklTitle() throws {
        let media = try XCTUnwrap(SimklDiscoverMedia.media(item(), kind: .tv, tracker: .anilist))
        XCTAssertEqual(media.provider, .simkl)
        XCTAssertEqual(media.id, 1359610)
        XCTAssertEqual(media.simklTitleKind, .tv)
        XCTAssertEqual(media.title.displayTitle, "Ted Lasso")
        XCTAssertEqual(media.coverImage.large,
                       "https://wsrv.nl/?url=https://simkl.in/posters/11/116270662d150894ff_m.webp&q=90")
        XCTAssertEqual(media.bannerImage,
                       "https://wsrv.nl/?url=https://simkl.in/fanart/10/100607388512169211_medium.webp&q=90")
        XCTAssertEqual(media.averageScore, 85, "8.54 out of 10")
        XCTAssertEqual(media.episodes, 44)
        XCTAssertEqual(media.runtime, 33)
        XCTAssertEqual(media.genres, ["Comedy", "Drama"])
        XCTAssertEqual(media.description, "A coach moves to England.")
    }

    func testAMovieIsASimklMovieWithoutEpisodes() throws {
        let media = try XCTUnwrap(SimklDiscoverMedia.media(item(simkl: 2123791, runtime: 100), kind: .movie, tracker: .mal))
        XCTAssertEqual(media.simklTitleKind, .movie)
        XCTAssertNil(media.episodes)
        XCTAssertEqual(media.runtime, 100)
    }

    /// A show or movie finds its logo on TVDB by this id. An anime finds its own through its
    /// AniList or MyAnimeList id, as every anime does.
    func testAShowOrMovieCarriesItsTVDBId() throws {
        XCTAssertEqual(SimklDiscoverMedia.media(item(tvdb: 383203), kind: .tv, tracker: .anilist)?.tvdbID, 383203)
        XCTAssertEqual(SimklDiscoverMedia.media(item(tvdb: 346729), kind: .movie, tracker: .anilist)?.tvdbID, 346729)
        XCTAssertNil(SimklDiscoverMedia.media(item(mal: 59741, anilist: 180136, tvdb: 453028),
                                              kind: .anime, tracker: .anilist)?.tvdbID)
    }

    func testAnAnimeOpensByItsAniListIdForAniListUsers() throws {
        let media = try XCTUnwrap(SimklDiscoverMedia.media(item(simkl: 2573730, mal: 59741, anilist: 180136),
                                                           kind: .anime, tracker: .anilist))
        XCTAssertEqual(media.provider, .anilist)
        XCTAssertEqual(media.id, 180136)
        XCTAssertEqual(media.idMal, 59741)
        XCTAssertNil(media.simklTitleKind)
    }

    func testAnAnimeOpensByItsMALIdForMALUsers() throws {
        let media = try XCTUnwrap(SimklDiscoverMedia.media(item(simkl: 2573730, mal: 59741, anilist: 180136),
                                                           kind: .anime, tracker: .mal))
        XCTAssertEqual(media.provider, .mal)
        XCTAssertEqual(media.id, 59741)
    }

    /// The calendar's anime come with a MAL id only; the app's mapping table fills in AniList's.
    func testAMissingAniListIdComesFromTheMap() throws {
        let calendarAnime = item(simkl: 3200766, mal: 64710, anilist: nil)
        XCTAssertNil(SimklDiscoverMedia.media(calendarAnime, kind: .anime, tracker: .anilist))
        let media = try XCTUnwrap(SimklDiscoverMedia.media(calendarAnime, kind: .anime, tracker: .anilist,
                                                           anilistForMAL: [64710: 999]))
        XCTAssertEqual(media.id, 999)
        XCTAssertEqual(media.idMal, 64710)
    }

    func testAnAnimeWithoutTheTrackersIdIsLeftOut() {
        XCTAssertNil(SimklDiscoverMedia.media(item(simkl: 5, mal: nil, anilist: 42), kind: .anime, tracker: .mal))
    }

    func testOnlyAnimeWithoutAnAniListIdNeedLookingUp() {
        let items = [item(simkl: 1, mal: 10, anilist: 100), item(simkl: 2, mal: 20, anilist: nil),
                     item(simkl: 3, mal: nil, anilist: nil)]
        XCTAssertEqual(SimklDiscoverMedia.malIDsNeedingAniList(items), [20])
    }

    @MainActor
    func testTheMapIsOnlyLookedUpForAnimeWithAniListAsTracker() async {
        let items = [item(simkl: 2, mal: 20, anilist: nil)]
        var asked: [[Int]] = []
        let lookUp: @MainActor ([Int]) async -> [Int: Int] = { ids in
            asked.append(ids)
            return [20: 200]
        }
        let map = await SimklDiscoverMedia.anilistMap(for: items, kind: .anime, tracker: .anilist, lookUp: lookUp)
        XCTAssertEqual(map, [20: 200])
        _ = await SimklDiscoverMedia.anilistMap(for: items, kind: .anime, tracker: .mal, lookUp: lookUp)
        _ = await SimklDiscoverMedia.anilistMap(for: items, kind: .tv, tracker: .anilist, lookUp: lookUp)
        XCTAssertEqual(asked, [[20]])
    }
}
