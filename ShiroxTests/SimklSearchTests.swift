import XCTest
@testable import Shirox

/// A Simkl search runs anime, shows and movies at once and shows them in sections; one kind
/// failing keeps the others. An anime result opens by its tracker's id.
@MainActor
final class SimklSearchTests: XCTestCase {
    private struct Offline: LocalizedError { var errorDescription: String? { "Offline" } }

    private func items(_ json: String) throws -> [SimklCatalogItem] {
        try SimklCatalog.decodeSearch(Data(json.utf8))
    }

    func testSectionsComeInPillOrderAndEmptyKindsAreLeftOut() throws {
        let shows = try items(#"[{"title":"Dune: Prophecy","ids":{"simkl_id":1}}]"#)
        let movies = try items(#"[{"title":"Dune","ids":{"simkl_id":2}},{"title":"No id","ids":{}}]"#)
        let outcome = SimklSearch.outcome([(.anime, .success([])), (.tv, .success(shows)), (.movie, .success(movies))])
        XCTAssertEqual(outcome.sections.map(\.kind), [.tv, .movie])
        XCTAssertEqual(outcome.sections.last?.items.map(\.title), ["Dune"], "An entry without a Simkl id can't be opened")
        XCTAssertTrue(outcome.failedKinds.isEmpty)
        XCTAssertNil(outcome.error)
    }

    func testOneKindFailingKeepsTheOthers() throws {
        let shows = try items(#"[{"title":"Dune: Prophecy","ids":{"simkl_id":1}}]"#)
        let outcome = SimklSearch.outcome([(.anime, .failure(Offline())), (.tv, .success(shows)), (.movie, .success([]))])
        XCTAssertEqual(outcome.sections.map(\.kind), [.tv])
        XCTAssertEqual(outcome.failedKinds, [.anime])
        XCTAssertNil(outcome.error)
    }

    func testEveryKindFailingIsAnError() {
        let outcome = SimklSearch.outcome([(.anime, .failure(Offline())), (.tv, .failure(Offline())),
                                           (.movie, .failure(Offline()))])
        XCTAssertTrue(outcome.sections.isEmpty)
        XCTAssertTrue(outcome.failedKinds.isEmpty)
        XCTAssertEqual(outcome.error, "Offline")
    }

    func testASearchAsksForAllThreeKinds() async {
        let asked = AskedKinds()
        let outcome = await SimklSearch.run("dune") { query, kind in
            XCTAssertEqual(query, "dune")
            asked.kinds.append(kind)
            return try SimklCatalog.decodeSearch(Data(#"[{"title":"Dune","ids":{"simkl_id":1}}]"#.utf8))
        }
        XCTAssertEqual(Set(asked.kinds), [.anime, .tv, .movie])
        XCTAssertEqual(outcome.sections.map(\.kind), [.anime, .tv, .movie])
    }

    func testAShowResultIsASimklTitleAndAnAnimeWaitsToBeOpened() throws {
        let item = try XCTUnwrap(items(#"[{"title":"Dune: Prophecy","year":2024,"poster":"74/abc","ids":{"simkl_id":1}}]"#).first)
        let show = try XCTUnwrap(SimklSearch.cardMedia(item, kind: .tv))
        XCTAssertEqual(show.simklTitleKind, .tv)
        XCTAssertEqual(show.id, 1)
        XCTAssertEqual(show.coverImage.large, "https://wsrv.nl/?url=https://simkl.in/posters/74/abc_m.webp&q=90")
        let anime = try XCTUnwrap(SimklSearch.cardMedia(item, kind: .anime))
        XCTAssertNil(anime.simklTitleKind, "An anime opens through SimklAnimeOpener, not the Simkl page")
        XCTAssertFalse(anime.usesTVDBArtwork)
    }

    func testAnAnimeOpensByItsTrackersId() {
        let ids = SimklDiscoverItem.IDs(simkl: 1, mal: 59741, anilist: 180136)
        XCTAssertEqual(SimklSearch.animeTarget(ids, tracker: .anilist, anilistForMAL: nil), .init(id: 180136, provider: .anilist))
        XCTAssertEqual(SimklSearch.animeTarget(ids, tracker: .mal, anilistForMAL: nil), .init(id: 59741, provider: .mal))
        let malOnly = SimklDiscoverItem.IDs(simkl: 1, mal: 64710, anilist: nil)
        XCTAssertEqual(SimklSearch.animeTarget(malOnly, tracker: .anilist, anilistForMAL: 999), .init(id: 999, provider: .anilist))
        XCTAssertNil(SimklSearch.animeTarget(malOnly, tracker: .anilist, anilistForMAL: nil))
        XCTAssertNil(SimklSearch.animeTarget(.init(simkl: 1, mal: nil, anilist: 5), tracker: .mal, anilistForMAL: nil))
    }

    /// Out of allowance for the day: Simkl's own explanation, not a bare status code.
    func testADailyLimitExplainsItself() {
        let limit = SimklLibraryService.thrownError(
            for: SimklLibraryService.classify(status: 429, body: Data(#"{"error":"user_limit_exceeded"}"#.utf8),
                                              retryAfter: "3600"),
            status: 429)
        let outcome = SimklSearch.outcome([(.anime, .failure(limit)), (.tv, .failure(limit)), (.movie, .failure(limit))])
        XCTAssertEqual(outcome.error, SimklError.dailyLimit.errorDescription)
    }

    func testAnAnimeRecordGivesItsTrackerIDs() throws {
        let ids = try SimklCatalog.decodeAnimeIDs(Data(#"{"title":"X","ids":{"simkl":2573730,"mal":"59741","anilist":"180136"}}"#.utf8))
        XCTAssertEqual(ids, .init(simkl: 2573730, mal: 59741, anilist: 180136))
        XCTAssertNil(try SimklCatalog.decodeAnimeIDs(Data("[]".utf8)), "An unknown id comes back 200 []")
    }
}

/// The kinds a search asked for, written from the searches as they run.
@MainActor
private final class AskedKinds {
    var kinds: [MediaKind] = []
}
