import XCTest
@testable import Shirox

/// The canonical-key join is what lets a third tracking side exist at all: every side that
/// resolves to the same key contributes to one pair, with no pairwise id-map dance.
final class LibraryPairingTests: XCTestCase {

    /// Mirrors the helper in `LibrarySyncPlannerTests` exactly. `displayTitle` consults a
    /// UserDefaults title-language preference, so both english and romaji are set to the same
    /// string — a helper that sets only one is at the mercy of the machine's settings.
    private func entry(id: Int, progress: Int) -> LibraryEntry {
        LibraryEntry(
            id: id,
            media: Media(
                id: id, idMal: id, provider: .anilist,
                title: MediaTitle(romaji: "Title \(id)", english: "Title \(id)", native: nil),
                coverImage: MediaCoverImage(large: nil, extraLarge: nil),
                bannerImage: nil, description: nil, episodes: nil, status: nil,
                averageScore: nil, genres: nil, season: nil, seasonYear: nil,
                nextAiringEpisode: nil, relations: nil, type: nil, format: nil
            ),
            status: .current, progress: progress, score: 0, timesRewatched: nil)
    }

    // NOTE: the two Simkl cases below are restored in Task 3, once `.simkl` exists.

    /// A title nothing can identify is reported rather than silently dropped.
    func testTitleWithNoIdsAtAllIsReportedUnmatched() {
        let pairing = LibrarySyncPlanner.pair(
            entries: [.anilist: [entry(id: 100, progress: 5)]],
            ids: { _, _ in [:] })

        XCTAssertTrue(pairing.pairs.isEmpty)
        XCTAssertEqual(pairing.unmatched, ["Title 100"])
    }

    /// "Unmatched" is relative to the side being written to: a pair with no id on that side
    /// has nowhere to put the title, whichever side it came from.
    func testUnmatchedIsRelativeToTheSideBeingWrittenTo() {
        let pairing = LibrarySyncPlanner.pair(
            entries: [.anilist: [entry(id: 100, progress: 5)]],
            ids: { _, _ in [.anilist: 100] })

        XCTAssertEqual(pairing.unmatched(writingTo: .mal), ["Title 100"])
        XCTAssertTrue(pairing.unmatched(writingTo: .anilist).isEmpty)
    }

    /// Two sides sharing a MyAnimeList id collapse into one pair.
    func testTwoSidesSharingAMALIdBecomeOnePair() {
        let pairing = LibrarySyncPlanner.pair(
            entries: [
                .anilist: [entry(id: 100, progress: 5)],
                .mal:     [entry(id: 900, progress: 3)],
            ],
            ids: { _, _ in [.anilist: 100, .mal: 900] })

        XCTAssertEqual(pairing.pairs.count, 1)
        XCTAssertEqual(pairing.pairs[0].entry(on: .anilist)?.progress, 5)
        XCTAssertEqual(pairing.pairs[0].entry(on: .mal)?.progress, 3)
        XCTAssertTrue(pairing.unmatched.isEmpty)
    }

    /// Pair order is deterministic, so a summary sentence reads the same way on every run.
    func testPairOrderIsStable() {
        let make = {
            LibrarySyncPlanner.pair(
                entries: [
                    .anilist: [self.entry(id: 100, progress: 1), self.entry(id: 101, progress: 1)],
                    .mal: [self.entry(id: 900, progress: 1)],
                ],
                ids: { side, entry in
                    if side == .mal { return [.mal: 900, .anilist: 100] }
                    return entry.media.id == 100 ? [.anilist: 100, .mal: 900] : [.anilist: 101]
                })
        }
        XCTAssertEqual(make().pairs.count, 2)
        XCTAssertEqual(make().pairs.map { $0.id(on: .anilist) },
                       make().pairs.map { $0.id(on: .anilist) })
    }
}
