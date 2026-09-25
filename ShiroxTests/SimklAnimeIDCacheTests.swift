import XCTest
@testable import Shirox

/// Simkl's top-rated anime come with only Simkl's own id; their AniList and MyAnimeList ids are
/// looked up once from each anime's free record, and remembered on the device.
@MainActor
final class SimklAnimeIDCacheTests: XCTestCase {
    private struct Offline: Error {}

    private var lookUps: [Int] = []
    private var records: [Int: SimklDiscoverItem.IDs] = [:]
    private var failing: Set<Int> = []
    private lazy var file = FileManager.default.temporaryDirectory
        .appendingPathComponent("SimklAnimeIDCacheTests-\(UUID().uuidString).json")

    private func cache() -> SimklAnimeIDCache {
        let file = self.file
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return SimklAnimeIDCache(file: file, lookUp: { [unowned self] id in
            self.lookUps.append(id)
            if self.failing.contains(id) { throw Offline() }
            return self.records[id]
        })
    }

    private func top(_ simkl: Int, mal: Int? = nil, anilist: Int? = nil) -> SimklDiscoverItem {
        SimklDiscoverItem(title: "Title \(simkl)", titleRomaji: nil, ids: .init(simkl: simkl, mal: mal, anilist: anilist),
                          poster: nil, fanart: nil, overview: nil, genres: [], rating: nil, runtime: nil,
                          totalEpisodes: nil, rank: nil, airDay: nil)
    }

    func testTopRatedAnimeGetTheirTrackerIDs() async {
        records = [1: .init(simkl: 1, mal: 10, anilist: 100)]
        let filled = await cache().fill([top(1)])
        XCTAssertEqual(filled.first?.ids, .init(simkl: 1, mal: 10, anilist: 100))
    }

    func testEachIsLookedUpOnceAndRememberedOnTheDevice() async {
        records = [1: .init(simkl: 1, mal: 10, anilist: 100)]
        let cache = cache()
        _ = await cache.fill([top(1)])
        _ = await cache.fill([top(1)])
        XCTAssertEqual(lookUps, [1])
        let afterRelaunch = SimklAnimeIDCache(file: file, lookUp: { _ in
            XCTFail("Remembered on the device")
            return nil
        })
        let again = await afterRelaunch.fill([top(1)])
        XCTAssertEqual(again.first?.ids.anilist, 100)
    }

    func testAnimeThatAlreadyHaveIDsAreLeftAlone() async {
        let filled = await cache().fill([top(1, mal: 10)])
        XCTAssertTrue(lookUps.isEmpty)
        XCTAssertEqual(filled.first?.ids.mal, 10)
    }

    func testAFailedLookupIsTriedAgainNextTime() async {
        failing = [1]
        let cache = cache()
        let first = await cache.fill([top(1)])
        XCTAssertNil(first.first?.ids.mal)
        failing = []
        records = [1: .init(simkl: 1, mal: 10, anilist: nil)]
        let second = await cache.fill([top(1)])
        XCTAssertEqual(second.first?.ids.mal, 10)
        XCTAssertEqual(lookUps, [1, 1])
    }

    /// An anime Simkl knows no AniList or MyAnimeList id for isn't asked about again.
    func testARecordWithoutTrackerIDsIsRememberedToo() async {
        let cache = cache()
        _ = await cache.fill([top(1)])
        _ = await cache.fill([top(1)])
        XCTAssertEqual(lookUps, [1])
    }

    func testManyAreLookedUpAndKeepTheirOrder() async {
        records = Dictionary(uniqueKeysWithValues: (1...20).map { ($0, SimklDiscoverItem.IDs(simkl: $0, mal: $0 * 10, anilist: nil)) })
        let filled = await cache().fill((1...20).map { top($0) })
        XCTAssertEqual(filled.map(\.ids.simkl), Array(1...20))
        XCTAssertEqual(filled.map(\.ids.mal), (1...20).map { $0 * 10 })
        XCTAssertEqual(Set(lookUps), Set(1...20))
        XCTAssertEqual(lookUps.count, 20)
    }
}
