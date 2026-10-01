import XCTest
@testable import Shirox

/// The subtitles button's menu: the everyday settings, with the rest in the sheet it opens.
@MainActor
final class PlayerSubtitleMenuTests: XCTestCase {

    private let english = SubtitleTrack(title: "English", url: URL(string: "https://example.com/en.vtt")!, headers: [:])
    private let spanish = SubtitleTrack(title: "Spanish", url: URL(string: "https://example.com/es.vtt")!, headers: [:])

    private final class Log {
        var enabled: Bool?
        var delay: Double?
        var fontSize: Double?
        var selected: SubtitleTrack??
        var embedded: Int?
        var imported = false
        var moreSettings = false
    }

    private func menu(enabled: Bool = true, delay: Double = 0, fontSize: Double = 24,
                      tracks: [SubtitleTrack] = [], selected: SubtitleTrack? = nil,
                      embedded: [PlaybackSubtitleOption] = [], selectedEmbedded: Int? = nil,
                      canImport: Bool = false, log: Log = Log()) -> [PlayerMenuElement] {
        PlayerSubtitleMenu.elements(
            enabled: enabled, delay: delay, fontSize: fontSize, tracks: tracks, selected: selected,
            embedded: embedded, selectedEmbedded: selectedEmbedded,
            actions: PlayerSubtitleMenu.Actions(
                setEnabled: { log.enabled = $0 },
                currentDelay: { log.delay ?? delay },
                setDelay: { log.delay = $0 },
                setFontSize: { log.fontSize = $0 },
                selectTrack: { log.selected = .some($0) },
                importFile: canImport ? { log.imported = true } : nil,
                moreSettings: { log.moreSettings = true },
                selectEmbedded: { log.embedded = $0 }))
    }

    // MARK: - Labels

    func testTheDelayReadsWithItsSign() {
        XCTAssertEqual(PlayerSubtitleMenu.delayLabel(0), "0.0s")
        XCTAssertEqual(PlayerSubtitleMenu.delayLabel(0.3), "+0.3s")
        XCTAssertEqual(PlayerSubtitleMenu.delayLabel(-1.2), "−1.2s")
        XCTAssertEqual(PlayerSubtitleMenu.delayLabel(-0.04), "0.0s", "No minus on a zero that rounds")
    }

    func testAStepLandsOnATenthWithNoCap() {
        XCTAssertEqual(PlayerSubtitleMenu.stepped(0.1, by: 0.2), 0.3)
        XCTAssertEqual(PlayerSubtitleMenu.stepped(4.8, by: 0.5), 5.3)
        XCTAssertEqual(PlayerSubtitleMenu.stepped(-4.9, by: -0.5), -5.4)
        XCTAssertEqual(PlayerSubtitleMenu.stepped(83, by: 5), 88)
        XCTAssertEqual(PlayerSubtitleMenu.stepped(-120, by: -1), -121)
    }

    func testALargeDelayStillReadsInSeconds() {
        XCTAssertEqual(PlayerSubtitleMenu.delayLabel(83.5), "+83.5s")
        XCTAssertEqual(PlayerSubtitleMenu.delayLabel(-600), "−600.0s")
    }

    func testATypedDelayReadsWithEitherMinusOrDecimalMark() {
        XCTAssertEqual(PlayerSubtitleMenu.parseDelay("83.5"), 83.5)
        XCTAssertEqual(PlayerSubtitleMenu.parseDelay("+2"), 2)
        XCTAssertEqual(PlayerSubtitleMenu.parseDelay("-1.26"), -1.3, "On a tenth, like the steps")
        XCTAssertEqual(PlayerSubtitleMenu.parseDelay("−0.4"), -0.4, "The minus sign the labels show")
        XCTAssertEqual(PlayerSubtitleMenu.parseDelay(" 1,5 s "), 1.5, "A comma decimal mark and a trailing unit")
    }

    func testATypedDelayThatIsntANumberIsRefused() {
        XCTAssertNil(PlayerSubtitleMenu.parseDelay(""))
        XCTAssertNil(PlayerSubtitleMenu.parseDelay("abc"))
        XCTAssertNil(PlayerSubtitleMenu.parseDelay("1.2.3"))
        XCTAssertNil(PlayerSubtitleMenu.parseDelay("inf"), "Double() reads this as infinity")
        XCTAssertNil(PlayerSubtitleMenu.parseDelay("nan"))
    }

