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
            send: { body in recorder.bodies.append(body); return Data("{}".utf8) },
            sleep: { seconds in recorder.sleeps.append(seconds) })
    }

    private func write(_ id: Int) -> SimklWrite {
        SimklWrite(ids: ["mal": id], status: .watching, rating: nil, episodes: [1])
    }

    /// 120 writes become 5 requests, not 120. Batches hold 25 *writes*, and a write carrying
    /// both episodes and a status expands to two body entries — so a full batch is 50 items,
    /// which is the size Simkl recommends.
    func test120WritesBecomeFiveRequestsNotOneHundredAndTwenty() async {
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        for i in 1...120 { queue.enqueue(write(i)) }
        await queue.flush()

        XCTAssertEqual(recorder.bodies.count, 5)
        XCTAssertEqual(recorder.itemCounts(), [50, 50, 50, 50, 40])
    }

    /// The ceiling that protects the shared client_id: no request may exceed 50 entries,
    /// however the writes inside it expand.
    func testNoRequestEverCarriesMoreThanFiftyItems() async {
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        for i in 1...503 { queue.enqueue(write(i)) }
        await queue.flush()

        XCTAssertTrue(recorder.itemCounts().allSatisfy { $0 <= 50 },
                      "got \(recorder.itemCounts().max() ?? 0) in one request")
        // Every write here carries episodes, so each expands to an episode entry and a state one.
        XCTAssertEqual(recorder.itemCounts().reduce(0, +), 503 * 2)
    }

    /// A status-only write does not expand, so those batches stay at 25 entries.
    func testStatusOnlyWritesDoNotExpand() async {
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        for i in 1...25 {
            queue.enqueue(SimklWrite(ids: ["mal": i], status: .plantowatch, rating: nil, episodes: nil))
        }
        await queue.flush()

        XCTAssertEqual(recorder.itemCounts(), [25])
    }

    /// One POST per second is the documented ceiling, so the queue waits *between* batches —
    /// never before the first, which would add latency for no reason.
    func testBatchesArePacedAtOnePerSecond() async {
        let recorder = Recorder()
        let queue = makeQueue(recorder)
        for i in 1...120 { queue.enqueue(write(i)) }
        await queue.flush()

        XCTAssertEqual(recorder.sleeps.count, 4, "5 batches need 4 gaps, not 5")
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

    /// A 2xx does not mean stored. Titles whose ids Simkl cannot resolve come back under
    /// not_found, and nothing is written for them — which is how "9 added" repeated on every
    /// single run without anything ever being created.
    func testNotFoundTitlesAreCountedNotAssumedStored() async {
        let recorder = Recorder()
        let queue = SimklWriteQueue(
            minInterval: 1.0,
            send: { _ in
                Data(#"{"added":{"shows":1,"episodes":12},"not_found":{"shows":[{"ids":{"mal":1}},{"ids":{"mal":2}}]}}"#.utf8)
            },
            sleep: { recorder.sleeps.append($0) })
        for i in 1...3 { queue.enqueue(write(i)) }
        await queue.flush()

        XCTAssertEqual(queue.notFoundCount, 2)
        XCTAssertEqual(queue.acceptedShows, 1)
        XCTAssertEqual(queue.acceptedEpisodes, 12)
    }

    /// A response Simkl shapes differently must not crash the drain or invent successes.
    func testAnUnreadableResponseTalliesNothing() async {
        let recorder = Recorder()
        let queue = SimklWriteQueue(
            minInterval: 1.0,
            send: { _ in Data("not json".utf8) },
            sleep: { recorder.sleeps.append($0) })
        queue.enqueue(write(1))
        await queue.flush()

        XCTAssertEqual(queue.notFoundCount, 0)
        XCTAssertEqual(queue.acceptedShows, 0)
        XCTAssertEqual(queue.pendingCount, 0, "an unreadable body is still a delivered request")
    }

    /// A failing send must not silently lose the writes it was carrying.
    func testWritesSurviveAFailedSend() async {
        let recorder = Recorder()
        let queue = SimklWriteQueue(
            minInterval: 1.0,
            send: { _ -> Data in throw ProviderError.serverError(500) },
            sleep: { recorder.sleeps.append($0) })
        for i in 1...10 { queue.enqueue(write(i)) }
        await queue.flush()

        XCTAssertEqual(queue.pendingCount, 10, "a failed batch should stay queued for a later drain")
    }
}
