import Foundation

/// One anime in Simkl's catalog, as search and lookup return it.
struct SimklCatalogItem: Decodable, Equatable {
    let title: String?
    let year: Int?
    let poster: String?
    let type: String?
    let simklID: Int?

    /// Simkl's documented image pattern for a poster fragment.
    static func posterURLString(_ fragment: String) -> String {
        "https://wsrv.nl/?url=https://simkl.in/posters/\(fragment)_m.webp&q=90"
    }

    var posterURL: URL? {
        poster.flatMap { URL(string: Self.posterURLString($0)) }
    }

    private enum CodingKeys: String, CodingKey { case title, year, poster, type, ids }
    private struct IDs: Decodable {
        let simkl: SimklLibraryService.FlexibleID?
        let simkl_id: SimklLibraryService.FlexibleID?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        year = try? c.decodeIfPresent(Int.self, forKey: .year)
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        // The docs spell it both ways, as they did for the other ids.
        let ids = try c.decodeIfPresent(IDs.self, forKey: .ids)
        simklID = ids?.simkl?.value ?? ids?.simkl_id?.value
    }
}

/// A TV show's or movie's catalog record, as the info page shows it.
struct SimklTitleDetails: Codable, Equatable {
    let simklID: Int
    let title: String
    let year: Int?
    let overview: String?
    let genres: [String]
    let runtime: Int?
    let poster: String?
    let fanart: String?
    /// TV: "airing", "ended" and the like; nil for movies.
    let status: String?
    let network: String?
    let certification: String?
    let totalEpisodes: Int?

    var posterURL: String? { poster.map(SimklCatalogItem.posterURLString(_:)) }
    /// Simkl's 960×540 fanart — the size it names for a mobile hero.
    var fanartURL: String? { fanart.map { "https://wsrv.nl/?url=https://simkl.in/fanart/\($0)_mobile.webp&q=90" } }
}

extension SimklEpisode {
    /// Simkl's 210×118 still.
    var imageURL: String? { img.map { "https://wsrv.nl/?url=https://simkl.in/episodes/\($0)_c.webp&q=90" } }
}

/// `/tv/{id}` and `/movies/{id}` as Simkl sends them.
private struct SimklRawDetails: Decodable {
    struct IDs: Decodable { let simkl: SimklLibraryService.FlexibleID? }
    let title: String?
    let year: SimklLibraryService.FlexibleID?
    let ids: IDs?
    let overview: String?
    let genres: [String]?
    let runtime: SimklLibraryService.FlexibleID?
    let poster: String?
    let fanart: String?
    let status: String?
    let network: String?
    let certification: String?
    let total_episodes: Int?
}

/// One `/tv/episodes/{id}` item as Simkl sends it.
private struct SimklRawEpisode: Decodable {
    struct IDs: Decodable { let simkl_id: SimklLibraryService.FlexibleID? }
    let title: String?
    let season: Int?
    let episode: Int?
    let type: String?
    let aired: Bool?
    let img: String?
    let date: String?
    let ids: IDs?
}

