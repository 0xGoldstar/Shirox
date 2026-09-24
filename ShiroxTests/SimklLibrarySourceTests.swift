import XCTest
@testable import Shirox

/// The Simkl list sits beside AniList's and MyAnimeList's without ever becoming the app's
/// primary provider, and writes to exactly the entry on screen.
final class SimklLibrarySourceTests: XCTestCase {

    private func media(id: Int, idMal: Int?) -> Media {
        Media(id: id, idMal: idMal, provider: .simkl,
              title: MediaTitle(romaji: "Frieren", english: "Frieren", native: nil),
              coverImage: MediaCoverImage(large: nil, extraLarge: nil),
              bannerImage: nil, description: nil, episodes: 28, status: nil,
              averageScore: nil, genres: nil, season: nil, seasonYear: nil,
              nextAiringEpisode: nil, relations: nil, type: nil, format: nil)
    }

    private func entry(id: Int, mediaId: Int, idMal: Int?) -> LibraryEntry {
        LibraryEntry(id: id, media: media(id: mediaId, idMal: idMal), status: .current,
                     progress: 3, score: 0, timesRewatched: nil)
    }

    // MARK: - The source

    func testChoosingSimklNeverChangesThePrimaryProvider() {
        XCTAssertNil(LibrarySource.simkl.providerToSelect)
        XCTAssertNil(LibrarySource.local.providerToSelect)
        XCTAssertEqual(LibrarySource.provider(.mal).providerToSelect, .mal)
    }

    func testSimklListsAnimeShowsAndMovies() {
        XCTAssertEqual(LibrarySource.simkl.mediaKinds, [.anime, .tv, .movie])
        XCTAssertEqual(LibrarySource.provider(.anilist).mediaKinds, [.anime, .manga])
        XCTAssertEqual(LibrarySource.local.mediaKinds, [.anime, .manga])
    }

    func testSimklHasTheFiveListsWithoutRewatching() {
        let order: [MediaListStatus] = [.repeating, .current, .planning, .paused, .dropped, .completed]
        XCTAssertEqual(LibrarySource.simkl.statuses(in: order),
                       [.current, .planning, .paused, .dropped, .completed])
        XCTAssertEqual(LibrarySource.provider(.anilist).statuses(in: order), order)
    }

    func testSigningOutPrefersThePrimaryProvider() {
        XCTAssertEqual(LibrarySource.afterSignOut(primary: .mal, signedIn: [.anilist, .mal]), .provider(.mal))
    }

    func testSigningOutFallsToAnyProviderThenSimklThenMyLibrary() {
        XCTAssertEqual(LibrarySource.afterSignOut(primary: .anilist, signedIn: [.mal, .simkl]), .provider(.mal))
        XCTAssertEqual(LibrarySource.afterSignOut(primary: .anilist, signedIn: [.simkl]), .simkl)
        XCTAssertEqual(LibrarySource.afterSignOut(primary: .anilist, signedIn: []), .local)
    }

    // MARK: - Which entry a write goes to

    func testPairingIdsFollowHowEntriesAreKeyed() {
        let byMAL = SimklLibraryService.pairingIDs(of: media(id: 52991, idMal: 52991))
        XCTAssertEqual(byMAL.mal, 52991)
        XCTAssertNil(byMAL.anilist)

        let byAniList = SimklLibraryService.pairingIDs(of: media(id: 154587, idMal: nil))
        XCTAssertNil(byAniList.mal)
        XCTAssertEqual(byAniList.anilist, 154587)
    }

    /// `entry(from:)` falls back to the pairing id when Simkl sent no Simkl id; written as
    /// `ids.simkl`, that number would address some other show.
    func testAMissingSimklIdIsNeverWrittenAsOne() {
        XCTAssertEqual(SimklLibraryService.simklID(of: entry(id: 1234, mediaId: 52991, idMal: 52991)), 1234)
        XCTAssertNil(SimklLibraryService.simklID(of: entry(id: 52991, mediaId: 52991, idMal: 52991)))
    }

    func testWritesTargetTheEntrysSimklId() {
        let entry = entry(id: 1234, mediaId: 52991, idMal: 52991)
        let pair = SimklLibraryService.pairingIDs(of: entry.media)
        XCTAssertEqual(
            SimklLibraryService.writeIDs(malId: pair.mal, anilistId: pair.anilist,
                                         simklId: SimklLibraryService.simklID(of: entry)),
            ["simkl": 1234])
    }
}
