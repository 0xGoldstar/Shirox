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

/// Simkl's anime catalog, for the Tracking Links sheet only.
///
/// Simkl: "Never call search before scrobbling or marking something watched … use search only
/// when you have no usable IDs at all: a title the user typed." Tracking never calls this.
@MainActor
enum SimklCatalog {
    static func search(_ query: String) async throws -> [SimklCatalogItem] {
        let auth = SimklAuthManager.shared
        let (data, http) = try await auth.send {
            try auth.authorizedRequest(path: "/search/anime", query: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: "20"),
            ])
        }
        guard (200...299).contains(http.statusCode) else { throw ProviderError.serverError(http.statusCode) }
        return try decodeSearch(data)
    }

    /// Catalog lookup by Simkl id — edge-cached, free, and sent without Authorization.
    static func lookup(simklID: Int) async throws -> SimklCatalogItem? {
        let request = SimklAuthManager.shared.catalogRequest(path: "/anime/\(simklID)")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { throw ProviderError.serverError(status) }
        return try decodeLookup(data)
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
