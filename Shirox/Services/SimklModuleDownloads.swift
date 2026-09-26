import Foundation

/// Readies a linked module page's downloads to be marked on Simkl offline: the page's episode list
/// remembered, so a downloaded episode's place is known, and Simkl's episode list saved on the
/// device, so its Simkl episode is too. Both are free — the module's site, and Simkl's cache.
@MainActor
enum SimklModuleDownloads {
    typealias LoadEpisodes = @MainActor (Int) async throws -> [SimklEpisode]

    static func prepare(
        moduleId: String?, detailHref: String?, episodeHrefs: [String], pageEpisodes: [String]? = nil,
        pages: SimklModulePages? = nil,
        links: @MainActor (String) -> TrackingLinks? = { TrackingLinkStore.shared.links(for: $0) },
        fetch: SimklModuleTracker.FetchPage = { try await SimklModuleTracker.fetchPage(moduleId: $0, detailHref: $1) },
        loadEpisodes: LoadEpisodes = { try await SimklCatalog.loadEpisodes(simklID: $0) }
    ) async {
        let pages = pages ?? .shared
        guard let moduleId, let detailHref,
              let key = TrackingLinkStore.moduleKey(moduleId: moduleId, detailHref: detailHref),
              let link = links(key)?.simklTitle else { return }
        if let pageEpisodes, !pageEpisodes.isEmpty {
            pages.remember(pageEpisodes, for: key)
        } else if episodeHrefs.contains(where: { pages.position(of: $0, in: key) == nil }),
                  let fetched = try? await fetch(moduleId, detailHref), !fetched.isEmpty {
            pages.remember(fetched, for: key)
        }
        // Loading saves the list on the device, which is what marking offline reads.
        if link.kind != .movie { _ = try? await loadEpisodes(link.simklID) }
    }
}
