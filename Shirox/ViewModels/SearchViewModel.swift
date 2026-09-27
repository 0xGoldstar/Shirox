import Foundation
import Combine

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var moduleResults: [SearchItem] = []
    @Published var aniListResults: [Media] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var query = ""
    @Published var hasSearched = false
    /// A Simkl search's results, one section per kind.
    @Published var simklSections: [SimklSearchSection] = []
    /// Kinds whose Simkl search failed while others worked.
    @Published var simklFailedKinds: [MediaKind] = []

    private(set) var isUsingModule = false
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        ProviderManager.shared.$orderedProviders
            .map { $0.first?.providerType }
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] _ in self?.clearResults() }
            .store(in: &cancellables)
        DiscoverySource.shared.$usesSimkl
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.clearResults() }
            .store(in: &cancellables)
    }

    func search(usingModule: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { clearResults(); return }
        searchTask?.cancel()
        isUsingModule = usingModule
        hasSearched = true
        isLoading = true
        errorMessage = nil
        moduleResults = []
        aniListResults = []
        simklSections = []
        simklFailedKinds = []
        searchTask = Task {
            do {
                if usingModule {
                    CloudflareBypassManager.shared.pendingVerificationURL = nil
                    var res: [SearchItem]
                    do {
                        res = try await moduleSearch(q)
                    } catch {
                        // Modules often swallow a CF wall as a JSON parse error and rethrow.
                        // If a Turnstile host was flagged, fall through to verify; else surface it.
                        guard CloudflareBypassManager.shared.pendingVerificationURL != nil else { throw error }
                        res = []
                    }
                    // The user explicitly searched, so a Cloudflare wall here is solved inline
                    // (auto-verify + retry once) rather than deferred to a button. Verify whenever
                    // a wall was flagged — modules often swallow the CF page and return a bogus
                    // result, so we can't rely on the result being empty.
                    if !Task.isCancelled,
                       let cfURL = CloudflareBypassManager.shared.pendingVerificationURL {
                        try? await CloudflareBypassManager.shared.triggerBypass(for: cfURL)
                        if !Task.isCancelled {
                            CloudflareBypassManager.shared.pendingVerificationURL = nil
                            res = try await moduleSearch(q)
                        }
                    }
                    if !Task.isCancelled {
                        var seen = Set<String>()
                        let deduped = res.filter { seen.insert($0.href).inserted }
                        moduleResults = await NSFWContentFilter.shared.filter(deduped, keyword: q)
                        aniListResults = []
                    }
                    // Results with no image (every Seanime anime provider) get AniList's covers,
                    // after the grid is already showing.
                    let bare = moduleResults.filter { $0.image.isEmpty }.map(\.title)
                    if !bare.isEmpty, !Task.isCancelled {
                        isLoading = false
                        let manga = ModuleManager.shared.activeModule?.isManga == true
                        if let covers = try? await AniListService.shared.covers(for: bare, manga: manga),
                           !Task.isCancelled {
                            moduleResults = Self.withPosters(moduleResults, covers: covers)
                        }
                    }
                } else if DiscoverySource.shared.usesSimkl {
                    let outcome = await SimklSearch.run(q)
                    if !Task.isCancelled {
                        simklSections = outcome.sections
                        simklFailedKinds = outcome.failedKinds
                        errorMessage = outcome.error
                    }
                } else {
                    let res = try await ProviderManager.shared.call { try await $0.search(q) }
                    if !Task.isCancelled {
                        var seen = Set<String>()
                        aniListResults = res.filter { seen.insert($0.uniqueId).inserted }
                        moduleResults = []
                    }
                }
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    /// Manga modules use the Luna contract (raw-object returns); everything
    /// else uses the Sora searchResults path. Both produce [SearchItem].
    private func moduleSearch(_ q: String) async throws -> [SearchItem] {
        if ModuleManager.shared.activeModule?.isManga == true {
            return try await JSEngine.shared.mangaSearch(keyword: q)
        }
        return try await JSEngine.shared.search(keyword: q)
    }

    func clearResults() {
        searchTask?.cancel()
        searchTask = nil
        moduleResults = []
        aniListResults = []
        simklSections = []
        simklFailedKinds = []
        isLoading = false
        errorMessage = nil
        hasSearched = false
    }

    var hasResults: Bool { !moduleResults.isEmpty || !aniListResults.isEmpty || !simklSections.isEmpty }
    var resultCount: Int {
        moduleResults.count + aniListResults.count + simklSections.reduce(0) { $0 + $1.items.count }
    }
}

extension SearchViewModel {
    /// Results that came without an image take AniList's cover for their title. Each row is
    /// changed in place, keeping its identity, so the grid doesn't redraw it.
    static func withPosters(_ items: [SearchItem], covers: [String: String]) -> [SearchItem] {
        items.map { item in
            guard item.image.isEmpty, let cover = covers[item.title] else { return item }
            var filled = item
            filled.image = cover
            return filled
        }
    }
}
