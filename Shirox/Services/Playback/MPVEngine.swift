import Foundation
import QuartzCore
import Libmpv
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// The layer mpv draws into, through MoltenVK.
///
/// MoltenVK briefly sets the drawable to 1×1 to force a presentation through; taking that size
/// made the picture flicker and could leave it stuck at 1×1 (mpv-player/mpv#13651).
final class MPVMetalLayer: CAMetalLayer {
    /// Called when the layer's size in pixels changes — a rotation, a window resize — on
    /// whichever thread changed it.
    var onResize: (() -> Void)?

    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue }
        }
    }

    // Once MoltenVK has set the drawable's size it no longer follows the layer's, so it's kept
    // in step here: mpv reads it as the size to draw at.
    override var bounds: CGRect {
        didSet { if bounds.size != oldValue.size { fitDrawable() } }
    }

    override var contentsScale: CGFloat {
        didSet { if contentsScale != oldValue { fitDrawable() } }
    }

    private func fitDrawable() {
        let size = CGSize(width: (bounds.width * contentsScale).rounded(),
                          height: (bounds.height * contentsScale).rounded())
        guard size.width > 1, size.height > 1, size != drawableSize else { return }
        drawableSize = size
        onResize?()
    }
}

/// `PlaybackEngine` over libmpv (MPVKit): the engine for formats, codecs and subtitle styles
/// AVPlayer doesn't handle. It has no Picture in Picture or AirPlay video.
///
/// mpv reports through events, which are drained on a queue of their own after its wakeup
/// callback and applied here on the main actor to the state the getters read. Setters update that
/// state at once as well, as AVPlayer's do, so a pause reads as paused before mpv confirms it.
@MainActor
final class MPVEngine: PlaybackEngine {

    enum Output {
        /// Draws into `layer`.
        case metal
        /// No picture and no sound — for tests.
        case none
    }

    /// Why mpv couldn't play a file.
    struct Failure: LocalizedError {
        let code: Int32
        var errorDescription: String? { "mpv: " + String(cString: mpv_error_string(code)) }
    }

    /// What `MPVVideoView` shows.
    let layer = MPVMetalLayer()

    var events = PlaybackEngineEvents() {
        didSet { if !isStopped { isReporting = true } }
    }

    /// libmpv's API is thread-safe. The handle is read on the event queue and destroyed only
    /// there, after the wakeup callback that feeds that queue has been removed.
    nonisolated(unsafe) private var handle: OpaquePointer?
    private nonisolated let queue = DispatchQueue(label: "shirox.mpv.events", qos: .userInitiated)

    private var isStopped = false
    /// Ticks and play/pause reports wait for the listener, as AVPlayer's do.
    private var isReporting = false
    private var isPaused = true
    private var isPausedForCache = false
    private var speed: Float = 1
    private var storedVolume: Float = 1
    private var lastTimeControl: PlaybackTimeControl = .paused
    private var lastTickTime = -Double.infinity
    /// A seek waiting to land: sent with a reply number, taken once mpv has answered it.
    private struct PendingSeek {
        let reply: UInt64
        var taken = false
        let completion: (Bool) -> Void
    }
    private var pendingSeeks: [PendingSeek] = []
    private var nextSeekReply: UInt64 = 1
    /// A seek asked for while the file was still opening, which mpv can't do yet; made once it has.
    private var seekAfterLoad: (seconds: Double, precision: SeekPrecision, completion: ((Bool) -> Void)?)?
    /// A bitrate cap set while the file was still opening. mpv picks the variant as it opens a
    /// file, so the cap needs a reload once it's open.
    private var reloadAfterLoad = false
    /// What the player asked to play.
    private var source: PlaybackSource?
    /// What mpv was actually given — `source`, or where the router sent it.
    private var opened: PlaybackSource?
    private let router: MPVRouter?
    /// Counts loads, so a route that finishes after a newer load has started is dropped.
    private var loadGeneration = 0
    private var defaultUserAgent = ""
    private var observers: [NSObjectProtocol] = []
    private var pendingRefit: DispatchWorkItem?
    /// Whether the aspect override currently holds the invisible nudge (see `refitVideoOutput`).
    private var aspectNudged = false

