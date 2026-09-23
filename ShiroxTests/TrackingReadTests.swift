import XCTest
@testable import Shirox

/// Tracking has to tell "this show isn't on your list" from "the list couldn't be read".
///
/// They were one case: a rate limit or a dropped connection read as "not on your list", and
/// tracking then wrote a fresh Watching entry over a Rewatching or Completed one. AniList's record
/// of Death Parade shows exactly that — rewatched episode 6, then "watched episode 6 - 7" as
/// CURRENT during the next episode.
final class TrackingReadTests: XCTestCase {

    // MARK: - AniList's answer for "not on your list"

    /// AniList answers a MediaList lookup for a show you don't have with a 404 "Not Found".
    func testAniListsNotFoundMeansNotOnTheList() {
        XCTAssertTrue(AniListLibraryService.isNotOnList(AniListError.serviceMessage(code: 404, message: "Not Found.")))
        XCTAssertTrue(AniListLibraryService.isNotOnList(AniListError.httpError(404)))
    }

    /// THE ONE THAT MATTERS: a failure to read is never evidence the show is absent.
    func testFailuresAreNotAbsence() {
        XCTAssertFalse(AniListLibraryService.isNotOnList(AniListError.rateLimited))
        XCTAssertFalse(AniListLibraryService.isNotOnList(AniListError.httpError(500)))
        XCTAssertFalse(AniListLibraryService.isNotOnList(AniListError.serviceMessage(code: 500, message: "Internal")))
        XCTAssertFalse(AniListLibraryService.isNotOnList(AniListError.tokenRejected))
        XCTAssertFalse(AniListLibraryService.isNotOnList(URLError(.timedOut)))
    }

    // MARK: - What tracking does with a read

    func testAReadThatThrowsIsUnreadable() async {
        let read = await ContinueWatchingManager.readForTracking { throw URLError(.timedOut) }
        guard case .unreadable = read else { return XCTFail("a failed read must not look like an answer") }
    }

    func testNoEntryIsAReadableAnswer() async {
        let read = await ContinueWatchingManager.readForTracking { nil }
        guard case .found(let entry) = read else { return XCTFail("nil is a real answer: not on the list") }
        XCTAssertNil(entry)
    }
}
