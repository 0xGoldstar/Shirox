import SwiftUI

/// Which page a Simkl library row opens.
///
/// The show page loads from the app's primary provider (`AniListDetailView` →
/// `ProviderManager.call`), so it must be given that provider's id. A Simkl entry's own id is a
/// MyAnimeList number where Simkl had one; handed to an AniList page as-is, it opens a different
/// show.
enum SimklLibraryDestination {
    /// The entry's media rebuilt for `primary`, or nil when that provider's id is not known.
    static func media(for media: Media, primary: ProviderType, ids: TrackingIDs) -> Media? {
        let id: Int?
        switch primary {
        case .anilist:       id = ids.anilist
        case .mal:           id = ids.mal
        case .simkl, .local: id = nil
        }
        guard let id else { return nil }
        return Media(
            id: id, idMal: ids.mal, provider: primary,
            title: media.title, coverImage: media.coverImage,
            bannerImage: nil, description: nil, episodes: media.episodes,
            status: nil, averageScore: nil, genres: nil,
            season: nil, seasonYear: media.seasonYear, nextAiringEpisode: nil,
            relations: nil, type: nil, format: media.format)
    }
}

/// A Simkl library row's page: the show on the app's primary provider, once its id there is known.
struct SimklLibraryEntryPage: View {
    let entry: LibraryEntry

    @State private var target: Media?
    @State private var resolved = false

    private var primary: ProviderType { ProviderManager.shared.primary?.providerType ?? .anilist }

    var body: some View {
        Group {
            if let target {
                AniListDetailView(mediaId: target.id, preloadedMedia: target)
            } else if resolved {
                ContentUnavailableView(
                    "Not Found",
                    systemImage: "questionmark.circle",
                    description: Text("\(entry.media.title.displayTitle) couldn't be matched to a show on \(primary.displayName)."))
            } else {
                ProgressView()
            }
        }
        .task {
            guard !resolved else { return }
            // The user's tracking links first, then the ID mapping — the same ids every write uses.
            let own = SimklLibraryService.pairingIDs(of: entry.media)
            let ids = await TrackingLinkResolver.resolve(aniListID: own.anilist, malID: own.mal, moduleKey: nil)
            target = SimklLibraryDestination.media(for: entry.media, primary: primary, ids: ids)
            resolved = true
        }
    }
}
