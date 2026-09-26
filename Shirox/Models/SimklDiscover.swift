import Foundation

/// One title from Simkl's free CDN files — the trending lists, DVD releases and the calendar.
/// The files share one shape, give or take fields, so one type reads them all.
struct SimklDiscoverItem: Equatable, Sendable {
    struct IDs: Equatable, Sendable {
        let simkl: Int
        let mal: Int?
        let anilist: Int?
        /// A show's TVDB series or a movie's TVDB movie, where its logo comes from.
        var tvdb: Int? = nil
        /// Its TMDB show or movie, for a logo TVDB doesn't have.
        var tmdb: Int? = nil
    }

    let title: String
    let titleRomaji: String?
    var ids: IDs
    /// Image path fragments; `SimklDiscoverMedia` turns them into URLs.
    let poster: String?
    let fanart: String?
    let overview: String?
    let genres: [String]
    /// Simkl's community rating, out of 10.
    let rating: Double?
    /// Minutes.
    let runtime: Int?
    let totalEpisodes: Int?
    /// Popularity rank, 1 the most watched; nil where Simkl has none (the calendar sends 0).
    let rank: Int?
    /// Calendar entries only: the day it airs or releases, "yyyy-MM-dd" — the viewer's own day
    /// from v2's times, or the day as v1 lists it.
    var airDay: String?
    /// Calendar entries only: the episode airing — 1 for a new show or season.
    var episode: Int? = nil
    /// When the title came out, "yyyy-MM-dd".
    var released: String? = nil
}

extension SimklDiscoverItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case title, title_romaji, ids, poster, fanart, overview, genres, ratings, runtime, total_episodes, rank, date
        case episode, release_date
    }

    private struct RawIDs: Decodable {
        let simkl_id: SimklLibraryService.FlexibleID?
        let simkl: SimklLibraryService.FlexibleID?
        let mal: SimklLibraryService.FlexibleID?
        let anilist: SimklLibraryService.FlexibleID?
        let tvdb: SimklLibraryService.FlexibleID?
        let tmdb: SimklLibraryService.FlexibleID?
    }

    private struct Episode: Decodable {
        let episode: Int?
    }

    private struct Ratings: Decodable {
        struct Source: Decodable { let rating: Double? }
        let simkl: Source?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func optional<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        // The files spell the id `simkl_id`; the detail records `simkl`.
        let raw = try c.decode(RawIDs.self, forKey: .ids)
        guard let simkl = raw.simkl_id?.value ?? raw.simkl?.value else {
            throw DecodingError.dataCorruptedError(forKey: .ids, in: c, debugDescription: "No Simkl id")
        }
        ids = IDs(simkl: simkl, mal: raw.mal?.value, anilist: raw.anilist?.value,
                  tvdb: raw.tvdb?.value, tmdb: raw.tmdb?.value)
        title = try c.decode(String.self, forKey: .title)
        titleRomaji = optional(String.self, .title_romaji)
        poster = optional(String.self, .poster)
        fanart = optional(String.self, .fanart)
        overview = optional(String.self, .overview)
        // Simkl repeats genres ("Action", "Action", …).
        var seen = Set<String>()
        genres = (optional([String].self, .genres) ?? []).filter { seen.insert($0).inserted }
        rating = optional(Ratings.self, .ratings)?.simkl?.rating
        runtime = optional(String.self, .runtime).flatMap(Self.minutes(from:))
        totalEpisodes = optional(Int.self, .total_episodes)
        rank = optional(Int.self, .rank).flatMap { $0 > 0 ? $0 : nil }
        airDay = optional(String.self, .date).flatMap(Self.day(from:))
        episode = optional(Episode.self, .episode)?.episode
        released = optional(String.self, .release_date).flatMap(Self.releaseDay(from:))
    }

    /// A release date as "yyyy-MM-dd". The trending files write it "08/12/2026"; the calendar
    /// "2026-08-12".
    static func releaseDay(from text: String) -> String? {
        if let day = day(from: text) { return day }
        let parts = text.split(separator: "/")
        guard parts.count == 3, parts[0].count == 2, parts[1].count == 2, parts[2].count == 4,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return "\(parts[2])-\(parts[0])-\(parts[1])"
    }

    /// "25m", "1h 45m" or "2h", in minutes.
    static func minutes(from text: String) -> Int? {
        func number(before unit: String) -> Int? {
            guard let range = text.range(of: #"\d+\s*"# + unit, options: .regularExpression) else { return nil }
            return Int(text[range].filter(\.isNumber))
        }
        let hours = number(before: "h")
        let minutes = number(before: "m")
        guard hours != nil || minutes != nil else { return nil }
        return (hours ?? 0) * 60 + (minutes ?? 0)
    }

    /// The listed day of a calendar timestamp like "2026-09-24T00:00:00+09:00" — Simkl's own day,
    /// not converted, so a show listed for the 24th is on the 24th wherever the user is.
    static func day(from timestamp: String) -> String? {
        let day = String(timestamp.prefix(10))
        return day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? day : nil
    }

    /// A whole file — a list, or a v2 calendar. An entry that can't be read — no Simkl id, say —
    /// is skipped, not fatal. `timeZone` is the viewer's, whose days v2's UTC times fall on.
    static func decodeList(_ data: Data, timeZone: TimeZone = .current) throws -> [SimklDiscoverItem] {
        if let calendar = try? JSONDecoder().decode(CalendarV2.self, from: data) {
            return calendar.items(in: timeZone)
        }
        return try JSONDecoder().decode([Lenient].self, from: data).compactMap(\.item)
    }

    /// Calendar v2: the airings, with each title's details once, by Simkl id. An airing is joined
    /// with its title's details; one without them is skipped.
    private struct CalendarV2: Decodable {
        struct Airing: Decodable {
            struct Episode: Decodable { let episode: Int? }
            let simkl_id: SimklLibraryService.FlexibleID?
            let date: String?
            let episode: Episode?
        }

        let calendar: [Airing]
        let metadata: [String: Lenient]

        func items(in timeZone: TimeZone) -> [SimklDiscoverItem] {
            let parser = ISO8601DateFormatter()
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return calendar.compactMap { airing in
                guard let id = airing.simkl_id?.value, var item = metadata[String(id)]?.item,
                      let date = airing.date.flatMap(parser.date(from:)) else { return nil }
                item.airDay = formatter.string(from: date)
                item.episode = airing.episode?.episode
                return item
            }
        }
    }

    private struct Lenient: Decodable {
        let item: SimklDiscoverItem?
        init(from decoder: Decoder) throws { item = try? SimklDiscoverItem(from: decoder) }
    }
}

