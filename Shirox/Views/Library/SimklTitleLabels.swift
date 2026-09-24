import Foundation

/// What a Simkl show's or movie's row and page say about it.
enum SimklTitleLabels {
    /// "S2 E5 · 17 of 73" — how far the user is, then the count.
    static func showProgress(_ entry: LibraryEntry) -> String {
        let place = SimklEpisodePlanner.lastWatched(entry.watchedEpisodes)?.label
            ?? (entry.status == .completed ? "Completed" : "Not started")
        guard let total = entry.media.episodes, total > 0 else { return "\(place) · \(entry.progress) watched" }
        return "\(place) · \(entry.progress) of \(total)"
    }

    /// "1994 · 2h 34m".
    static func movieLine(_ media: Media) -> String {
        let parts = [media.seasonYear.map(String.init), media.runtime.map { Self.runtime($0) }].compactMap { $0 }
        return parts.isEmpty ? "Movie" : parts.joined(separator: " · ")
    }

    /// "2h 28m", "2h", "58m".
    static func runtime(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
    }
}
