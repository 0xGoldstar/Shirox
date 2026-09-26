import SwiftUI

/// One row in a player pull-down menu. `isOn` renders the system checkmark; `action` applies it.
struct PlayerMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let isOn: Bool
    /// Leaves the menu open after the tap, for stepping a value (iOS 16+; it closes before that).
    let keepsMenuOpen: Bool
    let action: () -> Void

    init(title: String, isOn: Bool = false, keepsMenuOpen: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.keepsMenuOpen = keepsMenuOpen
        self.action = action
    }
}

/// A row, a group of rows between separators, or a submenu in a player pull-down menu.
indirect enum PlayerMenuElement {
    case item(PlayerMenuItem)
    /// Rows shown in place, set apart by separators, under an optional heading.
    case section(String?, [PlayerMenuElement])
    /// A row opening its own menu; `value` shows the current setting beside the title.
    case submenu(title: String, value: String?, [PlayerMenuElement])
}

/// Native-menu button label, described declaratively so it can be rendered as a UIButton
/// label (iOS) or a SwiftUI label (macOS) without hosting a SwiftUI view inside UIKit.
enum PlayerMenuLabel {
    case symbol(String, size: CGFloat, weight: PlayerMenuWeight)
    case text(String, size: CGFloat, weight: PlayerMenuWeight)
}

enum PlayerMenuWeight { case medium, semibold, heavy }

// MARK: - iOS: UIKit-backed native menu
//
// Why UIKit instead of SwiftUI `Menu`: the player body repaints ~2×/sec (the periodic time
// observer rewrites currentTime/duration/bufferProgress). A SwiftUI `Menu` dismisses-and-
// re-presents (flashes) every time its ancestor re-renders while open. A UIKit `UIMenu` is
// owned by UIKit once presented, so SwiftUI re-rendering the wrapper never disturbs it —
// `updateUIView` only refreshes the label and never touches `button.menu`.
#if os(iOS)
import UIKit

struct PlayerMenuButton: UIViewRepresentable {
    let menuTitle: String
    let label: PlayerMenuLabel
    /// Rebuilt on every open (via an uncached deferred element) so checkmarks reflect current state.
    let elements: () -> [PlayerMenuElement]
    /// Fired the moment the menu is about to display — used to pin the controls open.
    var onOpen: () -> Void = {}

    init(menuTitle: String, label: PlayerMenuLabel, items: @escaping () -> [PlayerMenuItem],
         onOpen: @escaping () -> Void = {}) {
        self.init(menuTitle: menuTitle, label: label,
                  elements: { items().map(PlayerMenuElement.item) }, onOpen: onOpen)
    }

    init(menuTitle: String, label: PlayerMenuLabel, elements: @escaping () -> [PlayerMenuElement],
         onOpen: @escaping () -> Void = {}) {
        self.menuTitle = menuTitle
        self.label = label
        self.elements = elements
        self.onOpen = onOpen
    }

    func makeCoordinator() -> Coordinator { Coordinator(elements: elements, onOpen: onOpen) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.tintColor = .white
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        context.coordinator.apply(label, to: button)
        context.coordinator.button = button

        // Build the menu ONCE. The uncached deferred element re-runs its provider on every
        // open, so items stay fresh without ever reassigning `button.menu` (which would flash).
        let coordinator = context.coordinator
        let deferred = UIDeferredMenuElement.uncached { [weak coordinator] completion in
            completion(coordinator?.menuElements() ?? [])
            // Defer the state mutation out of the menu-build pass to avoid re-entrancy.
            DispatchQueue.main.async { coordinator?.onOpen() }
        }
        button.menu = UIMenu(title: menuTitle, children: [deferred])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.elements = elements
        context.coordinator.onOpen = onOpen
        context.coordinator.apply(label, to: button) // refresh (e.g. the speed label text)
    }

    /// The native rows for `elements`. `refresh` runs after a row that keeps the menu open.
    static func uiElements(_ elements: [PlayerMenuElement], refresh: @escaping () -> Void) -> [UIMenuElement] {
        elements.map { element -> UIMenuElement in
            switch element {
            case .item(let item):
                let action = UIAction(title: item.title, state: item.isOn ? .on : .off) { _ in
                    item.action()
                    if item.keepsMenuOpen { refresh() }
                }
                if item.keepsMenuOpen, #available(iOS 16, *) { action.attributes.insert(.keepsMenuPresented) }
                return action
            case let .section(title, children):
                return UIMenu(title: title ?? "", options: .displayInline,
                              children: uiElements(children, refresh: refresh))
            case let .submenu(title, value, children):
                return UIMenu(title: title, subtitle: value, identifier: submenuIdentifier(title),
                              children: uiElements(children, refresh: refresh))
            }
        }
    }

