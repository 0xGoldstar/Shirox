import SwiftUI

/// Where a title opens: a Simkl show or movie on its Simkl page, anything else on the anime page.
struct MediaDestination: View {
    let media: Media

    enum Target: Equatable {
        case simklTitle(simklID: Int, kind: MediaKind)
        case anime(id: Int)
    }

    static func target(for media: Media) -> Target {
        if let kind = media.simklTitleKind { return .simklTitle(simklID: media.id, kind: kind) }
        return .anime(id: media.id)
    }

    var body: some View {
        switch Self.target(for: media) {
        case .simklTitle(let simklID, let kind):
            SimklTitlePage(simklID: simklID, kind: kind, seedTitle: media.title.displayTitle,
                           seedPosterURL: media.coverImage.large)
        case .anime:
            AniListDetailView(mediaId: media.id, preloadedMedia: media)
        }
    }
}