/// One of Simkl's free lists on `data.simkl.in`.
enum SimklFeedList: Hashable, Sendable {
    enum Period: String, CaseIterable, Sendable {
        case today, week, month

        var title: String {
            switch self {
            case .today: return "Today"
            case .week:  return "This Week"
            case .month: return "This Month"
            }
        }
    }

    /// Most watched, over a period.
    case trending(MediaKind, Period)
    /// Movies only: the latest popular DVD and digital releases.
    case dvdReleases
    /// Airings and releases from yesterday to a month ahead; `.movie` is the release calendar.
    case calendar(MediaKind)
    /// Simkl's all-time top rated, from its API — with the user's token, so from their allowance.
    case top(MediaKind)
    /// New shows and new seasons starting in the calendar's month ahead.
    case premieres(MediaKind)
    /// Movies only: this month's most watched that came out recently.
    case newReleases

    var kind: MediaKind {
        switch self {
        case .trending(let kind, _), .calendar(let kind), .top(let kind), .premieres(let kind): return kind
        case .dvdReleases, .newReleases: return .movie
        }
    }

    /// Whether the list comes from Simkl's API, which wants the user's token and counts against
    /// their daily allowance. The rest are free files on the CDN.
    var needsToken: Bool {
        if case .top = self { return true }
        return false
    }

    /// Query items beyond Simkl's identification ones.
    var query: [URLQueryItem] {
        // The movie ranking pages; one page of 60 is the list.
        if case .top(.movie) = self { return [URLQueryItem(name: "limit", value: "60")] }
        return []
    }

    /// The file's path; `full` asks for the top 500 instead of the top 100 where there's a choice.
    func path(full: Bool) -> String {
        let size = full ? 500 : 100
        switch self {
        case .trending(let kind, let period):
            return "/discover/trending/\(Self.segment(kind))/\(period.rawValue)_\(size).json"
        case .dvdReleases:
            return "/discover/dvd/releases_\(size).json"
        case .calendar(let kind), .premieres(let kind):
            // v2: real air times, and each title's details — AniList ids for most anime among them.
            return "/calendar/v2/\(Self.calendarName(kind)).json"
        case .newReleases:
            return SimklFeedList.trending(.movie, .month).path(full: full)
        case .top(.anime):
            return "/anime/best/all"
        case .top(.movie):
            // Movies have no best-of list; all movies by rank is the same thing.
            return "/movies/genres/all/movies/all/all/rank"
        case .top:
            return "/tv/best/all"
        }
    }

    /// Where to look when the file can't be had: the calendar's v1 file, until Simkl retires it.
    func fallbackPath(full: Bool) -> String? {
        switch self {
        case .calendar(let kind), .premieres(let kind): return "/calendar/\(Self.calendarName(kind)).json"
        default: return nil
        }
    }

    private static func calendarName(_ kind: MediaKind) -> String {
        kind == .movie ? "movie_release" : segment(kind)
    }

    /// How often Simkl regenerates the file.
    var refreshInterval: TimeInterval {
        switch self {
        case .trending(_, .today): return 60 * 60
        case .trending, .dvdReleases, .newReleases, .top: return 24 * 60 * 60
        case .calendar, .premieres: return 6 * 60 * 60
        }
    }

    /// The row title.
    var title: String {
        switch self {
        case .trending(_, let period): return "Trending \(period.title)"
        case .dvdReleases: return "Popular on DVD & Digital"
        case .calendar(.movie): return "Coming Soon"
        case .calendar: return "Airing Today"
        case .top: return "Top Rated"
        case .premieres: return "New Premieres"
        case .newReleases: return "New Releases"
        }
    }

    private static func segment(_ kind: MediaKind) -> String {
        switch kind {
        case .tv: return "tv"
        case .movie: return "movies"
        default: return "anime"
        }
    }
}
