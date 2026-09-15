import Foundation

/// Batches Simkl writes and paces them.
///
/// Simkl allows **1 POST/sec** and its own guidance is "Send 50 items in one call rather than 50
/// calls". Sustained write-hammering suspends the `client_id` — "no warning, no appeal" — and a
/// single `client_id` serves every user of this app, so a careless backfill loop does not
/// throttle one account, it removes Simkl support from everyone.
///
/// `send` and `sleep` are injected so the batching and pacing rules can be asserted instantly
/// in tests, rather than against a live account in real time.
@MainActor
final class SimklWriteQueue {
    typealias Send = ([String: Any]) async throws -> Void
    typealias Sleep = (TimeInterval) async -> Void

    private var pending: [SimklWrite] = []
    private let send: Send
    private let sleep: Sleep
    private let minInterval: TimeInterval

    /// Queued writes not yet accepted by Simkl. A failed batch stays here rather than vanishing.
    var pendingCount: Int { pending.count }

    init(minInterval: TimeInterval = 1.0,
         send: @escaping Send,
         sleep: @escaping Sleep = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.minInterval = minInterval
        self.send = send
        self.sleep = sleep
    }

    func enqueue(_ write: SimklWrite) {
        pending.append(write)
    }

    /// Sends everything queued, in batches of at most 50, waiting `minInterval` between them.
    ///
    /// The wait goes *between* batches, never before the first — a single batch should not pay a
    /// second of latency for a limit it cannot breach.
    ///
    /// A batch that fails is put back at the front of the queue and the drain stops. Dropping it
    /// would silently lose somebody's progress; carrying on would spend the rate-limit budget on
    /// requests likely to fail the same way.
    func flush() async {
        guard !pending.isEmpty else { return }

        let batches = SimklPayloadBuilder.batches(pending)
        pending = []

        for (index, batch) in batches.enumerated() {
            if index > 0 { await sleep(minInterval) }
            do {
                try await send(SimklPayloadBuilder.historyBody(items: batch))
            } catch {
                Logger.shared.log("[Simkl] Write batch failed, keeping it queued: \(error)", type: "Error")
                pending = batch + batches[(index + 1)...].flatMap { $0 }
                return
            }
        }
    }
}
