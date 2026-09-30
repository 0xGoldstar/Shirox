import XCTest
@testable import Shirox

/// Where AVPlayer's picture sits on screen, so styled subtitles line up with it.
final class VideoFrameTests: XCTestCase {

    private let video = CGSize(width: 1920, height: 1080)

    func testFitShowsTheWholePictureCentred() {
        let rect = VideoFrame.rect(videoSize: video, in: CGRect(x: 0, y: 0, width: 390, height: 844), filled: false)
        XCTAssertEqual(rect.width, 390, accuracy: 0.01)
        XCTAssertEqual(rect.height, 219.375, accuracy: 0.01)
        XCTAssertEqual(rect.midY, 422, accuracy: 0.01)
    }

    func testFillCoversTheScreenAndOverhangs() {
        let rect = VideoFrame.rect(videoSize: video, in: CGRect(x: 0, y: 0, width: 844, height: 390), filled: true)
        XCTAssertEqual(rect.width, 844, accuracy: 0.01)
        XCTAssertEqual(rect.height, 474.75, accuracy: 0.01)
        XCTAssertLessThan(rect.minY, 0)
    }

    func testAnUnknownSizeTakesTheWholeView() {
        let bounds = CGRect(x: 0, y: 0, width: 844, height: 390)
        XCTAssertEqual(VideoFrame.rect(videoSize: .zero, in: bounds, filled: false), bounds)
    }
}