    private(set) var currentTime: Double = 0
    private(set) var duration: Double?
    private(set) var bufferedUntil: Double = 0
    private(set) var isItemReady = false
    private(set) var isItemFailed = false
    private(set) var audioOptions: [PlaybackAudioOption] = []
    private(set) var selectedAudioOption: PlaybackAudioOption.ID?

    /// What mpv draws: nothing (subtitles are then the overlay's), a track in the file, or an
    /// ASS script.
    enum SubtitleSource: Equatable {
        case none
        case embedded(Int)
        case script(String)
    }

    /// The subtitle tracks inside the file.
    private(set) var subtitleOptions: [PlaybackSubtitleOption] = []
    /// The file's default subtitle track, or its first; nil when it has none.
    private(set) var defaultSubtitleOption: PlaybackSubtitleOption.ID?
    private var subtitleSource: SubtitleSource = .none
    /// Where the script mpv is drawing was written.
    private var scriptFile: URL?

    /// - Parameter router: decides where each stream is fetched from; nil opens it as given.
    init(output: Output = .metal, router: MPVRouter? = nil) {
        self.router = router
        guard let mpv = mpv_create() else {
            Logger.shared.log("[MPV] Couldn't create an mpv instance", type: "Error")
            return
        }
        handle = mpv
        // Loading a file doesn't start it: the player decides when to play.
        setOption("pause", "yes")
        setOption("idle", "yes")
        // Stay on the last frame at the end, as AVPlayer does; the end is reported by eof-reached.
        setOption("keep-open", "yes")
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        setOption("ytdl", "no")
        setOption("cache", "yes")
        // Subtitles are the player's overlay's for now; mpv draws none of its own.
        setOption("sub-auto", "no")
        setOption("sid", "no")
        switch output {
        case .metal:
            layer.framebufferOnly = true
            layer.backgroundColor = CGColor(gray: 0, alpha: 1)
            var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
            mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)
            setOption("vo", "gpu-next")
            setOption("gpu-api", "vulkan")
            setOption("gpu-context", "moltenvk")
            setOption("hwdec", "videotoolbox")
        case .none:
            setOption("vo", "null")
            setOption("ao", "null")
        }
        mpv_request_log_messages(mpv, "warn")
        guard mpv_initialize(mpv) >= 0 else {
            Logger.shared.log("[MPV] Couldn't start mpv", type: "Error")
            mpv_terminate_destroy(mpv)
            handle = nil
            return
        }
        defaultUserAgent = getString("user-agent") ?? ""
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "demuxer-cache-time", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "track-list/count", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "aid", MPV_FORMAT_INT64)
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            Unmanaged<MPVEngine>.fromOpaque(context).takeUnretainedValue().drainSoon()
        }, Unmanaged.passUnretained(self).toOpaque())
        if output == .metal {
            observeBackground()
            // Layout resizes it on the main thread, but MoltenVK works the layer from mpv's own.
            layer.onResize = { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.layerResized() } }
            }
        }
    }

    deinit {
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            let doomed = Handle(pointer: handle)
            queue.async { mpv_terminate_destroy(doomed.pointer) }
        }
    }

    /// An mpv handle on its way to the event queue to be destroyed. libmpv's API is thread-safe.
    private struct Handle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    // MARK: - Events

    /// What the event queue hands the main actor.
    private enum Event: Sendable {
        case startFile
        case fileLoaded
        case endFile(reason: UInt32, error: Int32)
        case playbackRestart
        /// mpv took (or refused) the command sent with this reply number.
        case commandReply(UInt64, error: Int32)
        case double(String, Double?)
        case flag(String, Bool?)
        case int(String, Int64?)
        case log(String)
    }

    /// Called on one of mpv's threads, where no mpv call may be made: hop to the event queue.
    private nonisolated func drainSoon() {
        queue.async { [weak self] in self?.drain() }
    }

    private nonisolated func drain() {
        guard let mpv = handle else { return }
        var batch: [Event] = []
        while let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {
            if let converted = Self.convert(event.pointee) { batch.append(converted) }
            if event.pointee.event_id == MPV_EVENT_SHUTDOWN { break }
        }
        guard !batch.isEmpty else { return }
        let drained = batch
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for event in drained { self.apply(event) }
            }
        }
    }

    private nonisolated static func convert(_ event: mpv_event) -> Event? {
        switch event.event_id {
        case MPV_EVENT_START_FILE:
            return .startFile
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_PLAYBACK_RESTART:
            return .playbackRestart
        case MPV_EVENT_COMMAND_REPLY:
            return .commandReply(event.reply_userdata, error: event.error)
        case MPV_EVENT_END_FILE:
            guard let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else { return nil }
            return .endFile(reason: data.reason.rawValue, error: data.error)
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                  let rawName = property.name else { return nil }
            let name = String(cString: rawName)
            switch property.format {
            case MPV_FORMAT_DOUBLE:
                return .double(name, property.data?.assumingMemoryBound(to: Double.self).pointee)
            case MPV_FORMAT_FLAG:
                return .flag(name, property.data.map { $0.assumingMemoryBound(to: Int32.self).pointee != 0 })
            case MPV_FORMAT_INT64:
                return .int(name, property.data?.assumingMemoryBound(to: Int64.self).pointee)
            default:
                // Unavailable (no file, or "no" for a track): the format is NONE.
                return .double(name, nil)
            }
        case MPV_EVENT_LOG_MESSAGE:
            guard let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
                  let text = message.text, let prefix = message.prefix else { return nil }
            return .log("[\(String(cString: prefix))] \(String(cString: text))")
        default:
            return nil
        }
    }

    private func apply(_ event: Event) {
        guard !isStopped else { return }
        switch event {
        case .startFile:
            isItemReady = false
            isItemFailed = false
            reportTimeControl()
        case .fileLoaded:
            if reloadAfterLoad {
                reloadAfterLoad = false
                reload(at: seekAfterLoad?.seconds ?? currentTime)
                return
            }
            isItemReady = true
            events.itemReady()
            reportTimeControl()
            refreshSubtitleOptions()
            applySubtitleSource()
            if let pending = seekAfterLoad {
                seekAfterLoad = nil
                seek(to: pending.seconds, precision: pending.precision, completion: pending.completion)
            }
        case .endFile(let reason, let error):
            // A replaced or stopped file ends too; only an error is news.
            guard reason == MPV_END_FILE_REASON_ERROR.rawValue else { return }
            finishPendingSeeks(false)
            seekAfterLoad?.completion?(false)
            seekAfterLoad = nil
            reloadAfterLoad = false
            let failure = Failure(code: error)
            Logger.shared.log("[MPV] Playback failed: \(failure.localizedDescription)", type: "Error")
            if isItemReady {
                events.failedToPlayToEnd(failure)
            } else {
                isItemFailed = true
                events.itemFailed(failure)
            }
        case .playbackRestart:
            if let time = getDouble("time-pos") { currentTime = time }
            finishTakenSeeks()
            tick(force: true)
        case .commandReply(let reply, let error):
            guard let index = pendingSeeks.firstIndex(where: { $0.reply == reply }) else { return }
            if error < 0 {
                pendingSeeks.remove(at: index).completion(false)
            } else {
                pendingSeeks[index].taken = true
            }
        case .double(let name, let value):
            switch name {
            case "time-pos":
                if let value {
                    currentTime = value
                    tick(force: false)
                }
            case "duration":
                duration = value
            case "demuxer-cache-time":
                bufferedUntil = value ?? 0
            case "aid":
                selectedAudioOption = nil
            default:
                break
            }
        case .flag(let name, let value):
            switch name {
            case "pause":
                isPaused = value ?? true
                reportTimeControl()
            case "paused-for-cache":
                isPausedForCache = value ?? false
                reportTimeControl()
            case "eof-reached":
                if value == true { events.playedToEnd() }
            default:
                break
            }
        case .int(let name, let value):
            switch name {
            case "track-list/count":
                refreshAudioOptions()
                refreshSubtitleOptions()
            case "aid":
                selectedAudioOption = value.map(Int.init)
            default:
                break
            }
        case .log(let line):
            Logger.shared.log("[MPV] \(line.trimmingCharacters(in: .whitespacesAndNewlines))", type: "Player")
        }
    }

    /// About twice a second of playback, and always after a seek, as AVPlayer's periodic
    /// observer ticks.
    private func tick(force: Bool) {
        guard isReporting else { return }
        guard force || abs(currentTime - lastTickTime) >= 0.5 else { return }
        lastTickTime = currentTime
        events.tick()
    }

    private func reportTimeControl() {
        let now = timeControl
        guard now != lastTimeControl else { return }
        lastTimeControl = now
        if isReporting { events.timeControlChanged(now) }
    }

    private func finishPendingSeeks(_ finished: Bool) {
        let done = pendingSeeks
        pendingSeeks = []
        for seek in done { seek.completion(finished) }
    }

    /// A restart lands the seeks mpv had already taken. A seek sent just after the file started
    /// playing would otherwise land on that start's restart, still queued on its way here, and
    /// read as done at the old position.
    private func finishTakenSeeks() {
        let landed = pendingSeeks.filter(\.taken)
        pendingSeeks.removeAll { $0.taken }
        for seek in landed { seek.completion(true) }
    }

    /// Opens the current source again at `seconds` — how a new bitrate cap takes effect.
    private func reload(at seconds: Double) {
        guard let opened else { return }
        isItemReady = false
        command("loadfile", location(of: opened.url), "replace", "-1", "start=\(seconds)")
    }

    private func refreshAudioOptions() {
        let count = Int(getInt64("track-list/count") ?? 0)
        var options: [PlaybackAudioOption] = []
        for index in 0..<count where getString("track-list/\(index)/type") == "audio" {
            guard let id = getInt64("track-list/\(index)/id") else { continue }
            options.append(PlaybackAudioOption(id: Int(id), title: trackTitle(at: index, id: id)))
        }
        audioOptions = options
        selectedAudioOption = getInt64("aid").map(Int.init)
        events.audioOptionsChanged()
    }

    /// The file's own subtitle tracks — not the scripts added to it.
    private func refreshSubtitleOptions() {
        let count = Int(getInt64("track-list/count") ?? 0)
        var options: [PlaybackSubtitleOption] = []
        var flaggedDefault: Int?
        for index in 0..<count where getString("track-list/\(index)/type") == "sub"
            && getString("track-list/\(index)/external") != "yes" {
            guard let id = getInt64("track-list/\(index)/id") else { continue }
            options.append(PlaybackSubtitleOption(id: Int(id), title: trackTitle(at: index, id: id)))
            if flaggedDefault == nil, getString("track-list/\(index)/default") == "yes" { flaggedDefault = Int(id) }
        }
        let defaultOption = flaggedDefault ?? options.first?.id
        guard options != subtitleOptions || defaultOption != defaultSubtitleOption else { return }
        subtitleOptions = options
        defaultSubtitleOption = defaultOption
        events.subtitleOptionsChanged()
    }

    /// A track's title, else its language's name, else its number.
    private func trackTitle(at index: Int, id: Int64) -> String {
        getString("track-list/\(index)/title")
            ?? getString("track-list/\(index)/lang").map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
            ?? "Track \(id)"
    }

    // MARK: - PlaybackEngine

    func load(_ source: PlaybackSource) {
        self.source = source
        isItemReady = false
        isItemFailed = false
        currentTime = 0
        duration = nil
        bufferedUntil = 0
        lastTickTime = -.infinity
        audioOptions = []
        selectedAudioOption = nil
        subtitleOptions = []
        defaultSubtitleOption = nil
        finishPendingSeeks(false)
        seekAfterLoad?.completion?(false)
        seekAfterLoad = nil
        reloadAfterLoad = false
        reportTimeControl()
        guard let router else {
            open(source)
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        Task { [weak self] in
            let routed = await router.route(source)
            // A newer load, or a stop, while the route was worked out: this one is dropped.
            guard let self, !self.isStopped, generation == self.loadGeneration else { return }
            self.open(routed)
        }
    }

    /// Hands mpv the source — the stream itself, or where the router sent it.
    private func open(_ source: PlaybackSource) {
        opened = source
        setProperty("http-header-fields", MPVOptions.headerFields(source.headers))
        setProperty("user-agent", MPVOptions.userAgent(source.headers) ?? defaultUserAgent)
        setProperty("referrer", MPVOptions.referrer(source.headers) ?? "")
        // mpv has no per-file "prefer Japanese"; alang is an order of preference for the next file.
        setProperty("alang", source.prefersJapaneseAudio ? "ja,jpn" : "")
        // The nudge was for the last file's picture.
        aspectNudged = false
        setProperty("video-aspect-override", "no")
        // A track number means nothing in the next file; what to show is re-applied once it opens.
        setProperty("sid", "no")
        command("loadfile", location(of: source.url), "replace")
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        finishPendingSeeks(false)
        seekAfterLoad?.completion?(false)
        seekAfterLoad = nil
        pendingRefit?.cancel()
        removeScriptFile()
        router?.release()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        events = PlaybackEngineEvents()
        guard let mpv = handle else { return }
        handle = nil
        mpv_set_wakeup_callback(mpv, nil, nil)
        let doomed = Handle(pointer: mpv)
        queue.async { mpv_terminate_destroy(doomed.pointer) }
    }

    var timeControl: PlaybackTimeControl {
        if isPaused { return .paused }
        if isPausedForCache || !isItemReady { return .waiting }
        return .playing
    }

    var rate: Float {
        get { isPaused ? 0 : speed }
        set {
            if newValue > 0 {
                speed = newValue
                setDouble("speed", Double(newValue))
                setPaused(false)
            } else {
                setPaused(true)
            }
        }
    }

    var volume: Float {
        get { storedVolume }
        set {
            storedVolume = newValue
            setDouble("volume", MPVOptions.volume(newValue))
        }
    }

    /// Plays at normal speed, as AVPlayer's `play()` does.
    func play() { rate = 1 }
    func pause() { setPaused(true) }
    func playImmediately(atRate rate: Float) { self.rate = rate }

    func seek(to seconds: Double, precision: SeekPrecision, completion: ((Bool) -> Void)?) {
        guard isItemReady else {
            if source != nil, !isItemFailed {
                // Still opening: seek once it has. A later request replaces an earlier one, as a
                // newer seek does on AVPlayer.
                seekAfterLoad?.completion?(false)
                seekAfterLoad = (seconds, precision, completion)
                currentTime = seconds
            } else {
                // Nothing loading: nothing will restart to complete it.
                completion?(false)
            }
            return
        }
        currentTime = seconds
        guard let completion else {
            command("seek", String(seconds), MPVOptions.seekFlags(precision))
            return
        }
        let reply = nextSeekReply
        nextSeekReply += 1
        pendingSeeks.append(PendingSeek(reply: reply, completion: completion))
        if !commandAsync(reply: reply, "seek", String(seconds), MPVOptions.seekFlags(precision)) {
            pendingSeeks.removeAll { $0.reply == reply }
            completion(false)
        }
    }

    func seek(to seconds: Double, precision: SeekPrecision) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            seek(to: seconds, precision: precision) { _ in continuation.resume() }
        }
    }

    var waitsToMinimizeStalling = false {
        didSet { setProperty("cache-pause-initial", waitsToMinimizeStalling ? "yes" : "no") }
    }

    /// mpv picks a variant as a file opens, so a new cap reloads the stream where it is.
    func setPeakBitRate(_ bitsPerSecond: Int?) {
        setProperty("hls-bitrate", MPVOptions.hlsBitrate(bitsPerSecond))
        guard source != nil, !isItemFailed else { return }
        if isItemReady {
            reload(at: currentTime)
        } else {
            reloadAfterLoad = true
        }
    }

    func selectAudioOption(_ id: PlaybackAudioOption.ID) {
        var track = Int64(id)
        if let mpv = handle { mpv_set_property(mpv, "aid", MPV_FORMAT_INT64, &track) }
        selectedAudioOption = id
    }

    /// Fill crops the picture to the screen; fit shows all of it.
    func setFillsScreen(_ fills: Bool) {
        setDouble("panscan", fills ? 1 : 0)
    }

    // MARK: - Subtitles

    /// Draws `source` from now on, and again whenever the stream reopens.
    func showSubtitles(_ source: SubtitleSource) {
        guard source != subtitleSource else { return }
        subtitleSource = source
        applySubtitleSource()
    }

    /// The viewer's subtitle settings, applied to what mpv draws.
    func applySubtitleSettings(visible: Bool, delay: Double, fontSize: Double) {
        setProperty("sub-visibility", visible ? "yes" : "no")
        setDouble("sub-delay", MPVOptions.subDelay(fromOverlayDelay: delay))
        setDouble("sub-scale", MPVOptions.subScale(fontSize: fontSize))
    }

    /// The subtitle track mpv is drawing, and whether it came from outside the file.
    var shownSubtitleTrack: (id: Int, isExternal: Bool)? {
        guard let id = getInt64("sid") else { return nil }
        let count = Int(getInt64("track-list/count") ?? 0)
        for index in 0..<count where getString("track-list/\(index)/type") == "sub"
            && getInt64("track-list/\(index)/id") == id {
            return (Int(id), getString("track-list/\(index)/external") == "yes")
        }
        return nil
    }

    private func applySubtitleSource() {
        // mpv can only take a track once the file's open; this runs again then.
        guard isItemReady else { return }
        removeScriptTracks()
        switch subtitleSource {
        case .none:
            setProperty("sid", "no")
        case .embedded(let id):
            setProperty("sid", String(id))
        case .script(let text):
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("shirox-subtitles-\(UUID().uuidString).ass")
            do {
                try Data(text.utf8).write(to: file)
            } catch {
                Logger.shared.log("[MPV] Couldn't write the subtitle script: \(error)", type: "Error")
                return
            }
            scriptFile = file
            command("sub-add", file.path, "select")
        }
    }

    /// Takes out scripts added before; a reopened stream has dropped them anyway.
    private func removeScriptTracks() {
        let count = Int(getInt64("track-list/count") ?? 0)
        for index in (0..<count).reversed() where getString("track-list/\(index)/type") == "sub"
            && getString("track-list/\(index)/external") == "yes" {
            if let id = getInt64("track-list/\(index)/id") { command("sub-remove", String(id)) }
        }
        removeScriptFile()
    }

    private func removeScriptFile() {
        guard let scriptFile else { return }
        try? FileManager.default.removeItem(at: scriptFile)
        self.scriptFile = nil
    }

    /// The size in pixels mpv draws its picture at; nil until it has drawn one.
    var videoOutputSize: CGSize? {
        guard let width = getInt64("osd-dimensions/w"), let height = getInt64("osd-dimensions/h"),
              width > 0, height > 0 else { return nil }
        return CGSize(width: Int(width), height: Int(height))
    }

    // MARK: - Resizing

    /// MPVKit's renderer reads the layer's size only when it configures its video output, and
    /// never again (mpvkit/MPVKit#3): after a rotation mpv went on drawing at the old size, the
    /// picture small in one corner. It configures the output again whenever the picture's own
    /// parameters change, so once a resize has settled, they're changed by nothing visible: an
    /// aspect a millionth wider, which rounds to the same size in pixels.
    ///
    /// Rebuilding the video output instead did the job too, but mpv then re-read the video from
    /// its last keyframe, over the network: the sound dropped out and it buffered for a second
    /// on every turn of the phone.
    private func layerResized() {
        pendingRefit?.cancel()
        let refit = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refitVideoOutput() }
        }
        pendingRefit = refit
        // A rotation sets its final size up front; wait out the rest of the layout pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: refit)
    }

    private func refitVideoOutput() {
        guard !isStopped, let drawn = videoOutputSize,
              let aspect = getDouble("video-params/aspect"), aspect > 0 else { return }
        let target = layer.drawableSize
        guard abs(drawn.width - target.width) > 2 || abs(drawn.height - target.height) > 2 else { return }
        Logger.shared.log("[MPV] Drawing at \(Int(drawn.width))×\(Int(drawn.height)) in a \(Int(target.width))×\(Int(target.height)) layer; reconfiguring", type: "Player")
        aspectNudged.toggle()
        setProperty("video-aspect-override", aspectNudged ? String(aspect * (1 + 1e-6)) : "no")
    }

    // MARK: - Backgrounding

    /// No GPU work in the background: the picture goes off, the sound carries on, and comes back
    /// on return — drawing while backgrounded left a black picture afterwards.
    private func observeBackground() {
        #if os(iOS) || os(tvOS)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setProperty("vid", "no") }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setProperty("vid", "auto") }
            },
        ]
        #endif
    }

    // MARK: - mpv calls

    private func location(of url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }

    private func setPaused(_ paused: Bool) {
        isPaused = paused
        var flag: Int32 = paused ? 1 : 0
        if let mpv = handle { mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag) }
        reportTimeControl()
    }

    private func setOption(_ name: String, _ value: String) {
        guard let mpv = handle else { return }
        mpv_set_option_string(mpv, name, value)
    }

    private func setProperty(_ name: String, _ value: String) {
        guard let mpv = handle else { return }
        mpv_set_property_string(mpv, name, value)
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let mpv = handle else { return }
        var value = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &value)
    }

    private func getDouble(_ name: String) -> Double? {
        guard let mpv = handle else { return nil }
        var value = 0.0
        return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    private func getInt64(_ name: String) -> Int64? {
        guard let mpv = handle else { return nil }
        var value: Int64 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    private func getString(_ name: String) -> String? {
        guard let mpv = handle, let raw = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    private func command(_ arguments: String...) {
        guard let mpv = handle else { return }
        let owned = arguments.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var pointers = owned.map { UnsafePointer<CChar>($0) } + [nil]
        let status = mpv_command(mpv, &pointers)
        if status < 0 {
            Logger.shared.log("[MPV] \(arguments.first ?? "command") failed: \(String(cString: mpv_error_string(status)))", type: "Error")
        }
    }

    /// Sends a command whose answer comes back as an event carrying `reply`. False if it
    /// couldn't be sent.
    private func commandAsync(reply: UInt64, _ arguments: String...) -> Bool {
        guard let mpv = handle else { return false }
        let owned = arguments.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var pointers = owned.map { UnsafePointer<CChar>($0) } + [nil]
        let status = mpv_command_async(mpv, reply, &pointers)
        if status < 0 {
            Logger.shared.log("[MPV] \(arguments.first ?? "command") failed: \(String(cString: mpv_error_string(status)))", type: "Error")
        }
        return status >= 0
    }
}
