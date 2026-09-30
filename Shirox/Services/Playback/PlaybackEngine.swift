import Foundation

/// How exactly a seek must land.
enum SeekPrecision: Equatable {
    /// The engine's default tolerance: a nearby keyframe, cheap on streams.
    case fast
    /// Frame-exact.
    case exact
    /// Within this many seconds either side.
    case within(Double)
}

/// Whether the timeline is moving, stopped, or waiting on the network.
enum PlaybackTimeControl: Equatable {
    case playing, paused, waiting
}

/// One audio track a source offers.
struct PlaybackAudioOption: Identifiable, Equatable {
    let id: Int
    let title: String
}

/// A subtitle track inside the file, which the engine draws itself.
struct PlaybackSubtitleOption: Identifiable, Equatable {
    let id: Int
    let title: String
}

/// What to play.
struct PlaybackSource: Equatable {
    let url: URL
    /// Sent with every request for the stream; empty for a file or an already-proxied URL.
    var headers: [String: String] = [:]
    /// Start on Japanese audio when the source offers a choice — a subbed stream.
    var prefersJapaneseAudio = false
}

/// What an engine reports while it plays. Each is only ever about the item loaded now: an event
/// from one it has swapped out is dropped by the engine, so listeners needn't check.
struct PlaybackEngineEvents {
    var timeControlChanged: (PlaybackTimeControl) -> Void = { _ in }
    /// Twice a second while the clock runs.
    var tick: () -> Void = {}
    var itemReady: () -> Void = {}
    var itemFailed: (Error?) -> Void = { _ in }
    var playedToEnd: () -> Void = {}
    var failedToPlayToEnd: (Error?) -> Void = { _ in }
    var audioOptionsChanged: () -> Void = {}
    /// The file's own subtitle tracks changed. Only MPV draws them, so only MPV sends it.
    var subtitleOptionsChanged: () -> Void = {}
}

/// The player behind the player screen. `PlayerView` drives playback only through this, so the
/// same controls, menus and gestures work over any engine.
@MainActor
protocol PlaybackEngine: AnyObject {
    /// Setting these the first time also starts the clock and the play/pause reports.
    var events: PlaybackEngineEvents { get set }

    /// Plays `source` from now on in place of whatever was loaded. Doesn't start playback.
    func load(_ source: PlaybackSource)
    /// Pauses and stops reporting, for good.
    func stop()

    var currentTime: Double { get }
    /// nil until known.
    var duration: Double? { get }
    /// How far the buffer reaches, in seconds of timeline.
    var bufferedUntil: Double { get }
    var timeControl: PlaybackTimeControl { get }
    var isItemReady: Bool { get }
    var isItemFailed: Bool { get }

    /// Above 0 plays at that speed; 0 pauses.
    var rate: Float { get set }
    var volume: Float { get set }
    /// Plays at the engine's default rate.
    func play()
    func pause()
    /// Plays at `rate` without waiting to build a buffer first.
    func playImmediately(atRate rate: Float)

    func seek(to seconds: Double, precision: SeekPrecision, completion: ((Bool) -> Void)?)
    func seek(to seconds: Double, precision: SeekPrecision) async

    /// Hold playback until a network-sized buffer is built. Off for files on disk and while scrubbing.
    var waitsToMinimizeStalling: Bool { get set }
    /// Caps the stream's bitrate; nil lets it adapt.
    func setPeakBitRate(_ bitsPerSecond: Int?)

    var audioOptions: [PlaybackAudioOption] { get }
    var selectedAudioOption: PlaybackAudioOption.ID? { get }
    func selectAudioOption(_ id: PlaybackAudioOption.ID)
}
