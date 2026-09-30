import XCTest
import AVFoundation
@testable import Shirox

/// The AVPlayer engine against real files: silent audio of a known length, written for each test.
@MainActor
final class AVPlayerEngineTests: XCTestCase {

    private var engine: AVPlayerEngine!
    private var files: [URL] = []

    override func setUp() async throws {
        engine = AVPlayerEngine()
    }

    override func tearDown() async throws {
        engine.stop()
        engine = nil
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// `seconds` of silence as a CAF file.
    private func silence(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString).caf")
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

    /// Loads a file and waits for it to be ready.
    private func loadReady(seconds: Double) async throws {
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: try silence(seconds: seconds)))
        await fulfillment(of: [ready], timeout: 5)
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
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertTrue(engine.isItemFailed)
    }

    func testPlayingReportsPlayingAndTheClockTicks() async throws {
        try await loadReady(seconds: 2)
        let playing = expectation(description: "playing")
        playing.assertForOverFulfill = false
        let ticked = expectation(description: "ticked")
        ticked.assertForOverFulfill = false
        engine.events.timeControlChanged = { if $0 == .playing { playing.fulfill() } }
        engine.events.tick = { ticked.fulfill() }
        engine.rate = 1
        await fulfillment(of: [playing, ticked], timeout: 5)
        engine.pause()
        XCTAssertEqual(engine.timeControl, .paused)
        XCTAssertEqual(engine.rate, 0)
    }

    func testAnExactSeekLandsOnItsTime() async throws {
        try await loadReady(seconds: 2)
        await engine.seek(to: 1.25, precision: .exact)
        XCTAssertEqual(engine.currentTime, 1.25, accuracy: 0.02)
    }

    func testASeekWithACompletionCallsIt() async throws {
        try await loadReady(seconds: 2)
        let done = expectation(description: "seeked")
        engine.seek(to: 0.5, precision: .within(0.5)) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
    }

    func testPlayingToTheEndIsReported() async throws {
        try await loadReady(seconds: 0.5)
        let ended = expectation(description: "ended")
        engine.events.playedToEnd = { ended.fulfill() }
        engine.rate = 1
        await fulfillment(of: [ended], timeout: 5)
    }

    /// A swap replaces the item, as `replaceCurrentItem(with:)` did.
    func testASecondLoadReplacesTheFirst() async throws {
        try await loadReady(seconds: 2)
        try await loadReady(seconds: 1)
        XCTAssertEqual(engine.duration ?? 0, 1, accuracy: 0.05)
    }

    func testTheBitrateCapReachesTheItemAndNilLiftsIt() throws {
        engine.load(PlaybackSource(url: try silence(seconds: 1)))
        engine.setPeakBitRate(2_000_000)
        XCTAssertEqual(engine.player.currentItem?.preferredPeakBitRate, 2_000_000)
        engine.setPeakBitRate(nil)
        XCTAssertEqual(engine.player.currentItem?.preferredPeakBitRate, 0)
    }

    func testStallMinimisationAndVolumePassThrough() {
        engine.waitsToMinimizeStalling = false
        XCTAssertFalse(engine.player.automaticallyWaitsToMinimizeStalling)
        engine.volume = 0.25
        XCTAssertEqual(engine.player.volume, 0.25)
    }

    /// A plain audio file offers no choice of language, so there's nothing to pick.
    func testAFileWithoutAlternativesOffersNoAudioOptions() async throws {
        try await loadReady(seconds: 1)
        XCTAssertTrue(engine.audioOptions.isEmpty)
        XCTAssertNil(engine.selectedAudioOption)
    }

    /// After `stop()` nothing reaches the old listener — the next `setupPlayer()` owns the screen.
    func testAStoppedEngineReportsNothing() throws {
        var heard = false
        engine.events.itemReady = { heard = true }
        engine.load(PlaybackSource(url: try silence(seconds: 1)))
        engine.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(heard)
    }
}
