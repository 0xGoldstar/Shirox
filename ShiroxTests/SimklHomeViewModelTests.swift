import XCTest
@testable import Shirox

/// A Simkl Home loads its kind's lists; a list that fails leaves its row out, and only nothing at
/// all is an error.
@MainActor
final class SimklHomeViewModelTests: XCTestCase {
    private struct Offline: Error {}

    private func entry(_ simkl: Int, mal: Int? = nil, day: String? = nil) -> SimklDiscoverItem {
        SimklDiscoverItem(title: "Title \(simkl)", titleRomaji: nil, ids: .init(simkl: simkl, mal: mal, anilist: nil),
                          poster: "1/1", fanart: nil, overview: nil, genres: [], rating: nil, runtime: nil,
                          totalEpisodes: nil, rank: nil, airDay: day)
    }

    private func model(files: [SimklFeedList: [SimklDiscoverItem]],
                       saved: [SimklFeedList: [SimklDiscoverItem]] = [:],
                       anilistForMAL: [Int: Int] = [:]) -> SimklHomeViewModel {
        SimklHomeViewModel(
            fetch: { list, _ in
                guard let items = files[list] else { throw Offline() }
                return items
            },
            saved: { saved[$0] },
            anilistIDs: { _ in anilistForMAL },
            tracker: { .anilist },
            today: { "2026-09-25" })
    }

    func testLoadsTheKindsRows() async {
        let vm = model(files: [
            .trending(.tv, .today): [entry(1), entry(2)],
            .trending(.tv, .week): [entry(3)],
            .trending(.tv, .month): [entry(4)],
            .calendar(.tv): [entry(5, day: "2026-09-25")],
        ])
        await vm.load(kind: .tv)
        XCTAssertEqual(vm.layout?.hero.map(\.id), [1, 2])
        XCTAssertEqual(vm.layout?.rows.map(\.title), [
            "Trending Today on Simkl", "Trending This Week on Simkl", "Trending This Month on Simkl", "Airing Today",
        ])
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isLoading)
    }

    func testAListThatFailsIsLeftOut() async {
        let vm = model(files: [.trending(.tv, .today): [entry(1)]])
        await vm.load(kind: .tv)
        XCTAssertEqual(vm.layout?.rows.map(\.title), ["Trending Today on Simkl"])
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

    func testSwitchingKindDropsTheOldKindsRows() async {
        let vm = model(files: [.trending(.tv, .today): [entry(1)]])
        await vm.load(kind: .tv)
        XCTAssertNotNil(vm.layout)
        await vm.load(kind: .movie)
        XCTAssertNil(vm.layout, "Shows' rows never stand in for Movies'")
        XCTAssertNotNil(vm.error)
    }
}
