#if os(iOS)
import XCTest
import UIKit
@testable import Shirox

/// The ASS overlay over AVPlayer's picture: it draws the script as the picture plays, where the
/// script puts it within the picture, in Fit and in Fill.
@MainActor
final class PlayerAssOverlayTests: XCTestCase {

    /// One bottom-centred line for the first ten seconds, laid out on the clip's own 320×180.
    private let script = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 320
    PlayResY: 180

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica,16,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,Hello there
    """

    private var engine: AVPlayerEngine!
    private var window: UIWindow!
    private var files: [URL] = []

    override func setUp() async throws {
        engine = AVPlayerEngine()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        window.isHidden = false
    }

    override func tearDown() async throws {
        engine.stop()
        engine = nil
        window.isHidden = true
        window = nil
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    private func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func playingOverlay(filled: Bool) async throws -> AssOverlayView {
        let video = try await TestVideo.make(seconds: 10)
        files.append(video)
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: video))
        engine.play()
        await fulfillment(of: [ready], timeout: 10)

        let overlay = AssOverlayView(frame: window.bounds)
        window.addSubview(overlay)
        overlay.driver.update(script: script, engine: engine, filled: filled, visible: true, delay: 0, fontScale: 1)
        let drawn = await waitUntil { overlay.driver.layer.contents != nil }
        XCTAssertTrue(drawn, "the overlay never drew the line")
        return overlay
    }

    /// Fit: the 16:9 picture sits 400×225 in the middle of 400×300, and the line at its bottom.
    func testTheLineSitsAtTheBottomOfThePicture() async throws {
        let overlay = try await playingOverlay(filled: false)
        let picture = VideoFrame.rect(videoSize: engine.presentationSize, in: overlay.bounds, filled: false)
        let line = overlay.driver.layer.frame
        XCTAssertTrue(picture.contains(line), "\(line) isn't inside the picture \(picture)")
        XCTAssertGreaterThan(line.midY, picture.midY)
        XCTAssertEqual(line.midX, picture.midX, accuracy: 20)
        overlay.stop()
    }

    /// Fill crops the picture's top and bottom off screen; the line moves down with it.
    func testFillMovesTheLineWithThePicture() async throws {
        let overlay = try await playingOverlay(filled: false)
        let fitted = overlay.driver.layer.frame
        overlay.driver.update(script: script, engine: engine, filled: true, visible: true, delay: 0, fontScale: 1)
        let moved = await waitUntil { overlay.driver.layer.frame.maxY > fitted.maxY + 10 }
        XCTAssertTrue(moved, "still at \(overlay.driver.layer.frame) after filling")
        overlay.stop()
    }

    func testTurningSubtitlesOffHidesTheLine() async throws {
        let overlay = try await playingOverlay(filled: false)
        overlay.driver.update(script: script, engine: engine, filled: false, visible: false, delay: 0, fontScale: 1)
        XCTAssertTrue(overlay.driver.layer.isHidden)
        overlay.stop()
    }
}
#endif
