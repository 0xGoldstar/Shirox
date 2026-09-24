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

    /// What this source lists. Simkl's library here is anime only.
    var mediaKinds: [MediaKind] {
        self == .simkl ? [.anime] : [.anime, .manga]
    }

    /// The status lists this source can hold, in the user's order. A free Simkl account cannot
    /// record a rewatch, so Simkl has no Rewatching list.
    func statuses(in order: [MediaListStatus]) -> [MediaListStatus] {
        self == .simkl ? order.filter { $0 != .repeating } : order
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
    private var service: SimklLibraryService { .shared }

    /// The cached copy; only an account never read before is fetched.
    func fetchLibrary() async throws -> [LibraryEntry] {
        try await service.displayLibrary()
    }

    /// Pull to refresh: the one activity check, whose failure the Library shows.
    func checkForChanges() async throws -> [LibraryEntry] {
        try await service.checkNow()
    }

    func updateEntry(media: Media, status: MediaListStatus, progress: Int, score: Double) async throws {
        try Self.requireWriteAccess()
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
        #if os(iOS)
        ToastManager.shared.show(
            message: "Simkl couldn't be reached — your change is saved and will be sent later.",
            type: .warning)
        #endif
    }

    /// The edit sheet's Remove: the whole entry, never an episode un-mark.
    func deleteEntry(_ entry: LibraryEntry) async throws {
        try Self.requireWriteAccess()
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
        #if os(iOS)
        ToastManager.shared.show(message: SimklError.readOnly.localizedDescription, type: .error)
        #endif
        throw SimklError.readOnly
    }
}
