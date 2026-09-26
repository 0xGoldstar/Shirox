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
    }

    /// The sheet's slider range.
    static let delayRange: ClosedRange<Double> = -5...5
    static let delaySteps: [Double] = [-0.5, -0.1, 0.1, 0.5]
    static let sizes: [(name: String, points: Double)] = [
        ("Small", 18), ("Medium", 24), ("Large", 30), ("Extra Large", 36),
    ]

    static func elements(enabled: Bool, delay: Double, fontSize: Double, tracks: [SubtitleTrack],
                         selected: SubtitleTrack?, actions: Actions) -> [PlayerMenuElement] {
        var elements: [PlayerMenuElement] = [
            .item(PlayerMenuItem(title: "Show Subtitles", isOn: enabled) { actions.setEnabled(!enabled) }),
        ]

        if !tracks.isEmpty {
            let rows = [PlayerMenuItem(title: "Default", isOn: selected == nil) { actions.selectTrack(nil) }]
                + tracks.map { track in
                    PlayerMenuItem(title: track.title, isOn: selected?.id == track.id) { actions.selectTrack(track) }
                }
            elements.append(.section("Track", rows.map(PlayerMenuElement.item)))
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

    /// The delay after a step, on a tenth and within the sheet's range.
    static func stepped(_ delay: Double, by step: Double) -> Double {
        let value = ((delay + step) * 10).rounded() / 10
        return min(max(value, delayRange.lowerBound), delayRange.upperBound)
    }

    /// The preset's name, or the points of a size set with the sheet's slider.
    static func sizeLabel(_ points: Double) -> String {
        sizes.first { $0.points == points }?.name ?? "\(Int(points.rounded())) pt"
    }
}
