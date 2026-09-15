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
        case (.simkl, .update):
            // Manga never reaches Simkl — it has none.
            guard w.mediaType != .manga else { break }
            SimklLibraryService.shared.rawUpdateEntry(
                malId: w.mediaId, anilistId: w.entryId, status: w.status ?? .current,
                progress: w.progress ?? 0, previousProgress: nil,
                score: w.score ?? 0, format: .point10)
            await SimklLibraryService.shared.flush()
        case (.simkl, .delete):
            guard w.mediaType != .manga else { break }
            var ids: [String: Int] = [:]
            if let mal = w.mediaId { ids["mal"] = mal }
            if let anilist = w.entryId { ids["anilist"] = anilist }
            guard !ids.isEmpty else { break }
            try await SimklLibraryService.shared.rawDeleteEntry(ids: ids)
        case (.local, _):
            break   // local source is never queued
        }
    }
}
