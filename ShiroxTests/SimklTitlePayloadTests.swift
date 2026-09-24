import XCTest
@testable import Shirox

final class SimklTitlePayloadTests: XCTestCase {

    private func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private let show = ["simkl": 2090]

    func testAShowsEpisodesGoUnderShowsWithRealSeasons() {
        let write = SimklWrite(ids: show, status: .watching, rating: nil, episodes: nil, kind: .tv,
                               seasons: [SimklSeasonMark(number: 1, episodes: [2, 3]),
                                         SimklSeasonMark(number: 2, episodes: nil)])
        XCTAssertEqual(json(SimklPayloadBuilder.historyBody(items: [write])), json(["shows": [
            ["ids": show, "seasons": [
                ["number": 1, "episodes": [["number": 2], ["number": 3]]],
                ["number": 2]]],
            ["ids": show, "status": "watching"],
        ]]))
    }

    func testAMovieGoesUnderMovies() {
        let write = SimklWrite(ids: ["simkl": 472214], status: .completed, rating: 9, episodes: nil, kind: .movie)
        XCTAssertEqual(json(SimklPayloadBuilder.historyBody(items: [write])), json(["movies": [
            ["ids": ["simkl": 472214], "status": "completed", "rating": 9],
        ]]))
    }

    func testAMixedBatchSplitsByKind() {
        let body = SimklPayloadBuilder.historyBody(items: [
            SimklWrite(ids: ["mal": 1], status: .watching, rating: nil, episodes: nil),
            SimklWrite(ids: ["simkl": 5], status: .plantowatch, rating: nil, episodes: nil, kind: .movie),
        ])
        XCTAssertEqual((body["shows"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((body["movies"] as? [[String: Any]])?.count, 1)
    }

    /// Anime writes carry no kind, and must go out exactly as before.
    func testAnimeBodiesAreUnchanged() {
        let write = SimklWrite(ids: ["mal": 1], status: .watching, rating: nil, episodes: [1, 2])
        XCTAssertEqual(json(SimklPayloadBuilder.historyBody(items: [write])), json(["shows": [
            ["ids": ["mal": 1], "seasons": [["number": 1, "episodes": [["number": 1], ["number": 2]]]]],
            ["ids": ["mal": 1], "status": "watching"],
        ]]))
    }

    /// The queue on disk was written before `kind` and `seasons` existed.
    func testQueuedWritesSavedBeforeThisStillDecode() throws {
        let write = try JSONDecoder().decode(SimklWrite.self, from: Data("""
        {"ids":{"mal":1},"status":"watching","rating":null,"episodes":[1]}
        """.utf8))
        XCTAssertNil(write.kind)
        XCTAssertNil(write.seasons)
        XCTAssertEqual(write.episodes, [1])
    }

    func testATitleRemovalWithoutSeasonsRemovesTheWholeTitle() {
        XCTAssertEqual(json(SimklPayloadBuilder.titleRemovalBody(kind: .tv, ids: show, seasons: nil)),
                       json(["shows": [["ids": show]]]))
        XCTAssertEqual(json(SimklPayloadBuilder.titleRemovalBody(kind: .movie, ids: ["simkl": 7], seasons: nil)),
                       json(["movies": [["ids": ["simkl": 7]]]]))
    }

    func testATitleRemovalWithSeasonsUnmarksOnlyThose() {
        let body = SimklPayloadBuilder.titleRemovalBody(
            kind: .tv, ids: show, seasons: [SimklSeasonMark(number: 3, episodes: [4]), SimklSeasonMark(number: 4, episodes: nil)])
        XCTAssertEqual(json(body), json(["shows": [["ids": show, "seasons": [
            ["number": 3, "episodes": [["number": 4]]], ["number": 4]]]]]))
    }

    func testAMovieRemovalNeverCarriesSeasons() {
        let body = SimklPayloadBuilder.titleRemovalBody(kind: .movie, ids: ["simkl": 7],
                                                        seasons: [SimklSeasonMark(number: 1, episodes: [1])])
        XCTAssertEqual(json(body), json(["movies": [["ids": ["simkl": 7]]]]))
    }

    /// "Un-mark nothing" must never become "delete everything".
    func testEmptySeasonsNeverBecomeAWholeRemoval() {
        let body = SimklPayloadBuilder.titleRemovalBody(kind: .tv, ids: show, seasons: [])
        let item = (body["shows"] as? [[String: Any]])?.first
        XCTAssertNotNil(item?["seasons"])
    }
}
