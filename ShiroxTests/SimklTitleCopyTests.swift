import XCTest
@testable import Shirox

final class SimklTitleCopyTests: XCTestCase {

    private func show(_ id: Int, status: MediaListStatus = .current, score: Double = 0) -> LibraryEntry {
        SimklTitleCopy.entry(simklID: id, kind: .tv, title: "Show \(id)", posterURL: nil, year: 2010,
                             runtime: 43, totalEpisodes: 10, status: status)
            .with(score: score)
    }

    func testAnEditUpdatesStatusScoreAndEpisodes() {
        let updated = SimklTitleCopy.updating(
            [show(1), show(2)], simklID: 2, status: .paused, score: 8,
            watched: [SimklEpisodeRef(season: 1, episode: 1), SimklEpisodeRef(season: 1, episode: 2)])
        XCTAssertEqual(updated[0].status, .current)
        XCTAssertEqual(updated[1].status, .paused)
        XCTAssertEqual(updated[1].score, 8)
        XCTAssertEqual(updated[1].progress, 2)
        XCTAssertEqual(updated[1].watchedEpisodes, [SimklSeasonWatch(season: 1, episodes: [1, 2])])
    }

    /// An unrated save sends no rating, so Simkl keeps the one it has — and so does the copy.
    func testAnUnratedEditKeepsTheSavedScore() {
        let updated = SimklTitleCopy.updating([show(1, score: 7)], simklID: 1, status: .completed, score: 0, watched: nil)
        XCTAssertEqual(updated[0].score, 7)
        XCTAssertEqual(updated[0].status, .completed)
    }

    func testRemovingDropsOnlyThatTitle() {
        XCTAssertEqual(SimklTitleCopy.removing(1, from: [show(1), show(2)]).map(\.id), [2])
    }

    func testANewTitleIsBuiltFromWhatWasFound() {
        let entry = SimklTitleCopy.entry(simklID: 472214, kind: .movie, title: "Inception",
                                         posterURL: "https://example/p.webp", year: 2010, runtime: 148,
                                         totalEpisodes: nil, status: .planning)
        XCTAssertEqual(entry.id, 472214)
        XCTAssertEqual(entry.media.simklTitleKind, .movie)
        XCTAssertEqual(entry.media.coverImage.large, "https://example/p.webp")
        XCTAssertEqual(entry.media.runtime, 148)
        XCTAssertEqual(entry.status, .planning)
        XCTAssertNil(entry.media.episodes)
    }

    func testInsertingATitleAlreadyThereReplacesIt() {
        let result = SimklTitleCopy.inserting(show(2, status: .dropped), into: [show(1), show(2)])
        XCTAssertEqual(result.map(\.id), [1, 2])
        XCTAssertEqual(result[1].status, .dropped)
        XCTAssertEqual(SimklTitleCopy.inserting(show(3), into: [show(1)]).map(\.id), [1, 3])
    }
}

private extension LibraryEntry {
    func with(score: Double) -> LibraryEntry {
        var copy = self
        copy.score = score
        return copy
    }
}
