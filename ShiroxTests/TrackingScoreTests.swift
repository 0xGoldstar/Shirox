import XCTest
@testable import Shirox

/// Automatic writes — tracking an episode, counting a rewatch, un-marking one, reading a chapter —
/// carry no score, so the rating the user gave stays. AniList and MyAnimeList both read an explicit
/// 0 as "remove the rating"; the user's own 0, from the editor, still clears it.
final class TrackingScoreTests: XCTestCase {

    func testAMALWriteWithoutAScoreLeavesTheRating() {
        let body = MALLibraryService.updateBody(status: .current, progress: 4, score: nil, numTimesRewatched: nil)
        XCTAssertEqual(body, "status=watching&is_rewatching=false&num_watched_episodes=4")
    }

    func testAMALRewatchWithoutAScoreLeavesTheRating() {
        XCTAssertEqual(MALLibraryService.updateBody(status: .repeating, progress: 6, score: nil, numTimesRewatched: 2),
                       "status=watching&is_rewatching=true&num_watched_episodes=6&num_times_rewatched=2")
    }

    func testAnExplicitMALScoreIsSentEvenAsZero() {
        XCTAssertTrue(MALLibraryService.updateBody(status: .completed, progress: 12, score: 8, numTimesRewatched: nil)
            .hasSuffix("&score=8"))
        XCTAssertTrue(MALLibraryService.updateBody(status: .completed, progress: 12, score: 0, numTimesRewatched: nil)
            .hasSuffix("&score=0"), "The user clearing their rating")
    }

    func testAMALMangaWriteWithoutAScoreLeavesTheRating() {
        XCTAssertEqual(MALMangaLibraryService.updateBody(status: .current, progress: 30, score: nil),
                       "status=reading&num_chapters_read=30")
        XCTAssertEqual(MALMangaLibraryService.updateBody(status: .current, progress: 30, score: 7),
                       "status=reading&num_chapters_read=30&score=7")
    }

    func testAnAniListWriteWithoutAScoreLeavesTheRating() {
        let variables = AniListLibraryService.updateVariables(mediaId: 1, status: .current, progress: 4,
                                                              score: nil, repeat: nil)
        XCTAssertNil(variables["score"])
        XCTAssertEqual(variables["progress"] as? Int, 4)
        XCTAssertEqual(variables["status"] as? String, "CURRENT")
    }

    func testAnExplicitAniListScoreIsSentEvenAsZero() {
        XCTAssertEqual(AniListLibraryService.updateVariables(mediaId: 1, status: .completed, progress: 12,
                                                             score: 85, repeat: nil)["score"] as? Double, 85)
        XCTAssertEqual(AniListLibraryService.updateVariables(mediaId: 1, status: .completed, progress: 12,
                                                             score: 0, repeat: nil)["score"] as? Double, 0,
                       "The user clearing their rating")
    }
}
