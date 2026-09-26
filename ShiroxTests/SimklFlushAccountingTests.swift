import XCTest
@testable import Shirox

/// Simkl writes are queued and sent in batches, so a run's per-title tally is optimistic: it
/// records a write the moment it is queued, which is the only point the run knows which title it
/// belonged to. A batch that then fails has to be charged back, or the summary reports work that
/// never left the device — which is exactly what the first live runs did.
@MainActor
final class SimklFlushAccountingTests: XCTestCase {

    private func summary(created: Int, advanced: Int) -> LibrarySyncSummary {
        var s = LibrarySyncSummary()
        s.created = created
        s.advanced = advanced
        return s
    }

    func testUndeliveredWritesComeOffAdvancedFirst() {
        var s = summary(created: 9, advanced: 300)
        LibrarySyncService.chargeUndelivered(50, to: &s)

        XCTAssertEqual(s.advanced, 250)
        XCTAssertEqual(s.created, 9, "created is only charged once advanced is exhausted")
        XCTAssertEqual(s.failed, 50)
    }

    func testChargingSpillsIntoCreatedOnceAdvancedIsExhausted() {
        var s = summary(created: 9, advanced: 5)
        LibrarySyncService.chargeUndelivered(10, to: &s)

        XCTAssertEqual(s.advanced, 0)
        XCTAssertEqual(s.created, 4)
        XCTAssertEqual(s.failed, 10)
    }

    /// A total failure must not leave a run claiming anything succeeded.
    func testEverythingUndeliveredLeavesNoSuccesses() {
        var s = summary(created: 9, advanced: 396)
        LibrarySyncService.chargeUndelivered(405, to: &s)

        XCTAssertEqual(s.created, 0)
        XCTAssertEqual(s.advanced, 0)
        XCTAssertEqual(s.failed, 405)
        XCTAssertEqual(s.changed, 0, "nothing reached Simkl, so nothing changed")
    }

    /// Counts can never go negative, even if more is charged back than was ever recorded.
    func testOverChargingNeverGoesNegative() {
        var s = summary(created: 2, advanced: 3)
        LibrarySyncService.chargeUndelivered(99, to: &s)

        XCTAssertEqual(s.created, 0)
        XCTAssertEqual(s.advanced, 0)
    }

    func testAFullyDeliveredRunIsUntouched() {
        var s = summary(created: 9, advanced: 396)
        LibrarySyncService.chargeUndelivered(0, to: &s)

        XCTAssertEqual(s.created, 9)
        XCTAssertEqual(s.advanced, 396)
        XCTAssertEqual(s.failed, 0)
    }

    /// Removals are batched too, and one that never reached Simkl mustn't be reported as done.
    func testRemovalsThatNeverReachedSimklCountAsFailed() {
        var summary = LibrarySyncSummary()
        summary.deleted = 5
        LibrarySyncService.chargeUnsentRemovals(2, to: &summary)
        XCTAssertEqual(summary.deleted, 3)
        XCTAssertEqual(summary.failed, 2)
    }
}