    func testTheSizeReadsAsItsPresetOrItsPoints() {
        XCTAssertEqual(PlayerSubtitleMenu.sizeLabel(24), "Medium")
        XCTAssertEqual(PlayerSubtitleMenu.sizeLabel(36), "Extra Large")
        XCTAssertEqual(PlayerSubtitleMenu.sizeLabel(27), "27 pt", "A size set with the sheet's slider")
    }

    // MARK: - Rows

    func testShowSubtitlesComesFirstAndToggles() {
        let log = Log()
        let first = Self.items(in: menu(enabled: true, log: log)).first
        XCTAssertEqual(first?.title, "Show Subtitles")
        XCTAssertEqual(first?.isOn, true)
        first?.action()
        XCTAssertEqual(log.enabled, false)
    }

    func testTheTracksAreListedWithTheChosenOneChecked() {
        let log = Log()
        let elements = menu(tracks: [english, spanish], selected: spanish, log: log)
        XCTAssertEqual(Self.item("Default", in: elements)?.isOn, false)
        XCTAssertEqual(Self.item("English", in: elements)?.isOn, false)
        XCTAssertEqual(Self.item("Spanish", in: elements)?.isOn, true)

        Self.item("English", in: elements)?.action()
        XCTAssertEqual(log.selected, .some(english))
        Self.item("Default", in: elements)?.action()
        XCTAssertEqual(log.selected, .some(nil))
    }

    func testNoTrackListWithoutTracks() {
        XCTAssertNil(Self.item("Default", in: menu(tracks: [])))
    }

    /// A file's own tracks get their own section; the one on screen is checked.
    func testTheFilesOwnTracksAreListed() {
        let log = Log()
        let embedded = [PlaybackSubtitleOption(id: 3, title: "English"), PlaybackSubtitleOption(id: 4, title: "Signs")]
        let elements = menu(tracks: [english], embedded: embedded, selectedEmbedded: 3, log: log)
        let fileTracks = Self.section("In This Video", in: elements)
        XCTAssertEqual(Self.item("English", in: fileTracks)?.isOn, true)
        XCTAssertEqual(Self.item("Signs", in: fileTracks)?.isOn, false)
        XCTAssertEqual(Self.item("Default", in: elements)?.isOn, false, "something's on screen")
        Self.item("Signs", in: fileTracks)?.action()
        XCTAssertEqual(log.embedded, 4)
    }

    func testNoFileSectionWithoutTracksInTheFile() {
        XCTAssertTrue(Self.section("In This Video", in: menu(tracks: [english])).isEmpty)
    }

    func testTheDelayStepsKeepTheMenuOpenAndReset() {
        let log = Log()
        let elements = menu(delay: 1.2, log: log)
        guard case let .submenu(title, value, children)? = Self.submenu("Delay", in: elements) else {
            return XCTFail("No Delay submenu")
        }
        XCTAssertEqual(title, "Delay")
        XCTAssertEqual(value, "+1.2s")

        let steps = Self.items(in: children)
        XCTAssertEqual(steps.map(\.title),
                       ["−5.0s", "−1.0s", "−0.5s", "−0.1s", "+0.1s", "+0.5s", "+1.0s", "+5.0s", "Reset"])
        XCTAssertTrue(steps.dropLast().allSatisfy(\.keepsMenuOpen))
        steps[5].action()   // +0.5s
        XCTAssertEqual(log.delay, 1.7)
        steps[8].action()   // Reset
        XCTAssertEqual(log.delay, 0)
    }

    /// The menu stays open between steps, so a step reads the delay when tapped, not when built.
    func testStepsInARowAddUp() {
        let log = Log()
        guard case let .submenu(_, _, children)? = Self.submenu("Delay", in: menu(delay: 1.2, log: log)) else {
            return XCTFail("No Delay submenu")
        }
        let plusATenth = Self.items(in: children)[4]
        plusATenth.action()
        plusATenth.action()
        XCTAssertEqual(log.delay, 1.4)
    }

    func testTheMenuStepsPastFiveSeconds() {
        let log = Log()
        guard case let .submenu(_, _, children)? = Self.submenu("Delay", in: menu(delay: 4.8, log: log)) else {
            return XCTFail("No Delay submenu")
        }
        Self.item("+5.0s", in: children)?.action()
        XCTAssertEqual(log.delay, 9.8)
    }

