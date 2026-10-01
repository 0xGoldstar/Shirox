import Foundation

/// Who draws the subtitles on screen.
enum SubtitleRoute: Equatable {
    /// Nothing to show.
    case none
    /// Plain-text cues (VTT/SRT), drawn by `PlayerSubtitleOverlay` on either engine so they look the same.
    case cues
    /// An ASS script drawn over AVPlayer's picture by libass (`PlayerAssOverlay`).
    case assOverlay
    /// An ASS script handed to mpv, which draws it itself.
    case mpvScript
    /// A subtitle track inside the file, drawn by mpv.
    case mpvEmbedded(Int)
}

/// Picks the `SubtitleRoute` — apart from the view, so it can be tested.
enum SubtitleRouting {

    /// What the chosen (or default) downloadable track turned out to be.
    enum Loaded: Equatable { case nothing, cues, ass }

    /// - Parameters:
    ///   - pickedExternal: the viewer chose a downloadable (or imported) track, rather than
    ///     taking the default.
    ///   - pickedEmbedded: a track inside the file the viewer chose.
    ///   - embeddedDefault: the file's own default track, or its first; nil when it has none.
    ///     A file's own track is timed to that exact release and keeps its signs and styling,
    ///     so on MPV it wins until the viewer picks something else.
    static func route(engine: PlaybackEngineKind, loaded: Loaded, pickedExternal: Bool,
                      pickedEmbedded: Int?, embeddedDefault: Int?) -> SubtitleRoute {
        if engine == .mpv {
            if let pickedEmbedded { return .mpvEmbedded(pickedEmbedded) }
            if !pickedExternal, let embeddedDefault { return .mpvEmbedded(embeddedDefault) }
        }
        switch loaded {
        case .nothing: return .none
        case .cues: return .cues
        case .ass: return engine == .mpv ? .mpvScript : .assOverlay
        }
    }
}
