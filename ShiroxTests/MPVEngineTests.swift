import XCTest
import AVFoundation
import Network
#if os(iOS)
import UIKit
#endif
@testable import Shirox

/// The mpv engine against real files — silent audio of a known length — with no video or audio
/// output, so it runs without a GPU or a sound device.
@MainActor
final class MPVEngineTests: XCTestCase {

    private var engine: MPVEngine!
    private var files: [URL] = []

    override func setUp() async throws {
        engine = MPVEngine(output: .none)
    }

    override func tearDown() async throws {
        engine.stop()
        engine = nil
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    private func silence(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        files.append(url)
        return url
    }

    private func loadReady(seconds: Double) async throws {
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: try silence(seconds: seconds)))
        await fulfillment(of: [ready], timeout: 10)
    }

    /// mpv read ahead as far as 150 MB would take it — minutes of a stream, every byte through the
    /// proxy and decrypted as fast as the network would go, and all of it thrown away by a seek.
    /// It reads two minutes ahead, which rides out any stall worth riding out.
    func testReadsAheadTwoMinutesNotTheWholeFile() async throws {
        try await loadReady(seconds: 300)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertGreaterThan(engine.bufferedUntil, 60, "it should still read well ahead")
        XCTAssertLessThan(engine.bufferedUntil, 150, "read ahead to \(engine.bufferedUntil) s")
    }

    func testALoadedFileBecomesReadyWithItsDuration() async throws {
        try await loadReady(seconds: 2)
        XCTAssertTrue(engine.isItemReady)
        XCTAssertFalse(engine.isItemFailed)
        XCTAssertEqual(engine.duration ?? 0, 2, accuracy: 0.05)
    }

    func testAMissingFileFails() async {
        let failed = expectation(description: "failed")
        failed.assertForOverFulfill = false
        engine.events.itemFailed = { _ in failed.fulfill() }
        engine.load(PlaybackSource(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).caf")))
        await fulfillment(of: [failed], timeout: 10)
        XCTAssertTrue(engine.isItemFailed)
        XCTAssertFalse(engine.isItemReady)
    }

    /// A load doesn't start playback — the player decides when.
    func testLoadingLeavesItPaused() async throws {
        try await loadReady(seconds: 2)
        XCTAssertEqual(engine.rate, 0)
        XCTAssertEqual(engine.timeControl, .paused)
    }

    func testPlayingReportsPlayingAndTheClockTicks() async throws {
        try await loadReady(seconds: 3)
        let playing = expectation(description: "playing")
        playing.assertForOverFulfill = false
        let ticked = expectation(description: "ticked")
        ticked.assertForOverFulfill = false
        engine.events.timeControlChanged = { if $0 == .playing { playing.fulfill() } }
        // The first tick is the starting position; wait for one where the clock has moved.
        engine.events.tick = { [unowned engine] in if engine!.currentTime > 0 { ticked.fulfill() } }
        engine.rate = 1.5
        await fulfillment(of: [playing, ticked], timeout: 10)
        XCTAssertEqual(engine.rate, 1.5)
        engine.pause()
        XCTAssertEqual(engine.rate, 0)
        XCTAssertEqual(engine.timeControl, .paused)
    }

    func testAnExactSeekLandsOnItsTime() async throws {
        try await loadReady(seconds: 2)
        await engine.seek(to: 1.25, precision: .exact)
        XCTAssertEqual(engine.currentTime, 1.25, accuracy: 0.05)
    }

    /// The resume seek can come while the file is still opening; mpv can't seek until it has, so
    /// the seek waits for it instead of being dropped.
    func testASeekAskedForWhileLoadingLandsOnceLoaded() async throws {
        engine.load(PlaybackSource(url: try silence(seconds: 3)))
        XCTAssertFalse(engine.isItemReady)
        await engine.seek(to: 2, precision: .exact)
        XCTAssertTrue(engine.isItemReady)
        XCTAssertEqual(engine.currentTime, 2, accuracy: 0.05)
    }

    /// The saved quality preference arrives while the file opens; it's reported ready once, as it
    /// is when the cap reopens it (see `testACapOnAnotherVariantReopensTheStreamOnIt`).
    func testACapSetWhileLoadingReportsReadyOnce() async throws {
        var readyCount = 0
        let ready = expectation(description: "ready")
        engine.events.itemReady = {
            readyCount += 1
            ready.fulfill()
        }
        engine.load(PlaybackSource(url: try silence(seconds: 2)))
        engine.setPeakBitRate(1_000_000)
        await fulfillment(of: [ready], timeout: 10)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(readyCount, 1)
        XCTAssertTrue(engine.isItemReady)
        XCTAssertEqual(engine.duration ?? 0, 2, accuracy: 0.05)
    }

    func testASeekWithACompletionCallsIt() async throws {
        try await loadReady(seconds: 2)
        let done = expectation(description: "seeked")
        engine.seek(to: 0.5, precision: .within(0.5)) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 10)
    }

    func testPlayingToTheEndIsReported() async throws {
        try await loadReady(seconds: 0.5)
        let ended = expectation(description: "ended")
        engine.events.playedToEnd = { ended.fulfill() }
        engine.rate = 1
        await fulfillment(of: [ended], timeout: 10)
    }

    func testASecondLoadReplacesTheFirst() async throws {
        try await loadReady(seconds: 2)
        try await loadReady(seconds: 1)
        XCTAssertEqual(engine.duration ?? 0, 1, accuracy: 0.05)
    }

    func testVolumeIsKeptAsSet() {
        engine.volume = 0.25
        XCTAssertEqual(engine.volume, 0.25, accuracy: 0.001)
    }

    func testAFileWithOneAudioTrackOffersIt() async throws {
        try await loadReady(seconds: 1)
        if engine.audioOptions.isEmpty {
            let options = expectation(description: "options")
            options.assertForOverFulfill = false
            engine.events.audioOptionsChanged = { options.fulfill() }
            await fulfillment(of: [options], timeout: 10)
        }
        XCTAssertEqual(engine.audioOptions.count, 1)
    }

    // MARK: - Quality

    /// Loads `url` with the cap set as it opens, as the player does. Returns how often it was
    /// reported ready.
    @discardableResult
    private func loadReady(_ url: URL, cappedAt cap: Int?) async -> Int {
        var readyCount = 0
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = {
            readyCount += 1
            ready.fulfill()
        }
        engine.load(PlaybackSource(url: url))
        engine.setPeakBitRate(cap)
        await fulfillment(of: [ready], timeout: 10)
        // Long enough for a reopen to have fetched the stream again.
        try? await Task.sleep(nanoseconds: 500_000_000)
        return readyCount
    }

    /// The saved quality preference arrives while the stream opens. When it picks the variant
    /// mpv opens anyway — the highest, as it did on every stream in the logs — the stream is
    /// left be: reopening fetched all of it a second time, and every open took twice as long.
    func testACapOnTheVariantBeingOpenedDoesntFetchTheStreamAgain() async throws {
        let server = try await HLSServer.twoVariants()
        defer { server.stop() }
        await loadReady(server.url(of: "/master.m3u8"), cappedAt: 1_000_000)
        XCTAssertEqual(server.fetches(of: "/low.m3u8"), 1)
        XCTAssertEqual(engine.selectedAudioOption, 2, "on the high variant")
    }

    /// A cap on another variant reopens the stream on that one, and it's reported ready once.
    func testACapOnAnotherVariantReopensTheStreamOnIt() async throws {
        let server = try await HLSServer.twoVariants()
        defer { server.stop() }
        let readyCount = await loadReady(server.url(of: "/master.m3u8"), cappedAt: 600_000)
        XCTAssertEqual(engine.selectedAudioOption, 1, "on the low variant")
        XCTAssertEqual(readyCount, 1)
    }

    /// Choosing the quality already playing from the menu doesn't restart it either.
    func testACapOnTheVariantPlayingDoesntFetchTheStreamAgain() async throws {
        let server = try await HLSServer.twoVariants()
        defer { server.stop() }
        await loadReady(server.url(of: "/master.m3u8"), cappedAt: nil)
        engine.setPeakBitRate(1_000_000)
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(server.fetches(of: "/low.m3u8"), 1)
    }

    /// Choosing another quality from the menu reopens the stream on it.
    func testACapOnAnotherVariantOnceOpenReopensTheStreamOnIt() async throws {
        let server = try await HLSServer.twoVariants()
        defer { server.stop() }
        await loadReady(server.url(of: "/master.m3u8"), cappedAt: nil)
        let reopened = expectation(description: "reopened")
        reopened.assertForOverFulfill = false
        engine.events.itemReady = { reopened.fulfill() }
        engine.setPeakBitRate(600_000)
        await fulfillment(of: [reopened], timeout: 10)
        XCTAssertEqual(engine.selectedAudioOption, 1, "on the low variant")
    }

    // MARK: - Routing

    /// Stands in for the proxy: sends every source to a local file, and records what it was asked.
    final class FakeRouter: MPVRouter {
        var target: URL
        var routed: [URL] = []
        var released = 0
        var delay: UInt64 = 0
        init(target: URL) { self.target = target }
        func route(_ source: PlaybackSource) async -> PlaybackSource {
            routed.append(source.url)
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            return PlaybackSource(url: target)
        }
        func release() { released += 1 }
    }

    /// mpv plays what the router hands it, not the stream's own URL.
    func testARoutedSourceIsWhatPlays() async throws {
        let router = FakeRouter(target: try silence(seconds: 2))
        engine.stop()
        engine = MPVEngine(output: .none, router: router)
        let ready = expectation(description: "ready")
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: URL(string: "https://cdn.invalid/ep1.m3u8")!,
                                   headers: ["Referer": "https://site.invalid/"]))
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(router.routed, [URL(string: "https://cdn.invalid/ep1.m3u8")!])
        XCTAssertEqual(engine.duration ?? 0, 2, accuracy: 0.05)
    }

    /// A load that's replaced while its route is still being worked out never opens.
    func testASupersededRouteIsDropped() async throws {
        let first = try silence(seconds: 3)
        let router = FakeRouter(target: first)
        router.delay = 300_000_000
        engine.stop()
        engine = MPVEngine(output: .none, router: router)
        engine.load(PlaybackSource(url: URL(string: "https://cdn.invalid/ep1.m3u8")!))
        router.delay = 0
        router.target = try silence(seconds: 1)
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: URL(string: "https://cdn.invalid/ep2.m3u8")!))
        await fulfillment(of: [ready], timeout: 10)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(engine.duration ?? 0, 1, accuracy: 0.05, "the second episode is what's loaded")
    }

    func testStoppingReleasesTheRoute() throws {
        let router = FakeRouter(target: try silence(seconds: 1))
        engine.stop()
        engine = MPVEngine(output: .none, router: router)
        engine.load(PlaybackSource(url: URL(string: "https://cdn.invalid/ep1.m3u8")!))
        engine.stop()
        XCTAssertEqual(router.released, 1)
    }

    func testAStoppedEngineReportsNothing() throws {
        var heard = false
        engine.events.itemReady = { heard = true }
        engine.load(PlaybackSource(url: try silence(seconds: 1)))
        engine.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(heard)
    }
}

