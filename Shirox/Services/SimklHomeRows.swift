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

    /// The lists a kind's Home shows, in order.
    static func lists(for kind: MediaKind) -> [SimklFeedList] {
        let trending = SimklFeedList.Period.allCases.map { SimklFeedList.trending(kind, $0) }
        return kind == .movie ? trending + [.dvdReleases, .calendar(.movie)] : trending + [.calendar(kind)]
    }

    /// A list's entries in the order they're shown, each title once. Calendar lists are narrowed
    /// to today (Airing Today) or to what's still ahead (Coming Soon).
    static func select(_ list: SimklFeedList, _ items: [SimklDiscoverItem], today: String) -> [SimklDiscoverItem] {
        let chosen: [SimklDiscoverItem]
        switch list {
        case .trending, .dvdReleases:
            chosen = items
        case .calendar(.movie):
            chosen = items.enumerated()
                .filter { $0.element.airDay.map { $0 >= today } ?? false }
                .sorted { a, b in
                    let (x, y) = (a.element, b.element)
                    if x.airDay != y.airDay { return (x.airDay ?? "") < (y.airDay ?? "") }
                    return byRank(x, y, a.offset, b.offset)
                }
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

    /// The hero (Trending Today's first few) and every list that has something to show.
    static func layout(kind: MediaKind, files: [SimklFeedList: [SimklDiscoverItem]], today: String,
                       tracker: ProviderType, anilistForMAL: [Int: Int], rowLength: Int) -> SimklHomeLayout {
        var rows: [SimklHomeLayout.Row] = []
        for list in lists(for: kind) {
            guard let items = files[list] else { continue }
            let media = titles(list, items, today: today, tracker: tracker, anilistForMAL: anilistForMAL)
            if !media.isEmpty { rows.append(SimklHomeLayout.Row(list: list, items: Array(media.prefix(rowLength)))) }
        }
        let heroList = SimklFeedList.trending(kind, .today)
        let hero = files[heroList].map {
            titles(heroList, $0, today: today, tracker: tracker, anilistForMAL: anilistForMAL)
        } ?? []
        return SimklHomeLayout(hero: Array(hero.prefix(heroLength)), rows: rows)
    }

    /// "yyyy-MM-dd" for a moment in a time zone — the user's, for "today".
    static func day(_ date: Date, in timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
