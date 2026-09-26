import XCTest
@testable import Shirox

/// TMDB's logos, for titles TVDB has none for.
final class TMDBLogoTests: XCTestCase {

    private func logo(_ path: String, _ language: String? = "en", vote: Double = 0, size: Int = 100) -> TMDBImage {
        TMDBImage(file_path: path, iso_639_1: language, vote_average: vote, width: size, height: size)
    }

    func testEnglishThenTheTitlesOwnLanguageThenNone() {
        XCTAssertEqual(TMDBLogo.pick([logo("/ja.png", "ja", vote: 9), logo("/en.png")], originalLanguage: "ja"), "/en.png")
        XCTAssertEqual(TMDBLogo.pick([logo("/zh.png", "zh"), logo("/ja.png", "ja")], originalLanguage: "ja"), "/ja.png")
        XCTAssertEqual(TMDBLogo.pick([logo("/zh.png", "zh"), logo("/none.png", nil)], originalLanguage: "en"), "/none.png")
        XCTAssertNil(TMDBLogo.pick([logo("/zh.png", "zh")], originalLanguage: "en"),
                     "An English film with only a Chinese logo shows its title instead")
    }

    /// TMDB serves an SVG as SVG at every size, which the app can't draw.
    func testAnSVGIsPassedOver() {
        XCTAssertEqual(TMDBLogo.pick([logo("/a.svg", vote: 9), logo("/b.png")], originalLanguage: "en"), "/b.png")
        XCTAssertNil(TMDBLogo.pick([logo("/a.SVG")], originalLanguage: "en"))
    }

    func testTheBestVotedThenTheLargest() {
        XCTAssertEqual(TMDBLogo.pick([logo("/low.png", vote: 1), logo("/high.png", vote: 5)], originalLanguage: "en"), "/high.png")
        XCTAssertEqual(TMDBLogo.pick([logo("/small.png", size: 100), logo("/large.png", size: 500)], originalLanguage: "en"), "/large.png")
    }

    func testTheImageAddress() {
        XCTAssertEqual(TMDBLogo.imageURL("/abc.png"), "https://image.tmdb.org/t/p/w500/abc.png")
    }

    func testTheRecordsPaths() {
        XCTAssertEqual(TitleRecord.series.tmdbPath, "tv")
        XCTAssertEqual(TitleRecord.movie.tmdbPath, "movie")
        XCTAssertEqual(TitleRecord.series.tvdbPath, "series")
        XCTAssertEqual(TitleRecord.movie.tvdbPath, "movies")
    }

    // MARK: - The key

    /// A build without the gitignored local config has an empty setting — or, where the
    /// variable was never defined, Xcode's unexpanded text. Either way TMDB is skipped.
    func testTheKeyIsReadOnlyWhenSet() {
        XCTAssertEqual(TMDBLogoService.apiKey(in: ["TMDBAPIKey": " abc123 "]), "abc123")
        XCTAssertNil(TMDBLogoService.apiKey(in: ["TMDBAPIKey": ""]))
        XCTAssertNil(TMDBLogoService.apiKey(in: ["TMDBAPIKey": "$(TMDB_API_KEY)"]))
        XCTAssertNil(TMDBLogoService.apiKey(in: [:]))
    }

    // MARK: - Where an anime's TMDB logo is

    func testAnAnimesTMDBRecordIsItsFilmElseItsShow() {
        typealias Mapping = TVDBMappingService.BulkMapping
        let film = Mapping(mal_id: 1, anilist_id: 2, tvdb_id: nil, tvdb_season: nil, tvdb_epoffset: nil,
                           tmdb_show_id: nil, tmdb_movie_id: 568160)
        XCTAssertEqual(film.tmdbTitle?.id, 568160)
        XCTAssertEqual(film.tmdbTitle?.record, .movie)

        let season = Mapping(mal_id: 1, anilist_id: 2, tvdb_id: 305089, tvdb_season: 3, tvdb_epoffset: 0,
                             tmdb_show_id: 65942, tmdb_movie_id: nil)
        XCTAssertEqual(season.tmdbTitle?.id, 65942)
        XCTAssertEqual(season.tmdbTitle?.record, .series)

        XCTAssertNil(Mapping(mal_id: 1, anilist_id: 2, tvdb_id: 1, tvdb_season: 1, tvdb_epoffset: 0).tmdbTitle)
    }

    /// anira's snapshot, as the app keeps it on disk — the TMDB ids now among what's kept.
    func testTheSnapshotKeepsTMDBIds() throws {
        let json = #"[{"mal_id":59741,"anilist_id":180136,"tvdb_id":453028,"tvdb_season":1,"tvdb_epoffset":0,"tmdb_show_id":270603,"tmdb_movie_id":null,"kitsu_id":1}]"#
        let entry = try XCTUnwrap(JSONDecoder().decode([TVDBMappingService.BulkMapping].self, from: Data(json.utf8)).first)
        XCTAssertEqual(entry.tmdb_show_id, 270603)
        let saved = try JSONDecoder().decode([TVDBMappingService.BulkMapping].self,
                                             from: JSONEncoder().encode([entry]))
        XCTAssertEqual(saved.first?.tmdb_show_id, 270603)

        let old = #"[{"mal_id":59741,"anilist_id":180136,"tvdb_id":453028,"tvdb_season":1,"tvdb_epoffset":0}]"#
        XCTAssertNil(try JSONDecoder().decode([TVDBMappingService.BulkMapping].self, from: Data(old.utf8)).first?.tmdbTitle,
                     "A snapshot saved before still reads")
    }
}
