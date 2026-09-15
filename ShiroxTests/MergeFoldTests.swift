import XCTest
@testable import Shirox

/// The all-ways merge must have one answer per title, not a sequence of pairwise updates whose
/// result depends on the order the sides happened to be visited in.
final class MergeFoldTests: XCTestCase {

    private func entry(_ progress: Int, status: MediaListStatus = .current,
                       score: Double = 0, rewatches: Int? = nil) -> LibraryEntry {
        LibraryEntry(
            id: 1,
            media: Media(
                id: 1, idMal: 1, provider: .anilist,
                title: MediaTitle(romaji: "Title", english: "Title", native: nil),
                coverImage: MediaCoverImage(large: nil, extraLarge: nil),
                bannerImage: nil, description: nil, episodes: nil, status: nil,
                averageScore: nil, genres: nil, season: nil, seasonYear: nil,
                nextAiringEpisode: nil, relations: nil, type: nil, format: nil
            ),
            status: status, progress: progress, score: score, timesRewatched: rewatches)
    }

    func testFurthestAlongEntryWins() {
        let winner = LibrarySyncPlanner.winner(among: [entry(3), entry(9), entry(5)])
        XCTAssertEqual(winner?.progress, 9)
    }

    /// Order must not change the answer — that is the whole point of folding to a winner rather
    /// than running a chain of pairwise writes.
    func testResultDoesNotDependOnOrder() {
        let entries = [entry(3), entry(9), entry(5)]
        let forward = LibrarySyncPlanner.winner(among: entries)?.progress
        let backward = LibrarySyncPlanner.winner(among: entries.reversed())?.progress
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward, 9)
    }

    /// A rewatch in progress outranks a higher raw episode count, exactly as `decide` ranks it:
    /// episode 4 of a second watch is further along than episode 12 of a first.
    func testRewatchOutranksRawProgress() {
        let winner = LibrarySyncPlanner.winner(among: [
            entry(12, status: .completed),
            entry(4, status: .repeating, rewatches: 2),
        ])
        XCTAssertEqual(winner?.timesRewatched, 2)
    }

    func testEmptyInputHasNoWinner() {
        XCTAssertNil(LibrarySyncPlanner.winner(among: []))
    }

    func testWinnerOfOneSideIsThatSide() {
        XCTAssertEqual(LibrarySyncPlanner.winner(among: [entry(7)])?.progress, 7)
    }

    /// Equal entries must not flip-flop: whichever is first stays, so a re-run writes nothing.
    func testEqualEntriesKeepTheFirst() {
        let a = entry(5, score: 8)
        let b = entry(5, score: 0)
        XCTAssertEqual(LibrarySyncPlanner.winner(among: [a, b])?.score, 8)
    }
}
