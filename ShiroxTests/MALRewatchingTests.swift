import XCTest
@testable import Shirox

/// MyAnimeList has no "rewatching" status: it is a separate `is_rewatching` flag on the list
/// entry. Both halves have to be wired. Sending it without reading it back would read a
/// rewatching entry as plain watching, and the next tracked episode would then clear the flag.
final class MALRewatchingTests: XCTestCase {

    // MARK: - Reading

    func testTheFlagDecodesFromAListStatus() throws {
        let json = #"{"status":"watching","score":8,"num_episodes_watched":6,"is_rewatching":true,"num_times_rewatched":1}"#
        let status = try JSONDecoder().decode(MALLibraryService.MALListStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.is_rewatching, true)
    }

    /// Whatever status MyAnimeList pairs the flag with, the entry is being rewatched.
    func testAFlaggedEntryReadsAsRewatching() {
        XCTAssertEqual(MALLibraryService.listStatus(fromMAL: "watching", isRewatching: true), .repeating)
        XCTAssertEqual(MALLibraryService.listStatus(fromMAL: "completed", isRewatching: true), .repeating)
    }

    func testAnUnflaggedEntryReadsAsItsStatus() {
        XCTAssertEqual(MALLibraryService.listStatus(fromMAL: "watching", isRewatching: false), .current)
        XCTAssertEqual(MALLibraryService.listStatus(fromMAL: "completed", isRewatching: nil), .completed)
        XCTAssertEqual(MALLibraryService.listStatus(fromMAL: "on_hold", isRewatching: nil), .paused)
    }

    /// The single-entry read names its fields, so the flag has to be asked for explicitly —
    /// tracking decides from this read.
    func testTheSingleEntryReadAsksForTheFlag() {
        XCTAssertTrue(MALLibraryService.entryFields.contains("is_rewatching"))
    }

    // MARK: - Writing

    func testARewatchIsSentAsWatchingWithTheFlag() {
        XCTAssertEqual(
            MALLibraryService.updateBody(status: .repeating, progress: 6, score: 0, numTimesRewatched: 2),
            "status=watching&is_rewatching=true&num_watched_episodes=6&score=0&num_times_rewatched=2")
    }

    /// Finishing a rewatch, or any other status, clears the flag — otherwise a completed show
    /// would stay listed as being rewatched.
    func testEveryOtherStatusClearsTheFlag() {
        XCTAssertEqual(
            MALLibraryService.updateBody(status: .completed, progress: 12, score: 8, numTimesRewatched: nil),
            "status=completed&is_rewatching=false&num_watched_episodes=12&score=8")
        XCTAssertTrue(MALLibraryService.updateBody(status: .current, progress: 3, score: 0, numTimesRewatched: nil)
            .contains("is_rewatching=false"))
    }
}
