import XCTest
@testable import Shirox

/// Decoding against the shape Simkl actually returns, not the one its docs imply.
///
/// The first live read failed with `Expected to decode Int but found a string instead` at
/// `anime[0].show.ids.mal` — Simkl sends external ids as strings. These fixtures are taken from
/// that response so the mismatch cannot come back.
final class SimklDecodingTests: XCTestCase {

    private func entries(from json: String) throws -> [LibraryEntry] {
        try SimklLibraryService.decodeLibrary(from: Data(json.utf8))
    }

    /// The shape that broke: ids as strings.
    func testDecodesIdsSentAsStrings() throws {
        let entries = try self.entries(from: """
        {"anime":[{"show":{"title":"Frieren","ids":{"simkl":1234,"mal":"52991","anilist":"154587"}},
          "status":"watching","watched_episodes_count":13,"total_episodes_count":28,"user_rating":9}]}
        """)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].media.idMal, 52991)
        XCTAssertEqual(entries[0].progress, 13)
        XCTAssertEqual(entries[0].status, .current)
        XCTAssertEqual(entries[0].score, 9)
    }

    /// Numeric ids must keep working — Simkl is inconsistent about which form it sends.
    func testDecodesIdsSentAsNumbers() throws {
        let entries = try self.entries(from: """
        {"anime":[{"show":{"title":"Frieren","ids":{"simkl":1234,"mal":52991}},
          "status":"completed","watched_episodes_count":28,"total_episodes_count":28}]}
        """)

        XCTAssertEqual(entries[0].media.idMal, 52991)
        XCTAssertEqual(entries[0].status, .completed)
    }

    /// An unrated title is score 0, not a spurious rating.
    func testMissingRatingIsUnrated() throws {
        let entries = try self.entries(from: """
        {"anime":[{"show":{"title":"X","ids":{"mal":"1"}},"status":"hold","watched_episodes_count":2}]}
        """)

        XCTAssertEqual(entries[0].score, 0)
        XCTAssertEqual(entries[0].status, .paused)
    }

    /// A title with no usable id cannot be paired with anything, so it is dropped rather than
    /// failing the whole read.
    func testEntryWithNoUsableIdIsSkippedNotFatal() throws {
        let entries = try self.entries(from: """
        {"anime":[{"show":{"title":"X","ids":{"simkl":99}},"status":"watching","watched_episodes_count":1},
                  {"show":{"title":"Y","ids":{"mal":"7"}},"status":"watching","watched_episodes_count":1}]}
        """)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].media.idMal, 7)
    }

    /// An empty library is a valid answer, not an error.
    func testEmptyLibraryDecodes() throws {
        XCTAssertTrue(try entries(from: #"{"anime":[]}"#).isEmpty)
        XCTAssertTrue(try entries(from: #"{}"#).isEmpty)
    }

    // MARK: - Phase 2 delta merging

    private func entry(id: Int, progress: Int) -> LibraryEntry {
        LibraryEntry(
            id: id,
            media: Media(
                id: id, idMal: id, provider: .simkl,
                title: MediaTitle(romaji: "Title \(id)", english: "Title \(id)", native: nil),
                coverImage: MediaCoverImage(large: nil, extraLarge: nil),
                bannerImage: nil, description: nil, episodes: nil, status: nil,
                averageScore: nil, genres: nil, season: nil, seasonYear: nil,
                nextAiringEpisode: nil, relations: nil, type: nil, format: nil
            ),
            status: .current, progress: progress, score: 0, timesRewatched: nil)
    }

    /// THE ONE THAT MATTERS: a delta is not a library. Simkl's Phase 2 returns only what changed,
    /// so handing that straight to a sync run would look like the user owns three titles — and a
    /// mirror run would delete everything else.
    func testDeltaIsMergedOverTheCachedLibraryNotSubstitutedForIt() {
        let cached = [entry(id: 1, progress: 5), entry(id: 2, progress: 8), entry(id: 3, progress: 1)]
        let delta = [entry(id: 2, progress: 12)]

        let merged = SimklLibraryService.merge(delta, into: cached)

        XCTAssertEqual(merged.count, 3, "untouched titles must survive the delta")
        XCTAssertEqual(merged.first { $0.media.id == 2 }?.progress, 12)
        XCTAssertEqual(merged.first { $0.media.id == 1 }?.progress, 5)
    }

    func testDeltaCanAddTitlesTheCacheHadNeverSeen() {
        let merged = SimklLibraryService.merge([entry(id: 9, progress: 1)], into: [entry(id: 1, progress: 5)])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.media.id), [1, 9], "existing order is kept, new titles append")
    }

    func testEmptyDeltaLeavesTheLibraryUntouched() {
        let cached = [entry(id: 1, progress: 5), entry(id: 2, progress: 8)]
        XCTAssertEqual(SimklLibraryService.merge([], into: cached).map(\.progress), [5, 8])
    }

    // MARK: - Completed means fully watched

    /// THE ONE THAT MATTERS: Simkl stores no per-episode history for a completed title, so
    /// watched_episodes_count stays 0. Taken literally, every completed anime looked unwatched,
    /// every sync decided the library was behind, and the rewrite could never move the number it
    /// was reading — so it rewrote the same titles on every run, forever.
    func testCompletedCountsAsEveryEpisodeWatched() throws {
        let entries = try self.entries(from: """
        {"anime":[{"show":{"title":"Frieren","ids":{"mal":"52991"}},
          "status":"completed","watched_episodes_count":0,"total_episodes_count":28}]}
        """)

        XCTAssertEqual(entries[0].progress, 28, "completed means all of them, however it is stored")
        XCTAssertEqual(entries[0].status, .completed)
    }

    /// An explicit count higher than the total is kept — never reduced by the inference.
    func testAnExplicitCountIsNeverReducedByTheInference() {
        XCTAssertEqual(
            SimklLibraryService.progress(watched: 30, total: 28, status: .completed), 30)
    }

    /// The inference applies only to completed. A dropped or paused title keeps its real count.
    func testOnlyCompletedInfersFullProgress() {
        XCTAssertEqual(SimklLibraryService.progress(watched: 3, total: 28, status: .dropped), 3)
        XCTAssertEqual(SimklLibraryService.progress(watched: 3, total: 28, status: .paused), 3)
        XCTAssertEqual(SimklLibraryService.progress(watched: 3, total: 28, status: .current), 3)
        XCTAssertEqual(SimklLibraryService.progress(watched: 0, total: 28, status: .planning), 0)
    }

    /// A completed title whose total Simkl does not know keeps whatever count it has, rather
    /// than inventing one.
    func testCompletedWithNoKnownTotalKeepsItsCount() {
        XCTAssertEqual(SimklLibraryService.progress(watched: 5, total: nil, status: .completed), 5)
        XCTAssertEqual(SimklLibraryService.progress(watched: 0, total: 0, status: .completed), 0)
    }

    /// Every status Simkl can send maps back; anything unknown falls back to the numbers.
    func testEveryStatusMapsBack() {
        XCTAssertEqual(SimklLibraryService.status(from: "plantowatch", progress: 0, total: 12), .planning)
        XCTAssertEqual(SimklLibraryService.status(from: "completed", progress: 12, total: 12), .completed)
        XCTAssertEqual(SimklLibraryService.status(from: "dropped", progress: 3, total: 12), .dropped)
        XCTAssertEqual(SimklLibraryService.status(from: "hold", progress: 3, total: 12), .paused)
        XCTAssertEqual(SimklLibraryService.status(from: "watching", progress: 3, total: 12), .current)
        XCTAssertEqual(SimklLibraryService.status(from: nil, progress: 12, total: 12), .completed)
        XCTAssertEqual(SimklLibraryService.status(from: nil, progress: 3, total: 12), .current)
    }

    /// Simkl sends `notinteresting` where newer registrations get `dropped`, keyed to how old the
    /// registering app is. The fallback would otherwise read a dropped show as being watched.
    func testNotInterestingReadsAsDropped() {
        XCTAssertEqual(SimklLibraryService.status(from: "notinteresting", progress: 3, total: 12), .dropped)
    }
}
