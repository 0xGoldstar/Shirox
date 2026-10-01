import Foundation

/// Which engine actually owns playback right now.
enum PlaybackTarget: Equatable {
    /// A Chromecast session. The local `AVPlayer` is deliberately parked and silent.
    case cast
    /// The on-device `AVPlayer`.
    case local
    /// Nothing to drive.
    case none
}

/// A resolved play/pause decision. Concrete rather than "toggle", so dispatching it twice
/// means the same thing as dispatching it once.
enum PlaybackIntent: Equatable {
    case play
    case pause
}

/// What Now Playing shows apart from the position.
struct NowPlayingDetails: Equatable {
    var title: String
    var subtitle: String
    var duration: Double
    /// Which artwork is attached; nil for none yet.
    var artworkKey: String?
}

/// What Now Playing was told, and when (`time`, on a monotonic clock).
struct NowPlayingSnapshot: Equatable {
    var details: NowPlayingDetails
    var elapsed: Double
    var rate: Double
    var time: Double
}

/// Pure routing decisions for transport commands and Now Playing — no AVFoundation, no Cast
/// SDK, fully unit-testable.
///
/// TWO BUGS THIS EXISTS FOR:
///
/// * **The next episode played on the phone instead of the TV.** `swapStream` was written as
///   pure local-player code — `replaceCurrentItem`, then `player.rate = speed`. It had no
///   notion that a cast might be in progress, so an auto-advance started episode 2 out loud
///   on the handset while the Chromecast still showed the finished episode 1.
///
/// * **Play/pause behaving unpredictably, and Control Center disagreeing with reality.**
///   Partly a routing failure: the remote-command handlers drove the local player even while
///   casting, so the TV never heard them. And Now Playing published the local player's rate
///   and clock, which during a cast are 0 and frozen — Control Center drew a ▶ button over a
///   movie that was already playing, and its scrubber sat at 0:00.
enum PlaybackRouting {

    /// Where a transport command (or a newly-loaded episode) must be sent.
    ///
    /// Casting wins unconditionally: during a cast the local player exists but is parked, so
    /// "there is a local player" must never be read as "play it here".
    static func target(isCasting: Bool, hasLocalPlayer: Bool) -> PlaybackTarget {
        if isCasting { return .cast }
        return hasLocalPlayer ? .local : .none
    }

    /// Resolves a toggle into a concrete intent, captured from the state the user was looking
    /// at when they pressed the button.
    ///
    /// The old handler re-read the player instead. That is only correct if it runs exactly
    /// once — and it did not: duplicate registrations meant the first invocation paused and
    /// the second, re-reading the now-paused player, started it again. Net effect, nothing
    /// happened, which is precisely the reported symptom.
    static func toggleIntent(isPlaying: Bool) -> PlaybackIntent {
        isPlaying ? .pause : .play
    }

    /// The rate to publish to `MPNowPlayingInfoCenter`.
    ///
    /// This is what decides whether Control Center draws ▶ or ⏸ and how fast its scrubber
    /// advances, so it has to describe whichever engine is actually playing — including the
    /// user's speed setting, which the old code dropped by reading a raw `AVPlayer.rate` that
    /// a Control Center play had already reset to 1.0.
    static func nowPlayingRate(target: PlaybackTarget, isPlaying: Bool, playbackSpeed: Double) -> Double {
        guard target != .none, isPlaying else { return 0 }
        return playbackSpeed
    }

    /// Whether a `didPlayToEndTime` notification describes an episode that actually finished.
    ///
    /// AVPlayer posts that notification when a stream *dies* mid-episode as well as when one
    /// ends — a CDN connection dropped behind a phone call, or a seek into a region the server
    /// no longer serves. Trusting it skipped viewers to the next episode from the middle of
    /// one. A real ending has the playhead at the end; the tolerance absorbs the rounding HLS
    /// leaves on a final segment. An unknown duration can't be verified, so it isn't an ending.
    static func isGenuineEnd(position: Double, duration: Double, tolerance: Double = 5) -> Bool {
        guard duration > 0, position.isFinite else { return false }
        return position >= duration - tolerance
    }

    /// Whether a progress write should be dropped because the player's clock has collapsed.
    ///
    /// A dead item reports position 0 while its duration stays at the real value, so a save on
    /// the way out of a failure recorded 0 over a genuinely watched episode. Someone scrubbing
    /// to the very start loses nothing by being ignored here; silently discarding an hour of
    /// progress can't be undone from inside the app.
    static func shouldDiscardPositionWrite(position: Double, lastSaved: Double) -> Bool {
        position <= 0.5 && lastSaved > 30
    }

    /// The elapsed time to publish to `MPNowPlayingInfoCenter`.
    ///
    /// During a cast this must be the receiver's position: the local player's clock is frozen
    /// wherever it was parked, which is what pinned Control Center's scrubber at 0:00.
    /// Non-finite and negative values are clamped — an item that hasn't loaded reports NaN,
    /// and that renders as a garbage scrubber rather than simply being absent.
    static func nowPlayingElapsed(target: PlaybackTarget, castPosition: Double, localPosition: Double) -> Double {
        let raw = target == .cast ? castPosition : localPosition
        guard raw.isFinite, raw > 0 else { return 0 }
        return raw
    }

    /// How far the position may stray from where the system would have moved it before Now
    /// Playing is told again: more than a tick's jitter, less than anyone would notice.
    static let nowPlayingDriftTolerance = 1.0

    /// Whether Now Playing needs telling again. The system moves its scrubber along by itself from
    /// the last position and rate it was given, so it only needs what it can't work out: a change
    /// to what it shows, to the rate, or a position that has strayed from where it would have got
    /// to — a seek, a stall. Sent on every half-second tick instead, it cost a round trip to the
    /// media daemon twice a second for the length of every episode.
    static func nowPlayingNeedsUpdate(last: NowPlayingSnapshot?, next: NowPlayingSnapshot) -> Bool {
        guard let last, last.details == next.details, last.rate == next.rate else { return true }
        let expected = last.elapsed + (next.time - last.time) * last.rate
        return abs(next.elapsed - expected) > nowPlayingDriftTolerance
    }
}
