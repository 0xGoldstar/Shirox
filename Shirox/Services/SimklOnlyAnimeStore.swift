import Foundation

/// Anime on the user's Simkl list without the id the app's anime page needs, as Simkl titles.
///
/// Kept apart from the synced anime copy: sync pairs anime by their MyAnimeList or AniList id and
/// would read a Simkl id as one — copying it somewhere wrong, or deleting it. Only the Library and
/// the Simkl page read this; sync runs never do.
@MainActor
final class SimklOnlyAnimeStore {
    static let shared = SimklOnlyAnimeStore()

    private let file: URL
    private(set) var entries: [LibraryEntry]

    init(file: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("simkl-only-anime.json")) {
        self.file = file
        entries = (try? JSONDecoder().decode([LibraryEntry].self, from: Data(contentsOf: file))) ?? []
    }

    func replace(_ entries: [LibraryEntry]) {
        self.entries = entries
        save()
    }

    /// A delta read's entries: updated where known, added at the end otherwise.
    func merge(_ delta: [LibraryEntry]) {
        guard !delta.isEmpty else { return }
        var result = entries
        for entry in delta {
            if let index = result.firstIndex(where: { $0.id == entry.id }) { result[index] = entry } else { result.append(entry) }
        }
        replace(result)
    }

    /// After a removals check: only the titles still on the list.
    func keep(simklIDs: Set<Int>) {
        replace(entries.filter { simklIDs.contains($0.id) })
    }

    func clear() { replace([]) }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        } catch {
            Logger.shared.log("[Simkl] Could not save the Simkl-only anime: \(error)", type: "Error")
        }
    }
}
