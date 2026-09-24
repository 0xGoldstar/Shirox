import SwiftUI

/// Capsule-pill switcher for the Library tab. Always shows the local "My Library" pill,
/// plus a pill for each signed-in service. Hidden when only one source exists (logged out:
/// local-only) so a lone pill isn't shown.
struct LibrarySourceSwitcher: View {
    let selected: LibrarySource
    let onSelect: (LibrarySource) -> Void

    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var simklAuth = SimklAuthManager.shared
    @ObservedObject private var manager = ProviderManager.shared

    /// The pills, in order: My Library, then each signed-in service.
    static func sources(anilist: Bool, mal: Bool, simkl: Bool) -> [LibrarySource] {
        var result: [LibrarySource] = [.local]
        if anilist { result.append(.provider(.anilist)) }
        if mal { result.append(.provider(.mal)) }
        if simkl { result.append(.simkl) }
        return result
    }

    private var sources: [LibrarySource] {
        Self.sources(anilist: anilistAuth.isLoggedIn, mal: malAuth.isLoggedIn, simkl: simklAuth.isLoggedIn)
    }

    /// A provider pill is highlighted when a provider's list is on screen and it is the active
    /// primary provider — driven by `ProviderManager`, the same store the data source reads. My
    /// Library and Simkl are highlighted when they are the source.
    private func isSelected(_ source: LibrarySource) -> Bool {
        switch source {
        case .local, .simkl:
            return selected == source
        case .provider(let type):
            guard case .provider = selected else { return false }
            return manager.primary?.providerType == type
        }
    }

    var body: some View {
        // Only render when there's a real choice.
        // Scrolls sideways so every pill keeps its name. It must never be the first scroll view on
        // screen: iOS then attaches the Library's `.searchable` bar to it instead of the List, and
        // opening a show tears the bar down (b49f014). On iOS `LibraryView` keeps this row inside
        // its List in every state for that reason.
        let sources = self.sources
        if sources.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sources, id: \.self) { source in
                        pill(source, selected: isSelected(source)) {
                            if let type = source.providerToSelect {
                                ProviderManager.shared.selectProvider(type)
                            }
                            onSelect(source)
                        }
                    }
                }
                // The 16pt inset lives inside the scroll view, so the first pill lines up with
                // `filterCapsuleRow` and the row still scrolls to the screen's edges. Call sites
                // add no horizontal padding.
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    /// Short labels keep the pills compact; the icon identifies the service.
    private func title(for source: LibrarySource) -> String {
        switch source {
        case .local:              return "My Library"
        case .simkl:              return ProviderType.simkl.displayName
        case .provider(.mal):     return "MAL"
        case .provider(let type): return type.displayName
        }
    }

    @ViewBuilder
    private func icon(for source: LibrarySource) -> some View {
        switch source {
        case .local:
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
        case .simkl:
            // Simkl's icon is a dark tile with a see-through "S": on a dark background both
            // vanish, so it sits on white.
            serviceIcon(ProviderType.simkl.iconURL, backing: .white)
        case .provider(let type):
            serviceIcon(type.iconURL)
        }
    }

    private func serviceIcon(_ url: String, backing: Color = .clear) -> some View {
        CachedAsyncImage(urlString: url)
            .frame(width: 16, height: 16)
            .background(backing)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func pill(_ source: LibrarySource, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                icon(for: source)
                Text(title(for: source))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(selected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(selected ? Color.primary.opacity(0.3) : Color.clear, lineWidth: 1))
            .foregroundStyle(selected ? Color.primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}
