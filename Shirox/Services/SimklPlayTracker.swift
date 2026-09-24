import Foundation

/// Marks a movie or episode played from its Simkl page on Simkl once the player counts it watched.
@MainActor
enum SimklPlayTracker {
    struct Change: Equatable {
        let status: MediaListStatus
        let plan: SimklEpisodePlan?
    }

    /// What finishing `number` of `ref` changes — nil when there's nothing to send: the episode is
    /// already ticked, the movie already Completed, or the number isn't in the catalog.
    nonisolated static func change(for ref: SimklPlayRef, number: Int, entry: LibraryEntry?,
                                   episodes: [SimklEpisode]) -> Change? {
        if ref.kind == .movie {
            return entry?.status == .completed ? nil : Change(status: .completed, plan: nil)
        }
        guard let season = ref.season,
              let episode = SimklPlayNumbering.episode(season: season, number: number, in: episodes) else { return nil }
        let watched = SimklEpisodePlanner.watched(status: entry?.status ?? .planning,
                                                  recorded: entry?.watchedEpisodes, episodes: episodes)
        guard !watched.contains(episode) else { return nil }
        var newWatched = watched
        newWatched.insert(episode)
        return Change(
            status: SimklEpisodePlanner.statusAfterTick(current: entry?.status, marking: true),
            plan: SimklEpisodePlan(marks: [SimklSeasonMark(number: episode.season, episodes: [episode.episode])],
                                   unmarks: [], watched: newWatched))
    }

    /// Only when signed in with write access and with Track on Simkl on, as for anime.
    static func finished(_ ref: SimklPlayRef, number: Int, title: String) async {
        let enabled = UserDefaults.standard.object(forKey: "simklTrackingEnabled") as? Bool ?? true
        let auth = SimklAuthManager.shared
        guard enabled, auth.isLoggedIn, !auth.needsReauthorization else { return }

        let service = SimklLibraryService.shared
        let entry = service.cachedLibrary(ref.kind)?.first { $0.id == ref.simklID }
        let episodes = ref.kind == .tv ? ((try? await SimklCatalog.loadEpisodes(simklID: ref.simklID)) ?? []) : []
        guard let change = change(for: ref, number: number, entry: entry, episodes: episodes) else {
            Logger.shared.log("[Simkl] Nothing to mark for \(title) #\(number)", type: "Provider")
            return
        }

        let details = SimklCatalogCache.shared.details(ref.kind, simklID: ref.simklID)
        let newEntry = SimklTitleCopy.entry(simklID: ref.simklID, kind: ref.kind, title: details?.title ?? title,
                                            posterURL: details?.posterURL, year: details?.year,
                                            runtime: details?.runtime, totalEpisodes: details?.totalEpisodes,
                                            status: change.status)
        do {
            let delivered = try await service.saveTitle(ref.simklID, kind: ref.kind, status: change.status,
                                                        score: entry?.score ?? 0, episodes: change.plan,
                                                        ifAbsent: newEntry)
            Logger.shared.log("[Simkl] Marked \(title) #\(number) watched\(delivered ? "" : " (queued)")", type: "Provider")
        } catch {
            Logger.shared.log("[Simkl] Marking \(title) #\(number) failed: \(error)", type: "Error")
        }
    }
}
