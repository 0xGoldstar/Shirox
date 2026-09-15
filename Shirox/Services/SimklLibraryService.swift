import Foundation

/// Reads and writes a Simkl anime library.
///
/// Two rules from Simkl's own documentation shape this file, and both protect a `client_id`
/// shared by every user of the app:
///
/// - **Reads are gated on `/sync/activities`.** Polling `/sync/all-items` without it is named
///   explicitly as suspension-triggering behaviour.
/// - **Writes are batched and paced** — see `SimklWriteQueue`.
@MainActor
final class SimklLibraryService {
    static let shared = SimklLibraryService()

    private let auth = SimklAuthManager.shared
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    /// Last `all` timestamp seen from `/sync/activities`, so a read can be skipped entirely when
    /// nothing has changed.
    private let lastActivityKey = "simkl_last_activity"

    private lazy var queue = SimklWriteQueue { [weak self] body in
        guard let self else { return Data() }
        return try await self.post("/sync/history", body: body)
    }

    private init() {}

    // MARK: - Transport

    @discardableResult
    private func post(_ path: String, body: [String: Any],
                      query: [URLQueryItem] = []) async throws -> Data {
        let request = try auth.authorizedRequest(path: path, method: "POST", query: query, body: body)
        let (data, response) = try await session.data(for: request)
        try check(response)
        return data
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        let request = try auth.authorizedRequest(path: path, query: query)
        let (data, response) = try await session.data(for: request)
        try check(response)
        return data
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            // Tokens last ~5 years and there is no refresh grant, so a 401 means exactly one
            // thing: the user revoked access under Connected Apps. Nothing to retry.
            auth.logout()
            throw ProviderError.unauthenticated
        case 429:
            let retry = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 1
            Logger.shared.log("[Simkl] Rate limited, retry after \(retry)s", type: "Error")
            throw ProviderError.serverError(429)
        default:
            throw ProviderError.serverError(http.statusCode)
        }
    }

    // MARK: - Reading

    /// An external id as Simkl actually sends it.
    ///
    /// Its docs describe these as integers, but a real response has them as **strings**
    /// (`"mal": "52991"`) — the first live read failed decoding exactly that. Simkl is not
    /// consistent about which form it uses, so accept both rather than betting on either.
    struct FlexibleID: Decodable {
        let value: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let int = try? container.decode(Int.self) {
                value = int
            } else if let string = try? container.decode(String.self) {
                value = Int(string)
            } else {
                value = nil
            }
        }
    }

    struct AllItemsResponse: Decodable {
        struct Item: Decodable {
            struct Show: Decodable {
                struct IDs: Decodable {
                    let simkl: FlexibleID?
                    let mal: FlexibleID?
                    let anilist: FlexibleID?
                }
                let title: String?
                let ids: IDs?
            }
            let show: Show?
            let status: String?
            let watched_episodes_count: Int?
            let total_episodes_count: Int?
            let user_rating: Int?
        }
        let anime: [Item]?
    }

    /// Pure decoding seam, so the real response shape can be tested without a network.
    nonisolated static func decodeLibrary(from data: Data) throws -> [LibraryEntry] {
        let decoded = try JSONDecoder().decode(AllItemsResponse.self, from: data)
        return (decoded.anime ?? []).compactMap(entry(from:))
    }

    /// The user's anime library, following Simkl's two-phase sync policy.
    ///
    /// Their rules are explicit, and the penalty is not a throttle: *"Ensure you always use
    /// `date_from` to avoid overloading the API server. If you don't follow these rules, your
    /// `client_id` will be suspended."* One `client_id` serves every user of this app.
    ///
    /// - **Phase 1** — no saved timestamp, or no cache to merge into: one full read, no
    ///   `date_from`. Anime only, never in parallel with other types.
    /// - **Phase 2** — everything after: `/sync/activities` first, and if it has moved, a
    ///   `date_from` delta merged into the cached library.
    ///
    /// The cache is what makes Phase 2 safe. A delta is *not* a library: returning one to a sync
    /// run would look like the user had only the handful of titles that changed, and a mirror run
    /// would delete the rest.
    func fetchLibrary() async throws -> [LibraryEntry] {
        guard auth.isLoggedIn else { throw ProviderError.unauthenticated }

        let savedTimestamp = UserDefaults.standard.string(forKey: lastActivityKey)

        // Phase 1: nothing to build on, so take the full library once.
        guard let cached, let savedTimestamp else {
            let entries = try await fullRead()
            self.cached = entries
            UserDefaults.standard.set(try await currentActivityStamp(), forKey: lastActivityKey)
            return entries
        }

        // Phase 2: ask whether anything moved before asking for anything else.
        let stamp = try await currentActivityStamp()
        guard let stamp, stamp != savedTimestamp else { return cached }

        let delta = try await deltaRead(since: savedTimestamp)
        let merged = Self.merge(delta, into: cached)
        self.cached = merged
        UserDefaults.standard.set(stamp, forKey: lastActivityKey)
        return merged
    }

    /// Counts the per-write diagnostics emitted this run, so a 400-title sync logs three
    /// lines rather than four hundred.
    private var loggedWriteSamples = 0

    /// Last library read. Backs Phase 2 — see `fetchLibrary`.
    private var cached: [LibraryEntry]?

    /// Drops the cache and the saved timestamp, forcing the next read back to Phase 1.
    func invalidateCache() {
        cached = nil
        UserDefaults.standard.removeObject(forKey: lastActivityKey)
    }

    private func fullRead() async throws -> [LibraryEntry] {
        let data = try await get("/sync/all-items/anime/all",
                                 query: [URLQueryItem(name: "extended", value: Self.extendedMode)])
        let entries = try Self.decodeLibrary(from: data)
        logRead(entries, phase: "full")
        return entries
    }

    /// `ids_only` looked like the lightweight choice and is a trap: it returns **only** ids,
    /// stripping `status`, `watched_episodes_count` and `user_rating`. Every entry then read back
    /// at progress 0, so a sync run decided every single title was behind and rewrote the whole
    /// library on every run — forever.
    ///
    /// `full` is the documented superset. Simkl warns it is a large payload, which is what
    /// `date_from` on the Phase 2 delta is for; the full read happens once.
    static let extendedMode = "full"

    /// Reads are where this integration has been silently wrong twice. One line per read, saying
    /// what actually came back, is worth the log noise.
    private func logRead(_ entries: [LibraryEntry], phase: String) {
        let withProgress = entries.filter { $0.progress > 0 }.count
        // Status distribution matters as much as progress: Simkl tracks a list status separately
        // from episode history, so a title can read as completed with watched_episodes_count 0.
        // Whether the status writes are landing is only visible here.
        let byStatus = Dictionary(grouping: entries, by: \.status)
            .map { "\($0.key.rawValue)=\($0.value.count)" }
            .sorted()
            .joined(separator: " ")
        Logger.shared.log(
            "[Simkl] \(phase) read: \(entries.count) entries, \(withProgress) with progress > 0 — \(byStatus)",
            type: "Provider")
    }

    /// Only what changed, per Simkl's Phase 2 rule. The timestamp is passed back exactly as it
    /// was returned, which their guide calls out specifically.
    private func deltaRead(since timestamp: String) async throws -> [LibraryEntry] {
        let data = try await get("/sync/all-items/", query: [
            URLQueryItem(name: "date_from", value: timestamp),
            URLQueryItem(name: "extended", value: Self.extendedMode),
        ])
        let entries = try Self.decodeLibrary(from: data)
        logRead(entries, phase: "delta")
        return entries
    }

    /// The `all` timestamp from `/sync/activities`, or nil when it cannot be read.
    private func currentActivityStamp() async throws -> String? {
        let data = try await get("/sync/activities")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Simkl nests the anime timestamps; `all` is the cheap top-level "anything moved" check.
        return json["all"] as? String
    }

    /// Applies a delta over a cached library: changed titles replace their previous entry, new
    /// ones are appended, and everything the delta did not mention is left exactly as it was.
    nonisolated static func merge(_ delta: [LibraryEntry], into cached: [LibraryEntry]) -> [LibraryEntry] {
        guard !delta.isEmpty else { return cached }
        var byID = Dictionary(cached.map { ($0.media.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var order = cached.map(\.media.id)
        for entry in delta {
            if byID[entry.media.id] == nil { order.append(entry.media.id) }
            byID[entry.media.id] = entry
        }
        return order.compactMap { byID[$0] }
    }

    nonisolated static func entry(from item: AllItemsResponse.Item) -> LibraryEntry? {
        guard let show = item.show, let ids = show.ids else { return nil }
        // Keyed by the MyAnimeList id where there is one — the spine the pairing joins on.
        guard let id = ids.mal?.value ?? ids.anilist?.value else { return nil }

        let progress = item.watched_episodes_count ?? 0
        let total = item.total_episodes_count
        let status = Self.status(from: item.status, progress: progress, total: total)

        let media = Media(
            id: id, idMal: ids.mal?.value, provider: .simkl,
            title: MediaTitle(romaji: show.title, english: show.title, native: nil),
            coverImage: MediaCoverImage(large: nil, extraLarge: nil),
            bannerImage: nil, description: nil, episodes: total, status: nil,
            averageScore: nil, genres: nil, season: nil, seasonYear: nil,
            nextAiringEpisode: nil, relations: nil, type: nil, format: nil)

        return LibraryEntry(
            id: id, media: media, status: status, progress: progress,
            score: SimklPayloadBuilder.score(fromRating: item.user_rating, format: .point10),
            timesRewatched: nil)
    }

    /// Simkl's statuses map back one-to-one except that it cannot express `repeating` — a
    /// rewatch is a separate Pro-only session, so a rewatching title reads back as `current`.
    /// `LibrarySyncPlanner.isConflict` already treats that pair as agreement, because
    /// MyAnimeList has the same limitation.
    nonisolated static func status(from raw: String?, progress: Int, total: Int?) -> MediaListStatus {
        switch raw {
        case "plantowatch": return .planning
        case "completed":   return .completed
        case "dropped":     return .dropped
        case "hold":        return .paused
        case "watching":    return .current
        default:
            // Fall back to what the numbers say rather than guessing a status.
            if let total, total > 0, progress >= total { return .completed }
            return .current
        }
    }

    // MARK: - Writing

    /// Queues a status/progress/score write. Nothing leaves the app until `flush()`.
    func rawUpdateEntry(malId: Int?, anilistId: Int?, status: MediaListStatus,
                        progress: Int, previousProgress: Int?, score: Double,
                        format: ScoreFormat) {
        var ids: [String: Int] = [:]
        if let malId { ids["mal"] = malId }
        if let anilistId { ids["anilist"] = anilistId }
        guard !ids.isEmpty else { return }

        let episodes = SimklPayloadBuilder.episodeNumbers(from: previousProgress, to: progress)

        // The live write response showed requests with no episodes at all, so the inputs that
        // decide that are worth seeing for the first few writes of a run.
        if loggedWriteSamples < 3 {
            loggedWriteSamples += 1
            Logger.shared.log(
                "[Simkl] write in: mal=\(malId.map(String.init) ?? "nil") status=\(status.rawValue) "
                + "progress=\(progress) prev=\(previousProgress.map(String.init) ?? "nil") "
                + "episodes=\(episodes.count) score=\(score) format=\(format.rawValue) "
                + "rating=\(SimklPayloadBuilder.rating(from: score, format: format).map(String.init) ?? "nil")",
                type: "Provider")
        }

        queue.enqueue(SimklWrite(
            ids: ids,
            status: SimklPayloadBuilder.status(for: status),
            rating: SimklPayloadBuilder.rating(from: score, format: format),
            episodes: episodes.isEmpty ? nil : episodes))
    }

    /// Sends everything queued. Returns how many writes could **not** be delivered — a failed
    /// batch stays queued rather than vanishing, so this is the honest count of what did not
    /// reach Simkl.
    @discardableResult
    func flush() async -> Int {
        await queue.flush()
        loggedWriteSamples = 0
        return queue.pendingCount
    }

    /// Titles Simkl answered `not_found` for in the last flush — nothing was stored for them.
    var lastNotFoundCount: Int { queue.notFoundCount }

    /// Un-marks specific episodes. The title stays in the user's library.
    func rawUnmarkEpisodes(ids: [String: Int], episodes: [Int]) async throws {
        guard !episodes.isEmpty else { return }
        try await post("/sync/history/remove",
                       body: SimklPayloadBuilder.removalBody(ids: ids, episodes: episodes))
    }

    /// **Removes the title from the user's library entirely** — watch history and watchlist
    /// entry both. Deliberately a separate method from `rawUnmarkEpisodes`, rather than one
    /// method with an optional parameter: the difference between them is one field in the body
    /// and the whole of somebody's history for that title.
    func rawDeleteEntry(ids: [String: Int]) async throws {
        try await post("/sync/history/remove",
                       body: SimklPayloadBuilder.removalBody(ids: ids, episodes: nil))
    }
}
