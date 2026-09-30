import XCTest
@testable import Shirox

/// How the player's settings and a stream's headers are written as mpv options.
final class MPVOptionsTests: XCTestCase {

    func testHeadersBecomeOneFieldListInKeyOrder() {
        let headers = ["X-Token": "abc", "Accept": "*/*"]
        XCTAssertEqual(MPVOptions.headerFields(headers), "Accept: */*,X-Token: abc")
    }

    /// mpv splits the list on commas, so one inside a value must be escaped.
    func testACommaInAValueIsEscaped() {
        XCTAssertEqual(MPVOptions.headerFields(["Accept-Language": "en-US,en;q=0.9"]),
                       #"Accept-Language: en-US\,en;q=0.9"#)
    }

    /// The user agent and referrer have options of their own.
    func testTheUserAgentAndReferrerAreLeftToTheirOwnOptions() {
        let headers = ["user-agent": "Safari", "Referer": "https://site.example/", "Cookie": "a=1"]
        XCTAssertEqual(MPVOptions.headerFields(headers), "Cookie: a=1")
        XCTAssertEqual(MPVOptions.userAgent(headers), "Safari")
        XCTAssertEqual(MPVOptions.referrer(headers), "https://site.example/")
        XCTAssertNil(MPVOptions.userAgent([:]))
    }

    func testSeekPrecisionBecomesSeekFlags() {
        XCTAssertEqual(MPVOptions.seekFlags(.fast), "absolute+keyframes")
        XCTAssertEqual(MPVOptions.seekFlags(.exact), "absolute+exact")
        XCTAssertEqual(MPVOptions.seekFlags(.within(0.5)), "absolute")
    }

    func testABitrateCapOrNone() {
        XCTAssertEqual(MPVOptions.hlsBitrate(nil), "max")
        XCTAssertEqual(MPVOptions.hlsBitrate(2_500_000), "2500000")
    }

    /// The overlay shows a cue at `time + delay`, so positive is sooner; mpv's positive is later.
    func testTheSubtitleDelayFlipsSign() {
        XCTAssertEqual(MPVOptions.subDelay(fromOverlayDelay: 1.5), -1.5)
        XCTAssertEqual(MPVOptions.subDelay(fromOverlayDelay: -83.5), 83.5)
    }

    func testVolumeIsAPercentage() {
        XCTAssertEqual(MPVOptions.volume(0.25), 25)
        XCTAssertEqual(MPVOptions.volume(1), 100)
    }

    /// The viewer's size is points on a 24-point base; mpv scales its own drawing by the ratio.
    func testTheSubtitleSizeBecomesAScale() {
        XCTAssertEqual(MPVOptions.subScale(fontSize: 24), 1)
        XCTAssertEqual(MPVOptions.subScale(fontSize: 36), 1.5)
        XCTAssertEqual(MPVOptions.subScale(fontSize: 18), 0.75)
    }
}
