import Foundation

/// Simkl titles as the app's `Media`, for Home and Search.
///
/// A show or movie becomes a Simkl title, keyed by Simkl id, which opens the Simkl page. An anime
/// becomes an AniList or MyAnimeList title — whichever is the user's tracker — so it opens the
/// app's anime page with everything that has; one without that id is left out.
enum SimklDiscoverMedia {
    static func posterURL(_ path: String) -> String {
        "https://wsrv.nl/?url=https://simkl.in/posters/\(path)_m.webp&q=90"
    }

    /// Simkl's full-width fanart, for the hero.
    static func fanartURL(_ path: String) -> String {
        "https://wsrv.nl/?url=https://simkl.in/fanart/\(path)_medium.webp&q=90"
    }

    /// `anilistForMAL` supplies AniList ids Simkl didn't send, by MyAnimeList id — the calendar's
    /// anime carry only the latter.
    static func media(_ item: SimklDiscoverItem, kind: MediaKind, tracker: ProviderType,
                      anilistForMAL: [Int: Int] = [:]) -> Media? {
        let cover = MediaCoverImage(large: item.poster.map(posterURL), extraLarge: nil)
        let banner = item.fanart.map(fanartURL)
        let score = item.rating.map { Int(($0 * 10).rounded()) }
        let genres = item.genres.isEmpty ? nil : item.genres
        switch kind {
        case .tv, .movie:
            return Media(
                id: item.ids.simkl, idMal: nil, provider: .simkl,
                title: MediaTitle(romaji: nil, english: item.title, native: nil),
                coverImage: cover, bannerImage: banner, description: item.overview,
                episodes: kind == .tv ? item.totalEpisodes : nil, status: nil, averageScore: score,
                genres: genres, season: nil, seasonYear: nil, nextAiringEpisode: nil, relations: nil,
                type: kind == .tv ? Media.simklTVType : Media.simklMovieType, format: nil,
                runtime: item.runtime, tvdbID: item.ids.tvdb)
        case .anime, .manga:
            let provider: ProviderType = tracker == .mal ? .mal : .anilist
            let id = provider == .mal
                ? item.ids.mal
                : item.ids.anilist ?? item.ids.mal.flatMap { anilistForMAL[$0] }
            guard let id else { return nil }
            return Media(
                id: id, idMal: item.ids.mal, provider: provider,
                title: MediaTitle(romaji: item.titleRomaji, english: item.title, native: nil),
                coverImage: cover, bannerImage: banner, description: item.overview,
                episodes: item.totalEpisodes, status: nil, averageScore: score, genres: genres,
                season: nil, seasonYear: nil, nextAiringEpisode: nil, relations: nil,
                type: "ANIME", format: nil)
        }
    }

    /// A list's entries ready to turn into titles: anime's missing ids filled in (Top Rated sends
    /// only Simkl's), and AniList ids for those that had only MyAnimeList's.
    struct Prepared {
        let items: [SimklDiscoverItem]
        let tracker: ProviderType
        let anilistForMAL: [Int: Int]
    }

    @MainActor static func prepare(_ list: SimklFeedList, _ items: [SimklDiscoverItem]) async -> Prepared {
        let items = list.kind == .anime ? await SimklAnimeIDCache.shared.fill(items) : items
        let tracker = tracker
        let map = await anilistMap(for: items, kind: list.kind, tracker: tracker)
        return Prepared(items: items, tracker: tracker, anilistForMAL: map)
    }

    /// The anime tracker: MyAnimeList when it's first in the provider order, else AniList.
    @MainActor static var tracker: ProviderType {
        ProviderManager.shared.primary?.providerType == .mal ? .mal : .anilist
    }

    /// MyAnimeList ids of anime Simkl sent without an AniList id.
    static func malIDsNeedingAniList(_ items: [SimklDiscoverItem]) -> [Int] {
        items.compactMap { $0.ids.anilist == nil ? $0.ids.mal : nil }
    }

    /// AniList ids for MyAnimeList ones, from the app's AniList↔MyAnimeList mapping table.
    @MainActor static func anilistIDs(forMAL malIDs: [Int]) async -> [Int: Int] {
        var map: [Int: Int] = [:]
        for malID in Set(malIDs) {
            if let anilistID = await TVDBMappingService.shared.anilistId(forMalId: malID) {
                map[malID] = anilistID
            }
        }
        return map
    }

    /// AniList ids for the anime among `items` that came without one — looked up only when the
    /// list is anime and AniList is the tracker.
    @MainActor static func anilistMap(
        for items: [SimklDiscoverItem], kind: MediaKind, tracker: ProviderType,
        lookUp: @MainActor ([Int]) async -> [Int: Int] = { await SimklDiscoverMedia.anilistIDs(forMAL: $0) }
    ) async -> [Int: Int] {
        guard kind == .anime, tracker == .anilist else { return [:] }
        let missing = malIDsNeedingAniList(items)
        return missing.isEmpty ? [:] : await lookUp(missing)
    }
}
