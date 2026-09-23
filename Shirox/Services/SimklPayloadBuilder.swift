import Foundation

/// Simkl's five list statuses.
///
/// It has no "rewatching": a rewatch is a separate session behind a Pro-only flag, so
/// `repeating` degrades to `watching`. See the Simkl design doc §5.
enum SimklStatus: String, Codable {
    case watching, plantowatch, completed, dropped, hold
}

/// One title's worth of changes, ready to be batched into a request.
struct SimklWrite: Codable, Equatable {
    /// Every external id known for this title — Simkl picks the first that resolves and accepts
    /// the extras, so send all of them.
    let ids: [String: Int]
    let status: SimklStatus
    /// 1–10, or nil to leave the rating untouched.
    let rating: Int?
    /// Episode numbers to mark watched, or nil for a status/rating-only write.
    let episodes: [Int]?
    /// Sent alongside the ids. Simkl resolves a title from ids "or via fuzzy title+year", so
    /// this is context for the matcher rather than the primary key.
    var title: String? = nil
    var year: Int? = nil
}

/// What moving a title from one progress to another takes on Simkl.
struct SimklProgressChange: Equatable {
    /// Passed as `previousProgress` to `rawUpdateEntry`, which marks `markFrom+1…new`. nil marks
    /// from episode 1.
    let markFrom: Int?
    /// Episodes to take off first, through `rawUnmarkEpisodes`.
    let unmark: [Int]
}

/// Every Simkl mapping decision, with no network and no state.
///
/// Deliberately pure. Two of these rules are expensive to get wrong: the removal radius can
/// erase somebody's library, and the batching rule protects a `client_id` shared by every user
/// of the app — Simkl suspends one for sustained write-hammering with no appeal. Both are cheap
/// to assert here and expensive to discover against a live account.
enum SimklPayloadBuilder {

    // MARK: - Status

    static func status(for status: MediaListStatus) -> SimklStatus {
        switch status {
        case .current:   return .watching
        case .planning:  return .plantowatch
        case .completed: return .completed
        case .dropped:   return .dropped
        case .paused:    return .hold
        // Simkl cannot express a rewatch on a free account. Record the watching state that is
        // true either way rather than dropping the entry.
        case .repeating: return .watching
        }
    }

    // MARK: - Score

    /// `LibraryEntry.score` is the display-scale value of whatever format it was last saved
    /// under — not a canonical scale — so the format must be applied before a 1–10 rating
    /// exists. An AniList user on `POINT_100` has `score == 85`, and `Int(85)` is not a rating.
    static func rating(from score: Double, format: ScoreFormat) -> Int? {
        let canonical = format.toCanonical(score)
        guard canonical > 0 else { return nil }   // unrated: never write a literal 0
        return min(max(Int((canonical / 10).rounded()), 1), 10)
    }

    /// The inverse, for reading a Simkl rating back into a destination side's own format.
    static func score(fromRating rating: Int?, format: ScoreFormat) -> Double {
        guard let rating, rating > 0 else { return 0 }
        return format.fromCanonical(Double(rating) * 10)
    }

    // MARK: - Episodes

    /// Simkl's default anime numbering is AniDB sequential — a single flat season — so flat
    /// progress maps directly, with none of the season/offset arithmetic Trakt would have needed.
    ///
    /// Sends only the delta when the previous progress is known: re-posting a thousand episodes
    /// of a long-running show on every write is wasted budget against a 1 POST/sec limit.
    static func episodeNumbers(from previous: Int?, to current: Int) -> [Int] {
        let start = (previous ?? 0) + 1
        guard current >= start else { return [] }
        return Array(start...current)
    }

    /// `/sync/history` only ever adds, so lower progress means un-marking `new+1…old` first —
    /// except on a completed title, which carries no per-episode history to un-mark, so the
    /// episodes up to the new progress are marked afresh.
    static func progressChange(previous: Int?, previousStatus: MediaListStatus?,
                               to new: Int) -> SimklProgressChange {
        guard let previous, new < previous else {
            return SimklProgressChange(markFrom: previous, unmark: [])
        }
        if previousStatus == .completed {
            return SimklProgressChange(markFrom: 0, unmark: [])
        }
        return SimklProgressChange(markFrom: new, unmark: Array((new + 1)...previous))
    }

    // MARK: - Bodies