    /// Stable, so an open submenu can be found again in a rebuilt menu.
    private static func submenuIdentifier(_ title: String) -> UIMenu.Identifier {
        UIMenu.Identifier("shirox.player.menu.\(title)")
    }

    fileprivate static func submenu(_ identifier: UIMenu.Identifier, in elements: [UIMenuElement]) -> UIMenu? {
        for case let menu as UIMenu in elements {
            if menu.identifier == identifier { return menu }
            if let found = submenu(identifier, in: menu.children) { return found }
        }
        return nil
    }

    final class Coordinator {
        var elements: () -> [PlayerMenuElement]
        var onOpen: () -> Void
        weak var button: UIButton?
        init(elements: @escaping () -> [PlayerMenuElement], onOpen: @escaping () -> Void) {
            self.elements = elements
            self.onOpen = onOpen
        }

        func menuElements() -> [UIMenuElement] {
            PlayerMenuButton.uiElements(elements(), refresh: { [weak self] in self?.refreshVisibleMenu() })
        }

        /// A row that keeps the menu open changed a value the open submenu shows; show it anew.
        private func refreshVisibleMenu() {
            guard #available(iOS 16, *), let interaction = button?.contextMenuInteraction else { return }
            let fresh = menuElements()
            interaction.updateVisibleMenu { visible in
                guard let match = PlayerMenuButton.submenu(visible.identifier, in: fresh) else { return visible }
                return visible.replacingChildren(match.children)
            }
        }

        func apply(_ label: PlayerMenuLabel, to button: UIButton) {
            switch label {
            case let .symbol(name, size, weight):
                let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: weight.symbolWeight)
                button.setImage(UIImage(systemName: name, withConfiguration: cfg), for: .normal)
                button.setTitle(nil, for: .normal)
            case let .text(text, size, weight):
                button.setImage(nil, for: .normal)
                button.setTitle(text, for: .normal)
                button.setTitleColor(.white, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: size, weight: weight.fontWeight)
            }
        }
    }
}

private extension PlayerMenuWeight {
    var symbolWeight: UIImage.SymbolWeight {
        switch self { case .medium: return .medium; case .semibold: return .semibold; case .heavy: return .heavy }
    }
    var fontWeight: UIFont.Weight {
        switch self { case .medium: return .medium; case .semibold: return .semibold; case .heavy: return .heavy }
    }
}

// MARK: - macOS: SwiftUI Menu fallback
//
// macOS pull-down menus don't suffer the same re-render flash, and the player's auto-hide is
// iOS-only, so a plain SwiftUI `Menu` is sufficient here.
#else

struct PlayerMenuButton: View {
    let menuTitle: String
    let label: PlayerMenuLabel
    let elements: () -> [PlayerMenuElement]
    var onOpen: () -> Void = {}

    init(menuTitle: String, label: PlayerMenuLabel, items: @escaping () -> [PlayerMenuItem],
         onOpen: @escaping () -> Void = {}) {
        self.init(menuTitle: menuTitle, label: label,
                  elements: { items().map(PlayerMenuElement.item) }, onOpen: onOpen)
    }

    init(menuTitle: String, label: PlayerMenuLabel, elements: @escaping () -> [PlayerMenuElement],
         onOpen: @escaping () -> Void = {}) {
        self.menuTitle = menuTitle
        self.label = label
        self.elements = elements
        self.onOpen = onOpen
    }

    var body: some View {
        Menu {
            PlayerMenuContent(elements: elements())
        } label: {
            labelView
        }
        .menuStyle(.borderlessButton)
    }

    @ViewBuilder private var labelView: some View {
        switch label {
        case let .symbol(name, size, weight):
            Image(systemName: name).font(.system(size: size, weight: weight.font)).foregroundStyle(.white)
        case let .text(text, size, weight):
            Text(text).font(.system(size: size, weight: weight.font)).foregroundStyle(.white)
        }
    }
}

/// A menu's rows, sections and submenus as SwiftUI menu content.
private struct PlayerMenuContent: View {
    let elements: [PlayerMenuElement]

    var body: some View {
        ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
            switch element {
            case .item(let item):
                Button {
                    item.action()
                } label: {
                    if item.isOn { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                }
            case let .section(title, children):
                Section {
                    PlayerMenuContent(elements: children)
                } header: {
                    if let title { Text(title) }
                }
            case let .submenu(title, value, children):
                Menu {
                    PlayerMenuContent(elements: children)
                } label: {
                    Text(value.map { "\(title): \($0)" } ?? title)
                }
            }
        }
    }
}

private extension PlayerMenuWeight {
    var font: Font.Weight {
        switch self { case .medium: return .medium; case .semibold: return .semibold; case .heavy: return .heavy }
    }
}

#endif
