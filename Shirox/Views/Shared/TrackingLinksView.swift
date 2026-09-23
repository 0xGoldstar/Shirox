import SwiftUI

/// Which AniList, MyAnimeList and Simkl entry a show is — found by searching a service or by
/// entering an ID. Where the links apply is `TrackingLinkResolver`'s business.
struct TrackingLinksView: View {
    enum Page: Equatable {
        /// A module page. Its AniList link is the existing title match; MAL/Simkl live in the store.
        case module(title: String, moduleKey: String?, aniListID: Int?)
        case anilist(id: Int, title: String, idMal: Int?)
        case mal(id: Int, title: String, aniListID: Int?)

        var title: String {
            switch self {
            case .module(let t, _, _), .anilist(_, let t, _), .mal(_, let t, _): return t
            }
        }

        var storeKey: String? {
            switch self {
            case .module(_, let key, _): return key
            case .anilist(let id, _, _): return TrackingLinkStore.key(anilist: id)
            case .mal(let id, _, _):     return TrackingLinkStore.key(mal: id)
            }
        }

        /// The page's own service, shown but never changed — it is the entry the user opened.
        var fixedSide: LibrarySide? {
            switch self {
            case .module:  return nil
            case .anilist: return .anilist
            case .mal:     return .mal
            }
        }
    }

    let page: Page
    var initialSide: LibrarySide = .anilist
    /// Module pages only: the AniList match, which also drives page metadata. nil unlinks.
    var onAniListMatch: ((Int?) -> Void)? = nil
    /// After any stored link changes, so the page can reload its entries.
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var simklAuth = SimklAuthManager.shared

    @State private var side: LibrarySide = .anilist
    @State private var links = TrackingLinks()
    @State private var current: TrackingIDs?
    @State private var currentTitles: [LibrarySide: String] = [:]
    @State private var query = ""
    @State private var results: [LinkCandidate] = []
    @State private var isSearching = false
    @State private var idText = ""
    @State private var message: String?
    @State private var searchTask: Task<Void, Never>?

    private var isModulePage: Bool { if case .module = page { return true }; return false }

    private var sides: [LibrarySide] {
        LibrarySide.allCases.filter { s in
            if page.fixedSide == s { return true }
            switch s {
            case .anilist: return isModulePage || aniListAuth.isLoggedIn
            case .mal:     return malAuth.isLoggedIn
            case .simkl:   return simklAuth.isLoggedIn
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Service", selection: $side) {
                        ForEach(sides, id: \.self) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Linked") { currentRow }

                if page.fixedSide != side {
                    Section("Search \(side.name)") {
                        TextField("Title", text: $query)
                            .onChangeOf(query) { performSearch() }
                        if isSearching { ProgressView() }
                        ForEach(results) { candidate in
                            Button { link(candidate) } label: { candidateRow(candidate) }
                                .buttonStyle(.plain)
                        }
                    }
                    Section {
                        HStack {
                            TextField("ID or link", text: $idText)
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                #endif
                            Button("Link") { linkTypedID() }
                                .disabled(idText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } header: {
                        Text("Or enter an ID")
                    } footer: {
                        Text("A number, or a link to the anime on \(side.name).")
                    }
                }

                if let message {
                    Section { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Tracking Links")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            side = sides.contains(initialSide) ? initialSide : (sides.first ?? .anilist)
            query = page.title
            await reload()
            performSearch()
        }
        .onChangeOf(side) {
            results = []
            idText = ""
            message = nil
            performSearch()
        }
    }

    // MARK: - Rows

    @ViewBuilder private var currentRow: some View {
        let id = currentID(for: side)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentTitles[side] ?? (id.map { "#\($0)" } ?? "Not linked"))
                    .font(.headline)
                Text(badge(for: side, id: id))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isUserSet(side) {
                Button("Reset to automatic") { reset(side) }
                    .font(.caption)
            }
        }
        if isModulePage, side == .anilist, id != nil {
            Button("Unlink", role: .destructive) {
                onAniListMatch?(nil)
                dismiss()
            }
        }
    }

    private func candidateRow(_ candidate: LinkCandidate) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: candidate.posterURL) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 40, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text([candidate.detail, "#\(candidate.id)"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "link").font(.caption)
        }
    }

    // MARK: - State

    private func currentID(for s: LibrarySide) -> Int? {
        switch (page, s) {
        case (.anilist(let id, _, _), .anilist), (.mal(let id, _, _), .mal): return id
        case (.module(_, _, let aid), .anilist): return aid
        default:
            switch s {
            case .anilist: return current?.anilist
            case .mal:     return current?.mal
            case .simkl:   return current?.simkl
            }
        }
    }

    private func isUserSet(_ s: LibrarySide) -> Bool {
        guard page.fixedSide != s, !(isModulePage && s == .anilist) else { return false }
        switch s {
        case .anilist: return links.anilist != nil
        case .mal:     return links.mal != nil
        case .simkl:   return links.simkl != nil
        }
    }

    private func badge(for s: LibrarySide, id: Int?) -> String {
        if page.fixedSide == s { return "This page" }
        if isModulePage, s == .anilist { return id == nil ? "Not linked" : "Matched to this page" }
        if isUserSet(s) { return "Set by you" }
        if s == .simkl, id == nil { return "Automatic — Simkl matches it from the other ids" }
        return id == nil ? "Not linked" : "Automatic"
    }

    private func reload() async {
        links = page.storeKey.flatMap { TrackingLinkStore.shared.links(for: $0) } ?? TrackingLinks()
        switch page {
        case .module(_, let key, let aid):
            current = await TrackingLinkResolver.resolve(aniListID: aid, malID: nil, moduleKey: key)
        case .anilist(let id, _, let idMal):
            current = await TrackingLinkResolver.resolve(aniListID: id, malID: idMal, moduleKey: nil)
        case .mal(let id, _, let aid):
            current = await TrackingLinkResolver.resolve(aniListID: aid, malID: id, moduleKey: nil)
        }
        var titles: [LibrarySide: String] = [:]
        for s in sides {
            if let id = currentID(for: s), let found = try? await Self.lookup(id, on: s) {
                titles[s] = found.title
            }
        }
        currentTitles = titles
    }

    // MARK: - Actions

    private func performSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        let s = side
        guard !q.isEmpty, page.fixedSide != s else { results = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            do {
                let found = try await Self.search(q, on: s)
                guard !Task.isCancelled else { return }
                results = found
                message = found.isEmpty ? "No results on \(s.name)." : nil
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                message = "Search failed: \(error.localizedDescription)"
            }
            isSearching = false
        }
    }

