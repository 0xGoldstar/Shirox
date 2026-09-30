import XCTest
@testable import Shirox

/// Who draws the subtitles: the plain overlay, libass over AVPlayer, or mpv.
final class SubtitleRoutingTests: XCTestCase {

    private func route(_ engine: PlaybackEngineKind, _ loaded: SubtitleRouting.Loaded,
                       pickedExternal: Bool = false, pickedEmbedded: Int? = nil,
                       embeddedDefault: Int? = nil) -> SubtitleRoute {
        SubtitleRouting.route(engine: engine, loaded: loaded, pickedExternal: pickedExternal,
                              pickedEmbedded: pickedEmbedded, embeddedDefault: embeddedDefault)
    }

    /// Plain cues look the same on either engine: the overlay draws them.
    func testCuesAreTheOverlaysOnBothEngines() {
        XCTAssertEqual(route(.native, .cues), .cues)
        XCTAssertEqual(route(.mpv, .cues), .cues)
    }

    func testAnASSScriptIsDrawnByLibassOverAVPlayerAndByMPVItself() {
        XCTAssertEqual(route(.native, .ass), .assOverlay)
        XCTAssertEqual(route(.mpv, .ass), .mpvScript)
    }

    func testNothingLoadedIsNothingShown() {
        XCTAssertEqual(route(.native, .nothing), .none)
        XCTAssertEqual(route(.mpv, .nothing), .none)
    }

    /// The file's own track is timed to that exact release and keeps its styling.
    func testOnMPVTheFilesOwnTrackWinsUntilTheViewerPicks() {
        XCTAssertEqual(route(.mpv, .cues, embeddedDefault: 3), .mpvEmbedded(3))
        XCTAssertEqual(route(.mpv, .ass, embeddedDefault: 3), .mpvEmbedded(3))
        XCTAssertEqual(route(.mpv, .nothing, embeddedDefault: 3), .mpvEmbedded(3))
        XCTAssertEqual(route(.mpv, .cues, pickedExternal: true, embeddedDefault: 3), .cues)
        XCTAssertEqual(route(.mpv, .ass, pickedExternal: true, embeddedDefault: 3), .mpvScript)
    }

    func testAPickedTrackInTheFileIsShown() {
        XCTAssertEqual(route(.mpv, .cues, pickedEmbedded: 4, embeddedDefault: 3), .mpvEmbedded(4))
    }

    /// AVPlayer can't draw a file's own tracks; it never gets them.
    func testAVPlayerIgnoresTracksInTheFile() {
        XCTAssertEqual(route(.native, .cues, pickedEmbedded: 4, embeddedDefault: 3), .cues)
    }
}
