import SwiftUI

/// The Simkl browse grid's rules: the genres to offer, and the grid for one.
enum SimklBrowse {
    /// The genres in a list, most common first, then by name, at most `limit`.
    static func genres(in items: [SimklDiscoverItem], limit: Int = 20) -> [String] {
        var counts: [String: Int] = [:]
        for item in items {
            for genre in item.genres { counts[genre, default: 0] += 1 }
        }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map(\.key)
    }

    static func filter(_ items: [SimklDiscoverItem], genre: String?) -> [SimklDiscoverItem] {
        guard let genre else { return items }
        return items.filter { $0.genres.contains(genre) }
    }
}

@MainActor
final class SimklBrowseViewModel: ObservableObject {
    @Published var period: SimklFeedList.Period = .week
    @Published private(set) var genre: String?
    @Published private(set) var genres: [String] = []
    @Published private(set) var titles: [Media] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var items: [SimklDiscoverItem] = []
    private var list: SimklFeedList?
    private var tracker: ProviderType = .anilist
    private var map: [Int: Int] = [:]

    /// The top 500 most watched of a kind over the period — a free file, filtered on the device.
    func load(kind: MediaKind) async {
        let list = SimklFeedList.trending(kind, period)
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let raw = try await SimklFeedStore.shared.items(list, full: true)
            tracker = SimklDiscoverMedia.tracker
            map = await SimklDiscoverMedia.anilistMap(for: raw, kind: kind, tracker: tracker)
            guard !Task.isCancelled else { return }
            items = raw
            self.list = list
            genres = SimklBrowse.genres(in: raw)
            if let genre, !genres.contains(genre) { self.genre = nil }
            refilter()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            titles = []
        }
    }

    func choose(genre: String?) {
        self.genre = genre
        refilter()
    }

    private func refilter() {
        guard let list else { return }
        titles = SimklHomeRows.titles(list, SimklBrowse.filter(items, genre: genre), today: "",
                                      tracker: tracker, anilistForMAL: map)
    }
}

/// What Search shows on Simkl before anything's typed: the most watched of a kind, by period and
/// genre. Free — it's Simkl's trending file.
struct SimklBrowseView: View {
    @StateObject private var vm = SimklBrowseViewModel()
    @ObservedObject private var discovery = DiscoverySource.shared
    let columns: [GridItem]
    var recentSearches: [String] = []
    var onSelectRecent: (String) -> Void = { _ in }
    var onDeleteRecent: (String) -> Void = { _ in }
    var onClearRecents: () -> Void = {}

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !recentSearches.isEmpty {
                    RecentSearchesRow(queries: recentSearches, onSelect: onSelectRecent,
                                      onDelete: onDeleteRecent, onClear: onClearRecents)
                }
                filters

                if let message = vm.errorMessage, vm.titles.isEmpty {
                    ContentUnavailableView("Couldn't Load", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                        .padding(.top, 40)
                } else if vm.titles.isEmpty && vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(vm.titles, id: \.uniqueId) { media in
                            NavigationLink {
                                MediaDestination(media: media)
                            } label: {
                                AniListCardView(media: media)
                            }
                            .buttonStyle(CardPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }
            }
            .padding(.top, 4)
        }
        .task(id: "\(discovery.simklKind.rawValue)-\(vm.period.rawValue)") {
            await vm.load(kind: discovery.simklKind)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Trending")
                    .font(.title3.weight(.bold))
                Spacer()
                Menu {
                    Picker("Period", selection: $vm.period) {
                        ForEach(SimklFeedList.Period.allCases, id: \.self) { period in
                            Text(period.title).tag(period)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(vm.period.title)
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 16)

            SimklKindPicker(kind: $discovery.simklKind)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: "All", selected: vm.genre == nil) { vm.choose(genre: nil) }
                    ForEach(vm.genres, id: \.self) { name in
                        FilterChip(title: name, selected: vm.genre == name) { vm.choose(genre: name) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}
