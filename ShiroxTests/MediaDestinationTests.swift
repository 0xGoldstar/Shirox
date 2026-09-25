import XCTest
@testable import Shirox

/// A Simkl show or movie opens its Simkl page; everything else the anime page. TVDB art is
/// only looked up for titles whose ids TVDB's mapping knows.
@MainActor
final class MediaDestinationTests: XCTestCase {
    private func media(provider: ProviderType, type: String? = nil) -> Media {
        Media(id: 7, idMal: nil, provider: provider, title: MediaTitle(romaji: nil, english: "T", native: nil),
              coverImage: MediaCoverImage(large: nil, extraLarge: nil), bannerImage: nil, description: nil,
              episodes: nil, status: nil, averageScore: nil, genres: nil, season: nil, seasonYear: nil,
              nextAiringEpisode: nil, relations: nil, type: type, format: nil)
    }

    func testASimklShowOrMovieOpensTheSimklPage() {
        XCTAssertEqual(MediaDestination.target(for: media(provider: .simkl, type: Media.simklTVType)),
                       .simklTitle(simklID: 7, kind: .tv))
        XCTAssertEqual(MediaDestination.target(for: media(provider: .simkl, type: Media.simklMovieType)),
                       .simklTitle(simklID: 7, kind: .movie))
    }

    func testEverythingElseOpensTheAnimePage() {
        XCTAssertEqual(MediaDestination.target(for: media(provider: .anilist, type: "ANIME")), .anime(id: 7))
        XCTAssertEqual(MediaDestination.target(for: media(provider: .mal)), .anime(id: 7))
    }

    /// TVDB art is found through AniList and MyAnimeList ids; any other id would be looked up as
    /// an AniList one and show some other title's art.
    func testOnlyAniListAndMALTitlesUseTVDBArtwork() {
        XCTAssertTrue(media(provider: .anilist).usesTVDBArtwork)
        XCTAssertTrue(media(provider: .mal).usesTVDBArtwork)
        XCTAssertFalse(media(provider: .simkl, type: Media.simklTVType).usesTVDBArtwork)
        XCTAssertFalse(media(provider: .simkl).usesTVDBArtwork)
        XCTAssertFalse(media(provider: .local).usesTVDBArtwork)
    }
}
