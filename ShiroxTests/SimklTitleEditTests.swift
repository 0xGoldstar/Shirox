import XCTest
@testable import Shirox

final class SimklTitleEditTests: XCTestCase {

    private func ep(_ season: Int, _ number: Int) -> SimklEpisode {
        SimklEpisode(season: season, episode: number, title: nil, aired: true, img: nil, date: nil,
                     isSpecial: false, simklID: season * 100 + number)
    }

    private lazy var catalog = [ep(1, 1), ep(1, 2), ep(2, 1)]
    private let s1e1 = SimklEpisodeRef(season: 1, episode: 1)

    /// Completed marks every episode by status alone — no episode list goes out.
    func testCompletedMarksEveryAiredEpisodeByStatus() {
        let plan = SimklEpisodePlanner.edit(status: .completed, watched: [s1e1], upTo: s1e1,
                                            initialUpTo: s1e1, episodes: catalog)
        XCTAssertEqual(plan?.marks, [])
        XCTAssertEqual(plan?.unmarks, [])
        XCTAssertEqual(plan?.watched.count, 3)
    }

    func testAnUnchangedWatchedUpToSendsNoEpisodes() {
        XCTAssertNil(SimklEpisodePlanner.edit(status: .current, watched: [s1e1], upTo: s1e1,
                                              initialUpTo: s1e1, episodes: catalog))
    }

    func testAChangedWatchedUpToSendsThePlan() {
        let target = SimklEpisodeRef(season: 2, episode: 1)
        XCTAssertEqual(
            SimklEpisodePlanner.edit(status: .current, watched: [s1e1], upTo: target, initialUpTo: s1e1, episodes: catalog),
            SimklEpisodePlanner.plan(watched: [s1e1], upTo: target, episodes: catalog))
    }
}
