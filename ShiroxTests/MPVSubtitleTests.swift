import XCTest
import AVFoundation
@testable import Shirox

/// mpv drawing subtitles: the tracks inside a file, and ASS scripts handed to it.
@MainActor
final class MPVSubtitleTests: XCTestCase {

    /// Two seconds of silence with two ASS tracks: "English" (default) and "Signs". Made with
    /// ffmpeg: `-f lavfi -t 2 -i anullsrc=r=8000:cl=mono -i en.ass -i signs.ass -map 0:a -map 1
    /// -map 2 -c:a libopus -b:a 6k -c:s ass`, titles and default disposition set per track.
    private static let mkv = Data(base64Encoded: "GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAMexFNm3TAv4TA8tN1TbuLU6uEFUmpZlOsgaFNu4tTq4QWVK5rU6yB7027jFOrhBJUw2dTrIIF7U27jFOrhBxTu2tTrIIMP+wBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsm/hOyy4TAq17GDD0JATYCMTGF2ZjYxLjcuMTAwV0GMTGF2ZjYxLjcuMTAwc6SQ3lpLkHgwEnoCiwEj7hSXqUSJiECfYAAAAAAAFlSua0T4v4SGJozhrgEAAAAAAABg14EBc8WI6aswKRJg/OScgQAitZyDdW5kiIEAhoZBX09QVVNWqoNjLqBWu4QExLQAg4EC4ZGfgQG1iEC/QAAAAAAAYmSBEFXugQBjopNPcHVzSGVhZAEBOAFAHwAAAAAArgEAAAAAAAI714ECc8WIt+vNGdqJPRucgQBTbodFbmdsaXNoIrWcg2VuZ4aKU19URVhUL0FTU4OBEVXugQBjokICW1NjcmlwdCBJbmZvXQpTY3JpcHRUeXBlOiB2NC4wMCsKUGxheVJlc1g6IDY0MApQbGF5UmVzWTogMzYwCgpbVjQrIFN0eWxlc10KRm9ybWF0OiBOYW1lLCBGb250bmFtZSwgRm9udHNpemUsIFByaW1hcnlDb2xvdXIsIFNlY29uZGFyeUNvbG91ciwgT3V0bGluZUNvbG91ciwgQmFja0NvbG91ciwgQm9sZCwgSXRhbGljLCBVbmRlcmxpbmUsIFN0cmlrZU91dCwgU2NhbGVYLCBTY2FsZVksIFNwYWNpbmcsIEFuZ2xlLCBCb3JkZXJTdHlsZSwgT3V0bGluZSwgU2hhZG93LCBBbGlnbm1lbnQsIE1hcmdpbkwsIE1hcmdpblIsIE1hcmdpblYsIEVuY29kaW5nClN0eWxlOiBEZWZhdWx0LEhlbHZldGljYSwzMiwmSDAwRkZGRkZGLCZIMDAwMDAwRkYsJkgwMDAwMDAwMCwmSDAwMDAwMDAwLDAsMCwwLDAsMTAwLDEwMCwwLDAsMSwyLDAsMiwxMCwxMCwyMCwxCgpbRXZlbnRzXQpGb3JtYXQ6IExheWVyLCBTdGFydCwgRW5kLCBTdHlsZSwgTmFtZSwgTWFyZ2luTCwgTWFyZ2luUiwgTWFyZ2luViwgRWZmZWN0LCBUZXh0Cq4BAAAAAAACPNeBA3PFiBRDVdqjUGR6nIEAU26FU2lnbnMitZyDZW5niIEAhopTX1RFWFQvQVNTg4ERVe6BAGOiQgJbU2NyaXB0IEluZm9dClNjcmlwdFR5cGU6IHY0LjAwKwpQbGF5UmVzWDogNjQwClBsYXlSZXNZOiAzNjAKCltWNCsgU3R5bGVzXQpGb3JtYXQ6IE5hbWUsIEZvbnRuYW1lLCBGb250c2l6ZSwgUHJpbWFyeUNvbG91ciwgU2Vjb25kYXJ5Q29sb3VyLCBPdXRsaW5lQ29sb3VyLCBCYWNrQ29sb3VyLCBCb2xkLCBJdGFsaWMsIFVuZGVybGluZSwgU3RyaWtlT3V0LCBTY2FsZVgsIFNjYWxlWSwgU3BhY2luZywgQW5nbGUsIEJvcmRlclN0eWxlLCBPdXRsaW5lLCBTaGFkb3csIEFsaWdubWVudCwgTWFyZ2luTCwgTWFyZ2luUiwgTWFyZ2luViwgRW5jb2RpbmcKU3R5bGU6IERlZmF1bHQsSGVsdmV0aWNhLDMyLCZIMDBGRkZGRkYsJkgwMDAwMDBGRiwmSDAwMDAwMDAwLCZIMDAwMDAwMDAsMCwwLDAsMCwxMDAsMTAwLDAsMCwxLDIsMCwyLDEwLDEwLDIwLDEKCltFdmVudHNdCkZvcm1hdDogTGF5ZXIsIFN0YXJ0LCBFbmQsIFN0eWxlLCBOYW1lLCBNYXJnaW5MLCBNYXJnaW5SLCBNYXJnaW5WLCBFZmZlY3QsIFRleHQKElTDZ0Euv4Q3t6Afc3OfY8CAZ8iZRaOHRU5DT0RFUkSHjExhdmY2MS43LjEwMHNz12PAi2PFiOmrMCkSYPzkZ8iiRaOHRU5DT0RFUkSHlUxhdmM2MS4xOS4xMDEgbGlib3B1c2fIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDIuMDA4MDAwMDAwAHNz02PAi2PFiLfrzRnaiT0bZ8ieRaOHRU5DT0RFUkSHkUxhdmM2MS4xOS4xMDEgYXNzZ8ihRaOIRFVSQVRJT05Eh5MwMDowMDowMi4wMDAwMDAwMDAAc3PTY8CLY8WIFENV2qNQZHpnyJ5Fo4dFTkNPREVSRIeRTGF2YzYxLjE5LjEwMSBhc3NnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAyLjAwMDAwMDAwMAAfQ7Z1RRi/hGsc6dDngQCji4EAAIAIC+Y7I6tgoKOhnYIAAAAwLDAsRGVmYXVsdCwsMCwwLDAsLEhlbGxvm4IH0KCioZyDAAAAMCwwLERlZmF1bHQsLDAsMCwwLCxTSUdOm4IH0KOKgQAVgAgIrLMOxqOKgQApgAgIrLMOxqOKgQA9gAgIrLMOxqOKgQBRgAgIrLMOxqOKgQBlgAgIrLMOxqOKgQB5gAgIrLMOxqOKgQCNgAgIrLMOxqOKgQChgAgIrLMOxqOKgQC1gAgIrLMOxqOKgQDJgAgIrLMOxqOKgQDdgAgIrLMOxqOKgQDxgAgIrLMOxqOKgQEFgAgIrLMOxqOKgQEZgAgIrLMOxqOKgQEtgAgIrLMOxqOKgQFBgAgIrLMOxqOKgQFVgAgIrLMOxqOKgQFpgAgIrLMOxqOKgQF9gAgIrLMOxqOKgQGRgAgIrLMOxqOKgQGlgAgIrLMOxqOKgQG5gAgIrLMOxqOKgQHNgAgIrLMOxqOKgQHhgAgIrLMOxqOKgQH1gAgIrLMOxqOKgQIJgAgIrLMOxqOKgQIdgAgIrLMOxqOKgQIxgAgIrLMOxqOKgQJFgAgIrLMOxqOKgQJZgAgIrLMOxqOKgQJtgAgIrLMOxqOKgQKBgAgIrLMOxqOKgQKVgAgIrLMOxqOKgQKpgAgIrLMOxqOKgQK9gAgIrLMOxqOKgQLRgAgIrLMOxqOKgQLlgAgIrLMOxqOKgQL5gAgIrLMOxqOKgQMNgAgIrLMOxqOKgQMhgAgIrLMOxqOKgQM1gAgIrLMOxqOKgQNJgAgIrLMOxqOKgQNdgAgIrLMOxqOKgQNxgAgIrLMOxqOKgQOFgAgIrLMOxqOKgQOZgAgIrLMOxqOKgQOtgAgIrLMOxqOKgQPBgAgIrLMOxqOKgQPVgAgIrLMOxqOKgQPpgAgIrLMOxqOKgQP9gAgIrLMOxqOKgQQRgAgIrLMOxqOKgQQlgAgIrLMOxqOKgQQ5gAgIrLMOxqOKgQRNgAgIrLMOxqOKgQRhgAgIrLMOxqOKgQR1gAgIrLMOxqOKgQSJgAgIrLMOxqOKgQSdgAgIrLMOxqOKgQSxgAgIrLMOxqOKgQTFgAgIrLMOxqOKgQTZgAgIrLMOxqOKgQTtgAgIrLMOxqOKgQUBgAgIrLMOxqOKgQUVgAgIrLMOxqOKgQUpgAgIrLMOxqOKgQU9gAgIrLMOxqOKgQVRgAgIrLMOxqOKgQVlgAgIrLMOxqOKgQV5gAgIrLMOxqOKgQWNgAgIrLMOxqOKgQWhgAgIrLMOxqOKgQW1gAgIrLMOxqOKgQXJgAgIrLMOxqOKgQXdgAgIrLMOxqOKgQXxgAgIrLMOxqOKgQYFgAgIrLMOxqOKgQYZgAgIrLMOxqOKgQYtgAgIrLMOxqOKgQZBgAgIrLMOxqOKgQZVgAgIrLMOxqOKgQZpgAgIrLMOxqOKgQZ9gAgIrLMOxqOKgQaRgAgIrLMOxqOKgQalgAgIrLMOxqOKgQa5gAgIrLMOxqOKgQbNgAgIrLMOxqOKgQbhgAgIrLMOxqOKgQb1gAgIrLMOxqOKgQcJgAgIrLMOxqOKgQcdgAgIrLMOxqOKgQcxgAgIrLMOxqOKgQdFgAgIrLMOxqOKgQdZgAgIrLMOxqOKgQdtgAgIrLMOxqOKgQeBgAgIrLMOxqOKgQeVgAgIrLMOxqOKgQepgAgIrLMOxqOKgQe9gAgIrLMOxqCToYqBB9EACAissw7GdaKEAM3+YBxTu2u3v4TnV2AMu6+zgQC3iveBAfGCByHwgQm3jveBAvGCByHwgRayggfQt473gQPxggch8IE7soIH0A==")!

