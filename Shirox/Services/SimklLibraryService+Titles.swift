import Foundation

/// Changes to the saved copy of the Simkl TV or movie list, as pure functions.
enum SimklTitleCopy {
    static func updating(_ entries: [LibraryEntry], simklID: Int, status: MediaListStatus,
                         score: Double, watched: Set<SimklEpisodeRef>?) -> [LibraryEntry] {
        entries.map { entry in
            guard entry.id == simklID else { return entry }
            var updated = entry
            updated.status = status
            // An unrated save sends no rating, so Simkl keeps the one it has.
            if score > 0 { updated.score = score }
            if let watched {
                updated.watchedEpisodes = SimklEpisodePlanner.seasons(from: watched)
                updated.progress = watched.count
            }
            return updated
        }
    }

    static func removing(_ simklID: Int, from entries: [LibraryEntry]) -> [LibraryEntry] {
        entries.filter { $0.id != simklID }
    }

    /// Adds `entry`, or replaces the one with its id.
    static func inserting(_ entry: LibraryEntry, into entries: [LibraryEntry]) -> [LibraryEntry] {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return entries + [entry] }
        var result = entries
        result[index] = entry
        return result
    }

    /// A list entry for a title added from search or its info page.
    static func entry(simklID: Int, kind: MediaKind, title: String, posterURL: String?, year: Int?,
                      runtime: Int?, totalEpisodes: Int?, status: MediaListStatus) -> LibraryEntry {
        LibraryEntry(
            id: simklID,
            media: SimklTitleReads.titleMedia(simklID: simklID, kind: kind, title: title, posterURL: posterURL,
                                              year: year, runtime: runtime,
                                              episodes: kind == .tv ? totalEpisodes : nil),
            status: status, progress: 0, score: 0, timesRewatched: nil)
    }
}

/// Writes for Simkl TV shows and movies, addressed by `ids: {simkl}` alone.
///
/// Marks, statuses and ratings go through the durable queue like anime's. Un-marks and removals
/// are sent at once, as anime's are, so a failure is reported rather than retried behind the
/// user's back.
extension SimklLibraryService {

    /// Saves a status, score and — for a show — episode changes, updating the saved copy first so
    /// the list and the page show it at once. Returns whether Simkl has it; false means queued.
    ///
    /// - Parameter newEntry: added to the copy when the title isn't there yet — adding from search,
    ///   or ticking an episode of a show not in the library.
    @discardableResult
    func saveTitle(_ simklID: Int, kind: MediaKind, status: MediaListStatus, score: Double,
                   episodes plan: SimklEpisodePlan? = nil,
                   ifAbsent newEntry: LibraryEntry? = nil) async throws -> Bool {
        let ids = ["simkl": simklID]
        if let unmarks = plan?.unmarks, !unmarks.isEmpty {
            try await postRemoval(SimklPayloadBuilder.titleRemovalBody(kind: kind, ids: ids, seasons: unmarks))
        }

        var copy = cachedLibrary(kind) ?? []
        if let newEntry, !copy.contains(where: { $0.id == simklID }) {
            copy = SimklTitleCopy.inserting(newEntry, into: copy)
        }
        let known = copy.first { $0.id == simklID }
        store(SimklTitleCopy.updating(copy, simklID: simklID, status: status, score: score,
                                      watched: plan?.watched), kind: kind)

        let marks = plan?.marks ?? []
        enqueue(SimklWrite(
            ids: ids, status: SimklPayloadBuilder.status(for: status),
            // Always beside the status: rating an unrated title makes Simkl move it by itself.
            rating: SimklPayloadBuilder.rating(from: score, format: .point10),
            episodes: nil, title: known?.media.title.displayTitle, year: known?.media.seasonYear,
            kind: kind, seasons: marks.isEmpty ? nil : marks))
        return await flush() == 0
    }

    /// The title out of the user's Simkl library entirely — history, list entry and rating.
    func removeTitle(_ simklID: Int, kind: MediaKind) async throws {
        try await postRemoval(SimklPayloadBuilder.titleRemovalBody(kind: kind, ids: ["simkl": simklID], seasons: nil))
        store(SimklTitleCopy.removing(simklID, from: cachedLibrary(kind) ?? []), kind: kind)
    }
}
