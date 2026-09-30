import XCTest
import AVFoundation
@testable import Shirox

/// Which engine plays a stream, and what happens when one fails.
final class PlaybackFallbackTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: - Starting engine

    func testTheChosenEngineIsUsed() {
        XCTAssertEqual(PlaybackFallback.initialEngine(preferred: .native, url: url("https://cdn.example/ep1.m3u8")), .native)
        XCTAssertEqual(PlaybackFallback.initialEngine(preferred: .mpv, url: url("https://cdn.example/ep1.m3u8")), .mpv)
    }

    /// Containers AVPlayer can't open go straight to MPV, whatever the setting says.
    func testAFileAVPlayerCantOpenStartsOnMPV() {
        XCTAssertEqual(PlaybackFallback.initialEngine(preferred: .native, url: url("https://cdn.example/ep1.mkv")), .mpv)
        XCTAssertEqual(PlaybackFallback.initialEngine(preferred: .native, url: url("file:///tmp/Episode%201.MKV")), .mpv)
        XCTAssertEqual(PlaybackFallback.initialEngine(preferred: .native, url: url("https://cdn.example/a.webm?token=1")), .mpv)
        XCTAssertEqual(PlaybackFallback.initialEngine(preferred: .native, url: url("https://cdn.example/ep1.mp4")), .native)
    }

    // MARK: - Format errors

    private func avError(_ code: AVError.Code) -> NSError {
        NSError(domain: AVFoundationErrorDomain, code: code.rawValue)
    }

    func testAVFoundationsFormatErrorsAreRecognised() {
        for code in [AVError.fileFormatNotRecognized, .failedToParse, .decodeFailed, .decoderNotFound, .formatUnsupported] {
            XCTAssertTrue(PlaybackFallback.isUnsupportedFormat(avError(code)), "\(code)")
        }
    }

    func testOtherErrorsAreNotFormatErrors() {
        XCTAssertFalse(PlaybackFallback.isUnsupportedFormat(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        XCTAssertFalse(PlaybackFallback.isUnsupportedFormat(avError(.contentIsUnavailable)))
        XCTAssertFalse(PlaybackFallback.isUnsupportedFormat(nil))
    }

    /// AVFoundation often wraps the real reason one or two levels down.
    func testAFormatErrorUnderneathAnotherIsFound() {
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: -1, userInfo: [
                NSUnderlyingErrorKey: avError(.fileFormatNotRecognized),
            ]),
        ])
        XCTAssertTrue(PlaybackFallback.isUnsupportedFormat(wrapped))
    }

    // MARK: - Decisions

    private let network = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse)

    func testNativeOnAFormatErrorSwitchesToMPVAtOnce() {
        XCTAssertEqual(PlaybackFallback.decision(after: avError(.fileFormatNotRecognized), engine: .native,
                                                 canRefetch: true, hasRefetched: false), .switchToMPV)
    }

    func testNativeOnAnyOtherFailureRefetchesFirst() {
        XCTAssertEqual(PlaybackFallback.decision(after: network, engine: .native,
                                                 canRefetch: true, hasRefetched: false), .refetch)
    }

    /// A fresh URL that fails too, or one there's no way to get, is MPV's turn.
    func testNativeAfterARefetchOrWithoutOneSwitchesToMPV() {
        XCTAssertEqual(PlaybackFallback.decision(after: network, engine: .native,
                                                 canRefetch: true, hasRefetched: true), .switchToMPV)
        XCTAssertEqual(PlaybackFallback.decision(after: network, engine: .native,
                                                 canRefetch: false, hasRefetched: false), .switchToMPV)
    }

    func testMPVRefetchesOnceThenGivesUp() {
        XCTAssertEqual(PlaybackFallback.decision(after: network, engine: .mpv,
                                                 canRefetch: true, hasRefetched: false), .refetch)
        XCTAssertEqual(PlaybackFallback.decision(after: network, engine: .mpv,
                                                 canRefetch: true, hasRefetched: true), .giveUp)
        XCTAssertEqual(PlaybackFallback.decision(after: network, engine: .mpv,
                                                 canRefetch: false, hasRefetched: false), .giveUp)
    }

    // MARK: - Waiting

    /// mpv gives up on a dead source by itself, so while it's opening a stream the wait is left
    /// to it: a far-away server took 15 s, and Retry came up just before it would have played.
    func testMPVOpeningIsLeftToFinish() {
        XCTAssertTrue(PlaybackFallback.waitIsOpening(engine: .mpv, isItemReady: false, isItemFailed: false))
        XCTAssertFalse(PlaybackFallback.waitIsOpening(engine: .mpv, isItemReady: true, isItemFailed: false))
        XCTAssertFalse(PlaybackFallback.waitIsOpening(engine: .mpv, isItemReady: false, isItemFailed: true))
        XCTAssertNotNil(PlaybackFallback.openingPatience(for: .mpv))
    }

    /// AVPlayer can wait forever on a wedged request, so its waits stay the watchdog's.
    func testAVPlayerOpeningIsStillWatched() {
        XCTAssertFalse(PlaybackFallback.waitIsOpening(engine: .native, isItemReady: false, isItemFailed: false))
        XCTAssertNil(PlaybackFallback.openingPatience(for: .native))
    }

    /// A wait is a stall only if nothing moved: a moved playhead is a seek landing, a grown
    /// buffer a slow connection catching up.
    func testAWaitIsAStallOnlyIfNothingMoved() {
        XCTAssertTrue(PlaybackFallback.isStalled(playheadMoved: 0, bufferGrew: 0))
        XCTAssertTrue(PlaybackFallback.isStalled(playheadMoved: 0.2, bufferGrew: 0.2))
        XCTAssertFalse(PlaybackFallback.isStalled(playheadMoved: 0, bufferGrew: 3))
        XCTAssertFalse(PlaybackFallback.isStalled(playheadMoved: 12, bufferGrew: 0))
        XCTAssertFalse(PlaybackFallback.isStalled(playheadMoved: -12, bufferGrew: 0))
    }
}
