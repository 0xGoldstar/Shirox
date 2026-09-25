import XCTest
@testable import Shirox

/// How Simkl's files become Home: which rows, in what order, and what Airing Today and
/// Coming Soon pick from the calendar.
final class SimklHomeRowsTests: XCTestCase {
    private let today = "2026-09-25"

    private func entry(_ simkl: Int, mal: Int? = nil, anilist: Int? = nil, rank: Int? = nil,
                       day: String? = nil, episode: Int? = nil, released: String? = nil) -> SimklDiscoverItem {
        SimklDiscoverItem(title: "Title \(simkl)", titleRomaji: nil,
                          ids: .init(simkl: simkl, mal: mal, anilist: anilist), poster: "1/1", fanart: nil,
                          overview: nil, genres: [], rating: nil, runtime: nil, totalEpisodes: nil,
                          rank: rank, airDay: day, episode: episode, released: released)
    }

    func testEachKindsRowsInOrder() {
        XCTAssertEqual(SimklHomeRows.rows(for: .tv),
                       [.top(.tv), .trending(.tv, .week), .premieres(.tv), .calendar(.tv)])
        XCTAssertEqual(SimklHomeRows.rows(for: .anime),
                       [.top(.anime), .trending(.anime, .week), .premieres(.anime), .calendar(.anime)])
        XCTAssertEqual(SimklHomeRows.rows(for: .movie),
                       [.top(.movie), .trending(.movie, .week), .newReleases, .dvdReleases, .calendar(.movie)])
    }

    /// The hero stays today's most watched, so Home loads that file beside the rows'.
    func testHomeLoadsTheHerosListAndTheRows() {
        XCTAssertEqual(SimklHomeRows.heroList(for: .tv), .trending(.tv, .today))
        XCTAssertEqual(SimklHomeRows.lists(for: .tv), [.trending(.tv, .today)] + SimklHomeRows.rows(for: .tv))
    }

    func testNewPremieresAreFirstEpisodesStillAheadSoonestFirst() {
        let calendar = [entry(1, rank: 9, day: "2026-10-02", episode: 1), entry(2, day: today, episode: 5),
                        entry(3, rank: 7, day: today, episode: 1), entry(4, rank: 2, day: "2026-09-24", episode: 1),
                        entry(5, day: today, episode: 1)]
        let picked = SimklHomeRows.select(.premieres(.tv), calendar, today: today)
        XCTAssertEqual(picked.map(\.ids.simkl), [3, 5, 1], "Episode 1s from today on; later episodes and past days left out")
    }

    func testNewReleasesCameOutInTheLastSixtyDays() {
        let month = [entry(1, released: "2026-09-20"), entry(2, released: "2026-06-01"),
                     entry(3, released: "2026-07-27"), entry(4, released: "2026-10-10"), entry(5)]
        let picked = SimklHomeRows.select(.newReleases, month, today: today)
        XCTAssertEqual(picked.map(\.ids.simkl), [1, 3], "The month's own order; older, unreleased and undated left out")
    }

    func testTopRatedKeepsSimklsOrder() {
        let picked = SimklHomeRows.select(.top(.tv), [entry(3), entry(1), entry(2)], today: today)
        XCTAssertEqual(picked.map(\.ids.simkl), [3, 1, 2])
    }

    func testADayCountsBack() {
        XCTAssertEqual(SimklHomeRows.day("2026-09-25", minus: 60), "2026-07-27")
        XCTAssertEqual(SimklHomeRows.day("2026-03-30", minus: 1), "2026-03-29")
    }

    func testAiringTodayIsTodaysMostPopularFirst() {
        let calendar = [entry(1, rank: 50, day: today), entry(2, rank: nil, day: today), entry(3, rank: 5, day: today),
                        entry(4, rank: 1, day: "2026-09-26"), entry(3, rank: 5, day: today)]
        let picked = SimklHomeRows.select(.calendar(.tv), calendar, today: today)
        XCTAssertEqual(picked.map(\.ids.simkl), [3, 1, 2], "Ranked first, unranked last, tomorrow left out, once each")
    }

    func testComingSoonIsWhatsStillAheadSoonestFirst() {
        let releases = [entry(1, rank: 9, day: "2026-10-02"), entry(2, rank: 3, day: "2026-09-24"),
                        entry(3, rank: 7, day: today), entry(4, rank: 2, day: today)]
        let picked = SimklHomeRows.select(.calendar(.movie), releases, today: today)
        XCTAssertEqual(picked.map(\.ids.simkl), [4, 3, 1])
    }

    func testTrendingKeepsSimklsOrderOnceEach() {
        let picked = SimklHomeRows.select(.trending(.tv, .week), [entry(3), entry(1), entry(2), entry(1)], today: today)
        XCTAssertEqual(picked.map(\.ids.simkl), [3, 1, 2])
    }

    func testTheLayoutForShows() {
        let files: [SimklFeedList: [SimklDiscoverItem]] = [
            .trending(.tv, .today): (1...10).map { entry($0) },
            .trending(.tv, .week): [entry(20)],
            .calendar(.tv): [entry(30, day: today)],
        ]
        let layout = SimklHomeRows.layout(kind: .tv, files: files, today: today, tracker: .anilist,
                                          anilistForMAL: [:], rowLength: 20)
        XCTAssertEqual(layout.hero.map(\.id), Array(1...8))
        XCTAssertEqual(layout.rows.map(\.title), ["Trending This Week", "Airing Today"],
                       "The hero's list isn't a row, and a list with no file is left out")
        XCTAssertEqual(layout.rows.last?.items.map(\.id), [30])
    }

    func testRowsAreCutToTheRowLength() {
        let layout = SimklHomeRows.layout(kind: .movie, files: [.trending(.movie, .week): (1...30).map { entry($0) }],
                                          today: today, tracker: .anilist, anilistForMAL: [:], rowLength: 12)
        XCTAssertEqual(layout.rows.first?.items.count, 12)
        XCTAssertTrue(layout.hero.isEmpty, "The hero is Trending Today, which didn't load")
    }

    func testAnimeWithoutTheTrackersIdDropOut() {
        let files: [SimklFeedList: [SimklDiscoverItem]] = [
            .calendar(.anime): [entry(1, mal: 10, day: today), entry(2, mal: 20, day: today), entry(3, day: today)],
        ]
        let forAniList = SimklHomeRows.layout(kind: .anime, files: files, today: today, tracker: .anilist,
                                              anilistForMAL: [10: 100], rowLength: 20)
        XCTAssertEqual(forAniList.rows.first?.items.map(\.id), [100])
        let forMAL = SimklHomeRows.layout(kind: .anime, files: files, today: today, tracker: .mal,
                                          anilistForMAL: [:], rowLength: 20)
        XCTAssertEqual(forMAL.rows.first?.items.map(\.id), [10, 20])
    }

    func testAnEmptyRowIsLeftOut() {
        let layout = SimklHomeRows.layout(kind: .tv, files: [.calendar(.tv): [entry(1, day: "2026-09-20")]],
                                          today: today, tracker: .anilist, anilistForMAL: [:], rowLength: 20)
        XCTAssertTrue(layout.rows.isEmpty)
    }

    func testTodayIsTheUsersOwnDay() throws {
        let moment = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-24T20:00:00Z"))
        XCTAssertEqual(SimklHomeRows.day(moment, in: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))), "2026-09-25")
        XCTAssertEqual(SimklHomeRows.day(moment, in: try XCTUnwrap(TimeZone(identifier: "America/New_York"))), "2026-09-24")
    }
}
