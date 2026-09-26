import Foundation

/// The episode list of each module page linked to a Simkl show or movie, remembered so a finished
/// episode's place on its page is known. Its Simkl episode is found by that place, not by the
/// number the module prints, which may run 25, 26… or restart each season.
@MainActor
final class SimklModulePages {
    static let shared = SimklModulePages()

    private let file: URL
    private var pages: [String: [String]]

    init(file: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("simkl-module-pages.json")) {
        self.file = file
        pages = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: file))) ?? [:]
    }

    /// A page's episode addresses, in the page's order.
    func remember(_ hrefs: [String], for key: String) {
        guard pages[key] != hrefs else { return }
        pages[key] = hrefs
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pages).write(to: file, options: .atomic)
        } catch {
            Logger.shared.log("[Simkl] Could not save a page's episodes: \(error)", type: "Error")
        }
    }

    /// An episode's place on its page, from 1.
    func position(of href: String?, in key: String) -> Int? {
        guard let href, let index = pages[key]?.firstIndex(of: href) else { return nil }
        return index + 1
    }
}

/// Which Simkl play a finished module episode is, when its page is linked to a Simkl show or movie.
@MainActor
enum SimklModuleTracker {
    struct Play: Equatable {
        let ref: SimklPlayRef
        /// Counted from the start of `ref.season`, as `SimklPlayTracker` takes it.
        let number: Int
    }

    enum Outcome: Equatable {
        /// Tracked as before — AniList, MyAnimeList, and Simkl for anime.
        case notLinked
        /// Marked on Simkl alone; nil when the episode's place on the page isn't known.
        case linked(Play?)
    }

    /// Place `position` on a page linked to `link`: season S is S E`position`; every season is the
    /// `position`-th regular episode, counted from season 1; a movie is the movie.
    nonisolated static func play(for link: SimklTitleLink, position: Int) -> Play {
        if link.kind == .movie {
            return Play(ref: SimklPlayRef(simklID: link.simklID, kind: .movie, season: nil), number: 1)
        }
        return Play(ref: SimklPlayRef(simklID: link.simklID, kind: .tv, season: link.season ?? 1), number: position)
    }

    static func outcome(
        moduleId: String?, detailHref: String?, episodeHref: String?,
        links: @MainActor (String) -> TrackingLinks? = { TrackingLinkStore.shared.links(for: $0) },
        position: @MainActor (String?, String) -> Int? = { SimklModulePages.shared.position(of: $0, in: $1) }
    ) -> Outcome {
        guard let key = TrackingLinkStore.moduleKey(moduleId: moduleId, detailHref: detailHref),
              let link = links(key)?.simklTitle else { return .notLinked }
        if link.kind == .movie { return .linked(play(for: link, position: 1)) }
        return .linked(position(episodeHref, key).map { play(for: link, position: $0) })
    }

    typealias FetchPage = @MainActor (_ moduleId: String, _ detailHref: String) async throws -> [String]

    /// A page's episode addresses, fetched through its module — the module's site, not Simkl, so
    /// it costs no allowance.
    static func fetchPage(moduleId: String, detailHref: String) async throws -> [String] {
        guard let module = ModuleManager.shared.modules.first(where: { $0.id == moduleId }) else {
            throw ProviderError.notFound
        }
        let runner = ModuleJSRunner()
        try await runner.load(module: module)
        return try await runner.fetchEpisodes(url: detailHref).map(\.href)
    }

    /// For a finished episode its page's remembered list doesn't hold — one added since, or a list
    /// never remembered: fetches the page's list, remembers it, and gives the play. Nil when the
    /// page isn't linked, can't be fetched, or still doesn't hold the episode.
    static func placeByFetching(
        moduleId: String?, detailHref: String?, episodeHref: String?,
        pages: SimklModulePages? = nil,
        links: @MainActor (String) -> TrackingLinks? = { TrackingLinkStore.shared.links(for: $0) },
        fetch: FetchPage = { try await SimklModuleTracker.fetchPage(moduleId: $0, detailHref: $1) }
    ) async -> Play? {
        // Read here: a default argument can't reach the main actor's state.
        let pages = pages ?? .shared
        guard let moduleId, let detailHref,
              let key = TrackingLinkStore.moduleKey(moduleId: moduleId, detailHref: detailHref),
              links(key)?.simklTitle != nil else { return nil }
        do {
            let hrefs = try await fetch(moduleId, detailHref)
            guard !hrefs.isEmpty else { return nil }
            pages.remember(hrefs, for: key)
        } catch {
            Logger.shared.log("[Simkl] Couldn't fetch the page's episodes to place one: \(error)", type: "Error")
            return nil
        }
        if case .linked(let play?) = outcome(moduleId: moduleId, detailHref: detailHref, episodeHref: episodeHref,
                                            links: links, position: { pages.position(of: $0, in: $1) }) {
            return play
        }
        return nil
    }
}