/// Simkl's catalog: search for the Tracking Links sheet and the Library's Shows and Movies, and
/// the free detail lookups.
///
/// Simkl: "Never call search before scrobbling or marking something watched … use search only
/// when you have no usable IDs at all: a title the user typed." Tracking never calls this.
@MainActor
enum SimklCatalog {
    static func search(_ query: String, kind: MediaKind = .anime) async throws -> [SimklCatalogItem] {
        if let remembered = rememberedSearch(query, kind: kind) { return remembered }
        let auth = SimklAuthManager.shared
        let (data, http) = try await auth.send {
            try auth.authorizedRequest(path: searchPath(for: kind), query: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: "20"),
            ])
        }
        guard (200...299).contains(http.statusCode) else { throw ProviderError.serverError(http.statusCode) }
        let results = try decodeSearch(data)
        rememberSearch(results, query: query, kind: kind)
        return results
    }

    nonisolated static func searchPath(for kind: MediaKind) -> String { "/search/\(kind.simklSearchPath)" }

    /// Every search is one request of the user's daily budget, so the same one in a session is
    /// answered from memory.
    private static var searches: [String: [SimklCatalogItem]] = [:]

    private static func searchKey(_ query: String, _ kind: MediaKind) -> String {
        "\(kind.rawValue)|\(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    static func rememberedSearch(_ query: String, kind: MediaKind) -> [SimklCatalogItem]? {
        searches[searchKey(query, kind)]
    }

    static func rememberSearch(_ results: [SimklCatalogItem], query: String, kind: MediaKind) {
        searches[searchKey(query, kind)] = results
    }

    /// Catalog lookup by Simkl id — edge-cached, free, and sent without Authorization.
    static func lookup(simklID: Int) async throws -> SimklCatalogItem? {
        try decodeLookup(try await catalogData(path: "/anime/\(simklID)"))
    }

    /// A show's or movie's details — free, edge-cached, sent without Authorization — saved on
    /// the device for the next visit.
    static func details(_ kind: MediaKind, simklID: Int) async throws -> SimklTitleDetails? {
        let details = try decodeDetails(try await catalogData(path: "/\(kind == .movie ? "movies" : "tv")/\(simklID)"))
        if let details { SimklCatalogCache.shared.store(details, kind: kind) }
        return details
    }

    /// A show's episode list: Simkl's copy when it answers, the saved one when it doesn't.
    static func loadEpisodes(simklID: Int) async throws -> [SimklEpisode] {
        do {
            let episodes = try decodeEpisodes(try await catalogData(path: "/tv/episodes/\(simklID)"))
            SimklCatalogCache.shared.store(episodes: episodes, simklID: simklID)
            return episodes
        } catch {
            if let saved = SimklCatalogCache.shared.episodes(simklID: simklID) { return saved }
            throw error
        }
    }

    private static func catalogData(path: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: SimklAuthManager.shared.catalogRequest(path: path))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { throw ProviderError.serverError(status) }
        return data
    }

    /// An unknown id comes back `200 []`, as for anime.
    nonisolated static func decodeDetails(_ data: Data) throws -> SimklTitleDetails? {
        guard let raw = try? JSONDecoder().decode(SimklRawDetails.self, from: data) else {
            _ = try JSONDecoder().decode([SimklRawDetails].self, from: data)
            return nil
        }
        guard let id = raw.ids?.simkl?.value, let title = raw.title else { return nil }
        return SimklTitleDetails(
            simklID: id, title: title, year: raw.year?.value, overview: raw.overview,
            genres: raw.genres ?? [], runtime: raw.runtime?.value, poster: raw.poster,
            fanart: raw.fanart, status: raw.status, network: raw.network,
            certification: raw.certification, totalEpisodes: raw.total_episodes)
    }

    /// Specials carry `type: "special"` and no season or episode number.
    nonisolated static func decodeEpisodes(_ data: Data) throws -> [SimklEpisode] {
        try JSONDecoder().decode([SimklRawEpisode].self, from: data).map { raw in
            SimklEpisode(
                season: raw.season, episode: raw.episode, title: raw.title, aired: raw.aired ?? false,
                img: raw.img, date: raw.date,
                isSpecial: raw.type == "special" || raw.season == nil || raw.episode == nil,
                simklID: raw.ids?.simkl_id?.value ?? 0)
        }
    }

    nonisolated static func decodeSearch(_ data: Data) throws -> [SimklCatalogItem] {
        try JSONDecoder().decode([SimklCatalogItem].self, from: data)
    }

    /// A missing id comes back `200 []`, not a 404.
    nonisolated static func decodeLookup(_ data: Data) throws -> SimklCatalogItem? {
        if let item = try? JSONDecoder().decode(SimklCatalogItem.self, from: data) { return item }
        _ = try JSONDecoder().decode([SimklCatalogItem].self, from: data)
        return nil
    }
}