    /// The array anime entries are posted under. See `historyBody`.
    /// Tried as `"anime"` when episode writes were being dropped; it made no difference, so
    /// this is back to the key Simkl's docs recommend for both TV and anime.
    static let animeKey = "shows"

    /// Builds a `/sync/history` body.
    ///
    /// A write that carries **both** a status and episodes is emitted as **two entries** for the
    /// same title, because Simkl ignores the episode data on an item that also carries a status.
    /// That was not a guess: the app sent
    ///
    ///     {"ids":{"mal":55888},"rating":10,"episodes":[…12 of them…],"status":"completed"}
    ///
    /// and Simkl echoed the request back without the episodes at all, reporting
    /// `added.episodes: 0` while the status and rating landed. Simkl's own documented example
    /// for marking anime episodes carries `seasons` and no `status`.
    ///
    /// Episodes use `seasons: [{number: 1, …}]`, which is the documented shape for anime too —
    /// the top-level shorthand is not anime-specific and was a wrong turn.
    static func historyBody(items: [SimklWrite]) -> [String: Any] {
        // Anime goes under `anime[]`, not `shows[]`.
        //
        // Simkl's docs say `shows[]` is the cleaner pattern for both, and that is true for the
        // status half — statuses and ratings land through it. But episodes sent that way are
        // discarded: three shapes were tried under `shows[]` (seasons with a status, the
        // top-level shorthand, and seasons alone, which is their own documented anime example)
        // and every one came back echoed as `{"ids":…,"type":"show"}` with the episodes gone
        // and `added.episodes: 0`. The response labels those items `type: show` while reporting
        // `simkl_type: anime`, and the read endpoint is `/sync/all-items/anime/all`, so the
        // anime catalog is keyed separately here too.
        var shows: [[String: Any]] = []

        for item in items {
            if let episodes = item.episodes, !episodes.isEmpty {
                var entry: [String: Any] = [
                    "ids": item.ids,
                    "seasons": [["number": 1, "episodes": episodes.map { ["number": $0] }]],
                ]
                Self.addMetadata(from: item, to: &entry)
                shows.append(entry)
            }

            var state: [String: Any] = ["ids": item.ids, "status": item.status.rawValue]
            if let rating = item.rating { state["rating"] = rating }
            Self.addMetadata(from: item, to: &state)
            shows.append(state)
        }

        return [Self.animeKey: shows]
    }

    /// Attaches the title and year Simkl can fall back on when an id does not resolve.
    private static func addMetadata(from item: SimklWrite, to entry: inout [String: Any]) {
        if let title = item.title, !title.isEmpty { entry["title"] = title }
        if let year = item.year { entry["year"] = year }
    }

    /// `/sync/history/remove` does two very different things depending on one field.
    ///
    /// - `episodes` non-nil: un-marks exactly those episodes; the title stays in the library.
    /// - `episodes` nil: **removes the title from the user's library entirely** — watch history
    ///   and watchlist entry both.
    ///
    /// An empty array is treated as the partial case, never the destructive one: "un-mark
    /// nothing" must not become "delete everything".
    static func removalBody(ids: [String: Int], episodes: [Int]?) -> [String: Any] {
        var show: [String: Any] = ["ids": ids]
        if let episodes {
            // `seasons` is the documented shape for anime episodes, same as `historyBody`.
            show["seasons"] = [["number": 1, "episodes": episodes.map { ["number": $0] }]]
        }
        return [Self.animeKey: [show]]
    }

    // MARK: - Batching

    /// Simkl's guidance is explicit: "Send 50 items in one call rather than 50 calls." Sustained
    /// write-hammering suspends the `client_id` with no warning and no appeal, and a single one
    /// serves every user of this app.
    /// Sized to keep a backfill to a handful of requests.
    ///
    /// Simkl's guidance is that "one POST per second is enough for arrays of 50+ items", so 50
    /// writes — up to 100 body entries, since a write carrying both episodes and a status
    /// expands to two — turns a 400-title backfill into single figures rather than hundreds.
    ///
    /// It was first sized against an app-wide daily cap. Under AUTH V2 the cap is per user
    /// instead — 500 requests a day on a free plan, shared with every other app that user
    /// connects — so a backfill that spends 3 requests rather than 400 still decides whether
    /// the user has a day's allowance left afterwards.
    static func batches<T>(_ items: [T], size: Int = 50) -> [[T]] {
        guard !items.isEmpty, size > 0 else { return [] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0 ..< min($0 + size, items.count)])
        }
    }
}
