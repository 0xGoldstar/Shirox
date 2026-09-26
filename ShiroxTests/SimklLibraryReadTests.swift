import XCTest
@testable import Shirox

/// The Library shows Simkl's list itself, so a read keeps what a row needs to look like one —
/// and a failed read says why in words the user can act on.
final class SimklLibraryReadTests: XCTestCase {

    private func entries(from json: String) throws -> [LibraryEntry] {
        try SimklLibraryService.decodeLibrary(from: Data(json.utf8))
    }

    private let frieren = """
    {"anime":[{"show":{"title":"Frieren","poster":"74/74415673dcdc9cdd","year":2023,
      "ids":{"simkl":1234,"mal":"52991","anilist":"154587"}},"anime_type":"tv",
      "status":"watching","watched_episodes_count":13,"total_episodes_count":28}]}
    """

    func testKeepsPosterYearAndType() throws {
        let media = try entries(from: frieren)[0].media
        let url = "https://wsrv.nl/?url=https://simkl.in/posters/74/74415673dcdc9cdd_m.webp&q=90"
        XCTAssertEqual(media.coverImage.large, url)
        XCTAssertEqual(media.coverImage.extraLarge, url)
        XCTAssertEqual(media.seasonYear, 2023)
        XCTAssertEqual(media.format, "TV")
    }

    /// Sync pairs on these; the display fields must not move them.
    func testIdsAreUnchanged() throws {
        let entry = try entries(from: frieren)[0]
        XCTAssertEqual(entry.id, 1234)
        XCTAssertEqual(entry.media.id, 52991)
        XCTAssertEqual(entry.media.idMal, 52991)
        XCTAssertEqual(entry.media.provider, .simkl)
    }

    func testMissingDisplayFieldsStayEmpty() throws {
        let media = try entries(from: """
        {"anime":[{"show":{"title":"X","ids":{"mal":"1"}},"status":"hold"}]}
        """)[0].media
        XCTAssertNil(media.coverImage.large)
        XCTAssertNil(media.seasonYear)
        XCTAssertNil(media.format)
    }

    /// Simkl sends ids as strings despite its docs; a year sent the same way must not fail the
    /// whole library.
    func testYearSentAsStringStillDecodes() throws {
        let entries = try entries(from: """
        {"anime":[{"show":{"title":"X","year":"2023","ids":{"mal":"1"}},"status":"hold"}]}
        """)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].media.seasonYear, 2023)
    }

    func testAnimeTypeBecomesAniListsFormat() {
        XCTAssertEqual(SimklLibraryService.format(fromAnimeType: "ova"), "OVA")
        XCTAssertEqual(SimklLibraryService.format(fromAnimeType: "music video"), "MUSIC")
        XCTAssertNil(SimklLibraryService.format(fromAnimeType: nil))
        XCTAssertNil(SimklLibraryService.format(fromAnimeType: ""))
    }

    /// A cache written before posters were kept has none, and a delta read only refreshes titles
    /// that changed — so that cache must be read again in full, once.
    func testCacheFromBeforePostersIsReadAgain() {
        XCTAssertFalse(SimklLibraryService.cacheIsCurrent(storedVersion: 0))
        XCTAssertFalse(SimklLibraryService.cacheIsCurrent(storedVersion: 1))
        XCTAssertTrue(SimklLibraryService.cacheIsCurrent(storedVersion: SimklLibraryService.cacheVersion))
    }

    func testDailyLimitSaysWhenItClears() {
        let error = SimklLibraryService.thrownError(for: .dailyLimit(retryAfter: nil), status: 429)
        XCTAssertEqual(error as? SimklError, .dailyLimit)
        XCTAssertTrue(error.localizedDescription.contains("midnight US Eastern"))
    }

    func testOtherFailuresKeepTheirStatus() {
        let error = SimklLibraryService.thrownError(for: .other(500), status: 500)
        guard case ProviderError.serverError(500)? = error as? ProviderError else {
            return XCTFail("expected serverError(500), got \(error)")
        }
    }

    func testReadOnlySaysToSignInAgain() {
        XCTAssertEqual(SimklError.readOnly.localizedDescription, "Sign in to Simkl again to allow edits.")
    }

    // MARK: - Anime without the tracker's ids

    private let mixedRead = #"""
    {"anime":[
      {"show":{"title":"Frieren","poster":"12/abc","year":2023,"ids":{"simkl":1,"mal":"52991"}},
       "status":"watching","watched_episodes_count":4,"total_episodes_count":28},
      {"show":{"title":"Feng Tian Qi","poster":"34/def","year":2026,"ids":{"simkl":3226062}},
       "status":"plantowatch","watched_episodes_count":0,"total_episodes_count":10,"user_rating":8}
    ]}
    """#

    /// Anime without the tracker's ids stay out of the synced copy and come back as Simkl titles.
    func testSimklOnlyAnimeAreReadApart() throws {
        let data = Data(mixedRead.utf8)
        XCTAssertEqual(try SimklLibraryService.decodeLibrary(from: data).map(\.media.id), [52991])
        let only = try SimklLibraryService.decodeSimklOnlyAnime(from: data)
        XCTAssertEqual(only.map(\.id), [3226062])
        XCTAssertEqual(only.first?.media.simklTitleKind, .anime)
        XCTAssertEqual(only.first?.media.id, 3226062)
        XCTAssertEqual(only.first?.status, .planning)
        XCTAssertEqual(only.first?.media.episodes, 10)
        XCTAssertEqual(only.first?.score, 8)
    }

    /// The anime copy is read again in full once, so Simkl-only anime already listed turn up.
    func testTheAnimeCopyIsReadAgainOnce() {
        XCTAssertFalse(SimklLibraryService.cacheIsCurrent(storedVersion: 2, kind: .anime))
        XCTAssertTrue(SimklLibraryService.cacheIsCurrent(storedVersion: 3, kind: .anime))
        XCTAssertTrue(SimklLibraryService.cacheIsCurrent(storedVersion: 2, kind: .tv), "Shows and movies aren't")
    }

    @MainActor
    func testAFullReadReplacesADeltaMergesARemovalsCheckKeeps() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let store = SimklOnlyAnimeStore(file: file)
        let entries = (try? SimklLibraryService.decodeSimklOnlyAnime(from: Data(mixedRead.utf8))) ?? []
        SimklLibraryService.updateSimklOnly(store, read: .full, found: entries, present: nil)
        XCTAssertEqual(store.entries.map(\.id), [3226062])
        SimklLibraryService.updateSimklOnly(store, read: .delta(since: "x"), found: [], present: nil)
        XCTAssertEqual(store.entries.map(\.id), [3226062], "A delta without it leaves it")
        SimklLibraryService.updateSimklOnly(store, read: .upToDate, found: [], present: [1])
        XCTAssertTrue(store.entries.isEmpty, "Gone from the list")
    }
}
