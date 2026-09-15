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
    typealias Send = ([String: Any]) async throws -> Data
    typealias Sleep = (TimeInterval) async -> Void

    private var pending: [SimklWrite] = []
    private let send: Send
    private let sleep: Sleep
    private let minInterval: TimeInterval

    /// Queued writes not yet accepted by Simkl. A failed batch stays here rather than vanishing.
    var pendingCount: Int { pending.count }

    /// Titles Simkl answered `not_found` for in the last flush — it could not resolve the ids,
    /// so nothing was written for them however cleanly the request succeeded.
    private(set) var notFoundCount = 0

    /// What Simkl reported it actually stored in the last flush.
    private(set) var acceptedShows = 0
    private(set) var acceptedEpisodes = 0

    /// One raw response per flush is logged, to see the shape rather than assume it.
    private var loggedSample = false
    private var loggedOutgoing = false

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
        guard !pending.isEmpty else {
            Logger.shared.log("[Simkl] flush: nothing queued", type: "Provider")
            return
        }
        Logger.shared.log("[Simkl] flush: sending \(pending.count) queued write(s)", type: "Provider")

        notFoundCount = 0
        acceptedShows = 0
        acceptedEpisodes = 0
        loggedSample = false
        loggedOutgoing = false

        let batches = SimklPayloadBuilder.batches(pending)
        pending = []

        for (index, batch) in batches.enumerated() {
            if index > 0 { await sleep(minInterval) }
            do {
                let body = SimklPayloadBuilder.historyBody(items: batch)
                logOutgoing(body)
                let data = try await send(body)
                tally(data)
            } catch {
                Logger.shared.log("[Simkl] Write batch failed, keeping it queued: \(error)", type: "Error")
                pending = batch + batches[(index + 1)...].flatMap { $0 }
                return
            }
        }

        // Unconditional: a silent flush is exactly what hid the last two bugs.
        Logger.shared.log(
            "[Simkl] flush done: \(acceptedShows) shows / \(acceptedEpisodes) episodes stored, "
            + "\(notFoundCount) not found, \(pending.count) still queued",
            type: "Provider")
    }

    /// Logs the first item of the first batch **as this app serialises it**.
    ///
    /// Simkl's reply echoes a `request` object, but that echo is its own reconstruction — it is
    /// not proof of what was sent. Two rounds have now been spent guessing whether episodes were
    /// missing from the payload or being dropped on receipt; this settles which.
    private func logOutgoing(_ body: [String: Any]) {
        guard !loggedOutgoing else { return }
        loggedOutgoing = true
        guard let first = (body["shows"] as? [[String: Any]])?.first,
              let data = try? JSONSerialization.data(withJSONObject: first),
              let json = String(data: data, encoding: .utf8) else { return }
        Logger.shared.log("[Simkl] outgoing item: \(json.prefix(300))", type: "Provider")
    }

    /// Reads what Simkl says it did with a batch.
    ///
    /// A 2xx does **not** mean everything was stored: titles whose ids Simkl cannot resolve come
    /// back under `not_found`, and nothing is written for them. Without reading this, a run
    /// reports those as added on every single run and never notices.
    private func tally(_ data: Data) {
        // The first response of a flush is logged verbatim. Simkl's write reply is the only
        // place that says what was actually stored, and guessing at its shape has cost two
        // rounds of wrong fixes already.
        if !loggedSample {
            loggedSample = true
            let body = String(data: data.prefix(400), encoding: .utf8) ?? "<undecodable>"
            Logger.shared.log("[Simkl] write response sample: \(body)", type: "Provider")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let added = json["added"] as? [String: Any] {
            acceptedShows += (added["shows"] as? Int) ?? 0
            acceptedEpisodes += (added["episodes"] as? Int) ?? 0
        }
        if let notFound = json["not_found"] as? [String: Any] {
            for value in notFound.values {
                if let list = value as? [Any] { notFoundCount += list.count }
            }
        }
    }
}
