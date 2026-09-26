import XCTest
@testable import Shirox

/// Up Next after resuming a play from a Simkl page reports the episode's number within the play's
/// season, as the page's own Up Next does — not the module's number, which the tracker would read
/// as that season's episode 13 on a page listing every season.
final class SimklPlayNumberingUpNextTests: XCTestCase {
    private func simkl(_ season: Int, _ count: Int) -> [SimklEpisode] {
        (1...count).map {
            SimklEpisode(season: season, episode: $0, title: nil, aired: true, img: nil, date: nil,
                         isSpecial: false, simklID: season * 1000 + $0)
        }
    }

    private func page(_ numbers: ClosedRange<Int>) -> [EpisodeLink] {
        numbers.map { EpisodeLink(number: Double($0), href: "/e\($0)") }
    }

    func testAPageListingEverySeasonCountsFromTheSeasonsStart() {
        let episodes = simkl(1, 10) + simkl(2, 12)
        let list = page(1...22)
        XCTAssertEqual(SimklPlayNumbering.upNextNumber(moduleNumber: 13, index: 12, in: list,
                                                       season: 2, simklEpisodes: episodes), 3)
    }

    func testASeasonsOwnPageCountsFromOne() {
        let episodes = simkl(1, 10) + simkl(2, 12)
        XCTAssertEqual(SimklPlayNumbering.upNextNumber(moduleNumber: 4, index: 3, in: page(1...12),
                                                       season: 2, simklEpisodes: episodes), 4)
    }

    func testASeasonPageNumberedOnFromTheLastSeason() {
        let episodes = simkl(1, 12) + simkl(2, 12)
        XCTAssertEqual(SimklPlayNumbering.upNextNumber(moduleNumber: 16, index: 3, in: page(13...24),
                                                       season: 2, simklEpisodes: episodes), 4)
    }

    func testSeasonOneIsTheModulesNumber() {
        XCTAssertEqual(SimklPlayNumbering.upNextNumber(moduleNumber: 5, index: 4, in: page(1...22),
                                                       season: 1, simklEpisodes: simkl(1, 10) + simkl(2, 12)), 5)
    }
}
