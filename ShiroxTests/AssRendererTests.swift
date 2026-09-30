import XCTest
import CoreGraphics
@testable import Shirox

/// libass drawing an ASS script: where the line lands, when it's there, and at what size.
final class AssRendererTests: XCTestCase {

    /// One bottom-centred line from 1 s to 3 s, on a 640×360 canvas.
    private let script = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica,32,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Hello there
    """

    private let canvas = CGSize(width: 640, height: 360)

    private func frame(_ rendered: AssRenderer.Rendered) -> AssFrame? {
        if case .frame(let frame) = rendered { return frame }
        return nil
    }

    /// Sum of the image's alpha, drawn into a bitmap: something visible was drawn.
    private func coverage(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + Int(pixels[$1]) }
    }

    func testALineOnScreenIsDrawnAtTheBottomMiddle() throws {
        let renderer = try XCTUnwrap(AssRenderer(script: script))
        let drawn = try XCTUnwrap(frame(renderer.render(at: 2, frameSize: canvas)), "nothing drawn")
        XCTAssertGreaterThan(coverage(drawn.image), 0)
        XCTAssertGreaterThan(drawn.rect.width, 40)
        XCTAssertGreaterThan(drawn.rect.minY, canvas.height / 2, "in the lower half")
        XCTAssertLessThanOrEqual(drawn.rect.maxY, canvas.height)
        XCTAssertEqual(drawn.rect.midX, canvas.width / 2, accuracy: 30, "centred")
    }

    func testNothingIsDrawnOutsideTheLinesTime() throws {
        let renderer = try XCTUnwrap(AssRenderer(script: script))
        guard case .frame(nil) = renderer.render(at: 5, frameSize: canvas) else { return XCTFail("drew at 5 s") }
    }

    /// The overlay redraws every screen refresh; an unchanged frame costs nothing.
    func testAnUnchangedFrameSaysSo() throws {
        let renderer = try XCTUnwrap(AssRenderer(script: script))
        XCTAssertNotNil(frame(renderer.render(at: 2, frameSize: canvas)))
        guard case .unchanged = renderer.render(at: 2.02, frameSize: canvas) else { return XCTFail() }
        XCTAssertNotNil(frame(renderer.render(at: 2.02, frameSize: canvas, force: true)))
    }

    func testTheLineScalesWithThePicture() throws {
        let renderer = try XCTUnwrap(AssRenderer(script: script))
        let small = try XCTUnwrap(frame(renderer.render(at: 2, frameSize: canvas)))
        let big = try XCTUnwrap(frame(renderer.render(at: 2, frameSize: CGSize(width: 1280, height: 720))))
        XCTAssertEqual(big.rect.width / small.rect.width, 2, accuracy: 0.3)
    }

    /// The viewer's subtitle size scales the script's own sizes.
    func testTheFontScaleResizesTheLine() throws {
        let renderer = try XCTUnwrap(AssRenderer(script: script))
        let normal = try XCTUnwrap(frame(renderer.render(at: 2, frameSize: canvas)))
        let larger = try XCTUnwrap(frame(renderer.render(at: 2, frameSize: canvas, fontScale: 1.5)))
        XCTAssertGreaterThan(larger.rect.width, normal.rect.width * 1.3)
    }
}
