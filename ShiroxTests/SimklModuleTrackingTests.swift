import XCTest
@testable import Shirox

/// A finished episode of a module page linked to a Simkl show or movie is marked there, found by
/// its place on the page — not its printed number, which may be 25, 26… or restart per season.
@MainActor
final class SimklModuleTrackingTests: XCTestCase {
    private let key = "module:m|/show"
    private let show = SimklTitleLink(simklID: 7, kind: .tv, season: 1, automatic: true)
    private lazy var file = FileManager.default.temporaryDirectory
        .appendingPathComponent("SimklModuleTrackingTests-\(UUID().uuidString).json")

    private func episode(_ season: Int, _ number: Int) -> SimklEpisode {
        SimklEpisode(season: season, episode: number, title: nil, aired: true, img: nil, date: nil,
                     isSpecial: false, simklID: season * 100 + number)
    }

    func testASeasonPagesPlaceIsThatSeasonsEpisode() {
        let play = SimklModuleTracker.play(for: SimklTitleLink(simklID: 7, kind: .tv, season: 2, automatic: false), position: 5)
        XCTAssertEqual(play, .init(ref: SimklPlayRef(simklID: 7, kind: .tv, season: 2), number: 5))
    }

    /// Every season counts from season 1, and `SimklPlayTracker` carries it past each season's end.
    func testAnAllSeasonsPageCountsFromSeasonOne() {
        let play = SimklModuleTracker.play(for: SimklTitleLink(simklID: 7, kind: .tv, season: nil, automatic: true), position: 13)
        XCTAssertEqual(play, .init(ref: SimklPlayRef(simklID: 7, kind: .tv, season: 1), number: 13))
        let episodes = (1...12).map { episode(1, $0) } + (1...10).map { episode(2, $0) }
        XCTAssertEqual(SimklPlayNumbering.episode(season: 1, number: play.number, in: episodes),
                       SimklEpisodeRef(season: 2, episode: 1), "Season 1 has 12: the 13th is S2 E1")
    }

    func testAMovieIsTheMovie() {
        let play = SimklModuleTracker.play(for: SimklTitleLink(simklID: 9, kind: .movie, season: nil, automatic: false), position: 3)
        XCTAssertEqual(play, .init(ref: SimklPlayRef(simklID: 9, kind: .movie, season: nil), number: 1))
    }

    func testAnUnlinkedPageIsntSimkls() {
        XCTAssertEqual(SimklModuleTracker.outcome(moduleId: "m", detailHref: "/show", episodeHref: "/e1",
                                                  links: { _ in nil }, position: { _, _ in 1 }), .notLinked)
        XCTAssertEqual(SimklModuleTracker.outcome(moduleId: "m", detailHref: "/show", episodeHref: "/e1",
                                                  links: { _ in TrackingLinks(simkl: 5) }, position: { _, _ in 1 }),
                       .notLinked, "An anime's Simkl link is tracked as anime")
        XCTAssertEqual(SimklModuleTracker.outcome(moduleId: nil, detailHref: "/show", episodeHref: "/e1",
                                                  links: { [show] _ in TrackingLinks(simklTitle: show) }, position: { _, _ in 1 }),
                       .notLinked, "No page address, no link")
    }

    func testALinkedPagesEpisodeIsFoundByItsPlace() {
        var asked: [String] = []
        let outcome = SimklModuleTracker.outcome(
            moduleId: "m", detailHref: "/show", episodeHref: "/e4",
            links: { [show] key in key == "module:m|/show" ? TrackingLinks(simklTitle: show) : nil },
            position: { href, key in
                asked.append("\(href ?? "-")@\(key)")
                return 4
            })
        XCTAssertEqual(outcome, .linked(.init(ref: SimklPlayRef(simklID: 7, kind: .tv, season: 1), number: 4)))
        XCTAssertEqual(asked, ["/e4@module:m|/show"])
    }

    func testAnEpisodeWhosePlaceIsntKnownIsntMarked() {
        let outcome = SimklModuleTracker.outcome(moduleId: "m", detailHref: "/show", episodeHref: "/e4",
                                                 links: { [show] _ in TrackingLinks(simklTitle: show) },
                                                 position: { _, _ in nil })
        XCTAssertEqual(outcome, .linked(nil))
    }

    func testAMovieNeedsNoPlace() {
        let movie = SimklTitleLink(simklID: 9, kind: .movie, season: nil, automatic: true)
        let outcome = SimklModuleTracker.outcome(moduleId: "m", detailHref: "/movie", episodeHref: nil,
                                                 links: { _ in TrackingLinks(simklTitle: movie) },
                                                 position: { _, _ in nil })
        XCTAssertEqual(outcome, .linked(.init(ref: SimklPlayRef(simklID: 9, kind: .movie, season: nil), number: 1)))
    }

    func testAPagesEpisodesAreRememberedInOrder() {
        let file = self.file
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let pages = SimklModulePages(file: file)
        pages.remember(["/e1", "/e2", "/e3"], for: key)
        XCTAssertEqual(pages.position(of: "/e2", in: key), 2)
        XCTAssertNil(pages.position(of: "/e9", in: key))
        XCTAssertNil(pages.position(of: nil, in: key))
        XCTAssertNil(pages.position(of: "/e1", in: "module:other|/page"))
        XCTAssertEqual(SimklModulePages(file: file).position(of: "/e3", in: key), 3, "Remembered across launches")
    }
}
