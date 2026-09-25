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
}
