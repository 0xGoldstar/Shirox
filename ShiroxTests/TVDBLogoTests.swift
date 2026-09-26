import XCTest
@testable import Shirox

/// Which TVDB artwork becomes a title's logo, and how long the answer is kept.
final class TVDBLogoTests: XCTestCase {

    private func art(_ image: String, type: Int = 23, language: String? = "eng",
                     score: Double = 0, size: Int = 100) -> TVDBArtwork {
        TVDBArtwork(image: image, type: type, language: language, width: size, height: size,
                    includesText: nil, score: score)
    }

    private func logo(season: [TVDBArtwork] = [], _ record: [TVDBArtwork], _ kind: TVDBRecord = .series,
                      original: String? = "eng") -> String? {
        TVDBLogo.pick(season: season, record: record, kind: kind, originalLanguage: original)
    }

    // MARK: - Language

    func testEnglishComesFirst() {
        XCTAssertEqual(logo([art("jpn", language: "jpn", score: 90), art("eng", score: 10)], original: "jpn"), "eng")
    }

    func testThenTheTitlesOwnLanguage() {
        XCTAssertEqual(logo([art("fra", language: "fra", score: 90), art("jpn", language: "jpn")], original: "jpn"),
                       "jpn", "An anime keeps its Japanese logo")
    }

    func testThenALogoWithoutALanguage() {
        XCTAssertEqual(logo([art("fra", language: "fra"), art("none", language: nil)]), "none")
    }

    func testAnotherLanguagesLogoIsNoLogo() {
        XCTAssertNil(logo([art("zhtw", type: 25, language: "zhtw")], .movie),
                     "An English film with only a Chinese logo shows its title instead")
    }

    // MARK: - Season, series, ClearArt

    func testTheSeasonsLogoBeforeTheSeries() {
        XCTAssertEqual(logo(season: [art("season")], [art("series", score: 99)]), "season")
    }

    func testTheSeriesLogoWhenTheSeasonHasNoneInAReadableLanguage() {
        XCTAssertEqual(logo(season: [art("season", language: "fra")], [art("series")]), "series")
    }

    func testClearArtOnlyWithoutALogo() {
        XCTAssertEqual(logo([art("clearart", type: 22), art("logo", language: "jpn")], original: "jpn"), "logo")
        XCTAssertEqual(logo([art("clearart", type: 22)]), "clearart")
    }

    func testTheBestScoredThenTheLargest() {
        XCTAssertEqual(logo([art("low", score: 1), art("high", score: 5)]), "high")
        XCTAssertEqual(logo([art("small", size: 100), art("large", size: 400)]), "large")
    }

    // MARK: - Types

    /// Type 14 is a movie's poster, not a logo; 25 and 24 are a movie's ClearLogo and ClearArt.
    func testEachRecordReadsItsOwnTypes() {
        XCTAssertNil(logo([art("moviePoster", type: 14), art("movieLogo", type: 25)], .series))
        XCTAssertEqual(logo([art("seriesLogo", type: 23), art("movieLogo", type: 25)], .movie), "movieLogo")
        XCTAssertEqual(logo([art("movieClearArt", type: 24)], .movie), "movieClearArt")
    }

    func testAKindsRecord() {
        XCTAssertEqual(TVDBRecord(kind: .tv), .series)
        XCTAssertEqual(TVDBRecord(kind: .anime), .series)
        XCTAssertEqual(TVDBRecord(kind: .movie), .movie)
    }

    // MARK: - Keeping the answer

    func testAFoundLogoIsKept() {
        let now = Date()
        let entry = TVDBTitleLogoEntry(path: "logo.png", checked: now.addingTimeInterval(-90 * 24 * 60 * 60))
        XCTAssertEqual(entry.answer(now: now), .known("logo.png"))
    }

    func testNoLogoIsAskedAgainAfterThreeDays() {
        let now = Date()
        XCTAssertEqual(TVDBTitleLogoEntry(path: nil, checked: now.addingTimeInterval(-2 * 24 * 60 * 60)).answer(now: now),
                       .known(nil))
        XCTAssertEqual(TVDBTitleLogoEntry(path: nil, checked: now.addingTimeInterval(-4 * 24 * 60 * 60)).answer(now: now),
                       .askAgain)
    }

    func testTheKeyNamesTheRecord() {
        XCTAssertEqual(TVDBTitleLogoEntry.key(tvdbID: 376098, record: .series), "series-376098")
        XCTAssertEqual(TVDBTitleLogoEntry.key(tvdbID: 346729, record: .movie), "movie-346729")
    }
}
