import XCTest
@testable import Shirox

/// A module that sends no poster or synopsis (every Seanime anime provider) borrows AniList's.
@MainActor
final class ModuleArtworkTests: XCTestCase {
    private func media(cover: String?, description: String?) -> Media {
        Media(id: 154587, idMal: nil, provider: .anilist,
              title: MediaTitle(romaji: "Sousou no Frieren", english: "Frieren", native: nil),
              coverImage: MediaCoverImage(large: cover.map { $0 + "?large" }, extraLarge: cover),
              bannerImage: nil, description: description, episodes: 28, status: "FINISHED",
              averageScore: 90, genres: nil, season: nil, seasonYear: 2023, nextAiringEpisode: nil,
              relations: nil, type: "ANIME", format: "TV")
    }

    private func detail(image: String, description: String) -> MediaDetail {
        MediaDetail(title: "Frieren", image: image, description: description, aliases: "", airdate: "",
                    episodes: [EpisodeLink(number: 1, href: "seanime-episode:1")])
    }

    func testADetailWithNoPosterOrSynopsisBorrowsTheAniListOnes() {
        let match = media(cover: "https://img/frieren.jpg", description: "An elf<br>outlives her party.")
        let filled = detail(image: "", description: "").borrowing(from: match)
        XCTAssertEqual(filled.image, "https://img/frieren.jpg")
        XCTAssertEqual(filled.description, "An elf\noutlives her party.")
        XCTAssertEqual(filled.episodes, [EpisodeLink(number: 1, href: "seanime-episode:1")])
        XCTAssertEqual(detail(image: "", description: "N/A").borrowing(from: match).description,
                       "An elf\noutlives her party.")
    }

    func testADetailKeepsItsOwnPosterAndSynopsis() {
        let match = media(cover: "https://img/frieren.jpg", description: "AniList's synopsis")
        let own = detail(image: "https://site/poster.jpg", description: "The site's synopsis").borrowing(from: match)
        XCTAssertEqual(own.image, "https://site/poster.jpg")
        XCTAssertEqual(own.description, "The site's synopsis")
    }

    func testWithNoMatchTheDetailIsUnchanged() {
        let bare = detail(image: "", description: "").borrowing(from: nil)
        XCTAssertEqual(bare.image, "")
        XCTAssertEqual(bare.description, "")
        XCTAssertEqual(detail(image: "", description: "").borrowing(from: media(cover: nil, description: nil)).image, "")
    }

    func testCoverLookupsLeaveOutDubAndSubTags() {
        XCTAssertEqual(AniListService.coverSearchTerm("One Piece (Dub)"), "One Piece")
        XCTAssertEqual(AniListService.coverSearchTerm("Frieren [SUB]"), "Frieren")
        XCTAssertEqual(AniListService.coverSearchTerm("Dubbed Life"), "Dubbed Life")
    }

    func testEachTitlesCoverIsReadFromItsOwnPage() {
        let response = Data("""
        {"data":{"t0":{"media":[{"coverImage":{"large":"https://img/frieren.jpg"}}]},
                 "t1":{"media":[]},
                 "t2":null,
                 "t3":{"media":[{"coverImage":{"large":"https://img/op.jpg"}}]}}}
        """.utf8)
        let covers = AniListService.covers(from: response, titles: ["Frieren", "Nothing Here", "Broken", "One Piece (Dub)"])
        XCTAssertEqual(covers, ["Frieren": "https://img/frieren.jpg", "One Piece (Dub)": "https://img/op.jpg"])
    }

    func testSearchResultsWithoutAnImageGetTheirCover() {
        let items = [SearchItem(title: "Frieren", image: "", href: "frieren"),
                     SearchItem(title: "Own Art", image: "https://site/own.jpg", href: "own"),
                     SearchItem(title: "Unknown", image: "", href: "unknown")]
        let filled = SearchViewModel.withPosters(items, covers: ["Frieren": "https://img/frieren.jpg",
                                                                 "Own Art": "https://img/other.jpg"])
        XCTAssertEqual(filled.map(\.image), ["https://img/frieren.jpg", "https://site/own.jpg", ""])
        XCTAssertEqual(filled.map(\.id), items.map(\.id), "Rows keep their identity, so the grid doesn't redraw them")
    }
}
