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

    /// Whether a pill shows its name beside its icon.
    ///
    /// Four named pills measure 407 pt, and a 375-pt iPhone has 343 pt for the row — which can't
    /// scroll (see `body`). So with four, a service's pill shows only its icon unless it is the
    /// one selected; the widest case, AniList selected, is 322 pt.
    static func showsName(of source: LibrarySource, selected: Bool, pillCount: Int) -> Bool {
        source == .local || selected || pillCount < 4
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
        // NOTE: a plain HStack (not a horizontal ScrollView) — a horizontal ScrollView above the
        // Library's List would steal the `.searchable` bar's scroll-view association and break it
        // across navigation. `showsName` keeps four pills inside the narrowest iPhone instead.
        let sources = self.sources
        if sources.count > 1 {
            HStack(spacing: 8) {
                ForEach(sources, id: \.self) { source in
                    let active = isSelected(source)
                    pill(source, selected: active,
                         showsName: Self.showsName(of: source, selected: active, pillCount: sources.count)) {
                        if let type = source.providerToSelect {
                            ProviderManager.shared.selectProvider(type)
                        }
                        onSelect(source)
                    }
                }
                Spacer()
            }
            // No internal horizontal padding — call sites supply the 16pt inset (matching
            // `filterCapsuleRow`) so the pills sit flush-left with the List button + search bar.
            .padding(.vertical, 8)
        }
    }

    /// Short labels keep the row on one line; the icon identifies the service. "MyAnimeList" is
    /// the only name wide enough to force a wrap.
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
            serviceIcon(ProviderType.simkl.iconURL)
        case .provider(let type):
            serviceIcon(type.iconURL)
        }
    }

    private func serviceIcon(_ url: String) -> some View {
        CachedAsyncImage(urlString: url)
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func pill(_ source: LibrarySource, selected: Bool, showsName: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                icon(for: source)
                if showsName {
                    Text(title(for: source))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(selected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(selected ? Color.primary.opacity(0.3) : Color.clear, lineWidth: 1))
            .foregroundStyle(selected ? Color.primary : .secondary)
        }
        .buttonStyle(.plain)
        // An icon-only pill still has a name for VoiceOver.
        .accessibilityLabel(Text(title(for: source)))
    }
}
