import XCTest
@testable import Shirox

/// A Simkl Home loads its kind's lists; a list that fails leaves its row out, and only nothing at
/// all is an error.
@MainActor
final class SimklHomeViewModelTests: XCTestCase {
    private struct Offline: Error {}

    private func entry(_ simkl: Int, mal: Int? = nil, day: String? = nil, episode: Int? = nil) -> SimklDiscoverItem {
        SimklDiscoverItem(title: "Title \(simkl)", titleRomaji: nil, ids: .init(simkl: simkl, mal: mal, anilist: nil),
                          poster: "1/1", fanart: nil, overview: nil, genres: [], rating: nil, runtime: nil,
                          totalEpisodes: nil, rank: nil, airDay: day, episode: episode)
    }

    private func model(files: [SimklFeedList: [SimklDiscoverItem]],
                       saved: [SimklFeedList: [SimklDiscoverItem]] = [:],
                       anilistForMAL: [Int: Int] = [:],
                       fillIDs: @escaping SimklHomeViewModel.FillIDs = { $0 }) -> SimklHomeViewModel {
        SimklHomeViewModel(
            fetch: { list, _ in
                guard let items = files[list] else { throw Offline() }
                return items
            },
            saved: { saved[$0] },
            anilistIDs: { _ in anilistForMAL },
            fillIDs: fillIDs,
            tracker: { .anilist },
            today: { "2026-09-25" })
    }

    func testLoadsTheKindsRows() async {
        // Airing Today and New Premieres share the calendar file; the store hands each its copy.
        let calendar = [entry(5, day: "2026-09-25", episode: 3), entry(6, day: "2026-09-26", episode: 1)]
        let vm = model(files: [
            .trending(.tv, .today): [entry(1), entry(2)],
            .top(.tv): [entry(7)],
            .trending(.tv, .week): [entry(3)],
            .premieres(.tv): calendar,
            .calendar(.tv): calendar,
        ])
        await vm.load(kind: .tv)
        XCTAssertEqual(vm.layout?.hero.map(\.id), [1, 2])
        XCTAssertEqual(vm.layout?.rows.map(\.title), [
            "Top Rated", "Trending This Week", "New Premieres", "Airing Today",
        ])
        XCTAssertEqual(vm.layout?.rows[2].items.map(\.id), [6])
        XCTAssertEqual(vm.layout?.rows[3].items.map(\.id), [5])
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isLoading)
    }

    func testAListThatFailsIsLeftOut() async {
        let vm = model(files: [.trending(.tv, .today): [entry(1)], .trending(.tv, .week): [entry(2)]])
        await vm.load(kind: .tv)
        XCTAssertEqual(vm.layout?.rows.map(\.title), ["Trending This Week"])
        XCTAssertNil(vm.error)
    }

    func testNothingAtAllIsAnError() async {
        let vm = model(files: [:])
        await vm.load(kind: .movie)
        XCTAssertNil(vm.layout)
        XCTAssertNotNil(vm.error)
        XCTAssertFalse(vm.isLoading)
    }

    func testSavedCopiesStandInWhenNothingDownloads() async {
        let vm = model(files: [:], saved: [.trending(.movie, .today): [entry(9)]])
        await vm.load(kind: .movie)
        XCTAssertEqual(vm.layout?.hero.map(\.id), [9])
        XCTAssertNil(vm.error)
    }

    func testCalendarAnimeGetTheirAniListIdFromTheMap() async {
        let vm = model(files: [.calendar(.anime): [entry(3200766, mal: 64710, day: "2026-09-25")]],
                       anilistForMAL: [64710: 999])
        await vm.load(kind: .anime)
        XCTAssertEqual(vm.layout?.rows.first?.items.map(\.id), [999])
        XCTAssertEqual(vm.layout?.rows.first?.items.first?.provider, .anilist)
    }

    /// Simkl's top-rated anime come with only its own id; once their ids are known the row fills in.
    func testTopRatedAnimeAppearOnceTheirIDsAreKnown() async {
        let vm = model(files: [.top(.anime): [entry(1990194)]],
                       fillIDs: { items in
                           items.map { item in
                               var filled = item
                               filled.ids = .init(simkl: item.ids.simkl, mal: 52991, anilist: 154587)
                               return filled
                           }
                       })
        await vm.load(kind: .anime)
        XCTAssertEqual(vm.layout?.rows.first?.title, "Top Rated")
        XCTAssertEqual(vm.layout?.rows.first?.items.map(\.id), [154587])
    }

    func testSwitchingKindDropsTheOldKindsRows() async {
        let vm = model(files: [.trending(.tv, .today): [entry(1)]])
        await vm.load(kind: .tv)
        XCTAssertNotNil(vm.layout)
        await vm.load(kind: .movie)
        XCTAssertNil(vm.layout, "Shows' rows never stand in for Movies'")
        XCTAssertNotNil(vm.error)
    }
}
