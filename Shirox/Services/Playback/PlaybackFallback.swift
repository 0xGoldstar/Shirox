import AVFoundation

/// The two engines the player can run on.
enum PlaybackEngineKind: String, CaseIterable {
    /// AVPlayer: Picture in Picture and AirPlay video, but only the formats Apple plays.
    case native
    /// libmpv: more containers, codecs and subtitle styles; no Picture in Picture or AirPlay video.
    case mpv
}

/// Which engine plays a stream, and what the player does when one fails — apart from the view.
enum PlaybackFallback {

    /// Containers AVPlayer can't open at all, so they start on MPV whatever the setting says.
    static let mpvOnlyExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "ts", "m2ts", "ogv"]

    static func initialEngine(preferred: PlaybackEngineKind, url: URL) -> PlaybackEngineKind {
        if preferred == .mpv { return .mpv }
        return mpvOnlyExtensions.contains(url.pathExtension.lowercased()) ? .mpv : .native
    }

    /// AVFoundation's ways of saying it can't read or decode the media — no new URL will help, a
    /// different player might. It often wraps the real reason a level or two down.
    static func isUnsupportedFormat(_ error: Error?) -> Bool {
        let formatCodes: Set<Int> = [
            AVError.fileFormatNotRecognized.rawValue,
            AVError.failedToParse.rawValue,
            AVError.decodeFailed.rawValue,
            AVError.decoderNotFound.rawValue,
            AVError.formatUnsupported.rawValue,
        ]
        var current = error.map { $0 as NSError }
        for _ in 0..<3 {
            guard let nsError = current else { return false }
            if nsError.domain == AVFoundationErrorDomain, formatCodes.contains(nsError.code) { return true }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    enum Decision: Equatable {
        /// Re-extract a fresh URL and try again on the same engine.
        case refetch
        /// Carry on in MPV from the same position.
        case switchToMPV
        /// Offer the manual retry.
        case giveUp
    }

    /// What to do when the item fails to load.
    /// - Native: a format error goes to MPV at once. Anything else re-fetches first — an expired
    ///   CDN URL is the usual cause — and goes to MPV once a fresh one has failed too, or when
    ///   there's no way to get one.
    /// - MPV: a re-fetch is the only thing left to try, once.
    static func decision(after error: Error?, engine: PlaybackEngineKind,
                         canRefetch: Bool, hasRefetched: Bool) -> Decision {
        let refetchLeft = canRefetch && !hasRefetched
        switch engine {
        case .native:
            if isUnsupportedFormat(error) { return .switchToMPV }
            return refetchLeft ? .refetch : .switchToMPV
        case .mpv:
            return refetchLeft ? .refetch : .giveUp
        }
    }
}
