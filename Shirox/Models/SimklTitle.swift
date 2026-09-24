import Foundation

/// The episodes of one season a user has watched on Simkl.
struct SimklSeasonWatch: Codable, Equatable, Sendable {
    let season: Int
    let episodes: [Int]
}

/// One season of a Simkl episode write: the episodes to mark or un-mark, or all of the season when
/// `episodes` is nil.
struct SimklSeasonMark: Codable, Equatable, Sendable {
    let number: Int
    let episodes: [Int]?
}

/// One regular episode, by season and number.
struct SimklEpisodeRef: Hashable, Codable, Comparable, Sendable {
    let season: Int
    let episode: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.season, lhs.episode) < (rhs.season, rhs.episode)
    }

    /// "S2 E5".
    var label: String { "S\(season) E\(episode)" }
}

/// One entry of a show's episode list from Simkl's catalog.
struct SimklEpisode: Codable, Equatable, Sendable, Identifiable {
    let season: Int?
    let episode: Int?
    let title: String?
    let aired: Bool
    let img: String?
    let date: String?
    /// Simkl lists specials after the regular episodes, with no season or episode number.
    let isSpecial: Bool
    let simklID: Int
    /// The episode's synopsis. Optional, so episode lists saved before it still decode.
    var overview: String? = nil

    var id: Int { simklID }

    /// Its place in season order — nil for a special, which has none.
    var ref: SimklEpisodeRef? {
        guard !isSpecial, let season, let episode else { return nil }
        return SimklEpisodeRef(season: season, episode: episode)
    }
}

extension MediaKind {
    /// The kinds the Simkl list holds, in pill order.
    static let simklKinds: [MediaKind] = [.anime, .tv, .movie]

    /// The segment of `/sync/all-items/…` for this kind.
    var simklListPath: String {
        switch self {
        case .tv:    return "shows"
        case .movie: return "movies"
        default:     return "anime"
        }
    }

    /// The segment of `/search/…` — singular for movies, unlike every other endpoint.
    var simklSearchPath: String {
        switch self {
        case .tv:    return "tv"
        case .movie: return "movie"
        default:     return "anime"
        }
    }

    /// The group `/sync/activities` reports this kind under.
    var simklActivitiesKey: String {
        switch self {
        case .tv:    return "tv_shows"
        case .movie: return "movies"
        default:     return "anime"
        }
    }

    /// The array a write for this kind goes under. Anime shares `shows`; see
    /// `SimklPayloadBuilder.animeKey`.
    var simklWriteKey: String { self == .movie ? "movies" : "shows" }
}
