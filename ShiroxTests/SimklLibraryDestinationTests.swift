import XCTest
@testable import Shirox

/// The show page loads from the primary provider, so a Simkl row must hand it that provider's id.
@MainActor
final class SimklLibraryDestinationTests: XCTestCase {

    private let row = Media(
        id: 52991, idMal: 52991, provider: .simkl,
        title: MediaTitle(romaji: "Frieren", english: "Frieren", native: nil),
        coverImage: MediaCoverImage(large: "poster", extraLarge: "poster"),
        bannerImage: nil, description: nil, episodes: 28, status: nil,
        averageScore: nil, genres: nil, season: nil, seasonYear: 2023,
        nextAiringEpisode: nil, relations: nil, type: nil, format: "TV")

    func testAniListPrimaryOpensTheAniListPage() {
        let page = SimklLibraryDestination.media(
            for: row, primary: .anilist, ids: TrackingIDs(anilist: 154587, mal: 52991, simkl: nil))
        XCTAssertEqual(page?.id, 154587)
        XCTAssertEqual(page?.provider, .anilist)
        XCTAssertEqual(page?.idMal, 52991)
    }

    func testMALPrimaryOpensTheMALPage() {
        let page = SimklLibraryDestination.media(
            for: row, primary: .mal, ids: TrackingIDs(anilist: 154587, mal: 52991, simkl: nil))
        XCTAssertEqual(page?.id, 52991)
        XCTAssertEqual(page?.provider, .mal)
    }

    /// THE ONE THAT MATTERS: a MyAnimeList number read as an AniList id opens a different show.
    func testAMALNumberIsNeverOpenedAsAnAniListId() {
        XCTAssertNil(SimklLibraryDestination.media(
            for: row, primary: .anilist, ids: TrackingIDs(anilist: nil, mal: 52991, simkl: nil)))
    }

    func testRebuiltMediaKeepsWhatTheRowShowed() {
        let page = SimklLibraryDestination.media(
            for: row, primary: .anilist, ids: TrackingIDs(anilist: 154587, mal: 52991, simkl: nil))
        XCTAssertEqual(page?.title, row.title)
        XCTAssertEqual(page?.coverImage, row.coverImage)
        XCTAssertEqual(page?.episodes, 28)
        XCTAssertEqual(page?.seasonYear, 2023)
        XCTAssertEqual(page?.format, "TV")
    }

    func testSimklEntriesAreNeverOfferedRewatching() {
        let statuses = LibraryEntryEditSheet.statuses(for: .simkl)
        XCTAssertFalse(statuses.contains(.repeating))
        XCTAssertEqual(statuses.count, 5)
    }

    func testOtherEntriesStillAre() {
        XCTAssertTrue(LibraryEntryEditSheet.statuses(for: .anilist).contains(.repeating))
        XCTAssertTrue(LibraryEntryEditSheet.statuses(for: .mal).contains(.repeating))
    }
}
