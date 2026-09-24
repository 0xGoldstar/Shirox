import Foundation

/// Plays a movie or episode found through the module picker from a Simkl page — the anime page's
/// `selectStream`, with the player told what the play is on Simkl.
@MainActor
enum SimklPlayback {
    struct Request {
        let ref: SimklPlayRef
        /// The episode number, counted from the start of `ref.season`; 1 for a movie.
        let number: Int
        let mediaTitle: String
        let imageURL: String
        let thumbnailURL: String?
        let totalEpisodes: Int?
        let isAiring: Bool?
        let seasonNumbering: ModuleSeasonNumbering?
    }

    static func play(_ stream: StreamResult, streams: [StreamResult], request: Request,
                     searchResultHref: String?, episodeHref: String?, availableCount: Int?) {
        var context = PlayerContext(
            mediaTitle: request.mediaTitle, episodeNumber: request.number, episodeTitle: nil,
            imageUrl: request.imageURL, aniListID: nil, malID: nil,
            moduleId: ModuleManager.shared.activeModule?.id,
            totalEpisodes: request.totalEpisodes, availableEpisodes: availableCount, isAiring: request.isAiring,
            resumeFrom: resumePosition(for: request),
            detailHref: searchResultHref, episodeHref: episodeHref, streamTitle: stream.title,
            workingDetailHref: searchResultHref, thumbnailUrl: request.thumbnailURL)
        context.simklTitle = request.ref
        let offset = request.seasonNumbering?.offset(forListCount: availableCount ?? 0) ?? 0
        let onWatchNext = request.ref.kind == .movie
            ? nil
            : nextLoader(resultHref: searchResultHref, episodeHref: episodeHref, number: request.number, offset: offset)
        PlayerPresenter.shared.presentPlayer(stream: stream, streams: streams, context: context, onWatchNext: onWatchNext)
    }

    /// Where a Continue Watching item for this episode stopped.
    static func resumePosition(for request: Request) -> Double? {
        ContinueWatchingManager.shared.items.first {
            $0.simklTitle == request.ref && $0.episodeNumber == request.number
        }?.watchedSeconds
    }

    /// Up Next through the same module page, reporting numbers in the units the play started with,
    /// so the tracker maps them back to the right season.
    private static func nextLoader(resultHref: String?, episodeHref: String?, number: Int,
                                   offset: Int) -> WatchNextLoader? {
        guard let module = ModuleManager.shared.activeModule, let resultHref else { return nil }
        var currentHref = episodeHref
        var fallbackNumber = number
        return { _ in
            let runner = ModuleJSRunner()
            try await runner.load(module: module)
            let episodes = try await runner.fetchEpisodes(url: resultHref)
            guard let step = EpisodeNavigator.next(afterHref: currentHref, in: episodes)
                ?? EpisodeNavigator.next(currentNumber: fallbackNumber, anchor: 0, in: episodes) else { return nil }
            let streams = try await runner.fetchStreams(episodeUrl: step.episode.href).sorted { $0.title < $1.title }
            guard !streams.isEmpty else { return nil }
            currentHref = step.episode.href
            fallbackNumber = Int(step.episode.number)
            let relative = EpisodeNavigator.seasonRelativeNumber(
                moduleNumber: Int(step.episode.number), index: step.current + 1, in: episodes, seasonOffset: offset)
            return (streams: streams, episodeNumber: relative, episodeHref: step.episode.href)
        }
    }
}
