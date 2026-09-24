import Foundation

/// What a module episode played from a Simkl page is, on Simkl. The player's context and
/// Continue Watching carry it, so finishing the play can be marked there.
struct SimklPlayRef: Codable, Hashable {
    let simklID: Int
    let kind: MediaKind
    /// The season the play started in — the context's episode number counts from its start. Nil
    /// for a movie.
    let season: Int?
}

/// How a module's episode list lines up with one Simkl season.
struct ModuleSeasonNumbering: Equatable {
    /// Regular episodes before the season.
    let offset: Int
    /// Regular episodes in the season.
    let seasonCount: Int

    /// The offset to look episodes up by in a module list of `listCount` episodes: none on the
    /// season's own page, the season's offset on a page listing every season — one with more
    /// episodes than the season has.
    func offset(forListCount listCount: Int) -> Int {
        seasonCount > 0 && listCount > seasonCount ? offset : 0
    }
}

/// Simkl seasons and module episode numbers.
enum SimklPlayNumbering {
    static func offset(before season: Int, in episodes: [SimklEpisode]) -> Int {
        SimklEpisodePlanner.regular(episodes).filter { $0.season < season }.count
    }

    static func seasonCount(_ season: Int, in episodes: [SimklEpisode]) -> Int {
        SimklEpisodePlanner.regular(episodes).filter { $0.season == season }.count
    }

    /// What the module picker searches: the title for a movie or season 1, "Title Season N" after.
    static func searchTitle(_ title: String, season: Int?) -> String {
        guard let season, season > 1 else { return title }
        return "\(title) Season \(season)"
    }

    /// The picker's numbering for `season`, or nil when there's no season before it to skip.
    static func numbering(for season: Int, in episodes: [SimklEpisode]) -> ModuleSeasonNumbering? {
        let offset = offset(before: season, in: episodes)
        guard offset > 0 else { return nil }
        return ModuleSeasonNumbering(offset: offset, seasonCount: seasonCount(season, in: episodes))
    }

    /// The Simkl episode a play is on. `number` counts from the start of `season` and may run past
    /// its end — Up Next on a page listing every season — into the next season.
    static func episode(season: Int, number: Int, in episodes: [SimklEpisode]) -> SimklEpisodeRef? {
        let regular = SimklEpisodePlanner.regular(episodes)
        let index = offset(before: season, in: episodes) + number - 1
        return regular.indices.contains(index) ? regular[index] : nil
    }
}

/// What the page's big button plays, and what it says.
enum SimklWatchTarget {
    /// The episode a Continue Watching item stopped in, else the next unwatched aired one, else
    /// the first aired.
    static func episode(resume: SimklEpisodeRef?, watched: Set<SimklEpisodeRef>,
                        episodes: [SimklEpisode]) -> SimklEpisodeRef? {
        resume ?? SimklEpisodePlanner.next(after: watched, in: episodes) ?? SimklEpisodePlanner.aired(episodes).first
    }

    /// "Watch Movie", "Continue Movie", "Watch S1 E1", "Continue S2 E6".
    static func label(kind: MediaKind, episode: SimklEpisodeRef?, resuming: Bool) -> String {
        let verb = resuming ? "Continue" : "Watch"
        if kind == .movie { return "\(verb) Movie" }
        guard let episode else { return verb }
        return "\(verb) \(episode.label)"
    }
}
