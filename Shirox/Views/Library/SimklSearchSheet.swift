import SwiftUI

/// Simkl search results for TV shows or movies, run once, when the user asks.
struct SimklSearchSheet: View {
    let kind: MediaKind
    let query: String
    /// Called after a title is added, so the list can reload its copy.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var results: [SimklCatalogItem] = []
    @State private var state: SimklLoadState = .loading
    @State private var errorMessage: String?
    @State private var inLibrary: [Int: MediaListStatus] = [:]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("“\(query)”")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await search() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Couldn't Search", systemImage: "wifi.slash")
            } description: {
                Text(errorMessage ?? "")
            } actions: {
                Button("Retry") { Task { await search() } }
            }
        case .loaded:
            if results.isEmpty {
                ContentUnavailableView(
                    "No Results", systemImage: "magnifyingglass",
                    description: Text("Simkl has no \(kind == .movie ? "movie" : "show") matching “\(query)”."))
            } else {
                List(results, id: \.simklID) { item in
                    row(item)
                }
                .listStyle(.plain)
            }
        }
    }

    private func row(_ item: SimklCatalogItem) -> some View {
        let id = item.simklID ?? 0
        return HStack(spacing: 12) {
            NavigationLink(destination: SimklTitlePage(simklID: id, kind: kind, seedTitle: item.title ?? "",
                                                       seedPosterURL: item.posterURL?.absoluteString)) {
                HStack(spacing: 12) {
                    CachedAsyncImage(urlString: item.posterURL?.absoluteString ?? "")
                        .frame(width: 46, height: 69)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title ?? "Untitled")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if let year = item.year {
                                Text(String(year)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let status = inLibrary[id] {
                                Text(status.displayName)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                }
            }
            if inLibrary[id] == nil {
                Menu {
                    ForEach(LibrarySource.simkl.statuses(in: MediaListStatus.allCases, for: kind)) { status in
                        Button(status.displayName) { Task { await add(item, as: status) } }
                    }
                } label: {
                    Image(systemName: "plus.circle").font(.title2)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func search() async {
        state = .loading
        do {
            results = try await SimklCatalog.search(query, kind: kind).filter { $0.simklID != nil }
            refreshBadges()
            state = .loaded
        } catch {
            errorMessage = error.localizedDescription
            state = .failed
        }
    }

    private func refreshBadges() {
        let copy = SimklLibraryService.shared.cachedLibrary(kind) ?? []
        inLibrary = Dictionary(copy.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
    }

    private func add(_ item: SimklCatalogItem, as status: MediaListStatus) async {
        guard let id = item.simklID else { return }
        guard !SimklAuthManager.shared.needsReauthorization else {
            SimklNotice.failed(SimklError.readOnly)
            return
        }
        let entry = SimklTitleCopy.entry(simklID: id, kind: kind, title: item.title ?? "",
                                         posterURL: item.posterURL?.absoluteString, year: item.year,
                                         runtime: nil, totalEpisodes: nil, status: status)
        do {
            let delivered = try await SimklLibraryService.shared.saveTitle(id, kind: kind, status: status,
                                                                           score: 0, ifAbsent: entry)
            refreshBadges()
            onChange()
            if !delivered { SimklNotice.queued() }
        } catch {
            SimklNotice.failed(error)
        }
    }
}
