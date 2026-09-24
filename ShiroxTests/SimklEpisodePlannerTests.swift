import XCTest
@testable import Shirox

final class SimklEpisodePlannerTests: XCTestCase {

    private func ep(_ season: Int, _ number: Int, aired: Bool = true) -> SimklEpisode {
        SimklEpisode(season: season, episode: number, title: nil, aired: aired, img: nil, date: nil,
                     isSpecial: false, simklID: season * 100 + number)
    }

    private func ref(_ season: Int, _ number: Int) -> SimklEpisodeRef {
        SimklEpisodeRef(season: season, episode: number)
    }

    /// Season 1 has three aired episodes; season 2 has two aired and one still to come; one special.
    private lazy var catalog: [SimklEpisode] = [
        ep(1, 1), ep(1, 2), ep(1, 3),
        ep(2, 1), ep(2, 2), ep(2, 3, aired: false),
        SimklEpisode(season: nil, episode: nil, title: "Special", aired: true, img: nil, date: nil,
                     isSpecial: true, simklID: 9999),
    ]

    func testUpToMarksEverythingBeforeAndCompressesWholeSeasons() {
        let plan = SimklEpisodePlanner.plan(watched: [], upTo: ref(2, 2), episodes: catalog)
        XCTAssertEqual(plan.marks, [SimklSeasonMark(number: 1, episodes: nil),
                                    SimklSeasonMark(number: 2, episodes: [1, 2])])
        XCTAssertEqual(plan.unmarks, [])
        XCTAssertEqual(plan.watched, [ref(1, 1), ref(1, 2), ref(1, 3), ref(2, 1), ref(2, 2)])
    }

    func testMovingBackUnmarksWhatComesAfter() {
        let watched: Set = [ref(1, 1), ref(1, 2), ref(1, 3), ref(2, 1), ref(2, 2)]
        let plan = SimklEpisodePlanner.plan(watched: watched, upTo: ref(1, 2), episodes: catalog)
        XCTAssertEqual(plan.marks, [])
        XCTAssertEqual(plan.unmarks, [SimklSeasonMark(number: 1, episodes: [3]),
                                      SimklSeasonMark(number: 2, episodes: [1, 2])])
        XCTAssertEqual(plan.watched, [ref(1, 1), ref(1, 2)])
    }

    func testNothingYetUnmarksEveryRegularEpisode() {
        let plan = SimklEpisodePlanner.plan(watched: [ref(1, 1), ref(1, 2), ref(1, 3)], upTo: nil, episodes: catalog)
        XCTAssertEqual(plan.unmarks, [SimklSeasonMark(number: 1, episodes: nil)])
        XCTAssertEqual(plan.watched, [])
    }

    /// Season 0 is where a list read reports watched specials — nothing here may touch them.
    func testSpecialsAreNeverTouched() {
        let plan = SimklEpisodePlanner.plan(watched: [ref(0, 1), ref(1, 1)], upTo: nil, episodes: catalog)
        XCTAssertEqual(plan.watched, [ref(0, 1)])
    }

    func testNextEpisodeFollowsTheFurthestWatched() {
        XCTAssertEqual(SimklEpisodePlanner.next(after: [ref(1, 1), ref(1, 2), ref(1, 3)], in: catalog), ref(2, 1))
        XCTAssertEqual(SimklEpisodePlanner.next(after: [], in: catalog), ref(1, 1))
        XCTAssertEqual(SimklEpisodePlanner.next(after: [ref(1, 1), ref(1, 3)], in: catalog), ref(2, 1))
    }

    func testNextEpisodeStopsAtAnUnairedEpisode() {
        let watched: Set = [ref(1, 1), ref(1, 2), ref(1, 3), ref(2, 1), ref(2, 2)]
        XCTAssertNil(SimklEpisodePlanner.next(after: watched, in: catalog))
    }

    /// Simkl may hold no per-episode history for a show marked complete in one go.
    func testACompletedShowCountsEveryAiredEpisodeWatched() {
        let watched = SimklEpisodePlanner.watched(status: .completed, recorded: nil, episodes: catalog)
        XCTAssertEqual(watched, [ref(1, 1), ref(1, 2), ref(1, 3), ref(2, 1), ref(2, 2)])
        XCTAssertEqual(SimklEpisodePlanner.watched(status: .current, recorded: nil, episodes: catalog), [])
    }

    func testLastWatchedForTheRow() {
        XCTAssertEqual(SimklEpisodePlanner.lastWatched([SimklSeasonWatch(season: 1, episodes: [1, 2, 3]),
                                                        SimklSeasonWatch(season: 2, episodes: [1])]), ref(2, 1))
        XCTAssertNil(SimklEpisodePlanner.lastWatched(nil))
        XCTAssertNil(SimklEpisodePlanner.lastWatched([SimklSeasonWatch(season: 0, episodes: [1])]))
    }

    func testWatchedSetRoundTripsToStorage() {
        XCTAssertEqual(SimklEpisodePlanner.seasons(from: [ref(2, 1), ref(1, 2), ref(1, 1)]),
                       [SimklSeasonWatch(season: 1, episodes: [1, 2]), SimklSeasonWatch(season: 2, episodes: [1])])
    }

    func testRegularSeasonsInOrder() {
        XCTAssertEqual(SimklEpisodePlanner.regularSeasons(in: catalog.reversed()), [1, 2])
    }

    func testTickingAPlanToWatchShowMakesItWatching() {
        XCTAssertEqual(SimklEpisodePlanner.statusAfterTick(current: .planning, marking: true), .current)
        XCTAssertEqual(SimklEpisodePlanner.statusAfterTick(current: nil, marking: true), .current)
        XCTAssertEqual(SimklEpisodePlanner.statusAfterTick(current: .completed, marking: false), .current)
        XCTAssertEqual(SimklEpisodePlanner.statusAfterTick(current: .paused, marking: true), .paused)
    }

    func testMarkingASeasonAddsItsAiredEpisodes() {
        let whole = SimklEpisodePlanner.seasonChange(1, marking: true, watched: [ref(1, 1)], episodes: catalog)
        XCTAssertEqual(whole.marks, [SimklSeasonMark(number: 1, episodes: nil)])
        XCTAssertEqual(whole.watched, [ref(1, 1), ref(1, 2), ref(1, 3)])

        // Season 2 is still airing: only its aired episodes, by number.
        let airing = SimklEpisodePlanner.seasonChange(2, marking: true, watched: [], episodes: catalog)
        XCTAssertEqual(airing.marks, [SimklSeasonMark(number: 2, episodes: [1, 2])])
    }

    func testUnmarkingASeasonRemovesItWhole() {
        let plan = SimklEpisodePlanner.seasonChange(1, marking: false, watched: [ref(1, 1), ref(2, 1)], episodes: catalog)
        XCTAssertEqual(plan.unmarks, [SimklSeasonMark(number: 1, episodes: nil)])
        XCTAssertEqual(plan.watched, [ref(2, 1)])
    }
}
