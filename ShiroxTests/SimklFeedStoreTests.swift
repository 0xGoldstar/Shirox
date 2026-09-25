import XCTest
@testable import Shirox

/// Simkl's free files are saved until Simkl regenerates them, and a failed download falls back
/// to the saved copy.
@MainActor
final class SimklFeedStoreTests: XCTestCase {
    private struct Offline: Error {}

    private let fileData = Data(#"[{"title":"Ted Lasso","ids":{"simkl_id":1359610}}]"#.utf8)
    private lazy var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SimklFeedStoreTests-\(UUID().uuidString)", isDirectory: true)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var downloads: [SimklFeedList] = []
    /// The files asked for, in order.
    private var paths: [String] = []
    private var failingPaths: Set<String> = []
    /// Lets a download yield mid-way, so a second caller can arrive while it runs.
    private var slowDownloads = false
    private var failing = false

    private func store() -> SimklFeedStore {
        let directory = self.directory
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SimklFeedStore(
            directory: directory,
            download: { [unowned self] list, path in
                self.downloads.append(list)
                self.paths.append(path)
                if self.slowDownloads { await Task.yield() }
                if self.failing || self.failingPaths.contains(path) { throw Offline() }
                return self.fileData
            },
            now: { [unowned self] in self.clock })
    }

    func testAFreshCopyIsServedWithoutDownloading() async throws {
        let store = store()
        _ = try await store.items(.trending(.tv, .today))
        clock += 30 * 60
        let again = try await store.items(.trending(.tv, .today))
        XCTAssertEqual(downloads.count, 1)
        XCTAssertEqual(again.map(\.title), ["Ted Lasso"])
    }

    func testAStaleCopyIsDownloadedAgain() async throws {
        let store = store()
        _ = try await store.items(.trending(.tv, .today))
        clock += 61 * 60
        _ = try await store.items(.trending(.tv, .today))
        XCTAssertEqual(downloads.count, 2)
    }

    func testTheWeekListKeepsForADay() async throws {
        let store = store()
        _ = try await store.items(.trending(.tv, .week))
        clock += 23 * 3600
        _ = try await store.items(.trending(.tv, .week))
        XCTAssertEqual(downloads.count, 1)
        clock += 2 * 3600
        _ = try await store.items(.trending(.tv, .week))
        XCTAssertEqual(downloads.count, 2)
    }

    func testAFailedDownloadFallsBackToTheSavedCopy() async throws {
        let store = store()
        _ = try await store.items(.calendar(.tv))
        clock += 7 * 3600
        failing = true
        let items = try await store.items(.calendar(.tv))
        XCTAssertEqual(items.map(\.title), ["Ted Lasso"])
        XCTAssertEqual(downloads.count, 3, "The first, then v2 and its v1 fallback both failing")
    }

    func testNoCopyAndNoDownloadThrows() async {
        failing = true
        do {
            _ = try await store().items(.dvdReleases)
            XCTFail("Expected a throw")
        } catch {
            XCTAssertTrue(error is Offline)
        }
    }

    func testForcingDownloadsEvenAFreshCopy() async throws {
        let store = store()
        _ = try await store.items(.trending(.anime, .today))
        _ = try await store.items(.trending(.anime, .today), forceRefresh: true)
        XCTAssertEqual(downloads.count, 2)
    }

    func testTheSavedCopyIsThereWithoutTheNetwork() async throws {
        let store = store()
        XCTAssertNil(store.savedItems(.trending(.movie, .month)))
        _ = try await store.items(.trending(.movie, .month))
        XCTAssertEqual(store.savedItems(.trending(.movie, .month))?.count, 1)
        XCTAssertNil(store.savedItems(.trending(.movie, .month), full: true), "The top 500 is its own file")
    }

    /// A pull to refresh never spends the allowance on a list that's still fresh.
    func testForcingLeavesAFreshTokenListAlone() async throws {
        let store = store()
        _ = try await store.items(.top(.tv))
        _ = try await store.items(.top(.tv), forceRefresh: true)
        XCTAssertEqual(downloads.count, 1)
        clock += 25 * 3600
        _ = try await store.items(.top(.tv), forceRefresh: true)
        XCTAssertEqual(downloads.count, 2, "A day on, it's fetched again")
    }

    /// Airing Today and New Premieres read the same calendar; loaded together, it's fetched once.
    func testListsSharingAFileDownloadItOnce() async throws {
        let store = store()
        slowDownloads = true
        async let airing = store.items(.calendar(.tv))
        async let premieres = store.items(.premieres(.tv))
        let (a, b) = try await (airing, premieres)
        XCTAssertEqual(downloads.count, 1)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
    }

    /// The calendar's v2 file first; v1 when v2 can't be had.
    func testTheCalendarFallsBackToVersionOne() async throws {
        failingPaths = ["/calendar/v2/tv.json"]
        let items = try await store().items(.calendar(.tv))
        XCTAssertEqual(paths, ["/calendar/v2/tv.json", "/calendar/tv.json"])
        XCTAssertEqual(items.map(\.title), ["Ted Lasso"])
    }

    func testTheCalendarStaysOnVersionTwoWhenItWorks() async throws {
        _ = try await store().items(.calendar(.anime))
        XCTAssertEqual(paths, ["/calendar/v2/anime.json"])
    }

    func testOtherListsHaveNoFallback() async {
        failing = true
        _ = try? await store().items(.trending(.tv, .week))
        XCTAssertEqual(paths, ["/discover/trending/tv/week_100.json"])
    }

    func testFilesComeFromTheCDNWithoutAToken() throws {
        let request = SimklAuthManager.shared.dataRequest(path: SimklFeedList.trending(.tv, .today).path(full: false))
        XCTAssertEqual(request.url?.host, "data.simkl.in")
        XCTAssertEqual(request.url?.path, "/discover/trending/tv/today_100.json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains { $0.name == "client_id" })
        XCTAssertTrue(query.contains { $0.name == "app-name" })
    }
}
