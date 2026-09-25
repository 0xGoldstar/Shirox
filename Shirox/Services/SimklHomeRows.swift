import Foundation

/// A Simkl Home for one kind: the hero and the titled rows.
struct SimklHomeLayout: Equatable {
    struct Row: Equatable, Identifiable {
        let list: SimklFeedList
        let items: [Media]
        var title: String { list.title }
        var id: SimklFeedList { list }
    }

    let hero: [Media]
    let rows: [Row]
}

/// How Simkl's files become Home — no networking, so all of it is testable.
enum SimklHomeRows {
    static let heroLength = 8

    /// The rows a kind's Home shows, in order.
    static func rows(for kind: MediaKind) -> [SimklFeedList] {
        kind == .movie
            ? [.top(.movie), .trending(.movie, .week), .newReleases, .dvdReleases, .calendar(.movie)]
            : [.top(kind), .trending(kind, .week), .premieres(kind), .calendar(kind)]
    }

    /// The hero: what's most watched today.
    static func heroList(for kind: MediaKind) -> SimklFeedList {
        .trending(kind, .today)
    }

    /// Every list Home loads for a kind — the hero's and the rows'.
    static func lists(for kind: MediaKind) -> [SimklFeedList] {
        [heroList(for: kind)] + rows(for: kind)
    }

    /// How far back New Releases looks.
    static let newReleaseDays = 60

    /// A list's entries in the order they're shown, each title once. Calendar lists are narrowed
    /// to today (Airing Today), to what's still ahead (Coming Soon), or to first episodes still
    /// ahead (New Premieres); New Releases to what came out lately.
    static func select(_ list: SimklFeedList, _ items: [SimklDiscoverItem], today: String) -> [SimklDiscoverItem] {
        let chosen: [SimklDiscoverItem]
        switch list {
        case .trending, .dvdReleases, .top:
            chosen = items
        case .newReleases:
            let since = day(today, minus: newReleaseDays)
            chosen = items.filter { $0.released.map { $0 >= since && $0 <= today } ?? false }
        case .premieres:
            chosen = items.enumerated()
                .filter { $0.element.episode == 1 && ($0.element.airDay.map { $0 >= today } ?? false) }
                .sorted(by: soonestThenRank)
                .map(\.element)
        case .calendar(.movie):
            chosen = items.enumerated()
                .filter { $0.element.airDay.map { $0 >= today } ?? false }
                .sorted(by: soonestThenRank)
                .map(\.element)
        case .calendar:
            chosen = items.enumerated()
                .filter { $0.element.airDay == today }
                .sorted { byRank($0.element, $1.element, $0.offset, $1.offset) }
                .map(\.element)
        }
        var seen = Set<Int>()
        return chosen.filter { seen.insert($0.ids.simkl).inserted }
    }

    /// Soonest first, then most popular.
    private static func soonestThenRank(_ a: (offset: Int, element: SimklDiscoverItem),
                                        _ b: (offset: Int, element: SimklDiscoverItem)) -> Bool {
        let (x, y) = (a.element, b.element)
        if x.airDay != y.airDay { return (x.airDay ?? "") < (y.airDay ?? "") }
        return byRank(x, y, a.offset, b.offset)
    }

    /// Most popular first, unranked last, and otherwise the file's own order.
    private static func byRank(_ x: SimklDiscoverItem, _ y: SimklDiscoverItem, _ xIndex: Int, _ yIndex: Int) -> Bool {
        switch (x.rank, y.rank) {
        case let (a?, b?) where a != b: return a < b
        case (.some, nil): return true
        case (nil, .some): return false
        default: return xIndex < yIndex
        }
    }

    /// A list's titles, converted — anime by the tracker's id, those without one dropped.
    static func titles(_ list: SimklFeedList, _ items: [SimklDiscoverItem], today: String,
                       tracker: ProviderType, anilistForMAL: [Int: Int]) -> [Media] {
        var seen = Set<String>()
        return select(list, items, today: today)
            .compactMap { SimklDiscoverMedia.media($0, kind: list.kind, tracker: tracker, anilistForMAL: anilistForMAL) }
            .filter { seen.insert($0.uniqueId).inserted }
    }

    /// The hero (Trending Today's first few) and every row that has something to show.
    static func layout(kind: MediaKind, files: [SimklFeedList: [SimklDiscoverItem]], today: String,
                       tracker: ProviderType, anilistForMAL: [Int: Int], rowLength: Int) -> SimklHomeLayout {
        var rows: [SimklHomeLayout.Row] = []
        for list in self.rows(for: kind) {
            guard let items = files[list] else { continue }
            let media = titles(list, items, today: today, tracker: tracker, anilistForMAL: anilistForMAL)
            if !media.isEmpty { rows.append(SimklHomeLayout.Row(list: list, items: Array(media.prefix(rowLength)))) }
        }
        let heroSource = heroList(for: kind)
        let hero = files[heroSource].map {
            titles(heroSource, $0, today: today, tracker: tracker, anilistForMAL: anilistForMAL)
        } ?? []
        return SimklHomeLayout(hero: Array(hero.prefix(heroLength)), rows: rows)
    }

    /// "yyyy-MM-dd" for a moment in a time zone — the user's, for "today".
    static func day(_ date: Date, in timeZone: TimeZone = .current) -> String {
        dayFormatter(timeZone).string(from: date)
    }

    /// The "yyyy-MM-dd" day `days` before another.
    static func day(_ day: String, minus days: Int) -> String {
        // In UTC, where every day is 24 hours long.
        let formatter = dayFormatter(TimeZone(identifier: "UTC")!)
        guard let date = formatter.date(from: day) else { return day }
        return formatter.string(from: date.addingTimeInterval(-Double(days) * 24 * 60 * 60))
    }

    private static func dayFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
