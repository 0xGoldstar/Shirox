import XCTest
@testable import Shirox

/// Simkl accepts either a MyAnimeList or an AniList id, so a queued write for a title with only
/// the latter has no `mediaId`. The generic dedup key used `mediaId ?? -1`, which collapsed every
/// such write onto one key — and dedup is last-write-wins, so all but one vanished.
final class SimklQueueTests: XCTestCase {

    private func write(kind: PendingWrite.Kind = .update,
                       mediaId: Int?, entryId: Int?) -> PendingWrite {
        PendingWrite(
            id: UUID(), provider: .simkl, mediaType: .anime, kind: kind,
            mediaId: mediaId, entryId: entryId, status: .current, progress: 1,
            score: nil, repeatCount: nil, updatedAt: Date(), attempts: 0)
    }

    func testTwoAniListOnlyTitlesDoNotShareADedupKey() {
        let a = write(mediaId: nil, entryId: 100)
        let b = write(mediaId: nil, entryId: 101)
        XCTAssertNotEqual(a.dedupKey, b.dedupKey)
    }

    func testRepeatedWritesToOneTitleStillCollapse() {
        let first = write(mediaId: nil, entryId: 100)
        let second = write(mediaId: nil, entryId: 100)
        XCTAssertEqual(first.dedupKey, second.dedupKey)
    }

    func testMALIdIsPreferredWhenBothArePresent() {
        let both = write(mediaId: 900, entryId: 100)
        let malOnly = write(mediaId: 900, entryId: nil)
        XCTAssertEqual(both.dedupKey, malOnly.dedupKey)
    }

    func testUpdatesAndDeletesForOneTitleAreDistinct() {
        let update = write(kind: .update, mediaId: 900, entryId: nil)
        let delete = write(kind: .delete, mediaId: 900, entryId: nil)
        XCTAssertNotEqual(update.dedupKey, delete.dedupKey)
    }

    /// Simkl writes must never collide with another service's for the same numeric id.
    func testSimklDoesNotCollideWithMyAnimeList() {
        let simkl = write(mediaId: 900, entryId: nil)
        let mal = PendingWrite(
            id: UUID(), provider: .mal, mediaType: .anime, kind: .update,
            mediaId: 900, entryId: nil, status: .current, progress: 1,
            score: nil, repeatCount: nil, updatedAt: Date(), attempts: 0)
        XCTAssertNotEqual(simkl.dedupKey, mal.dedupKey)
    }
}
