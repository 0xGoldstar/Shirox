#if os(iOS)
import XCTest
import AVFoundation
import UIKit
@testable import Shirox

/// mpv's picture after the view changes size — a rotation, a window resize. MPVKit's renderer
/// reads the layer's size only when it sets up its video output, so the picture used to stay
/// at the old size, small in one corner of the rotated screen.
@MainActor
final class MPVResizeTests: XCTestCase {

    private var files: [URL] = []

    override func tearDown() async throws {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    func testTheLayersDrawableFollowsItsSizeInPixels() {
        let layer = MPVMetalLayer()
        layer.contentsScale = 2
        var resized = 0
        layer.onResize = { resized += 1 }
        layer.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(layer.drawableSize, CGSize(width: 800, height: 600))
        layer.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        XCTAssertEqual(layer.drawableSize, CGSize(width: 600, height: 800))
        layer.frame = CGRect(x: 10, y: 10, width: 300, height: 400)
        XCTAssertEqual(resized, 2, "a move isn't a resize")
    }

    func testThePictureFollowsARotation() async throws {
        try await rotate(paused: false)
    }

    /// Paused, the rebuilt output still has to show the frame it's paused on.
    func testThePictureFollowsARotationWhilePaused() async throws {
        try await rotate(paused: true)
    }

    private func rotate(paused: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.isHidden = false
        defer { window.isHidden = true }

        let engine = MPVEngine()
        defer { engine.stop() }
        let host = MPVLayerHostView(hosting: engine.layer)
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        window.addSubview(host)
        host.layoutIfNeeded()

        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: try await makeVideo(seconds: 6)))
        await fulfillment(of: [ready], timeout: 10)
        engine.play()

        let landscape = engine.layer.drawableSize
        let drewLandscape = await waitUntil(10) { self.matches(engine.videoOutputSize, landscape) }
        XCTAssertTrue(drewLandscape, "drew at \(String(describing: engine.videoOutputSize)), not \(landscape)")
        if paused { engine.pause() }

        host.frame = CGRect(x: 0, y: 0, width: 180, height: 320)
        host.layoutIfNeeded()
        let portrait = CGSize(width: landscape.height, height: landscape.width)
        XCTAssertEqual(engine.layer.drawableSize, portrait)
        let drewPortrait = await waitUntil(10) { self.matches(engine.videoOutputSize, portrait) }
        XCTAssertTrue(drewPortrait, "still drawing at \(String(describing: engine.videoOutputSize)) after rotating to \(portrait)")
    }

    private func matches(_ size: CGSize?, _ target: CGSize) -> Bool {
        guard let size else { return false }
        return abs(size.width - target.width) <= 2 && abs(size.height - target.height) <= 2
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    /// An H.264 clip of changing grey frames, ten a second.
    private func makeVideo(seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-\(UUID().uuidString).mp4")
        files.append(url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(40 + frame * 3 % 200), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
        return url
    }
}
#endif
