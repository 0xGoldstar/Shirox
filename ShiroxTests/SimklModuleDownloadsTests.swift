import XCTest
@testable import Shirox

/// Downloading from a linked module page readies it for marking offline: the page's list
/// remembered, Simkl's episode list saved.
@MainActor
final class SimklModuleDownloadsTests: XCTestCase {
    private let key = "module:m|/show"

    private func tempPages() -> SimklModulePages {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return SimklModulePages(file: file)
    }

    private func linked(_ kind: MediaKind) -> TrackingLinks {
        TrackingLinks(simklTitle: SimklTitleLink(simklID: 7, kind: kind, season: kind == .tv ? 1 : nil, automatic: true))
    }

    func testABatchRemembersThePageAndSavesSimklsEpisodes() async {
        let pages = tempPages()
        var loaded: [Int] = []
        await SimklModuleDownloads.prepare(
            moduleId: "m", detailHref: "/show", episodeHrefs: ["/e2"], pageEpisodes: ["/e1", "/e2"],
            pages: pages, links: { _ in self.linked(.tv) },
            fetch: { _, _ in XCTFail("The batch had the list"); return [] },
            loadEpisodes: { loaded.append($0); return [] })
        XCTAssertEqual(pages.position(of: "/e2", in: key), 2)
        XCTAssertEqual(loaded, [7])
    }

    func testAnEpisodeTheListDoesntHoldFetchesThePage() async {
        let pages = tempPages()
        await SimklModuleDownloads.prepare(
            moduleId: "m", detailHref: "/show", episodeHrefs: ["/e3"], pages: pages,
            links: { _ in self.linked(.tv) }, fetch: { _, _ in ["/e1", "/e2", "/e3"] },
            loadEpisodes: { _ in [] })
        XCTAssertEqual(pages.position(of: "/e3", in: key), 3)
    }

    func testAMovieNeedsNoEpisodeList() async {
        var loaded = false
        await SimklModuleDownloads.prepare(
            moduleId: "m", detailHref: "/show", episodeHrefs: ["/e1"], pageEpisodes: ["/e1"], pages: tempPages(),
            links: { _ in self.linked(.movie) }, fetch: { _, _ in [] },
            loadEpisodes: { _ in loaded = true; return [] })
        XCTAssertFalse(loaded)
    }

    func testAnUnlinkedPageIsLeftAlone() async {
        var fetched = false
        let pages = tempPages()
        await SimklModuleDownloads.prepare(
            moduleId: "m", detailHref: "/show", episodeHrefs: ["/e1"], pages: pages,
            links: { _ in nil }, fetch: { _, _ in fetched = true; return ["/e1"] }, loadEpisodes: { _ in [] })
        XCTAssertFalse(fetched)
        XCTAssertNil(pages.position(of: "/e1", in: key))
    }
}
