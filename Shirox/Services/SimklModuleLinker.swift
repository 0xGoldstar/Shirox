import Foundation

/// Links a module page to a Simkl show or movie by its title — searching once per page, ever.
///
/// Only an exact title links (`SimklModuleMatch`). A page with a confident AniList match is an
/// anime, tracked as one, and isn't searched; a guessed AniList match — AniList's top result for a
/// title that matched nothing — doesn't count, or almost no TV page would be.
@MainActor
enum SimklModuleLinker {
    struct Page: Equatable {
        let key: String
        let title: String
        let aliases: String
        let airdate: String
        let episodeCount: Int
        let hasConfidentAniListMatch: Bool
    }

    typealias Search = @MainActor (String, MediaKind) async throws -> [SimklCatalogItem]
    typealias Episodes = @MainActor (Int) async throws -> [SimklEpisode]

    /// Pages being matched now, so a page reopened mid-search isn't searched twice.
    private static var running: Set<String> = []

    static var trackingOn: Bool {
        UserDefaults.standard.object(forKey: "simklTrackingEnabled") as? Bool ?? true
    }

    static func shouldSearch(_ page: Page, links: TrackingLinks?, signedIn: Bool, trackingOn: Bool) -> Bool {
        signedIn && trackingOn && !page.hasConfidentAniListMatch
            && links?.simklTitle == nil && links?.simklSearched != true
    }

    /// Searches once and saves what it finds: a link, or that nothing matched. A search that
    /// doesn't reach Simkl saves nothing, so the page is tried next time.
    @discardableResult
    static func matchIfNeeded(
        _ page: Page, store: TrackingLinkStore? = nil, signedIn: Bool? = nil, trackingOn: Bool? = nil,
        search: @escaping Search = { try await SimklCatalog.search($0, kind: $1) },
        episodes: @escaping Episodes = { try await SimklCatalog.loadEpisodes(simklID: $0) }
    ) async -> SimklTitleLink? {
        // Defaults are read here: a default argument can't reach the main actor's state.
        let store = store ?? .shared
        let signedIn = signedIn ?? SimklAuthManager.shared.isLoggedIn
        let trackingOn = trackingOn ?? Self.trackingOn
        guard shouldSearch(page, links: store.links(for: page.key), signedIn: signedIn, trackingOn: trackingOn),
              running.insert(page.key).inserted else { return nil }
        defer { running.remove(page.key) }

        let kind = SimklModuleMatch.searchKind(episodeCount: page.episodeCount)
        let results: [SimklCatalogItem]
        do {
            results = try await search(page.title, kind)
        } catch {
            Logger.shared.log("[Simkl] Couldn't search for \(page.title): \(error)", type: "Error")
            return nil
        }
        guard let found = SimklModuleMatch.match(title: page.title, aliases: page.aliases,
                                                 airdate: page.airdate, in: results),
              let simklID = found.simklID else {
            store.update(page.key) { $0.simklSearched = true }
            return nil
        }
        var season: Int?
        if kind == .tv {
            season = SimklModuleMatch.seasonGuess(title: page.title, moduleEpisodeCount: page.episodeCount,
                                                  simklEpisodes: try? await episodes(simklID))
        }
        let link = SimklTitleLink(simklID: simklID, kind: kind, season: season, automatic: true)
        store.update(page.key) {
            $0.simklTitle = link
            $0.simklSearched = true
        }
        Logger.shared.log("[Simkl] Matched \(page.title) to \(found.title ?? "#\(simklID)")", type: "Provider")
        return link
    }
}
