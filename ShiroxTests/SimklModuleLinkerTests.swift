import XCTest
@testable import Shirox

/// A module page is matched to a Simkl show or movie by exact title — searched once, ever, and
/// never when it's an anime with a confident AniList match.
@MainActor
final class SimklModuleLinkerTests: XCTestCase {
    private struct Offline: Error {}

    private let key = "module:m|/show"
    private var searches: [String] = []
    private var answer: Result<[SimklCatalogItem], Error> = .success([])
    private lazy var store: TrackingLinkStore = {
        let name = "SimklModuleLinkerTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return TrackingLinkStore(defaults: UserDefaults(suiteName: name)!)
    }()

    private func items(_ json: String) -> [SimklCatalogItem] {
        (try? SimklCatalog.decodeSearch(Data(json.utf8))) ?? []
    }

    private func episode(_ season: Int, _ number: Int) -> SimklEpisode {
        SimklEpisode(season: season, episode: number, title: nil, aired: true, img: nil, date: nil,
                     isSpecial: false, simklID: season * 100 + number)
    }

    private func page(title: String = "Ted Lasso", airdate: String = "2020", episodes: Int = 22,
                      confident: Bool = false) -> SimklModuleLinker.Page {
        SimklModuleLinker.Page(key: key, title: title, aliases: "", airdate: airdate, episodeCount: episodes,
                               hasConfidentAniListMatch: confident)
    }

    private func match(_ page: SimklModuleLinker.Page, signedIn: Bool = true, trackingOn: Bool = true,
                       simklEpisodes: [SimklEpisode] = [], now: Date = Date()) async -> SimklTitleLink? {
        await SimklModuleLinker.matchIfNeeded(
            page, store: store, signedIn: signedIn, trackingOn: trackingOn,
            search: { [unowned self] query, kind in
                self.searches.append("\(query)|\(kind.rawValue)")
                return try self.answer.get()
            },
            episodes: { _ in simklEpisodes }, now: now)
    }

    func testAnExactMatchIsLinkedAutomatically() async {
        answer = .success(items(#"[{"title":"Ted Lasso","year":2020,"ids":{"simkl_id":1359610}}]"#))
        let seasons = (1...10).map { episode(1, $0) } + (1...12).map { episode(2, $0) }
        let link = await match(page(episodes: 22), simklEpisodes: seasons)
        XCTAssertEqual(link, SimklTitleLink(simklID: 1359610, kind: .tv, season: nil, automatic: true),
                       "22 episodes where season 1 has 10: every season")
        XCTAssertEqual(store.links(for: key)?.simklTitle, link)
        XCTAssertEqual(store.links(for: key)?.simklSearched, true)
        XCTAssertEqual(searches, ["Ted Lasso|tv"])
    }

    func testAOneEpisodePageIsMatchedAsAMovie() async {
        answer = .success(items(#"[{"title":"Dune","year":2021,"ids":{"simkl_id":5}}]"#))
        let link = await match(page(title: "Dune", airdate: "2021", episodes: 1))
        XCTAssertEqual(link, SimklTitleLink(simklID: 5, kind: .movie, season: nil, automatic: true))
        XCTAssertEqual(searches, ["Dune|movie"])
    }

    func testNoMatchIsRememberedAndNotSearchedAgain() async {
        answer = .success(items(#"[{"title":"Ted Lasso: The Movie","ids":{"simkl_id":1}}]"#))
        let first = await match(page())
        let second = await match(page())
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertNil(store.links(for: key)?.simklTitle)
        XCTAssertEqual(store.links(for: key)?.simklSearched, true)
        XCTAssertEqual(searches.count, 1)
    }

    /// Offline, say: Simkl never answered, so the page is tried next time.
    func testAFailedSearchIsTriedAgain() async {
        answer = .failure(Offline())
        let first = await match(page())
        XCTAssertNil(first)
        XCTAssertNil(store.links(for: key))
        answer = .success(items(#"[{"title":"Ted Lasso","ids":{"simkl_id":1359610}}]"#))
        let second = await match(page())
        XCTAssertEqual(second?.simklID, 1359610)
        XCTAssertEqual(searches.count, 2)
    }

    func testAnAnimeWithAConfidentAniListMatchIsLeftToAniList() async {
        answer = .success(items(#"[{"title":"Ted Lasso","ids":{"simkl_id":1359610}}]"#))
        let link = await match(page(confident: true))
        XCTAssertNil(link)
        XCTAssertTrue(searches.isEmpty)
        XCTAssertNil(store.links(for: key))
    }

    func testSignedOutOrTrackingOffDoesntSearch() async {
        answer = .success(items(#"[{"title":"Ted Lasso","ids":{"simkl_id":1359610}}]"#))
        _ = await match(page(), signedIn: false)
        _ = await match(page(), trackingOn: false)
        XCTAssertTrue(searches.isEmpty)
    }

    func testALinkedPageIsntSearched() async {
        store.update(key) { $0.simklTitle = SimklTitleLink(simklID: 1, kind: .tv, season: 1, automatic: false) }
        _ = await match(page())
        XCTAssertTrue(searches.isEmpty)
        XCTAssertEqual(store.links(for: key)?.simklTitle?.simklID, 1, "The user's link stands")
    }

    // MARK: - Re-matching

    func testANoMatchIsSearchedAgainAfterThirtyDays() async {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 24 * 60 * 60
        answer = .success([])
        _ = await match(page(), now: start)
        XCTAssertEqual(store.links(for: key)?.simklNoMatchAt, start)
        _ = await match(page(), now: start + 29 * day)
        XCTAssertEqual(searches.count, 1, "Not before 30 days")
        _ = await match(page(), now: start + 30 * day)
        XCTAssertEqual(searches.count, 2)
        XCTAssertEqual(store.links(for: key)?.simklNoMatchAt, start + 30 * day)
    }

    /// Unlinking in Tracking Links leaves the page searched with no date: never re-matched.
    func testAPageTheUserUnlinkedIsntSearchedAgain() async {
        store.update(key) { $0.simklSearched = true }
        _ = await match(page(), now: Date().addingTimeInterval(365 * 24 * 60 * 60))
        XCTAssertTrue(searches.isEmpty)
    }

    func testAMatchClearsTheDate() async {
        store.update(key) {
            $0.simklSearched = true
            $0.simklNoMatchAt = Date(timeIntervalSince1970: 0)
        }
        answer = .success(items(#"[{"title":"Ted Lasso","year":2020,"ids":{"simkl_id":1359610}}]"#))
        _ = await match(page())
        XCTAssertNotNil(store.links(for: key)?.simklTitle)
        XCTAssertNil(store.links(for: key)?.simklNoMatchAt)
    }
}
