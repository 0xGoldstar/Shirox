import XCTest
@testable import Shirox

/// What the app asks Simkl for by itself is marked automatic, so the reserve can hold it back.
@MainActor
final class SimklAutomaticRequestTests: XCTestCase {
    private final class Seen { var priorities: [SimklRequestPriority] = [] }

    func testHomesTokenListsLoadAsAutomaticUnlessPulled() async throws {
        let seen = Seen()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = SimklFeedStore(directory: directory, download: { _, _ in
            seen.priorities.append(SimklRequestPriority.current)
            return Data("[]".utf8)
        })
        _ = try await store.items(.top(.tv))
        _ = try await store.items(.top(.movie), forceRefresh: true)
        XCTAssertEqual(seen.priorities, [.automatic, .own])
    }

    func testAModulePagesSearchIsAutomatic() async {
        let seen = Seen()
        let name = "SimklAutomaticRequestTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = TrackingLinkStore(defaults: UserDefaults(suiteName: name)!)
        let page = SimklModuleLinker.Page(key: "module:m|/show", title: "Ted Lasso", aliases: "", airdate: "2020",
                                          episodeCount: 22, hasConfidentAniListMatch: false)
        _ = await SimklModuleLinker.matchIfNeeded(
            page, store: store, signedIn: true, trackingOn: true,
            search: { _, _ in
                seen.priorities.append(SimklRequestPriority.current)
                return []
            },
            episodes: { _ in [] })
        XCTAssertEqual(seen.priorities, [.automatic])
    }
}
