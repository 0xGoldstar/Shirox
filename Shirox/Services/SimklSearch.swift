import Foundation

/// One kind's results in a Simkl search.
struct SimklSearchSection: Identifiable, Equatable {
    let kind: MediaKind
    let items: [SimklCatalogItem]
    var id: MediaKind { kind }
}

struct SimklSearchOutcome: Equatable {
    var sections: [SimklSearchSection] = []
    /// Kinds whose search failed while another's worked — named in a one-line note.
    var failedKinds: [MediaKind] = []
    /// Every kind failed: this is why.
    var error: String?
}

/// A typed Simkl search: anime, shows and movies at once, in sections.
enum SimklSearch {
    typealias Search = @MainActor @Sendable (String, MediaKind) async throws -> [SimklCatalogItem]

    struct AnimeTarget: Equatable {
        let id: Int
        let provider: ProviderType
    }

    /// Three requests from the user's daily allowance, run together. `SimklCatalog` remembers each
    /// kind's results for the session, so the same search again is free.
    @MainActor static func run(_ query: String,
                               search: @escaping Search = { try await SimklCatalog.search($0, kind: $1) }) async -> SimklSearchOutcome {
        async let anime = attempt { try await search(query, .anime) }
        async let shows = attempt { try await search(query, .tv) }
        async let movies = attempt { try await search(query, .movie) }
        return outcome([(.anime, await anime), (.tv, await shows), (.movie, await movies)])
    }

    private static func attempt<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// Sections in pill order, a kind with nothing left out, and an entry without a Simkl id —
    /// which can't be opened — dropped.
    static func outcome(_ results: [(MediaKind, Result<[SimklCatalogItem], Error>)]) -> SimklSearchOutcome {
        var outcome = SimklSearchOutcome()
        var errors: [Error] = []
        for (kind, result) in results {
            switch result {
            case .success(let items):
                let usable = items.filter { $0.simklID != nil }
                if !usable.isEmpty { outcome.sections.append(SimklSearchSection(kind: kind, items: usable)) }
            case .failure(let error):
                outcome.failedKinds.append(kind)
                errors.append(error)
            }
        }
        if !results.isEmpty, errors.count == results.count {
            outcome.error = errors.first?.localizedDescription
            outcome.failedKinds = []
        }
        return outcome
    }

    /// A result as a card. Shows and movies are Simkl titles, which open the Simkl page. An anime,
    /// whose AniList or MyAnimeList id isn't known until it's opened, is keyed by its Simkl id and
    /// shows Simkl's poster.
    static func cardMedia(_ item: SimklCatalogItem, kind: MediaKind) -> Media? {
        guard let simklID = item.simklID else { return nil }
        let type: String?
        switch kind {
        case .tv:    type = Media.simklTVType
        case .movie: type = Media.simklMovieType
        default:     type = nil
        }
        return Media(
            id: simklID, idMal: nil, provider: .simkl,
            title: MediaTitle(romaji: nil, english: item.title ?? "Untitled", native: nil),
            coverImage: MediaCoverImage(large: item.poster.map(SimklDiscoverMedia.posterURL), extraLarge: nil),
            bannerImage: nil, description: nil, episodes: nil, status: nil, averageScore: nil, genres: nil,
            season: nil, seasonYear: item.year, nextAiringEpisode: nil, relations: nil, type: type, format: nil)
    }

    /// The anime page for a Simkl anime: by the tracker's id — AniList's filled from the mapping
    /// table when Simkl has none. Nil when there's neither.
    static func animeTarget(_ ids: SimklDiscoverItem.IDs, tracker: ProviderType, anilistForMAL: Int?) -> AnimeTarget? {
        if tracker == .mal { return ids.mal.map { AnimeTarget(id: $0, provider: .mal) } }
        return (ids.anilist ?? anilistForMAL).map { AnimeTarget(id: $0, provider: .anilist) }
    }
}
