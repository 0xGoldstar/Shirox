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
        guard let cached = cachedLibrary(), let savedTimestamp else {
            Logger.shared.log(
                "[Simkl] sync phase 1: full read, no date_from (no saved timestamp or cache yet)",
                type: "Provider")
            let entries = try await fullRead()
            store(entries)
            if let stamp = try await currentActivityStamp() {
                UserDefaults.standard.set(stamp, forKey: lastActivityKey)
                Logger.shared.log("[Simkl] saved activities timestamp \(stamp)", type: "Provider")
            }
            return entries
        }

        // Phase 2: ask whether anything moved before asking for anything else.
        let stamp = try await currentActivityStamp()
        Logger.shared.log(
            "[Simkl] sync phase 2: /sync/activities checked — saved=\(savedTimestamp) "
            + "current=\(stamp ?? "nil")",
            type: "Provider")

        guard let stamp, stamp != savedTimestamp else {
            Logger.shared.log(
                "[Simkl] nothing changed — skipping the library request entirely",
                type: "Provider")
            return cached
        }

        let delta = try await deltaRead(since: savedTimestamp)
        let merged = Self.merge(delta, into: cached)
        store(merged)
        UserDefaults.standard.set(stamp, forKey: lastActivityKey)
        return merged
    }

    /// The one full download, taken when the user connects their account.
    ///
    /// Simkl's flow is: connect, download the whole watchlist once, then only ever fetch
    /// changes. Doing it at connect rather than lazily means the first thing the app does with
    /// a new account is the one request that is supposed to be large.
    func primeLibrary() async {
        guard auth.isLoggedIn else { return }
        do {
            _ = try await fetchLibrary()
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        } catch {
            Logger.shared.log("[Simkl] initial library download failed: \(error)", type: "Error")
        }
    }

    // MARK: - Activation refresh

    private let lastCheckKey = "simkl_last_check"
    private let backgroundedAtKey = "simkl_backgrounded_at"

    /// Simkl's developer, on when to call the activities endpoint: *"usually after app goes into
    /// background for 30 minutes or on pull to refresh check activity — don't spam activity
    /// endpoint unnecessarily, will use user requests."*
    ///
    /// The last clause is the reason this exists. Activity checks are charged to the user's own
    /// request budget, so a check on every activation is spending something that belongs to them.
    static let minimumAwayInterval: TimeInterval = 30 * 60

    /// Whether returning to the foreground should check for changes.
    ///
    /// Keyed on how long the app was **away**, not on wall-clock since the last check: coming
    /// back after a moment is the rapid-switch case their guidance names, however long ago the
    /// last check happened to be.
    nonisolated static func shouldCheckOnActivation(
        backgroundedAt: Date?, lastCheck: Date?, now: Date,
        minimumAway: TimeInterval = minimumAwayInterval
    ) -> Bool {
        // Never checked: a first run, or the account was just connected.
        guard let lastCheck else { return true }
        // No background marker yet this install — fall back to time since the last check.
        guard let backgroundedAt else { return now.timeIntervalSince(lastCheck) >= minimumAway }
        return now.timeIntervalSince(backgroundedAt) >= minimumAway
    }

    /// Records when the app left the foreground, so the next activation knows how long it was away.
    func noteEnteredBackground(now: Date = Date()) {
        UserDefaults.standard.set(now, forKey: backgroundedAtKey)
    }

    /// Picks up changes made on Simkl elsewhere, when the app returns after being away a while.
    func refreshOnActivation(now: Date = Date()) async {
        guard auth.isLoggedIn else { return }

        let backgroundedAt = UserDefaults.standard.object(forKey: backgroundedAtKey) as? Date
        let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        guard Self.shouldCheckOnActivation(backgroundedAt: backgroundedAt,
                                           lastCheck: lastCheck, now: now) else {
            Logger.shared.log(
                "[Simkl] activation: away too briefly to check activities", type: "Provider")
            return
        }
        await refreshNow(now: now)
    }

    /// An explicit user request — pull to refresh, or a sync the user started. Always checks,
    /// because the user asked; the throttle exists for automatic checks only.
    func refreshNow(now: Date = Date()) async {
        guard auth.isLoggedIn else { return }
        UserDefaults.standard.set(now, forKey: lastCheckKey)
        do {
            _ = try await fetchLibrary()
        } catch {
            Logger.shared.log("[Simkl] refresh failed: \(error)", type: "Error")
        }
    }

    /// Counts the per-write diagnostics emitted this run, so a 400-title sync logs three
    /// lines rather than four hundred.
    private var loggedWriteSamples = 0

    /// Last library read, in memory for this session.
    private var cached: [LibraryEntry]?

    /// The cached library, falling back to the on-disk snapshot.
    ///
    /// Persisting matters for more than speed. `cached` alone is empty on every launch, so the
    /// Phase 1 branch was taken every single time and `date_from` was never actually used —
    /// exactly the behaviour Simkl's sync policy exists to prevent. `LibraryCacheStore` already
    /// keeps per-provider snapshots on disk, and Simkl is a `ProviderType`, so it just works.
    private func cachedLibrary() -> [LibraryEntry]? {
        if let cached { return cached }
        let snapshot = LibraryCacheStore.shared.snapshot(provider: .simkl, mediaType: .anime)
        cached = snapshot?.entries
        return cached
    }

    private func store(_ entries: [LibraryEntry]) {
        cached = entries
        LibraryCacheStore.shared.save(entries: entries, provider: .simkl, mediaType: .anime)
    }

    /// Drops the cache and the saved timestamp, forcing the next read back to Phase 1.
    func invalidateCache() {
        cached = nil
        UserDefaults.standard.removeObject(forKey: lastActivityKey)
    }

    private func fullRead() async throws -> [LibraryEntry] {
        let data = try await get(Self.libraryPath,
                                 query: [URLQueryItem(name: "extended", value: Self.extendedMode)])
        let entries = try Self.decodeLibrary(from: data)
        logRead(entries, phase: "full")
        return entries
    }

    /// The anime category, not the combined `/sync/all-items/` endpoint.
    ///
    /// Simkl's Phase 2 guidance points at the combined endpoint, and their developer added the
    /// qualifier: *"if you have only anime, you can add sync /anime/ category … whatever you
    /// support, if both shows and movies then it's correct."*
    ///
    /// Only anime reaches Simkl from here. The library comes from AniList and MyAnimeList, which
    /// are anime trackers — what the app can *play* is a separate matter and none of it syncs.
    /// The delta read used the combined endpoint and then discarded every shows and movies entry
    /// it had just downloaded.
    static let libraryPath = "/sync/all-items/anime/all"

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
        Logger.shared.log("[Simkl] delta read using date_from=\(timestamp)", type: "Provider")
        let data = try await get(Self.libraryPath, query: [
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

        let watched = item.watched_episodes_count ?? 0
        let total = item.total_episodes_count
        let status = Self.status(from: item.status, progress: watched, total: total)
        let progress = Self.progress(watched: watched, total: total, status: status)

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

    /// How many episodes a Simkl entry represents as watched.
    ///
    /// Simkl's developer, on why episode writes to a completed title report `added.episodes: 0`:
    /// *"if you already have the anime in your completed watchlist, you cannot mark episodes
    /// there anymore, only as rewatches. Completed = always mean all episodes were watched."*
    ///
    /// So a completed title carries no per-episode history and `watched_episodes_count` stays 0.
    /// Reading that literally made every completed title look unwatched, so every sync decided
    /// the whole library was behind and rewrote it — forever, because the rewrite could never
    /// change the number it was reading.
    nonisolated static func progress(watched: Int?, total: Int?, status: MediaListStatus) -> Int {
        let watched = watched ?? 0
        guard status == .completed, let total, total > 0 else { return watched }
        return max(watched, total)
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
                        format: ScoreFormat, title: String? = nil, year: Int? = nil) {
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
            episodes: episodes.isEmpty ? nil : episodes,
            title: title, year: year))
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
