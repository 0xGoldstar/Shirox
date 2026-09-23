import Foundation

/// Which entry a show is on each tracking service, as the user set it. nil means automatic.
struct TrackingLinks: Codable, Equatable {
    var anilist: Int?
    var mal: Int?
    var simkl: Int?

    init(anilist: Int? = nil, mal: Int? = nil, simkl: Int? = nil) {
        self.anilist = anilist
        self.mal = mal
        self.simkl = simkl
    }

    var isEmpty: Bool { anilist == nil && mal == nil && simkl == nil }
}

/// The ids a write for a show should use, once the user's links are applied.
struct TrackingIDs: Equatable {
    let anilist: Int?
    let mal: Int?
    let simkl: Int?
}

/// The user's per-show tracking links.
///
/// Keyed by what a page already knows a show as: `anilist:<id>`, `mal:<id>`, or — for a module
/// page — `module:<moduleId>|<detailHref>`. Not by title: module flows carry three different
/// titles (the search result's, the detail page's and Continue Watching's), so a title key would
/// be missed from the player. `moduleId` and `detailHref` travel with every tracking context.
@MainActor
final class TrackingLinkStore {
    static let shared = TrackingLinkStore()
    static let storageKey = "com.shirox.tracking_links"

    private let defaults: UserDefaults
    private(set) var all: [String: TrackingLinks]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: TrackingLinks].self, from: data) {
            all = decoded
        } else {
            all = [:]
        }
    }

    nonisolated static func key(anilist id: Int) -> String { "anilist:\(id)" }
    nonisolated static func key(mal id: Int) -> String { "mal:\(id)" }

    /// nil unless both halves are present — without both, a module page has no stable identity.
    nonisolated static func moduleKey(moduleId: String?, detailHref: String?) -> String? {
        guard let moduleId, !moduleId.isEmpty, let detailHref, !detailHref.isEmpty else { return nil }
        return "module:\(moduleId)|\(detailHref)"
    }

    func links(for key: String) -> TrackingLinks? { all[key] }

    /// Replaces the record for `key`. An empty record removes it.
    func set(_ links: TrackingLinks, for key: String) {
        if links.isEmpty { all.removeValue(forKey: key) } else { all[key] = links }
        persist()
    }

    func update(_ key: String, _ change: (inout TrackingLinks) -> Void) {
        var links = all[key] ?? TrackingLinks()
        change(&links)
        set(links, for: key)
    }

    /// Wholesale replacement, for restoring a backup.
    func replaceAll(_ links: [String: TrackingLinks]) {
        all = links.filter { !$0.value.isEmpty }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

/// Applies the user's links to the ids a write starts from.
enum TrackingLinkResolver {

    /// Field by field, first link wins. A show opened from both its AniList and its MAL page has a
    /// record under each key; merging means neither page's record can hide the other's.
    static func merged(_ records: [TrackingLinks?]) -> TrackingLinks {
        var result = TrackingLinks()
        for case let record? in records {
            result.anilist = result.anilist ?? record.anilist
            result.mal = result.mal ?? record.mal
            result.simkl = result.simkl ?? record.simkl
        }
        return result
    }

    /// Whether a module page's links still describe the entry an episode is going to.
    ///
    /// `SeasonChainMapper` re-targets a module's absolute episode to the right season's entry.
    /// A module link was set for the anchor season; applying it to another season would write
    /// that season's episodes onto the wrong entry.
    static func moduleLinksApply(anchorAniListID: Int?, anchorMALID: Int?,
                                 mappedAniListID: Int?, mappedMALID: Int?) -> Bool {
        if let mapped = mappedAniListID, let anchor = anchorAniListID, mapped != anchor { return false }
        if let mapped = mappedMALID, let anchor = anchorMALID, mapped != anchor { return false }
        return true
    }

    /// Your link first, otherwise the automatic id — per service.
    static func resolve(aniListID: Int?, malID: Int?, moduleKey: String?,
                        links: (String) -> TrackingLinks?,
                        anilistForMAL: (Int) async -> Int?,
                        malForAniList: (Int) async -> Int?) async -> TrackingIDs {
        let record = merged([
            aniListID.flatMap { links(TrackingLinkStore.key(anilist: $0)) },
            malID.flatMap { links(TrackingLinkStore.key(mal: $0)) },
            moduleKey.flatMap { links($0) },
        ])

        var anilist = record.anilist ?? aniListID
        if anilist == nil, let mal = record.mal ?? malID {
            anilist = await anilistForMAL(mal)
        }
        var mal = record.mal ?? malID
        if mal == nil, let anilist {
            mal = await malForAniList(anilist)
        }
        return TrackingIDs(anilist: anilist, mal: mal, simkl: record.simkl)
    }

    /// The production resolver: the shared store and `IDMappingService`.
    @MainActor
    static func resolve(aniListID: Int?, malID: Int?, moduleKey: String?) async -> TrackingIDs {
        let store = TrackingLinkStore.shared
        return await resolve(
            aniListID: aniListID, malID: malID, moduleKey: moduleKey,
            links: { store.links(for: $0) },
            anilistForMAL: { await IDMappingService.shared.anilistId(forMALId: $0) },
            malForAniList: { await IDMappingService.shared.malId(forAnilistId: $0) })
    }
}
