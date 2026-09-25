import XCTest
@testable import Shirox

/// A show's tracking links decide which entry every write lands on. The rules pinned here are the
/// ones that fail silently: a link that loses to an automatic id, a page whose record hides the
/// other page's, and a module link that leaks onto another season.
@MainActor
final class TrackingLinksTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "TrackingLinksTests")
        defaults.removePersistentDomain(forName: "TrackingLinksTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "TrackingLinksTests")
        super.tearDown()
    }

    // MARK: - Store

    func testLinksSurviveARelaunch() {
        TrackingLinkStore(defaults: defaults).set(TrackingLinks(mal: 28223), for: "anilist:20931")
        XCTAssertEqual(TrackingLinkStore(defaults: defaults).links(for: "anilist:20931"), TrackingLinks(mal: 28223))
    }

    /// Resetting the last link must leave no record behind — an empty one would still be "found".
    func testAnEmptyRecordRemovesTheKey() {
        let store = TrackingLinkStore(defaults: defaults)
        store.set(TrackingLinks(simkl: 5), for: "mal:1")
        store.update("mal:1") { $0.simkl = nil }
        XCTAssertNil(store.links(for: "mal:1"))
        XCTAssertTrue(store.all.isEmpty)
    }

    func testModuleKeyNeedsBothHalves() {
        XCTAssertEqual(TrackingLinkStore.moduleKey(moduleId: "pahe", detailHref: "/anime/1"), "module:pahe|/anime/1")
        XCTAssertNil(TrackingLinkStore.moduleKey(moduleId: nil, detailHref: "/anime/1"))
        XCTAssertNil(TrackingLinkStore.moduleKey(moduleId: "pahe", detailHref: ""))
    }

    // MARK: - Resolver

    private func resolve(aniListID: Int? = nil, malID: Int? = nil, moduleKey: String? = nil,
                         records: [String: TrackingLinks] = [:],
                         anilistForMAL: [Int: Int] = [:], malForAniList: [Int: Int] = [:]) async -> TrackingIDs {
        await TrackingLinkResolver.resolve(
            aniListID: aniListID, malID: malID, moduleKey: moduleKey,
            links: { records[$0] },
            anilistForMAL: { anilistForMAL[$0] },
            malForAniList: { malForAniList[$0] })
    }

    /// THE ONE THAT MATTERS: a link set by the user beats the id the page came with.
    func testALinkBeatsThePagesId() async {
        let ids = await resolve(aniListID: 20931, malID: 1,
                                records: ["anilist:20931": TrackingLinks(mal: 28223)])
        XCTAssertEqual(ids, TrackingIDs(anilist: 20931, mal: 28223, simkl: nil))
    }

    func testThePagesIdBeatsTheMapping() async {
        let ids = await resolve(aniListID: 20931, malID: 28223, malForAniList: [20931: 99])
        XCTAssertEqual(ids.mal, 28223)
    }

    func testTheMappingFillsWhatNothingElseKnows() async {
        // Assigned first: XCTAssert's arguments are autoclosures and can't contain `await`.
        let fromAniList = await resolve(aniListID: 20931, malForAniList: [20931: 28223])
        let fromMAL = await resolve(malID: 28223, anilistForMAL: [28223: 20931])
        XCTAssertEqual(fromAniList.mal, 28223)
        XCTAssertEqual(fromMAL.anilist, 20931)
    }

    /// Links set on the AniList page and on the MAL page of the same show both apply.
    func testRecordsMergeFieldByField() async {
        let ids = await resolve(aniListID: 20931, malID: 28223, records: [
            "anilist:20931": TrackingLinks(simkl: 37145),
            "mal:28223": TrackingLinks(anilist: 777),
        ])
        XCTAssertEqual(ids, TrackingIDs(anilist: 777, mal: 28223, simkl: 37145))
    }

    func testEarlierRecordsWinAFieldBothSet() {
        let merged = TrackingLinkResolver.merged([TrackingLinks(simkl: 1), TrackingLinks(simkl: 2), nil])
        XCTAssertEqual(merged.simkl, 1)
    }

    func testAModuleRecordAppliesOnlyWithItsKey() async {
        let records = ["module:pahe|/a/1": TrackingLinks(mal: 28223)]
        let withKey = await resolve(moduleKey: "module:pahe|/a/1", records: records)
        let withoutKey = await resolve(moduleKey: nil, records: records)
        XCTAssertEqual(withKey.mal, 28223)
        XCTAssertNil(withoutKey.mal)
    }

    func testSimklComesOnlyFromALink() async {
        let unlinked = await resolve(aniListID: 1, malID: 2)
        let linked = await resolve(aniListID: 1, records: ["anilist:1": TrackingLinks(simkl: 9)])
        XCTAssertNil(unlinked.simkl)
        XCTAssertEqual(linked.simkl, 9)
    }

    func testNoRecordChangesNothing() async {
        let ids = await resolve(aniListID: 1, malID: 2)
        XCTAssertEqual(ids, TrackingIDs(anilist: 1, mal: 2, simkl: nil))
    }

    // MARK: - Seasons

    func testModuleLinksApplyWhenTheSeasonIsUnchanged() {
        XCTAssertTrue(TrackingLinkResolver.moduleLinksApply(
            anchorAniListID: 10, anchorMALID: 20, mappedAniListID: 10, mappedMALID: 20))
        XCTAssertTrue(TrackingLinkResolver.moduleLinksApply(
            anchorAniListID: 10, anchorMALID: nil, mappedAniListID: 10, mappedMALID: 55))
    }

    /// Otherwise a MAL fix for season 1 would write season 2's episodes onto season 1.
    func testModuleLinksDoNotFollowAnEpisodeIntoAnotherSeason() {
        XCTAssertFalse(TrackingLinkResolver.moduleLinksApply(
            anchorAniListID: 10, anchorMALID: 20, mappedAniListID: 11, mappedMALID: 21))
        XCTAssertFalse(TrackingLinkResolver.moduleLinksApply(
            anchorAniListID: nil, anchorMALID: 20, mappedAniListID: nil, mappedMALID: 21))
    }

    // MARK: - Simkl shows and movies (module pages)

    /// Links saved before shows and movies existed still load, with neither.
    func testOlderRecordsStillDecode() throws {
        let decoded = try JSONDecoder().decode(TrackingLinks.self, from: Data(#"{"mal":28223,"simkl":37145}"#.utf8))
        XCTAssertEqual(decoded, TrackingLinks(mal: 28223, simkl: 37145))
        XCTAssertNil(decoded.simklTitle)
        XCTAssertNil(decoded.simklSearched)
    }

    /// A page that has had its one automatic search keeps a record, even with nothing linked —
    /// or it would be searched again.
    func testASearchedPageKeepsItsRecord() {
        TrackingLinkStore(defaults: defaults).update("module:m|/show") { $0.simklSearched = true }
        XCTAssertEqual(TrackingLinkStore(defaults: defaults).links(for: "module:m|/show")?.simklSearched, true)
    }

    func testAShowLinkSurvivesARelaunch() {
        let link = SimklTitleLink(simklID: 1359610, kind: .tv, season: nil, automatic: true)
        TrackingLinkStore(defaults: defaults).update("module:m|/show") { $0.simklTitle = link }
        XCTAssertEqual(TrackingLinkStore(defaults: defaults).links(for: "module:m|/show")?.simklTitle, link)
    }
}
