import Foundation

/// Batches Simkl writes, paces them, sends one drain at a time, and keeps them on disk until
/// Simkl has them.
///
/// Simkl allows **1 POST/sec**, and every write endpoint takes arrays: "Send 50 items in one call
/// rather than 50 calls." Under AUTH V2 the daily allowance is the user's own — 500 requests on a
/// free plan, shared with every other app they connect — so a backfill that costs 3 requests
/// rather than 400 is the difference between a sync and a spent day.
///
/// `send` and `sleep` are injected so the batching and pacing rules can be asserted instantly
/// in tests, rather than against a live account in real time.
@MainActor
final class SimklWriteQueue {
    typealias Send = ([String: Any]) async throws -> Data
    typealias Sleep = (TimeInterval) async -> Void

    private var pending: [SimklWrite] = []
    /// The drain in progress. Kept on disk with `pending`, so a write mid-request when the app
    /// dies is sent again next launch rather than lost.
    private var inFlight: [SimklWrite] = []
    private var draining: Task<Void, Never>?
    private let send: Send
    private let sleep: Sleep
    private let minInterval: TimeInterval
    private let storeURL: URL?

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

    /// - Parameter storeURL: where queued writes live across launches; nil keeps them in memory.
    init(minInterval: TimeInterval = 1.0,
         storeURL: URL? = nil,
         send: @escaping Send,
         sleep: @escaping Sleep = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.minInterval = minInterval
        self.storeURL = storeURL
        self.send = send
        self.sleep = sleep
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([SimklWrite].self, from: data) {
            pending = saved
        }
    }

    func enqueue(_ write: SimklWrite) {
        pending.append(write)
        persist()
    }

    /// Forgets every queued write. Only for writes that belong to a Simkl account that is no
    /// longer the one signed in — never on sign-out, which keeps them for the next sign-in.
    func discardAll() {
        pending = []
        persist()
    }

    /// Sends everything queued, in batches of at most 50, `minInterval` apart.
    ///
    /// One drain at a time: Simkl holds a per-user lock while a `/sync/history` write runs and
    /// answers a second with `400 RATE_LIMIT`. A call arriving mid-drain waits for it, then
    /// sends whatever was queued meanwhile. The drain clears `draining` itself, before it
    /// completes, so a waiter never spins on a finished task.
    func flush() async {
        while let current = draining { await current.value }
        guard !pending.isEmpty else {
            Logger.shared.log("[Simkl] flush: nothing queued", type: "Provider")
            return
        }
        let task = Task { await self.drain(); self.draining = nil }
        draining = task
        await task.value
    }

    /// The wait goes *between* batches, never before the first. A batch that fails is put back
    /// at the front and the drain stops: dropping it would lose somebody's progress, and
    /// carrying on would spend requests likely to fail the same way.
    private func drain() async {
        Logger.shared.log("[Simkl] flush: sending \(pending.count) queued write(s)", type: "Provider")
        notFoundCount = 0
        acceptedShows = 0
        acceptedEpisodes = 0
        loggedSample = false
        loggedOutgoing = false

        let batches = SimklPayloadBuilder.batches(pending)
        inFlight = pending
        pending = []

        for (index, batch) in batches.enumerated() {
            if index > 0 { await sleep(minInterval) }
            do {
                let body = SimklPayloadBuilder.historyBody(items: batch)
                logOutgoing(body)
                tally(try await send(body))
            } catch {
                Logger.shared.log("[Simkl] Write batch failed, keeping it queued: \(error)", type: "Error")
                pending = batch + batches[(index + 1)...].flatMap { $0 } + pending
                inFlight = []
                persist()
                return
            }
        }

        inFlight = []
        persist()
        // Unconditional: a silent flush is exactly what hid the last two bugs.
        Logger.shared.log(
            "[Simkl] flush done: \(acceptedShows) shows / \(acceptedEpisodes) episodes stored, "
            + "\(notFoundCount) not found, \(pending.count) still queued",
            type: "Provider")
    }

    private func persist() {
        guard let storeURL else { return }
        let all = inFlight + pending
        do {
            if all.isEmpty {
                try? FileManager.default.removeItem(at: storeURL)
            } else {
                try FileManager.default.createDirectory(
                    at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(all).write(to: storeURL, options: .atomic)
            }
        } catch {
            Logger.shared.log("[Simkl] Could not save the write queue: \(error)", type: "Error")
        }
    }

    /// Logs the first item of the first batch **as this app serialises it**.
    ///
    /// Simkl's reply echoes a `request` object, but that echo is its own reconstruction — it is
    /// not proof of what was sent. Two rounds have now been spent guessing whether episodes were
    /// missing from the payload or being dropped on receipt; this settles which.
    private func logOutgoing(_ body: [String: Any]) {
        guard !loggedOutgoing else { return }
        loggedOutgoing = true
        guard let first = (body[SimklPayloadBuilder.animeKey] as? [[String: Any]])?.first,
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
