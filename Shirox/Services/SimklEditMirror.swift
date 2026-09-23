import Foundation

/// Writes an edit made on AniList or MyAnimeList through to Simkl, when `SyncTargets` says
/// edits on that service are mirrored there.
@MainActor
enum SimklEditMirror {
    static func edit(malId: Int?, anilistId: Int?, simklId: Int? = nil, editedOn side: LibrarySide,
                     status: MediaListStatus, progress: Int, score: Double,
                     format: ScoreFormat, title: String?) async {
        guard shouldMirror(from: side) else { return }
        let mal = await resolvedMALId(malId: malId, anilistId: anilistId)
        await SimklLibraryService.shared.writeNow(
            malId: mal, anilistId: anilistId, simklId: simklId, status: status, progress: progress,
            score: score, format: format, title: title)
    }

    /// The edit sheet's Delete removes the title, so this is whole-entry removal — never the
    /// narrower episode un-mark.
    static func delete(malId: Int?, anilistId: Int?, simklId: Int? = nil, editedOn side: LibrarySide) async {
        guard shouldMirror(from: side) else { return }
        let mal = await resolvedMALId(malId: malId, anilistId: anilistId)
        let ids = SimklLibraryService.writeIDs(malId: mal, anilistId: anilistId, simklId: simklId)
        guard !ids.isEmpty else { return }
        do {
            try await SimklLibraryService.shared.rawDeleteEntry(ids: ids)
            SimklLibraryService.shared.noteDeleted(malId: mal, anilistId: anilistId, simklId: simklId)
        } catch {
            Logger.shared.log("[Simkl] Mirroring a delete failed: \(error)", type: "Error")
        }
    }

    private static func shouldMirror(from side: LibrarySide) -> Bool {
        SyncTargets.mirrorTargets(for: side, in: SyncTargets.load(),
                                  signedIn: LibrarySyncService.shared.signedInSides).contains(.simkl)
    }

    /// Simkl's cache keys by MyAnimeList id where there is one, so an AniList-only edit resolves
    /// it first — the same lookup the MyAnimeList tracking path does.
    private static func resolvedMALId(malId: Int?, anilistId: Int?) async -> Int? {
        if let malId { return malId }
        guard let anilistId else { return nil }
        return await IDMappingService.shared.malId(forAnilistId: anilistId)
    }
}