    private func linkTypedID() {
        let s = side
        guard let id = TrackingIDInput.parse(idText, for: s) else {
            message = "Enter a number, or a link to the anime on \(s.name)."
            return
        }
        message = "Checking…"
        Task {
            do {
                guard let found = try await Self.lookup(id, on: s) else {
                    message = "\(s.name) has no anime with ID \(id)."
                    return
                }
                link(found)
            } catch {
                message = "Couldn't check that ID: \(error.localizedDescription)"
            }
        }
    }

    private func link(_ candidate: LinkCandidate) {
        if isModulePage, side == .anilist {
            onAniListMatch?(candidate.id)
            dismiss()
            return
        }
        guard let key = page.storeKey else {
            message = "This page has no module address, so links can't be saved for it."
            return
        }
        let s = side
        TrackingLinkStore.shared.update(key) { l in
            switch s {
            case .anilist: l.anilist = candidate.id
            case .mal:     l.mal = candidate.id
            case .simkl:   l.simkl = candidate.id
            }
        }
        message = "Linked \(s.name) to \(candidate.title)."
        idText = ""
        onChange()
        Task { await reload() }
    }

    private func reset(_ s: LibrarySide) {
        guard let key = page.storeKey else { return }
        TrackingLinkStore.shared.update(key) { l in
            switch s {
            case .anilist: l.anilist = nil
            case .mal:     l.mal = nil
            case .simkl:   l.simkl = nil
            }
        }
        message = nil
        onChange()
        Task { await reload() }
    }

    // MARK: - Services

    struct LinkCandidate: Identifiable, Equatable {
        let id: Int
        let title: String
        let detail: String?
        let posterURL: URL?

        init(media: Media) {
            id = media.id
            title = media.title.displayTitle
            detail = [media.format, media.seasonYear.map(String.init)].compactMap { $0 }.joined(separator: " · ")
                .nilIfEmpty
            posterURL = media.coverImage.large.flatMap(URL.init(string:))
        }

        init?(simkl item: SimklCatalogItem) {
            guard let simklID = item.simklID else { return nil }
            id = simklID
            title = item.title ?? "Simkl #\(simklID)"
            detail = [item.type?.uppercased(), item.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
                .nilIfEmpty
            posterURL = item.posterURL
        }
    }

    @MainActor
    static func search(_ query: String, on side: LibrarySide) async throws -> [LinkCandidate] {
        switch side {
        case .anilist: return try await AniListProvider.shared.search(query).map(LinkCandidate.init(media:))
        case .mal:     return try await MALProvider.shared.search(query).map(LinkCandidate.init(media:))
        case .simkl:   return try await SimklCatalog.search(query).compactMap(LinkCandidate.init(simkl:))
        }
    }

    @MainActor
    static func lookup(_ id: Int, on side: LibrarySide) async throws -> LinkCandidate? {
        switch side {
        case .anilist: return LinkCandidate(media: try await AniListProvider.shared.detail(id: id))
        case .mal:     return LinkCandidate(media: try await MALProvider.shared.detail(id: id))
        case .simkl:   return try await SimklCatalog.lookup(simklID: id).flatMap(LinkCandidate.init(simkl:))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
