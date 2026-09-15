import XCTest
@testable import Shirox

/// Simkl suspends a `client_id` for sustained write-hammering — "no warning, no appeal" — and a
/// single `client_id` serves every user of this app. So the batching and pacing rules are not a
/// performance concern, they are the top correctness constraint, and they get real tests.
@MainActor
final class SimklBatchingTests: XCTestCase {

    /// Records what would have been sent, and what the queue would have waited, without doing
    /// either. Keeps the pacing assertions instant instead of real-time.
    private final class Recorder {
        var bodies: [[String: Any]] = []
        var sleeps: [TimeInterval] = []

        func itemCounts() -> [Int] {
            bodies.map { ($0["shows"] as? [[String: Any]])?.count ?? 0 }
        }
    }

    private func makeQueue(_ recorder: Recorder, minInterval: TimeInterval = 1.0) -> SimklWriteQueue {
        SimklWriteQueue(
            minInterval: minInterval,
            send: { body in recorder.bodies.append(body) },
            sleep: { seconds in recorder.sleeps.append(seconds) })
    }

    private func write(_ id: Int) -> SimklWrite {
        SimklWrite(ids: ["mal": id], status: .watching, rating: nil, episodes: [1])
    }

    func test120WritesBecomeThreeRequestsNotOneHundredAndTwenty() async {
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        for i in 1...120 { queue.enqueue(write(i)) }
        await queue.flush()

        XCTAssertEqual(recorder.bodies.count, 3)
        XCTAssertEqual(recorder.itemCounts(), [50, 50, 20])
    }

    func testNoRequestEverCarriesMoreThanFiftyItems() async {
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        for i in 1...503 { queue.enqueue(write(i)) }
        await queue.flush()

        XCTAssertTrue(recorder.itemCounts().allSatisfy { $0 <= 50 })
        XCTAssertEqual(recorder.itemCounts().reduce(0, +), 503)
    }

    /// One POST per second is the documented ceiling, so the queue waits *between* batches —
    /// never before the first, which would add latency for no reason.
    func testBatchesArePacedAtOnePerSecond() async {
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        for i in 1...120 { queue.enqueue(write(i)) }
        await queue.flush()

        XCTAssertEqual(recorder.sleeps.count, 2, "3 batches need 2 gaps, not 3")
        XCTAssertTrue(recorder.sleeps.allSatisfy { $0 >= 1.0 })
    }

    func testASingleBatchWaitsForNothing() async {
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        queue.enqueue(write(1))
        await queue.flush()

        XCTAssertEqual(recorder.bodies.count, 1)
        XCTAssertTrue(recorder.sleeps.isEmpty)
    }

    func testAnEmptyQueueIssuesNothingAtAll() async {
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        await queue.flush()

        XCTAssertTrue(recorder.bodies.isEmpty)
        XCTAssertTrue(recorder.sleeps.isEmpty)
    }

    /// Flushing must drain: a second flush with nothing new sends nothing, so a retry loop
    /// cannot re-post the same writes.
    func testFlushingDrainsTheQueue() async {
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        for i in 1...10 { queue.enqueue(write(i)) }
        await queue.flush()
        await queue.flush()

        XCTAssertEqual(recorder.bodies.count, 1)
    }

    /// A failing send must not silently lose the writes it was carrying.
    func testWritesSurviveAFailedSend() async {
        let recorder = Recorder()
        let queue = SimklWriteQueue(
            minInterval: 1.0,
            send: { _ in throw ProviderError.serverError(500) },
            sleep: { recorder.sleeps.append($0) })
        for i in 1...10 { queue.enqueue(write(i)) }
        await queue.flush()

        XCTAssertEqual(queue.pendingCount, 10, "a failed batch should stay queued for a later drain")
    }
}
