import SwiftUI

/// An anime from a Simkl search. Search results carry only Simkl's own id, so the page first
/// finds the anime's AniList or MyAnimeList id in Simkl's free record, then becomes the app's
/// anime page — or the Simkl page, when the anime isn't on the user's tracker.
struct SimklAnimeOpener: View {
    /// The search card: Simkl id, title and poster.
    let seed: Media

    @State private var target: Media?
    @State private var failure: String?
    /// Not on the user's tracker: opened as a Simkl title.
    @State private var simklOnly = false

    var body: some View {
        Group {
            if let target {
                AniListDetailView(mediaId: target.id, preloadedMedia: target)
            } else if simklOnly {
                SimklTitlePage(simklID: seed.id, kind: .anime, seedTitle: seed.title.displayTitle,
                               seedPosterURL: seed.coverImage.large)
            } else if let failure {
                ContentUnavailableView("Can't Open", systemImage: "questionmark.circle", description: Text(failure))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if target == nil && failure == nil && !simklOnly { await resolve() }
        }
    }

    private func resolve() async {
        let tracker = SimklDiscoverMedia.tracker
        do {
            guard let ids = try await SimklCatalog.animeIDs(simklID: seed.id) else {
                failure = "Simkl no longer lists this anime."
                return
            }
            var mapped: Int?
            if tracker == .anilist, ids.anilist == nil, let mal = ids.mal {
                mapped = await TVDBMappingService.shared.anilistId(forMalId: mal)
            }
            guard let found = SimklSearch.animeTarget(ids, tracker: tracker, anilistForMAL: mapped) else {
                // Not on the tracker: opened as a Simkl title instead.
                simklOnly = true
                return
            }
            target = Media(
                id: found.id, idMal: ids.mal, provider: found.provider, title: seed.title,
                coverImage: seed.coverImage, bannerImage: nil, description: nil, episodes: nil, status: nil,
                averageScore: nil, genres: nil, season: nil, seasonYear: seed.seasonYear,
                nextAiringEpisode: nil, relations: nil, type: "ANIME", format: nil)
        } catch {
            failure = error.localizedDescription
        }
    }
}
