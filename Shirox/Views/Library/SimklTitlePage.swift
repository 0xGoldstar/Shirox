import SwiftUI

/// A Simkl TV show's or movie's page: details from Simkl's free catalog, the user's entry, and for
/// a show its seasons with a tick per episode.
struct SimklTitlePage: View {
    let simklID: Int
    let kind: MediaKind
    /// Shown while the catalog loads — a row's or search result's title and poster.
    let seedTitle: String
    let seedPosterURL: String?

    @State private var details: SimklTitleDetails?
    @State private var detailsFailed = false
    @State private var episodes: [SimklEpisode] = []
    @State private var entry: LibraryEntry?
    @State private var season: Int?
    @State private var showsSpecials = false
    @State private var editing: LibraryEntry?
    @State private var busy = false
    @State private var message: String?

    private static let scrollSpace = "simklTitleScroll"
    private var service: SimklLibraryService { .shared }
    private var title: String { details?.title ?? seedTitle }
    private var posterURL: String? { details?.posterURL ?? seedPosterURL }
    private var simklURL: URL { URL(string: "https://simkl.com/\(kind == .movie ? "movies" : "tv")/\(simklID)")! }

    private var watched: Set<SimklEpisodeRef> {
        SimklEpisodePlanner.watched(status: entry?.status ?? .planning, recorded: entry?.watchedEpisodes,
                                    episodes: episodes)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                VStack(alignment: .leading, spacing: 20) {
                    entrySection
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    detailsSection
                    if kind == .tv { episodesSection }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .softScrollEdges([.bottom, .leading, .trailing])
        .hideScrollEdgeEffect(.top)
        .coordinateSpace(name: Self.scrollSpace)
        #if os(iOS)
        .ignoresSafeArea(edges: [.top, .leading])
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundHidden()
        #endif
        .scrollAwareNavTitle(title)
        .task { await load() }
        .adaptiveSheet(item: $editing) { entry in
            SimklTitleEditSheet(entry: entry, kind: kind) { reloadEntry() }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        let height: CGFloat = 380
        return ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                // Stretch from the first point of the pull, by the whole distance, as the anime page does.
                let stretch = max(proxy.frame(in: .named(Self.scrollSpace)).minY, 0)
                CachedAsyncImage(urlString: details?.fanartURL ?? posterURL ?? "")
                    .frame(width: proxy.size.width, height: height)
                    .clipped()
                    .scaleEffect(1 + stretch / height, anchor: .bottom)
            }
            .frame(height: height)

            CurvedGradientShadow(height: 320, color: .adaptiveSystemBackground, style: .subtle)

            HStack(alignment: .bottom, spacing: 14) {
                CachedAsyncImage(urlString: posterURL ?? "")
                    .frame(width: 110, height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)
                        .heroTitleAnchor(in: Self.scrollSpace)
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.self) { chip in
                            Text(chip)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.1), in: Capsule())
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    private var chips: [String] {
        guard let details else { return [] }
        return [details.year.map(String.init),
                details.runtime.map { SimklTitleLabels.runtime($0) },
                details.status?.capitalized].compactMap { $0 }
    }

    // MARK: - Your entry

    @ViewBuilder
    private var entrySection: some View {
        if let entry {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.status.displayName).font(.headline)
                    Text(kind == .movie ? SimklTitleLabels.movieLine(entry.media) : SimklTitleLabels.showProgress(entry))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if entry.score > 0 {
                        Text("Your score: \(Int(entry.score))/10").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if kind == .movie, entry.status != .completed {
                    Button("Watched") { Task { await save(status: .completed, plan: nil) } }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                }
                Button("Edit") { editing = entry }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            Menu {
                ForEach(LibrarySource.simkl.statuses(in: MediaListStatus.allCases, for: kind)) { status in
                    Button(status.displayName) { Task { await save(status: status, plan: nil) } }
                }
            } label: {
                Label("Add to list", systemImage: "plus.circle.fill").font(.headline)
            }
            .disabled(busy)
        }
        Link(destination: simklURL) {
            Label("Open on Simkl", systemImage: "safari")
        }
        .font(.subheadline)
    }

    // MARK: - Details

    @ViewBuilder
    private var detailsSection: some View {
        if let details {
            VStack(alignment: .leading, spacing: 8) {
                if !details.genres.isEmpty {
                    Text(details.genres.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                }
                let facts = [details.network, details.certification].compactMap { $0 }
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                }
                if let overview = details.overview {
                    Text(overview)
                }
            }
        } else if detailsFailed {
            HStack {
                Text("Couldn't load the details.").foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
            }
            .font(.subheadline)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    // MARK: - Seasons and episodes

    @ViewBuilder
    private var episodesSection: some View {
        let seasons = SimklEpisodePlanner.regularSeasons(in: episodes)
        let specials = episodes.filter(\.isSpecial)
        if !seasons.isEmpty || !specials.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seasons, id: \.self) { number in
                            seasonPill("Season \(number)", selected: !showsSpecials && season == number) {
                                showsSpecials = false
                                season = number
                            }
                        }
                        if !specials.isEmpty {
                            seasonPill("Specials", selected: showsSpecials) { showsSpecials = true }
                        }
                    }
                }
                if showsSpecials {
                    Text("Simkl gives specials no season or episode number, so they can't be marked from here.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(specials) { episodeRow($0, ref: nil) }
                } else if let season {
                    seasonHeader(season)
                    ForEach(episodes.filter { $0.ref?.season == season }) { episodeRow($0, ref: $0.ref) }
                }
            }
        }
    }

    private func seasonPill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(selected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08)))
                .foregroundStyle(selected ? Color.primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func seasonHeader(_ number: Int) -> some View {
        HStack {
            Text("Season \(number)").font(.headline)
            Spacer()
            Menu {
                Button("Mark season watched") { Task { await changeSeason(number, marking: true) } }
                Button("Un-mark season", role: .destructive) { Task { await changeSeason(number, marking: false) } }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .disabled(busy)
        }
    }

    private func episodeRow(_ episode: SimklEpisode, ref: SimklEpisodeRef?) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: episode.imageURL ?? "")
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(ref.map { "E\($0.episode) · \(episode.title ?? "Episode \($0.episode)")" } ?? (episode.title ?? "Special"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let date = episode.date {
                    Text(String(date.prefix(10))).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let ref {
                Button {
                    Task { await toggle(ref) }
                } label: {
                    Image(systemName: watched.contains(ref) ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!episode.aired || busy)
                .opacity(episode.aired ? 1 : 0.35)
            }
        }
    }

    // MARK: - Loading and writing

    private func load() async {
        reloadEntry()
        if details == nil { details = SimklCatalogCache.shared.details(kind, simklID: simklID) }
        if kind == .tv, episodes.isEmpty, let saved = SimklCatalogCache.shared.episodes(simklID: simklID) {
            episodes = saved
            pickSeason()
        }
        detailsFailed = false
        do {
            if let fresh = try await SimklCatalog.details(kind, simklID: simklID) { details = fresh }
        } catch {
            if details == nil { detailsFailed = true }
        }
        if kind == .tv, let fresh = try? await SimklCatalog.loadEpisodes(simklID: simklID) {
            episodes = fresh
            pickSeason()
        }
    }

    /// Opens on the season of the next episode to watch — or of the furthest watched, or the first.
    private func pickSeason() {
        guard season == nil else { return }
        season = SimklEpisodePlanner.next(after: watched, in: episodes)?.season
            ?? SimklEpisodePlanner.furthest(watched)?.season
            ?? SimklEpisodePlanner.regularSeasons(in: episodes).first
    }

    private func reloadEntry() {
        entry = service.cachedLibrary(kind)?.first { $0.id == simklID }
    }

    private func toggle(_ ref: SimklEpisodeRef) async {
        let marking = !watched.contains(ref)
        var newWatched = watched
        if marking { newWatched.insert(ref) } else { newWatched.remove(ref) }
        let mark = [SimklSeasonMark(number: ref.season, episodes: [ref.episode])]
        await save(status: SimklEpisodePlanner.statusAfterTick(current: entry?.status, marking: marking),
                   plan: SimklEpisodePlan(marks: marking ? mark : [], unmarks: marking ? [] : mark, watched: newWatched))
    }

    private func changeSeason(_ number: Int, marking: Bool) async {
        let plan = SimklEpisodePlanner.seasonChange(number, marking: marking, watched: watched, episodes: episodes)
        guard !plan.marks.isEmpty || !plan.unmarks.isEmpty else { return }
        await save(status: SimklEpisodePlanner.statusAfterTick(current: entry?.status, marking: marking), plan: plan)
    }

    /// One write for this title through the durable queue; the page and the list's copy show it at once.
    private func save(status: MediaListStatus, plan: SimklEpisodePlan?) async {
        guard !SimklAuthManager.shared.needsReauthorization else {
            message = SimklError.readOnly.localizedDescription
            return
        }
        busy = true
        defer { busy = false }
        do {
            let delivered = try await service.saveTitle(
                simklID, kind: kind, status: status, score: entry?.score ?? 0, episodes: plan,
                ifAbsent: SimklTitleCopy.entry(simklID: simklID, kind: kind, title: title, posterURL: posterURL,
                                               year: details?.year, runtime: details?.runtime,
                                               totalEpisodes: details?.totalEpisodes, status: status))
            reloadEntry()
            if SimklAuthManager.shared.needsReauthorization {
                message = SimklError.readOnly.localizedDescription
            } else {
                message = delivered ? nil : "Simkl couldn't be reached — this is saved and will be sent later."
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
