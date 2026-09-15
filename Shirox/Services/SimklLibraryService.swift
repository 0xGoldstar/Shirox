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
        try await self?.post("/sync/history", body: body)
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

    private struct AllItemsResponse: Decodable {
        struct Item: Decodable {
            struct Show: Decodable {
                struct IDs: Decodable { let simkl: Int?; let mal: Int?; let anilist: Int? }
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

    /// The user's whole anime library, or nil when `/sync/activities` says nothing has changed.
    ///
    /// `extended=ids_only` is what carries the `mal` and `anilist` ids; `watched_episodes_count`
    /// is already part of the default item-level response, so `full` — which Simkl warns is a
    /// large payload — is not needed.
    func fetchLibrary(force: Bool = false) async throws -> [LibraryEntry] {
        guard auth.isLoggedIn else { throw ProviderError.unauthenticated }

        if !force, try await isUnchanged() { return [] }

        let data = try await get("/sync/all-items/anime/all",
                                 query: [URLQueryItem(name: "extended", value: "ids_only")])
        let decoded = try JSONDecoder().decode(AllItemsResponse.self, from: data)
        return (decoded.anime ?? []).compactMap(entry(from:))
    }

    /// Simkl's own guidance: call `/sync/activities` first and only read when it has moved.
    private func isUnchanged() async throws -> Bool {
        let data = try await get("/sync/activities")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = json["all"] as? String else { return false }
        let previous = UserDefaults.standard.string(forKey: lastActivityKey)
        UserDefaults.standard.set(all, forKey: lastActivityKey)
        return previous == all
    }

    private func entry(from item: AllItemsResponse.Item) -> LibraryEntry? {
        guard let show = item.show, let ids = show.ids else { return nil }
        // Keyed by the MyAnimeList id where there is one — the spine the pairing joins on.
        guard let id = ids.mal ?? ids.anilist else { return nil }

        let progress = item.watched_episodes_count ?? 0
        let total = item.total_episodes_count
        let status = Self.status(from: item.status, progress: progress, total: total)

        let media = Media(
            id: id, idMal: ids.mal, provider: .simkl,
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
    static func status(from raw: String?, progress: Int, total: Int?) -> MediaListStatus {
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
        queue.enqueue(SimklWrite(
            ids: ids,
            status: SimklPayloadBuilder.status(for: status),
            rating: SimklPayloadBuilder.rating(from: score, format: format),
            episodes: episodes.isEmpty ? nil : episodes))
    }

    func flush() async {
        await queue.flush()
    }

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
