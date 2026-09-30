import AVFoundation

/// `PlaybackEngine` over AVPlayer: the engine the player has always had, moved out of
/// `PlayerView` with its configuration and observer order unchanged.
@MainActor
final class AVPlayerEngine: PlaybackEngine {
    /// For the video layer and Picture in Picture, which need the AVPlayer itself.
    let player = AVPlayer()

    var events = PlaybackEngineEvents() {
        didSet { startReporting() }
    }

    private var isStopped = false
    private var timeObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var itemObservers: [NSObjectProtocol] = []
    private var audioGroup: AVMediaSelectionGroup?
    private var audioLoad: Task<Void, Never>?

    init() {
        #if os(iOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
    }

    /// The clock and the play/pause reports, attached when the listener first arrives — after
    /// the player has been told to play, as `PlayerView` always attached them, so the start-up
    /// transition isn't reported (it would arm the stall watchdog during the initial load).
    private func startReporting() {
        guard !isStopped, timeControlObservation == nil else { return }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.events.timeControlChanged(self.timeControl)
            }
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.events.tick() }
        }
    }

    func load(_ source: PlaybackSource) {
        let asset = source.headers.isEmpty
            ? AVURLAsset(url: source.url)
            : AVURLAsset(url: source.url, options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers])
        let item = AVPlayerItem(asset: asset)
        // Automatic: let AVPlayer size the buffer adaptively (YouTube-style ABR). A fixed value
        // fights stall-minimization and prolongs stalls on flaky CDNs.
        item.preferredForwardBufferDuration = 0
        // Continue buffering when paused.
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        observe(item)
        audioGroup = nil
        audioLoad?.cancel()
        let prefersJapanese = source.prefersJapaneseAudio
        audioLoad = Task { [weak self] in
            guard let group = try? await asset.loadMediaSelectionGroup(for: .audible) else { return }
            guard let self, self.player.currentItem === item else { return }
            self.audioGroup = group
            if prefersJapanese,
               let japanese = AVMediaSelectionGroup.mediaSelectionOptions(
                   from: group.options, with: Locale(identifier: "ja")).first {
                item.select(japanese, in: group)
            }
            self.events.audioOptionsChanged()
        }
        player.replaceCurrentItem(with: item)
    }

    /// Watches the item's status, its end, and its failure to reach the end — each only while it's
    /// the item on screen.
    ///
    /// Plain KVO (`.initial` + `.new`) rather than `publisher(for:).values`: AsyncPublisher buffers
    /// a single element and drops whatever the consumer hasn't demanded yet, so the fast
    /// `.unknown` -> `.failed` transition an expired CDN URL produces was routinely dropped.
    /// `.initial` covers an item already ready or failed when attached.
    private func observe(_ item: AVPlayerItem) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self, self.player.currentItem === observed else { return }
                switch observed.status {
                case .readyToPlay: self.events.itemReady()
                case .failed: self.events.itemFailed(observed.error)
                default: break
                }
            }
        }
        // Block observers are unregistered by token, or every swap would stack another pair.
        for token in itemObservers { NotificationCenter.default.removeObserver(token) }
        itemObservers = [
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.player.currentItem === item else { return }
                    self.events.playedToEnd()
                }
            },
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated {
                    guard let self, self.player.currentItem === item else { return }
                    self.events.failedToPlayToEnd(error)
                }
            },
        ]
    }

    func stop() {
        isStopped = true
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        for token in itemObservers { NotificationCenter.default.removeObserver(token) }
        itemObservers = []
        audioLoad?.cancel()
        events = PlaybackEngineEvents()
    }

    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var duration: Double? {
        guard let duration = player.currentItem?.duration, duration.isNumeric else { return nil }
        return duration.seconds
    }

    var bufferedUntil: Double {
        (player.currentItem?.loadedTimeRanges ?? [])
            .map { $0.timeRangeValue }
            .map { $0.start.seconds + $0.duration.seconds }
            .max() ?? 0
    }

    var timeControl: PlaybackTimeControl {
        switch player.timeControlStatus {
        case .paused: return .paused
        case .waitingToPlayAtSpecifiedRate: return .waiting
        case .playing: return .playing
        @unknown default: return .playing
        }
    }

    var isItemReady: Bool { player.currentItem?.status == .readyToPlay }
    var isItemFailed: Bool { player.currentItem?.status == .failed }

    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func playImmediately(atRate rate: Float) { player.playImmediately(atRate: rate) }

    func seek(to seconds: Double, precision: SeekPrecision, completion: ((Bool) -> Void)?) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        switch precision {
        case .fast:
            if let completion { player.seek(to: time, completionHandler: completion) } else { player.seek(to: time) }
        case .exact:
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero,
                        completionHandler: completion ?? { _ in })
        case .within(let seconds):
            let tolerance = CMTime(seconds: seconds, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance,
                        completionHandler: completion ?? { _ in })
        }
    }

    func seek(to seconds: Double, precision: SeekPrecision) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            seek(to: seconds, precision: precision) { _ in continuation.resume() }
        }
    }

    var waitsToMinimizeStalling: Bool {
        get { player.automaticallyWaitsToMinimizeStalling }
        set { player.automaticallyWaitsToMinimizeStalling = newValue }
    }

    func setPeakBitRate(_ bitsPerSecond: Int?) {
        player.currentItem?.preferredPeakBitRate = bitsPerSecond.map { Double($0) } ?? 0
    }

    var audioOptions: [PlaybackAudioOption] {
        (audioGroup?.options ?? []).enumerated().map {
            PlaybackAudioOption(id: $0.offset, title: $0.element.displayName)
        }
    }

    var selectedAudioOption: PlaybackAudioOption.ID? {
        guard let group = audioGroup, let item = player.currentItem,
              let selected = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return group.options.firstIndex(of: selected)
    }

    func selectAudioOption(_ id: PlaybackAudioOption.ID) {
        guard let group = audioGroup, group.options.indices.contains(id) else { return }
        player.currentItem?.select(group.options[id], in: group)
    }
}
