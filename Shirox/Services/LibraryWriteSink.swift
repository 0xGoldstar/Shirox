import Foundation

/// Replays a queued `PendingWrite` against the correct service's raw (non-queueing) method.
@MainActor
struct LibraryWriteSink: PendingWriteSink {
    func perform(_ w: PendingWrite) async throws {
        switch (w.provider, w.kind) {
        case (.anilist, .update):
            try await AniListLibraryService.shared.rawUpdateEntry(
                mediaId: w.mediaId ?? 0, status: w.status ?? .current, progress: w.progress ?? 0,
                score: w.score, repeat: w.repeatCount, type: w.mediaType == .manga ? .manga : .anime)
        case (.anilist, .delete):
            try await AniListLibraryService.shared.rawDeleteEntry(entryId: w.entryId ?? 0)
        case (.mal, .update):
            if w.mediaType == .manga {
                try await MALMangaLibraryService.shared.rawUpdateEntry(
                    malId: w.mediaId ?? 0, status: w.status ?? .current, progress: w.progress ?? 0, score: w.score ?? 0)
            } else {
                try await MALLibraryService.shared.rawUpdateEntry(
                    malId: w.mediaId ?? 0, status: w.status ?? .current, progress: w.progress ?? 0,
                    score: w.score ?? 0, numTimesRewatched: w.repeatCount)
            }
        case (.mal, .delete):
            if w.mediaType == .manga {
                try await MALMangaLibraryService.shared.rawDeleteEntry(malId: w.mediaId ?? 0)
            } else {
                try await MALLibraryService.shared.rawDeleteEntry(malId: w.mediaId ?? 0)
            }
        case (.simkl, _):
            // Wired in the Simkl client plan, where it also has to batch: Simkl allows 1 POST/sec
            // and replaying a backlog one write at a time would breach that. Throwing keeps the
            // write queued for a later drain rather than silently dropping it.
            throw ProviderError.unsupported
        case (.local, _):
            break   // local source is never queued
        }
    }
}
