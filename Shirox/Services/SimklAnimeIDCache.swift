import Foundation

/// AniList and MyAnimeList ids of Simkl anime, remembered on the device.
///
/// Simkl's top-rated list sends its anime with only Simkl's own id. Each anime's free record has
/// the others, and they don't change — so each is looked up once, a few at a time, and kept.
@MainActor
final class SimklAnimeIDCache {
    static let shared = SimklAnimeIDCache()

    typealias LookUp = @MainActor @Sendable (Int) async throws -> SimklDiscoverItem.IDs?

    private struct Known: Codable {
        let mal: Int?
        let anilist: Int?
    }

    private let file: URL
    private let lookUp: LookUp
    private var known: [Int: Known]

    init(file: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("simkl-anime-ids.json"),
         lookUp: @escaping LookUp = { try await SimklCatalog.animeIDs(simklID: $0) }) {
        self.file = file
        self.lookUp = lookUp
        known = (try? JSONDecoder().decode([Int: Known].self, from: Data(contentsOf: file))) ?? [:]
    }

    /// `items`, with the AniList and MyAnimeList ids Simkl left out filled in. One whose record
    /// can't be had stays as it was, and is tried again next time.
    func fill(_ items: [SimklDiscoverItem]) async -> [SimklDiscoverItem] {
        var seen = Set<Int>()
        let missing = items
            .filter { $0.ids.mal == nil && $0.ids.anilist == nil && known[$0.ids.simkl] == nil }
            .map(\.ids.simkl)
            .filter { seen.insert($0).inserted }
        if !missing.isEmpty {
            await lookUpAll(missing)
            save()
        }
        return items.map { item in
            guard item.ids.mal == nil, item.ids.anilist == nil, let entry = known[item.ids.simkl] else { return item }
            var filled = item
            filled.ids = SimklDiscoverItem.IDs(simkl: item.ids.simkl, mal: entry.mal, anilist: entry.anilist)
            return filled
        }
    }

    /// Six at a time: the records come from Simkl's cache, but not all at once.
    private func lookUpAll(_ ids: [Int]) async {
        let lookUp = self.lookUp
        for start in stride(from: 0, to: ids.count, by: 6) {
            let batch = ids[start..<min(start + 6, ids.count)]
            await withTaskGroup(of: (Int, Result<SimklDiscoverItem.IDs?, Error>).self) { group in
                for id in batch {
                    group.addTask {
                        do { return (id, .success(try await lookUp(id))) }
                        catch { return (id, .failure(error)) }
                    }
                }
                for await (id, result) in group {
                    // A record without the other ids is remembered as such; a failed lookup isn't.
                    if case .success(let ids) = result {
                        known[id] = Known(mal: ids?.mal, anilist: ids?.anilist)
                    }
                }
            }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(known).write(to: file, options: .atomic)
        } catch {
            Logger.shared.log("[Simkl] Could not save anime ids: \(error)", type: "Error")
        }
    }
}