    private let script = """
    [Script Info]
    ScriptType: v4.00+

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,Hello
    """

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

    private func mkvFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-sub-\(UUID().uuidString).mkv")
        try Self.mkv.write(to: url)
        files.append(url)
        return url
    }

    private func silence() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mpv-sub-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200)!
        buffer.frameLength = 88_200
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        files.append(url)
        return url
    }

    private func load(_ url: URL) async {
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: url))
        await fulfillment(of: [ready], timeout: 10)
    }

    private func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    func testTheFilesOwnTracksAreListedWithItsDefault() async throws {
        await load(try mkvFile())
        let listed = await waitUntil { self.engine.subtitleOptions.count == 2 }
        XCTAssertTrue(listed)
        XCTAssertEqual(engine.subtitleOptions.map(\.title), ["English", "Signs"])
        XCTAssertEqual(engine.defaultSubtitleOption, engine.subtitleOptions.first?.id)
    }

    /// Nothing is drawn until the player says what to draw.
    func testNothingIsShownUntilAsked() async throws {
        await load(try mkvFile())
        XCTAssertNil(engine.shownSubtitleTrack)
    }

    func testAPickedTrackInTheFileIsShown() async throws {
        await load(try mkvFile())
        _ = await waitUntil { self.engine.subtitleOptions.count == 2 }
        let signs = try XCTUnwrap(engine.subtitleOptions.last).id
        engine.showSubtitles(.embedded(signs))
        XCTAssertEqual(engine.shownSubtitleTrack?.id, signs)
        XCTAssertEqual(engine.shownSubtitleTrack?.isExternal, false)
        engine.showSubtitles(.none)
        XCTAssertNil(engine.shownSubtitleTrack)
    }

    func testAnASSScriptIsHandedToMPV() async throws {
        await load(try silence())
        engine.showSubtitles(.script(script))
        let shown = await waitUntil { self.engine.shownSubtitleTrack?.isExternal == true }
        XCTAssertTrue(shown)
        XCTAssertTrue(engine.subtitleOptions.isEmpty, "a script isn't one of the file's own tracks")
    }

    /// Asked for while the file is still opening, it's drawn once the file has opened.
    func testAScriptAskedForWhileOpeningIsShownOnceOpen() async throws {
        let ready = expectation(description: "ready")
        ready.assertForOverFulfill = false
        engine.events.itemReady = { ready.fulfill() }
        engine.load(PlaybackSource(url: try silence()))
        engine.showSubtitles(.script(script))
        await fulfillment(of: [ready], timeout: 10)
        let shown = await waitUntil { self.engine.shownSubtitleTrack?.isExternal == true }
        XCTAssertTrue(shown)
    }

    /// A quality change reopens the stream; the script comes back with it.
    func testTheScriptSurvivesAReload() async throws {
        await load(try silence())
        engine.showSubtitles(.script(script))
        _ = await waitUntil { self.engine.shownSubtitleTrack?.isExternal == true }
        let reopened = expectation(description: "reopened")
        reopened.assertForOverFulfill = false
        engine.events.itemReady = { reopened.fulfill() }
        engine.setPeakBitRate(1_000_000)
        await fulfillment(of: [reopened], timeout: 10)
        let back = await waitUntil { self.engine.shownSubtitleTrack?.isExternal == true }
        XCTAssertTrue(back)
    }
}
