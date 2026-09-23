import XCTest
@testable import Shirox

/// The first live sync reported "396 updated, 28 not found" and **nothing added**. Only Simkl
/// entries were contributing a `.simkl` id, so a title AniList had and Simkl did not got no id
/// for the target side, was skipped by `runSync`'s guard, and was then reported as unmatched
/// rather than created. Every side must be able to address Simkl.
final class SimklSideIDTests: XCTestCase {

    private func entry(id: Int, idMal: Int?) -> LibraryEntry {
        LibraryEntry(
            id: id,
            media: Media(
                id: id, idMal: idMal, provider: .anilist,
                title: MediaTitle(romaji: "T", english: "T", native: nil),
                coverImage: MediaCoverImage(large: nil, extraLarge: nil),
                bannerImage: nil, description: nil, episodes: nil, status: nil,
                averageScore: nil, genres: nil, season: nil, seasonYear: nil,
                nextAiringEpisode: nil, relations: nil, type: nil, format: nil
            ),
            status: .current, progress: 1, score: 0, timesRewatched: nil)
    }

    /// THE REGRESSION: an AniList title Simkl has never seen must still resolve a Simkl id, or
    /// it can never be created there.
    func testAniListEntryCanAddressSimkl() {
        let ids = LibrarySyncService.sideIDs(
            for: .anilist, entry: entry(id: 100, idMal: nil),
            malForAniList: [100: 900], anilistForMAL: [:])

        XCTAssertEqual(ids[.simkl], 900, "Simkl is addressed by MyAnimeList id")
        XCTAssertEqual(ids[.mal], 900)
        XCTAssertEqual(ids[.anilist], 100)
    }

    func testMALEntryCanAddressSimkl() {
        let ids = LibrarySyncService.sideIDs(
            for: .mal, entry: entry(id: 900, idMal: nil),
            malForAniList: [:], anilistForMAL: [900: 100])

        XCTAssertEqual(ids[.simkl], 900)
        XCTAssertEqual(ids[.anilist], 100)
    }

    /// Falls back to the entry's own idMal when the mapping service had no answer.
    func testAniListEntryUsesItsOwnMALIdWhenTheMapIsEmpty() {
        let ids = LibrarySyncService.sideIDs(
            for: .anilist, entry: entry(id: 100, idMal: 900),
            malForAniList: [:], anilistForMAL: [:])

        XCTAssertEqual(ids[.simkl], 900)
    }

    /// All three sides must agree on the value, or they land on different pairs.
    func testEverySideResolvesTheSameSimklID() {
        let fromAniList = LibrarySyncService.sideIDs(
            for: .anilist, entry: entry(id: 100, idMal: 900),
            malForAniList: [100: 900], anilistForMAL: [:])
        let fromMAL = LibrarySyncService.sideIDs(
            for: .mal, entry: entry(id: 900, idMal: nil),
            malForAniList: [:], anilistForMAL: [900: 100])
        let fromSimkl = LibrarySyncService.sideIDs(
            for: .simkl, entry: entry(id: 900, idMal: 900),
            malForAniList: [:], anilistForMAL: [:])

        XCTAssertEqual(fromAniList[.simkl], 900)
        XCTAssertEqual(fromMAL[.simkl], 900)
        XCTAssertEqual(fromSimkl[.simkl], 900)
    }

    /// A title with no MyAnimeList id anywhere genuinely cannot be addressed on Simkl. It is
    /// reported as unmatched rather than written to a guessed id.
    func testTitleWithNoMALIdCannotAddressSimkl() {
        let ids = LibrarySyncService.sideIDs(
            for: .anilist, entry: entry(id: 100, idMal: nil),
            malForAniList: [:], anilistForMAL: [:])

        XCTAssertNil(ids[.simkl])
        XCTAssertEqual(ids[.anilist], 100)
    }

    private func cachedLibrary() throws -> [LibraryEntry] {
        let json = """
        {"anime":[
          {"show":{"title":"A","ids":{"mal":900,"anilist":100}},"status":"watching","watched_episodes_count":3,"total_episodes_count":12},
          {"show":{"title":"B","ids":{"anilist":200}},"status":"watching","watched_episodes_count":1,"total_episodes_count":12}
        ]}
        """
        return try SimklLibraryService.decodeLibrary(from: Data(json.utf8))
    }

    func testCachedEntryIsFoundByMyAnimeListId() throws {
        XCTAssertEqual(SimklLibraryService.entry(in: try cachedLibrary(), malId: 900, anilistId: nil)?.progress, 3)
    }

    func testAniListOnlyEntryIsFoundByAniListId() throws {
        XCTAssertEqual(SimklLibraryService.entry(in: try cachedLibrary(), malId: 901, anilistId: 200)?.progress, 1)
    }

    /// Entries Simkl keyed by MyAnimeList id don't keep the AniList id, so callers resolve the
    /// MyAnimeList id first. An AniList id alone must not match some other entry's number.
    func testAnAniListIdDoesNotMatchAMyAnimeListKeyedEntry() throws {
        XCTAssertNil(SimklLibraryService.entry(in: try cachedLibrary(), malId: nil, anilistId: 100))
    }

    func testCachedEntryIsFoundBySimklId() throws {
        let json = #"{"anime":[{"show":{"title":"A","ids":{"simkl":37145,"mal":900}},"status":"watching","watched_episodes_count":4,"total_episodes_count":12}]}"#
        let entries = try SimklLibraryService.decodeLibrary(from: Data(json.utf8))
        XCTAssertEqual(SimklLibraryService.entry(in: entries, malId: nil, anilistId: nil, simklId: 37145)?.progress, 4)
    }

    /// A linked Simkl id goes out alone: the MAL/AniList ids could steer Simkl back to the entry
    /// the user corrected away from.
    func testALinkedSimklIdIsWrittenAlone() {
        XCTAssertEqual(SimklLibraryService.writeIDs(malId: 900, anilistId: 100, simklId: 37145), ["simkl": 37145])
    }

    func testWithoutALinkTheWriteIdsAreUnchanged() {
        XCTAssertEqual(SimklLibraryService.writeIDs(malId: 900, anilistId: 100, simklId: nil), ["mal": 900, "anilist": 100])
        XCTAssertEqual(SimklLibraryService.writeIDs(malId: nil, anilistId: nil, simklId: nil), [:])
    }
}
