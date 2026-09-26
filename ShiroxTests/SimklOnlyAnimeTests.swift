import XCTest
@testable import Shirox

/// Anime without the tracker's id are Simkl titles of kind anime, whose saved copy is kept apart
/// from the synced anime copy.
@MainActor
final class SimklOnlyAnimeTests: XCTestCase {
    private func entry(_ id: Int, _ status: MediaListStatus = .current) -> LibraryEntry {
        LibraryEntry(id: id, media: SimklTitleReads.titleMedia(simklID: id, kind: .anime, title: "Feng Tian Qi",
                                                               posterURL: nil, year: 2026, runtime: nil, episodes: 10),
                     status: status, progress: 0, score: 0, timesRewatched: nil)
    }

    private func tempStore() -> (SimklOnlyAnimeStore, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return (SimklOnlyAnimeStore(file: file), file)
    }

    func testAnAnimeTitleIsASimklTitleOfKindAnime() {
        let media = entry(3226062).media
        XCTAssertEqual(media.type, Media.simklAnimeType)
        XCTAssertEqual(media.simklTitleKind, .anime)
        XCTAssertEqual(media.uniqueId, "simkl-anime-3226062")
    }

    func testWhichKindsHaveEpisodes() {
        XCTAssertTrue(MediaKind.tv.hasSimklEpisodes)
        XCTAssertTrue(MediaKind.anime.hasSimklEpisodes)
        XCTAssertFalse(MediaKind.movie.hasSimklEpisodes)
    }

    func testTheStoreReplacesMergesAndKeeps() {
        let (store, file) = tempStore()
        store.replace([entry(1), entry(2)])
        store.merge([entry(2, .completed), entry(3)])
        XCTAssertEqual(store.entries.map(\.id), [1, 2, 3])
        XCTAssertEqual(store.entries[1].status, .completed)
        store.keep(simklIDs: [1, 3])
        XCTAssertEqual(store.entries.map(\.id), [1, 3])
        XCTAssertEqual(SimklOnlyAnimeStore(file: file).entries.map(\.id), [1, 3], "Kept across launches")
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }
}
