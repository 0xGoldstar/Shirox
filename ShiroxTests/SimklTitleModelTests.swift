import XCTest
@testable import Shirox

final class SimklTitleModelTests: XCTestCase {

    private func media(id: Int, provider: ProviderType = .simkl, type: String?) -> Media {
        Media(id: id, idMal: nil, provider: provider,
              title: MediaTitle(romaji: "T", english: "T", native: nil),
              coverImage: MediaCoverImage(large: nil, extraLarge: nil),
              bannerImage: nil, description: nil, episodes: nil, status: nil,
              averageScore: nil, genres: nil, season: nil, seasonYear: nil,
              nextAiringEpisode: nil, relations: nil, type: type, format: nil)
    }

    /// A Simkl anime entry is keyed by MyAnimeList id, a show or movie by Simkl id — the same
    /// number can be both.
    func testShowsAndMoviesNeverShareAnAnimeEntrysIdentity() {
        let anime = media(id: 52991, type: nil)
        let show = media(id: 52991, type: Media.simklTVType)
        let movie = media(id: 52991, type: Media.simklMovieType)
        XCTAssertEqual(anime.uniqueId, "simkl-52991")
        XCTAssertEqual(show.uniqueId, "simkl-tv-52991")
        XCTAssertEqual(movie.uniqueId, "simkl-movie-52991")
        XCTAssertNotEqual(anime, show)
        XCTAssertEqual(show.simklTitleKind, .tv)
        XCTAssertEqual(movie.simklTitleKind, .movie)
        XCTAssertNil(anime.simklTitleKind)
    }

    func testOtherProvidersKeepTheirIdentity() {
        XCTAssertEqual(media(id: 1, provider: .anilist, type: "TV").uniqueId, "anilist-1")
        XCTAssertNil(media(id: 1, provider: .anilist, type: "TV").simklTitleKind)
    }

    func testEntriesSavedWithoutTheNewFieldsStillDecode() throws {
        let entry = LibraryEntry(id: 1, media: media(id: 1, type: nil), status: .current,
                                 progress: 2, score: 0, timesRewatched: nil)
        let data = try JSONEncoder().encode(entry)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("watchedEpisodes"))
        XCTAssertFalse(text.contains("runtime"))
        let decoded = try JSONDecoder().decode(LibraryEntry.self, from: data)
        XCTAssertNil(decoded.watchedEpisodes)
        XCTAssertNil(decoded.media.runtime)
    }

    func testAShowsWatchedEpisodesRoundTrip() throws {
        var entry = LibraryEntry(id: 2090, media: media(id: 2090, type: Media.simklTVType),
                                 status: .current, progress: 3, score: 0, timesRewatched: nil)
        entry.watchedEpisodes = [SimklSeasonWatch(season: 1, episodes: [1, 2, 3])]
        let decoded = try JSONDecoder().decode(LibraryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.watchedEpisodes, entry.watchedEpisodes)
        XCTAssertEqual(decoded.media.uniqueId, "simkl-tv-2090")
    }

    func testSimklPathsPerKind() {
        XCTAssertEqual(MediaKind.simklKinds, [.anime, .tv, .movie])
        XCTAssertEqual(MediaKind.tv.simklListPath, "shows")
        XCTAssertEqual(MediaKind.movie.simklListPath, "movies")
        XCTAssertEqual(MediaKind.anime.simklListPath, "anime")
        XCTAssertEqual(MediaKind.movie.simklSearchPath, "movie")
        XCTAssertEqual(MediaKind.tv.simklSearchPath, "tv")
        XCTAssertEqual(MediaKind.tv.simklActivitiesKey, "tv_shows")
        XCTAssertEqual(MediaKind.anime.simklWriteKey, "shows")
        XCTAssertEqual(MediaKind.movie.simklWriteKey, "movies")
    }

    func testEpisodesOrderBySeasonThenNumber() {
        let a = SimklEpisodeRef(season: 1, episode: 10)
        let b = SimklEpisodeRef(season: 2, episode: 1)
        XCTAssertLessThan(a, b)
        XCTAssertEqual(b.label, "S2 E1")
        let special = SimklEpisode(season: nil, episode: nil, title: "Special", aired: true,
                                   img: nil, date: nil, isSpecial: true, simklID: 9)
        XCTAssertNil(special.ref)
    }
}
