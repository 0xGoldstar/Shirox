import Foundation

/// Writes an edit made in the Simkl library through to AniList and MyAnimeList, when
/// `SyncTargets` mirrors Simkl edits there — the other direction of `SimklEditMirror`.
///
/// Each side is read before it is written, and a side that can't be read is skipped. Simkl can't
/// say "rewatching", and its "unrated" says nothing about the other side's score, so writing
/// either through blindly would demote a rewatch to Watching or clear a score the user set.
@MainActor
enum SimklLibraryMirror {
    /// Where a Simkl-library edit is also written.
    static func targets(in sides: Set<LibrarySide>, signedIn: [LibrarySide]) -> [LibrarySide] {
        SyncTargets.mirrorTargets(for: .simkl, in: sides, signedIn: signedIn)
    }

    /// Simkl's Watching is also what a rewatch looks like there, so it never replaces Rewatching.
    nonisolated static func mirroredStatus(_ status: MediaListStatus,
                                           over existing: MediaListStatus?) -> MediaListStatus {
        status == .current && existing == .repeating ? .repeating : status
    }

    /// A Simkl score in `format`, or nil for unrated — which leaves the other side's score alone.
    nonisolated static func mirroredScore(_ score: Double, in format: ScoreFormat) -> Double? {
        guard score > 0 else { return nil }
        return format.fromCanonical(ScoreFormat.point10.toCanonical(score))
    }

    static func edit(_ entry: LibraryEntry, status: MediaListStatus, progress: Int, score: Double) async {
        let targets = targets(in: SyncTargets.load(), signedIn: LibrarySyncService.shared.signedInSides)
        guard !targets.isEmpty else { return }
        let ids = await linkedIDs(of: entry)
        for side in targets {
            do {
                switch side {
                case .anilist:
                    guard let id = ids.anilist else { continue }
                    let current = try await AniListProvider.shared.fetchEntry(mediaId: id)
                    try await AniListLibraryService.shared.updateEntry(
                        mediaId: id, status: mirroredStatus(status, over: current?.status),
                        progress: progress,
                        score: mirroredScore(score, in: AniListAuthManager.shared.scoreFormat))
                case .mal:
                    guard let id = ids.mal else { continue }
                    let current = try await MALProvider.shared.fetchEntry(mediaId: id)
                    // MyAnimeList's write always carries a score, so an unrated edit re-sends the
                    // one it already has.
                    try await MALProvider.shared.updateEntry(
                        mediaId: id, status: mirroredStatus(status, over: current?.status),
                        progress: progress,
                        score: mirroredScore(score, in: .point10) ?? current?.score ?? 0)
                case .simkl:
                    continue
                }
            } catch {
                Logger.shared.log("[Simkl] Mirroring an edit to \(side.name) failed: \(error)", type: "Error")
            }
        }
    }

    /// The edit sheet's Remove, on each mirrored side.
    static func delete(_ entry: LibraryEntry) async {
        let targets = targets(in: SyncTargets.load(), signedIn: LibrarySyncService.shared.signedInSides)
        guard !targets.isEmpty else { return }
        let ids = await linkedIDs(of: entry)
        for side in targets {
            do {
                switch side {
                case .anilist:
                    guard let id = ids.anilist,
                          let current = try await AniListProvider.shared.fetchEntry(mediaId: id) else { continue }
                    try await AniListProvider.shared.deleteEntry(entryId: current.id)
                case .mal:
                    guard let id = ids.mal else { continue }
                    try await MALProvider.shared.deleteEntry(entryId: id)
                case .simkl:
                    continue
                }
            } catch {
                Logger.shared.log("[Simkl] Mirroring a removal to \(side.name) failed: \(error)", type: "Error")
            }
        }
    }

    /// The entry's AniList and MyAnimeList ids, with the user's tracking links applied.
    private static func linkedIDs(of entry: LibraryEntry) async -> TrackingIDs {
        let own = SimklLibraryService.pairingIDs(of: entry.media)
        return await TrackingLinkResolver.resolve(aniListID: own.anilist, malID: own.mal, moduleKey: nil)
    }
}
