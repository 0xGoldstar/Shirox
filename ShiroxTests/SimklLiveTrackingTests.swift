import XCTest
@testable import Shirox

/// What finishing an episode writes to Simkl. The rule it adds to the AniList/MAL one: a title
/// Simkl has as completed is never touched — completion there carries no per-episode history,
/// and a rewatch is a Pro-only session this app does not create, so writing `watching` would
/// move a finished show backwards.
final class SimklLiveTrackingTests: XCTestCase {

    private func decide(_ status: MediaListStatus?, _ progress: Int, ep: Int,
                        total: Int? = 12, completed: Bool = false, skipRewatch: Bool = true) -> SimklTrackWrite? {
        ContinueWatchingManager.simklTrackDecision(
            currentStatus: status, currentProgress: progress, watchedEpisode: ep,
            totalEpisodes: total, isCompleted: completed, skipRewatch: skipRewatch)
    }

    func testAFirstEpisodeAddsTheTitleAsWatching() {
        XCTAssertEqual(decide(nil, 0, ep: 1), SimklTrackWrite(status: .current, progress: 1))
    }

    func testTheNextEpisodeAdvances() {
        XCTAssertEqual(decide(.current, 4, ep: 5), SimklTrackWrite(status: .current, progress: 5))
    }

    func testTheFinaleCompletes() {
        XCTAssertEqual(decide(.current, 11, ep: 12, completed: true), SimklTrackWrite(status: .completed, progress: 12))
    }

    /// THE ONE THAT MATTERS: rewatching a finished show must not demote it on Simkl.
    func testACompletedTitleIsLeftAloneEvenWhenRewatchesAreTracked() {
        XCTAssertNil(decide(.completed, 12, ep: 1, skipRewatch: false))
        XCTAssertNil(decide(.completed, 12, ep: 1, skipRewatch: true))
    }

    func testAnEpisodeAlreadyTrackedIsSkipped() {
        XCTAssertNil(decide(.current, 5, ep: 5))
    }

    func testAPausedTitleIsPickedBackUp() {
        XCTAssertEqual(decide(.paused, 3, ep: 4), SimklTrackWrite(status: .current, progress: 4))
    }

    /// Simkl cannot express `repeating`; it reads back as watching, and is written as watching.
    func testRepeatingIsWrittenAsWatching() {
        XCTAssertEqual(decide(.repeating, 2, ep: 3), SimklTrackWrite(status: .current, progress: 3))
    }
}
