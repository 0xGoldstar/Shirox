import Foundation

/// A show's episode changes, as the write and the copy need them.
struct SimklEpisodePlan: Equatable {
    let marks: [SimklSeasonMark]
    let unmarks: [SimklSeasonMark]
    /// The watched set once both have landed.
    let watched: Set<SimklEpisodeRef>
}

/// "Watched up to", the next episode, ticks and whole seasons for a Simkl TV show — pure decisions.
///
/// Specials take no part. Simkl's episode list gives them no season or episode number, and its
/// history write addresses episodes by nothing else, so nothing here can mark one. A list read
/// reports watched specials under season 0; they are carried along and never changed.
enum SimklEpisodePlanner {

    /// Regular episodes, in season order.
    static func regular(_ episodes: [SimklEpisode]) -> [SimklEpisodeRef] {
        episodes.compactMap(\.ref).sorted()
    }

    /// Regular episodes that have aired, in season order.
    static func aired(_ episodes: [SimklEpisode]) -> [SimklEpisodeRef] {
        episodes.filter(\.aired).compactMap(\.ref).sorted()
    }

    /// The seasons with regular episodes, in order.
    static func regularSeasons(in episodes: [SimklEpisode]) -> [Int] {
        Array(Set(regular(episodes).map(\.season))).sorted()
    }

    /// What the user has watched. A Completed show counts every aired regular episode: Simkl may
    /// hold no per-episode history for a show marked complete in one go.
    static func watched(status: MediaListStatus, recorded: [SimklSeasonWatch]?,
                        episodes: [SimklEpisode]) -> Set<SimklEpisodeRef> {
        var result = Set((recorded ?? []).flatMap { season in
            season.episodes.map { SimklEpisodeRef(season: season.season, episode: $0) }
        })
        if status == .completed { result.formUnion(aired(episodes)) }
        return result
    }

    /// The furthest regular episode in a list read's record — what a row shows, without the catalog.
    static func lastWatched(_ recorded: [SimklSeasonWatch]?) -> SimklEpisodeRef? {
        furthest(Set((recorded ?? []).flatMap { season in
            season.episodes.map { SimklEpisodeRef(season: season.season, episode: $0) }
        }))
    }

    /// The furthest regular episode watched.
    static func furthest(_ watched: Set<SimklEpisodeRef>) -> SimklEpisodeRef? {
        watched.filter { $0.season > 0 }.max()
    }

    /// The regular episode after the furthest one watched, if it has aired.
    static func next(after watched: Set<SimklEpisodeRef>, in episodes: [SimklEpisode]) -> SimklEpisodeRef? {
        let order = regular(episodes)
        let candidate = furthest(watched).map { last in order.first { $0 > last } } ?? order.first
        guard let candidate, aired(episodes).contains(candidate) else { return nil }
        return candidate
    }

    /// The marks and un-marks that make `upTo` the last regular episode watched; nil means none.
    static func plan(watched: Set<SimklEpisodeRef>, upTo: SimklEpisodeRef?,
                     episodes: [SimklEpisode]) -> SimklEpisodePlan {
        let wanted: Set<SimklEpisodeRef> = upTo.map { last in Set(regular(episodes).filter { $0 <= last }) } ?? []
        let toMark = wanted.subtracting(watched)
        let toUnmark = watched.filter { ref in ref.season > 0 && (upTo.map { ref > $0 } ?? true) }
        return SimklEpisodePlan(
            marks: compress(toMark, episodes: episodes),
            unmarks: compress(toUnmark, episodes: episodes),
            watched: watched.subtracting(toUnmark).union(toMark))
    }

    /// A season whose every regular episode is listed goes as the whole season — one small
    /// request for any jump — and the rest by episode number.
    static func compress(_ refs: Set<SimklEpisodeRef>, episodes: [SimklEpisode]) -> [SimklSeasonMark] {
        let bySeason = Dictionary(grouping: refs, by: \.season)
        let catalog = Dictionary(grouping: regular(episodes), by: \.season)
        return bySeason.keys.sorted().map { season in
            let numbers = (bySeason[season] ?? []).map(\.episode).sorted()
            let all = (catalog[season] ?? []).map(\.episode).sorted()
            return SimklSeasonMark(number: season, episodes: !all.isEmpty && numbers == all ? nil : numbers)
        }
    }

    /// The watched set in the copy's storage shape.
    static func seasons(from refs: Set<SimklEpisodeRef>) -> [SimklSeasonWatch] {
        Dictionary(grouping: refs, by: \.season).keys.sorted().map { season in
            SimklSeasonWatch(season: season,
                             episodes: refs.filter { $0.season == season }.map(\.episode).sorted())
        }
    }

    /// The status a tick leaves a show in. Ticking a Plan to Watch show — or one not in the
    /// library — starts it. Un-ticking an episode of a Completed one means it isn't complete, and
    /// a `completed` status sent later would mark every episode again. Otherwise it stays.
    static func statusAfterTick(current: MediaListStatus?, marking: Bool) -> MediaListStatus {
        guard let current else { return .current }
        if marking, current == .planning { return .current }
        if !marking, current == .completed { return .current }
        return current
    }

    /// A whole season. Marking takes its aired episodes — the season whole once every episode has
    /// aired; un-marking takes it whole.
    static func seasonChange(_ season: Int, marking: Bool, watched: Set<SimklEpisodeRef>,
                             episodes: [SimklEpisode]) -> SimklEpisodePlan {
        let inSeason = regular(episodes).filter { $0.season == season }
        guard marking else {
            let removed = watched.filter { $0.season == season }
            return SimklEpisodePlan(
                marks: [],
                unmarks: removed.isEmpty ? [] : [SimklSeasonMark(number: season, episodes: nil)],
                watched: watched.subtracting(removed))
        }
        let airedInSeason = Set(aired(episodes).filter { $0.season == season })
        let added = airedInSeason.subtracting(watched)
        let everyAired = airedInSeason.count == inSeason.count
        return SimklEpisodePlan(
            marks: added.isEmpty ? [] : [SimklSeasonMark(number: season,
                                                        episodes: everyAired ? nil : added.map(\.episode).sorted())],
            unmarks: [],
            watched: watched.union(airedInSeason))
    }

    /// What the edit sheet saves for a show. Completed marks every episode by status alone — a
    /// `completed` status with no seasons is exactly that on Simkl. An unchanged "watched up to"
    /// sends no episodes (nil).
    static func edit(status: MediaListStatus, watched: Set<SimklEpisodeRef>, upTo: SimklEpisodeRef?,
                     initialUpTo: SimklEpisodeRef?, episodes: [SimklEpisode]) -> SimklEpisodePlan? {
        if status == .completed {
            return SimklEpisodePlan(marks: [], unmarks: [], watched: watched.union(aired(episodes)))
        }
        guard upTo != initialUpTo else { return nil }
        return plan(watched: watched, upTo: upTo, episodes: episodes)
    }
}