/// Serves files from memory over loopback, one request a connection, and counts what's asked of it.
final class HLSServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.hls-server")
    private let files: [String: Data]
    /// The paths asked for, in order. Only touched on `queue`.
    private var requested: [String] = []

    private init(listener: NWListener, files: [String: Data]) {
        self.listener = listener
        self.files = files
    }

    static func start(files: [String: Data]) async throws -> HLSServer {
        let server = HLSServer(listener: try NWListener(using: .tcp, on: .any), files: files)
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            var resumed = false
            server.listener.stateUpdateHandler = { state in
                guard case .ready = state, !resumed else { return }
                resumed = true
                ready.resume()
            }
            server.listener.newConnectionHandler = { [weak server] in server?.serve($0) }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    /// Two variants of two seconds of silence, at 500 and 1000 kb/s, in `/master.m3u8`. mpv
    /// numbers the low one's track 1 and the high one's 2.
    static func twoVariants() async throws -> HLSServer {
        let media = { (segment: String) in
            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n"
                + "#EXTINF:2.0,\n\(segment)\n#EXT-X-ENDLIST\n"
        }
        return try await start(files: [
            "/master.m3u8": Data(("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000\nlow.m3u8\n"
                + "#EXT-X-STREAM-INF:BANDWIDTH=1000000\nhigh.m3u8\n").utf8),
            "/low.m3u8": Data(media("low.wav").utf8),
            "/high.m3u8": Data(media("high.wav").utf8),
            "/low.wav": silentWAV(seconds: 2),
            "/high.wav": silentWAV(seconds: 2),
        ])
    }

    func url(of path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
    }

    func fetches(of path: String) -> Int {
        queue.sync { requested.filter { $0 == path }.count }
    }

    func stop() { listener.cancel() }

    /// `seconds` of 8 kHz 16-bit mono silence as a WAV file.
    static func silentWAV(seconds: Int) -> Data {
        let samples = 8_000 * seconds
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))       // PCM
        append(UInt16(1))       // mono
        append(UInt32(8_000))   // sample rate
        append(UInt32(16_000))  // bytes a second
        append(UInt16(2))       // bytes a frame
        append(UInt16(16))      // bits a sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(on: connection, buffered: Data())
    }

    private func readHead(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            var buffered = buffered
            if let data { buffered.append(data) }
            guard let head = String(data: buffered, encoding: .utf8), head.contains("\r\n\r\n") else {
                if isComplete || error != nil { connection.cancel() } else { readHead(on: connection, buffered: buffered) }
                return
            }
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            requested.append(path)
            let body = files[path]
            let type = path.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : "audio/wav"
            let response = "HTTP/1.1 \(body == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(type)\r\n"
                + "Content-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8) + (body ?? Data()), contentContext: .finalMessage,
                            isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// mpv's software output, which Picture in Picture shows: frames come while it's on, and going
/// back to the Metal layer carries on playing.
@MainActor
final class MPVSoftwareOutputTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() async throws {
        for file in files { try? FileManager.default.removeItem(at: file) }
        files = []
    }

    /// Counts frames delivered on the output's own queue.
    private final class FrameCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// An engine playing a ten-frames-a-second clip on its Metal layer, a second and a half in.
    private func playingEngine() async throws -> MPVEngine {
        let url = try await TestVideo.make(seconds: 20)
        files.append(url)
        let engine = MPVEngine(output: .metal)
        engine.layer.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        engine.layer.contentsScale = 2
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: url))
        await fulfillment(of: [ready], timeout: 10)
        engine.play()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        return engine
    }

    /// The longest the engine's clock stood still, sampled every 20 ms for `seconds`.
    private func longestStall(of engine: MPVEngine, over seconds: Double) async -> Double {
        var last = engine.currentTime, lastMove = Date(), longest = 0.0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if engine.currentTime != last {
                last = engine.currentTime
                lastMove = Date()
            }
            longest = max(longest, Date().timeIntervalSince(lastMove))
        }
        return longest
    }

    func testFramesComeWhileTheSoftwareOutputIsOn() async throws {
        let engine = try await playingEngine()
        defer { engine.stop() }
        let frames = FrameCount()
        XCTAssertNotNil(engine.beginSoftwareOutput { _ in frames.add() })
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertGreaterThan(frames.value, 10, "a ten-frames-a-second clip drew \(frames.value) in 2 s")
        engine.endSoftwareOutput()
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterEnd = frames.value
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(frames.value, afterEnd, "frames still came after the output ended")
    }

    /// THE BUG, part of the second's stall back from Picture in Picture: mpv seeks back to where it
    /// was by itself when its output changes, and the engine sent a seek of its own on top, so it
    /// flushed the sound and decoded its way back from the keyframe twice. Paused, the clock only
    /// ticks when playback restarts after a seek.
    func testGoingBackToMetalRestartsPlaybackOnce() async throws {
        let engine = try await playingEngine()
        defer { engine.stop() }
        XCTAssertNotNil(engine.beginSoftwareOutput { _ in })
        try await Task.sleep(nanoseconds: 1_500_000_000)
        engine.pause()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var restarts = 0
        engine.events.tick = { restarts += 1 }
        engine.endSoftwareOutput()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(restarts, 1)
    }

    /// The same going into Picture in Picture, where a second seek held up its first frame.
    func testMovingToSoftwareRestartsPlaybackOnce() async throws {
        let engine = try await playingEngine()
        defer { engine.stop() }
        engine.pause()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var restarts = 0
        engine.events.tick = { restarts += 1 }
        XCTAssertNotNil(engine.beginSoftwareOutput { _ in })
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(restarts, 1)
        engine.endSoftwareOutput()
    }

    /// Picture in Picture's layer has to stay up until the Metal layer has a picture again, or the
    /// picture flashes: the engine says when mpv shows its first frame back on Metal — paused too.
    func testGoingBackToMetalSaysWhenThePictureIsBack() async throws {
        let engine = try await playingEngine()
        defer { engine.stop() }
        XCTAssertNotNil(engine.beginSoftwareOutput { _ in })
        try await Task.sleep(nanoseconds: 1_500_000_000)
        engine.pause()
        try await Task.sleep(nanoseconds: 500_000_000)
        var restarted = false, shown = 0, shownAfterRestart = false
        engine.events.tick = { restarted = true }
        engine.endSoftwareOutput {
            shown += 1
            shownAfterRestart = restarted
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(shown, 1)
        XCTAssertTrue(shownAfterRestart, "told before mpv had drawn")
    }

    /// Picture in Picture closed from another app: back on Metal, mpv draws nothing till the app
    /// is back, so the picture isn't back till then either — and Picture in Picture's layer stays up.
    func testGoingBackToMetalInTheBackgroundIsShownOnlyOnReturn() async throws {
        let engine = try await playingEngine()
        defer { engine.stop() }
        XCTAssertNotNil(engine.beginSoftwareOutput { _ in })
        try await Task.sleep(nanoseconds: 1_000_000_000)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        var shown = 0
        engine.endSoftwareOutput { shown += 1 }
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(shown, 0, "told while nothing could be drawn")
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(shown, 1)
    }

    /// Back from Picture in Picture the picture flashed and playback stood still for a second,
    /// while mpv rebuilt its Metal output and decoded its way back to where it was.
    func testGoingBackToMetalKeepsTheClockMoving() async throws {
        let engine = try await playingEngine()
        defer { engine.stop() }
        XCTAssertNotNil(engine.beginSoftwareOutput { _ in })
        try await Task.sleep(nanoseconds: 2_000_000_000)
        engine.endSoftwareOutput()
        let stall = await longestStall(of: engine, over: 2)
        XCTAssertLessThan(stall, 0.35, "the clock stood still for \(String(format: "%.2f", stall)) s")
    }
}
