import Foundation

/// Simkl's five list statuses.
///
/// It has no "rewatching": a rewatch is a separate session behind a Pro-only flag, so
/// `repeating` degrades to `watching`. See the Simkl design doc §5.
enum SimklStatus: String {
    case watching, plantowatch, completed, dropped, hold
}

/// One title's worth of changes, ready to be batched into a request.
struct SimklWrite {
    /// Every external id known for this title — Simkl picks the first that resolves and accepts
    /// the extras, so send all of them.
    let ids: [String: Int]
    let status: SimklStatus
    /// 1–10, or nil to leave the rating untouched.
    let rating: Int?
    /// Episode numbers to mark watched, or nil for a status/rating-only write.
    let episodes: [Int]?
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

    // MARK: - Bodies

    static func historyBody(items: [SimklWrite]) -> [String: Any] {
        // Anime goes under `shows[]`. Simkl accepts `anime[]` too, but its own docs specify shows.
        ["shows": items.map { item -> [String: Any] in
            var show: [String: Any] = ["ids": item.ids, "status": item.status.rawValue]
            if let rating = item.rating { show["rating"] = rating }
            if let episodes = item.episodes, !episodes.isEmpty {
                show["seasons"] = [["number": 1, "episodes": episodes.map { ["number": $0] }]]
            }
            return show
        }]
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
            show["seasons"] = [["number": 1, "episodes": episodes.map { ["number": $0] }]]
        }
        return ["shows": [show]]
    }

    // MARK: - Batching

    /// Simkl's guidance is explicit: "Send 50 items in one call rather than 50 calls." Sustained
    /// write-hammering suspends the `client_id` with no warning and no appeal, and a single one
    /// serves every user of this app.
    static func batches<T>(_ items: [T], size: Int = 50) -> [[T]] {
        guard !items.isEmpty, size > 0 else { return [] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0 ..< min($0 + size, items.count)])
        }
    }
}
