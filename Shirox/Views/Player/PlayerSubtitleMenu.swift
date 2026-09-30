import Foundation

/// The subtitles button's menu. A menu can't hold the sheet's sliders or colour picker, so it
/// carries the everyday settings — on or off, the track, the delay and the size — and its last
/// row opens the sheet for the rest.
@MainActor
enum PlayerSubtitleMenu {

    struct Actions {
        var setEnabled: (Bool) -> Void
        /// Read when a step is tapped: the menu stays open between steps, so the delay it was
        /// built with may be out of date.
        var currentDelay: () -> Double
        var setDelay: (Double) -> Void
        var setFontSize: (Double) -> Void
        var selectTrack: (SubtitleTrack?) -> Void
        /// nil when the video can't take a file — only a local or downloaded one can.
        var importFile: (() -> Void)?
        var moreSettings: () -> Void
        /// A track inside the file, by its number.
        var selectEmbedded: (Int) -> Void = { _ in }
    }

    static let delaySteps: [Double] = [-5, -1, -0.5, -0.1, 0.1, 0.5, 1, 5]
    static let sizes: [(name: String, points: Double)] = [
        ("Small", 18), ("Medium", 24), ("Large", 30), ("Extra Large", 36),
    ]

    /// - Parameters:
    ///   - selected: the downloadable track on screen, if one is.
    ///   - embedded: the subtitle tracks inside the file, which only MPV draws.
    ///   - selectedEmbedded: the track inside the file on screen, if one is.
    static func elements(enabled: Bool, delay: Double, fontSize: Double, tracks: [SubtitleTrack],
                         selected: SubtitleTrack?, embedded: [PlaybackSubtitleOption] = [],
                         selectedEmbedded: Int? = nil, actions: Actions) -> [PlayerMenuElement] {
        var elements: [PlayerMenuElement] = [
            .item(PlayerMenuItem(title: "Show Subtitles", isOn: enabled) { actions.setEnabled(!enabled) }),
        ]

        if !tracks.isEmpty {
            let isDefault = selected == nil && selectedEmbedded == nil
            let rows = [PlayerMenuItem(title: "Default", isOn: isDefault) { actions.selectTrack(nil) }]
                + tracks.map { track in
                    PlayerMenuItem(title: track.title, isOn: selected?.id == track.id) { actions.selectTrack(track) }
                }
            elements.append(.section("Track", rows.map(PlayerMenuElement.item)))
        }

        if !embedded.isEmpty {
            let rows = embedded.map { option in
                PlayerMenuElement.item(PlayerMenuItem(title: option.title, isOn: selectedEmbedded == option.id) {
                    actions.selectEmbedded(option.id)
                })
            }
            elements.append(.section("In This Video", rows))
        }

        let steps = delaySteps.map { step in
            PlayerMenuElement.item(PlayerMenuItem(title: delayLabel(step), keepsMenuOpen: true) {
                actions.setDelay(stepped(actions.currentDelay(), by: step))
            })
        }
        let delayMenu = PlayerMenuElement.submenu(title: "Delay", value: delayLabel(delay), [
            .section("Currently \(delayLabel(delay))", steps),
            .item(PlayerMenuItem(title: "Reset") { actions.setDelay(0) }),
        ])
        let sizeMenu = PlayerMenuElement.submenu(title: "Size", value: sizeLabel(fontSize), sizes.map { size in
            .item(PlayerMenuItem(title: size.name, isOn: fontSize == size.points) { actions.setFontSize(size.points) })
        })
        elements.append(.section(nil, [delayMenu, sizeMenu]))

        var last: [PlayerMenuElement] = []
        if let importFile = actions.importFile {
            last.append(.item(PlayerMenuItem(title: "Import Subtitle File…", action: importFile)))
        }
        last.append(.item(PlayerMenuItem(title: "More Settings…", action: actions.moreSettings)))
        elements.append(.section(nil, last))
        return elements
    }

    /// "+0.3s", "−1.2s", or "0.0s" — to the tenth, as the sheet shows it.
    static func delayLabel(_ seconds: Double) -> String {
        let tenths = (seconds * 10).rounded()
        guard tenths != 0 else { return "0.0s" }
        return (tenths > 0 ? "+" : "−") + String(format: "%.1f", abs(tenths) / 10) + "s"
    }

    /// The delay after a step, on a tenth. There's no cap: subtitles timed for another cut of
    /// the episode can be a whole recap or opening out.
    static func stepped(_ delay: Double, by step: Double) -> Double {
        ((delay + step) * 10).rounded() / 10
    }

    /// A delay typed into the sheet: "83.5", "-2", "−0.4" or "1,5", with or without a trailing
    /// "s". On a tenth like the steps; nil for anything that isn't a finite number.
    static func parseDelay(_ text: String) -> Double? {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: ".")
        if cleaned.hasSuffix("s") {
            cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return (value * 10).rounded() / 10
    }

    /// The preset's name, or the points of a size set with the sheet's slider.
    static func sizeLabel(_ points: Double) -> String {
        sizes.first { $0.points == points }?.name ?? "\(Int(points.rounded())) pt"
    }
}
