import XCTest
@testable import Shirox

/// A watched episode can arrive in the middle of a sync run's batches, and Simkl answers a second
/// concurrent history write with `400 RATE_LIMIT`. And a write is somebody's progress: killing
/// the app, a failed request or signing out must not make it vanish.
@MainActor
final class SimklWriteQueueDrainTests: XCTestCase {

    /// Holds every send open until the test lets it through, counting overlap.
    private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var inFlight = 0, maxInFlight = 0, calls = 0
        var waiting: Int { waiters.count }

        func pass() async {
            calls += 1; inFlight += 1; maxInFlight = max(maxInFlight, inFlight)
            await withCheckedContinuation { waiters.append($0) }
            inFlight -= 1
        }
        func openOne() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
    }

    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("simkl-queue-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL)
        super.tearDown()
    }

    private func write(_ id: Int) -> SimklWrite {
        SimklWrite(ids: ["mal": id], status: .watching, rating: 8, episodes: [1, 2], title: "T\(id)", year: 2024)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
    }

    func testConcurrentFlushesNeverOverlap() async {
        let gate = Gate()
        let queue = SimklWriteQueue(minInterval: 0, send: { _ in await gate.pass(); return Data("{}".utf8) },
                                    sleep: { _ in })
        queue.enqueue(write(1))
        let first = Task { await queue.flush() }
        await waitUntil { gate.waiting == 1 }            // first drain is mid-POST

        queue.enqueue(write(2))
        let second = Task { await queue.flush() }
        for _ in 0..<50 { await Task.yield() }           // every chance to overlap
        XCTAssertEqual(gate.maxInFlight, 1, "a second flush must wait for the POST in flight")

        gate.openOne()
        await waitUntil { gate.waiting == 1 }            // second drain's POST
        gate.openOne()
        await first.value
        await second.value

        XCTAssertEqual(gate.calls, 2)
        XCTAssertEqual(gate.maxInFlight, 1)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testQueuedWritesSurviveARelaunch() {
        let queue = SimklWriteQueue(storeURL: storeURL, send: { _ in Data() })
        queue.enqueue(write(1))
        queue.enqueue(write(2))

        let relaunched = SimklWriteQueue(storeURL: storeURL, send: { _ in Data() })
        XCTAssertEqual(relaunched.pendingCount, 2)
    }

    func testAFailedFlushKeepsTheWritesOnDisk() async {
        let queue = SimklWriteQueue(storeURL: storeURL, send: { _ in throw URLError(.timedOut) }, sleep: { _ in })
        queue.enqueue(write(1))
        await queue.flush()

        XCTAssertEqual(SimklWriteQueue(storeURL: storeURL, send: { _ in Data() }).pendingCount, 1)
    }

    func testADeliveredFlushClearsTheDisk() async {
        let queue = SimklWriteQueue(storeURL: storeURL, send: { _ in Data("{}".utf8) }, sleep: { _ in })
        queue.enqueue(write(1))
        await queue.flush()

        XCTAssertEqual(SimklWriteQueue(storeURL: storeURL, send: { _ in Data() }).pendingCount, 0)
    }

    /// Killed mid-request: the write in flight is still on disk and goes again next launch.
    func testAWriteInFlightIsNotLostIfTheAppDies() async {
        let gate = Gate()
        let queue = SimklWriteQueue(storeURL: storeURL, send: { _ in await gate.pass(); return Data("{}".utf8) },
                                    sleep: { _ in })
        queue.enqueue(write(1))
        let flushing = Task { await queue.flush() }
        await waitUntil { gate.waiting == 1 }

        XCTAssertEqual(SimklWriteQueue(storeURL: storeURL, send: { _ in Data() }).pendingCount, 1)

        gate.openOne()
        await flushing.value
    }

    func testDiscardAllEmptiesTheDisk() {
        let queue = SimklWriteQueue(storeURL: storeURL, send: { _ in Data() })
        queue.enqueue(write(1))
        queue.discardAll()
        XCTAssertEqual(SimklWriteQueue(storeURL: storeURL, send: { _ in Data() }).pendingCount, 0)
    }

    /// Simkl's reply to a status write, as a live sync returned it: nothing under `shows` or
    /// `episodes`, the statuses under `added.statuses`. Counting only the first two logged a
    /// delivered sync as "0 stored".
    func testStatusesSimklStoredAreCounted() async {
        let reply = #"""
        {"added":{"movies":0,"shows":0,"episodes":0,"statuses":[
          {"request":{"ids":{"mal":50360},"status":"completed"},"response":{"status":"completed","simkl_type":"anime"}},
          {"request":{"ids":{"mal":49877},"status":"completed"},"response":{"status":"completed","simkl_type":"anime"}}]},
         "not_found":{"shows":[{"ids":{"mal":1}}]}}
        """#
        let queue = SimklWriteQueue(send: { _ in Data(reply.utf8) }, sleep: { _ in })
        queue.enqueue(write(1))
        await queue.flush()

        XCTAssertEqual(queue.acceptedStatuses, 2)
        XCTAssertEqual(queue.acceptedShows, 0)
        XCTAssertEqual(queue.acceptedEpisodes, 0)
        XCTAssertEqual(queue.notFoundCount, 1)
    }

    func testAWriteRoundTripsThroughDiskIntact() throws {
        let original = write(7)
        let decoded = try JSONDecoder().decode(SimklWrite.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
