import Foundation

/// Which backing store the Library tab is currently showing.
enum LibrarySource: Hashable {
    case provider(ProviderType)
    case local
    /// The user's Simkl list. Its own case rather than `.provider(.simkl)`: selecting a provider
    /// makes it the app's primary provider, and Simkl is a tracker that must never become one.
    case simkl
}

extension LibrarySource {
    /// The provider choosing this source makes primary — none for My Library or Simkl.
    var providerToSelect: ProviderType? {
        if case .provider(let type) = self { return type }
        return nil
    }

    /// What this source lists. The Simkl list has anime, TV and movies.
    var mediaKinds: [MediaKind] {
        self == .simkl ? MediaKind.simklKinds : [.anime, .manga]
    }

    /// The status lists this source can hold for `kind`, in the user's order. On Simkl a free
    /// account records no rewatch, and movies have no Watching or On Hold.
    func statuses(in order: [MediaListStatus], for kind: MediaKind = .anime) -> [MediaListStatus] {
        guard self == .simkl else { return order }
        let allowed: Set<MediaListStatus> = kind == .movie
            ? [.planning, .completed, .dropped]
            : Set(MediaListStatus.allCases).subtracting([.repeating])
        return order.filter { allowed.contains($0) }
    }

    /// The list a kind opens on: Plan to Watch for movies, which have no Watching.
    static func defaultStatus(for kind: MediaKind) -> MediaListStatus {
        kind == .movie ? .planning : .current
    }

    /// Where the Library goes when the list on screen signs out: the primary provider if it is
    /// still signed in, then any signed-in provider, then Simkl, then My Library.
    static func afterSignOut(primary: ProviderType?, signedIn: Set<ProviderType>) -> LibrarySource {
        if let primary, ProviderType.userProviders.contains(primary), signedIn.contains(primary) {
            return .provider(primary)
        }
        if let type = ProviderType.userProviders.first(where: { signedIn.contains($0) }) {
            return .provider(type)
        }
        return signedIn.contains(.simkl) ? .simkl : .local
    }
}

/// The four library operations the Library tab needs, decoupled from where the data lives.
@MainActor protocol LibraryDataSource {
    func fetchLibrary() async throws -> [LibraryEntry]
    func updateEntry(media: Media, status: MediaListStatus, progress: Int, score: Double) async throws
    func deleteEntry(_ entry: LibraryEntry) async throws
}

/// Routes through `ProviderManager` (AniList / MAL, with its fallback logic).
@MainActor struct RemoteLibraryDataSource: LibraryDataSource {
    func fetchLibrary() async throws -> [LibraryEntry] {
        try await ProviderManager.shared.call { try await $0.fetchLibrary() }
    }
    func updateEntry(media: Media, status: MediaListStatus, progress: Int, score: Double) async throws {
        try await ProviderManager.shared.call {
            try await $0.updateEntry(mediaId: media.id, status: status, progress: progress, score: score)
        }
    }
    func deleteEntry(_ entry: LibraryEntry) async throws {
        try await ProviderManager.shared.call { try await $0.deleteEntry(entryId: entry.id) }
    }
}

/// Reads/writes the on-device `LocalLibraryManager`. Update is an upsert; never throws.
@MainActor struct LocalLibraryDataSource: LibraryDataSource {
    func fetchLibrary() async throws -> [LibraryEntry] {
        LocalLibraryManager.shared.entries
    }
    func updateEntry(media: Media, status: MediaListStatus, progress: Int, score: Double) async throws {
        LocalLibraryManager.shared.upsert(media: media, status: status, progress: progress, score: score)
    }
    func deleteEntry(_ entry: LibraryEntry) async throws {
        LocalLibraryManager.shared.remove(uniqueId: entry.media.uniqueId)
    }
}

/// The user's Simkl list, through `SimklLibraryService` — its cache, its activity-gated reads and
/// its durable write queue.
@MainActor struct SimklLibraryDataSource: LibraryDataSource {
    /// Which of the Simkl list's three kinds.
    var kind: MediaKind = .anime

    private var service: SimklLibraryService { .shared }

    /// The copy; only a kind never checked is read.
    func fetchLibrary() async throws -> [LibraryEntry] {
        try await service.displayLibrary(kind)
    }

    /// Pull to refresh: the one activity check, whose failure the Library shows.
    func checkForChanges() async throws -> [LibraryEntry] {
        try await service.checkNow(kind)
    }

    func updateEntry(media: Media, status: MediaListStatus, progress: Int, score: Double) async throws {
        try Self.requireWriteAccess()
        // A show's episodes are edited in `SimklTitleEditSheet`; this path carries status and score —
        // a movie's swipe to Watched.
        if kind != .anime {
            let delivered = try await service.saveTitle(media.id, kind: kind, status: status, score: score)
            try Self.requireWriteAccess()
            if !delivered { SimklNotice.queued() }
            return
        }
        let ids = SimklLibraryService.pairingIDs(of: media)
        let simklId = service.cachedEntry(malId: ids.mal, anilistId: ids.anilist)
            .flatMap(SimklLibraryService.simklID(of:))
        let delivered = await service.writeNow(
            malId: ids.mal, anilistId: ids.anilist, simklId: simklId, status: status,
            progress: progress, score: score, format: .point10, title: media.title.displayTitle)
        // A token without write access is found out by the write itself.
        try Self.requireWriteAccess()
        guard !delivered else { return }
        // The queue is durable and sends in order, so the cached list can show the edit now —
        // otherwise a reload before the next flush would put the old values back on screen.
        service.noteWritten(malId: ids.mal, anilistId: ids.anilist, simklId: simklId,
                            status: status, progress: progress)
        SimklNotice.queued()
    }

    /// The edit sheet's Remove: the whole entry, never an episode un-mark.
    func deleteEntry(_ entry: LibraryEntry) async throws {
        try Self.requireWriteAccess()
        if kind != .anime {
            do {
                try await service.removeTitle(entry.id, kind: kind)
            } catch {
                try Self.requireWriteAccess()
                throw error
            }
            return
        }
        let ids = SimklLibraryService.pairingIDs(of: entry.media)
        let simklId = SimklLibraryService.simklID(of: entry)
        do {
            try await service.rawDeleteEntry(
                ids: SimklLibraryService.writeIDs(malId: ids.mal, anilistId: ids.anilist, simklId: simklId))
        } catch {
            try Self.requireWriteAccess()
            throw error
        }
        service.noteDeleted(malId: ids.mal, anilistId: ids.anilist, simklId: simklId)
    }

    /// A sign-in that can't write fails every edit the same way, so it says how to fix it.
    private static func requireWriteAccess() throws {
        guard SimklAuthManager.shared.needsReauthorization else { return }
        SimklNotice.failed(SimklError.readOnly)
        throw SimklError.readOnly
    }
}

/// Short notices about Simkl writes. Toasts exist on iOS only; elsewhere the change simply shows
/// in the list.
enum SimklNotice {
    @MainActor static func queued() {
        info("Simkl couldn't be reached — your change is saved and will be sent later.", warning: true)
    }

    @MainActor static func failed(_ error: Error) {
        info(error.localizedDescription, warning: false)
    }

    @MainActor static func info(_ message: String, warning: Bool = true) {
        #if os(iOS)
        ToastManager.shared.show(message: message, type: warning ? .warning : .error)
        #endif
    }
}