    func testTheSizesAreChecked() {
        let log = Log()
        guard case let .submenu(_, value, children)? = Self.submenu("Size", in: menu(fontSize: 30, log: log)) else {
            return XCTFail("No Size submenu")
        }
        XCTAssertEqual(value, "Large")
        let sizes = Self.items(in: children)
        XCTAssertEqual(sizes.map(\.title), ["Small", "Medium", "Large", "Extra Large"])
        XCTAssertEqual(sizes.map(\.isOn), [false, false, true, false])
        sizes[0].action()
        XCTAssertEqual(log.fontSize, 18)
    }

    func testImportIsOfferedOnlyWhenItCanBeDone() {
        XCTAssertNil(Self.item("Import Subtitle File…", in: menu(canImport: false)))
        let log = Log()
        Self.item("Import Subtitle File…", in: menu(canImport: true, log: log))?.action()
        XCTAssertTrue(log.imported)
    }

    func testTheLastRowOpensTheSheet() {
        let log = Log()
        let last = Self.items(in: menu(tracks: [english], canImport: true, log: log)).last
        XCTAssertEqual(last?.title, "More Settings…")
        last?.action()
        XCTAssertTrue(log.moreSettings)
    }

    // MARK: - Helpers

    /// Every row, in order, through sections and submenus.
    private static func items(in elements: [PlayerMenuElement]) -> [PlayerMenuItem] {
        elements.flatMap { element -> [PlayerMenuItem] in
            switch element {
            case .item(let item): return [item]
            case .section(_, let children), .submenu(_, _, let children): return items(in: children)
            }
        }
    }

    private static func item(_ title: String, in elements: [PlayerMenuElement]) -> PlayerMenuItem? {
        items(in: elements).first { $0.title == title }
    }

    /// The rows of the top-level section with this heading; empty if there's none.
    private static func section(_ heading: String, in elements: [PlayerMenuElement]) -> [PlayerMenuElement] {
        for case .section(let title, let children) in elements where title == heading { return children }
        return []
    }

    private static func submenu(_ title: String, in elements: [PlayerMenuElement]) -> PlayerMenuElement? {
        for element in elements {
            switch element {
            case .item: continue
            case .submenu(let t, _, _) where t == title: return element
            case .section(_, let children), .submenu(_, _, let children):
                if let found = submenu(title, in: children) { return found }
            }
        }
        return nil
    }
}

#if os(iOS)
import UIKit

/// The native menu a player menu button builds from its rows.
@MainActor
final class PlayerMenuUIKitTests: XCTestCase {

    func testSectionsAreInlineSubmenusNestAndStepsKeepTheMenuOpen() {
        let elements: [PlayerMenuElement] = [
            .item(PlayerMenuItem(title: "Show", isOn: true) {}),
            .section("Track", [.item(PlayerMenuItem(title: "English", isOn: false) {})]),
            .submenu(title: "Delay", value: "+0.3s", [
                .item(PlayerMenuItem(title: "+0.1s", keepsMenuOpen: true) {}),
            ]),
        ]
        let built = PlayerMenuButton.uiElements(elements, refresh: {})

        let show = built[0] as? UIAction
        XCTAssertEqual(show?.title, "Show")
        XCTAssertEqual(show?.state, .on)

        let section = built[1] as? UIMenu
        XCTAssertEqual(section?.title, "Track")
        XCTAssertTrue(section?.options.contains(.displayInline) ?? false)

        let delay = built[2] as? UIMenu
        XCTAssertEqual(delay?.title, "Delay")
        XCTAssertEqual(delay?.subtitle, "+0.3s")
        XCTAssertFalse(delay?.options.contains(.displayInline) ?? true)
        if #available(iOS 16, *) {
            let step = delay?.children.first as? UIAction
            XCTAssertTrue(step?.attributes.contains(.keepsMenuPresented) ?? false)
        }
    }

    func testTheMenuKeepsItsOldRows() {
        let built = PlayerMenuButton.uiElements([.item(PlayerMenuItem(title: "1.5×", isOn: false) {})], refresh: {})
        XCTAssertEqual((built.first as? UIAction)?.title, "1.5×")
        if #available(iOS 16, *) {
            XCTAssertEqual((built.first as? UIAction)?.attributes.contains(.keepsMenuPresented), false)
        }
    }
}
#endif
