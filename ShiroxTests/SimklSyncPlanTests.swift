import XCTest
@testable import Shirox

/// Simkl's two-phase rule per kind: a full read once, then deltas only when a stamp moved — and
/// deletions only from a read that proved them.
final class SimklSyncPlanTests: XCTestCase {

    private func entry(_ id: Int) -> LibraryEntry {
        LibraryEntry(id: id,
                     media: SimklTitleReads.titleMedia(simklID: id, kind: .tv, title: "T\(id)", posterURL: nil,
                                                       year: nil, runtime: nil, episodes: nil),
                     status: .current, progress: 0, score: 0, timesRewatched: nil)
    }

    func testNoCopyMeansAFullRead() {
        XCTAssertEqual(SimklSyncPlan.read(saved: "a", current: "b", hasCache: false), .full)
        XCTAssertEqual(SimklSyncPlan.read(saved: nil, current: "b", hasCache: true), .full)
    }

    func testAnUnchangedStampReadsNothing() {
        XCTAssertEqual(SimklSyncPlan.read(saved: "a", current: "a", hasCache: true), .upToDate)
        XCTAssertEqual(SimklSyncPlan.read(saved: "a", current: nil, hasCache: true), .upToDate)
    }

    func testAMovedStampReadsADeltaFromTheSavedStamp() {
        XCTAssertEqual(SimklSyncPlan.read(saved: "a", current: "b", hasCache: true), .delta(since: "a"))
    }

    /// The first check after this update has no saved removal stamp, so it looks once — which is
    /// what catches titles deleted on simkl.com before deletions were detected at all.
    func testRemovalsAreCheckedOnlyWhenTheirStampMoved() {
        XCTAssertTrue(SimklSyncPlan.checkRemovals(saved: "r1", current: "r2", read: .upToDate))
        XCTAssertFalse(SimklSyncPlan.checkRemovals(saved: "r1", current: "r1", read: .upToDate))
        XCTAssertFalse(SimklSyncPlan.checkRemovals(saved: "r1", current: nil, read: .upToDate))
        XCTAssertTrue(SimklSyncPlan.checkRemovals(saved: nil, current: "r1", read: .delta(since: "a")))
    }

    func testAFullReadNeedsNoRemovalCheck() {
        XCTAssertFalse(SimklSyncPlan.checkRemovals(saved: "r1", current: "r2", read: .full))
    }

    func testRemovalDropsOnlyWhatIsGone() {
        let kept = SimklSyncPlan.applyRemovals(keeping: [1, 3], to: [entry(1), entry(2), entry(3)],
                                               simklID: { $0.id })
        XCTAssertEqual(kept.map(\.id), [1, 3])
    }

    /// An entry that can't be matched can't be proven gone.
    func testATitleWithoutAKnownSimklIdIsNeverRemoved() {
        let kept = SimklSyncPlan.applyRemovals(keeping: [1], to: [entry(1), entry(2)],
                                               simklID: { $0.id == 2 ? nil : $0.id })
        XCTAssertEqual(kept.map(\.id), [1, 2])
    }
}
