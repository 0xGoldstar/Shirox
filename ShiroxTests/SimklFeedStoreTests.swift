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
    private var downloads: [URLRequest] = []
    private var failing = false

    private func store() -> SimklFeedStore {
        let directory = self.directory
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SimklFeedStore(
            directory: directory,
            download: { [unowned self] request in
                self.downloads.append(request)
                if self.failing { throw Offline() }
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
        XCTAssertEqual(downloads.count, 2)
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

    func testFilesComeFromTheCDNWithoutAToken() async throws {
        _ = try await store().items(.trending(.tv, .today))
        let request = try XCTUnwrap(downloads.first)
        XCTAssertEqual(request.url?.host, "data.simkl.in")
        XCTAssertEqual(request.url?.path, "/discover/trending/tv/today_100.json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains { $0.name == "client_id" })
        XCTAssertTrue(query.contains { $0.name == "app-name" })
    }
}
