import XCTest
import AVFoundation
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

    /// The saved quality preference arrives while the file opens; mpv reopens it with the cap
    /// and only then reports it ready, once.
    func testACapSetWhileLoadingReloadsThenReportsReadyOnce() async throws {
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
