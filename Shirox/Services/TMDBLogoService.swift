import Foundation

/// One logo from TMDB's images for a show or movie.
struct TMDBImage: Decodable, Equatable, Sendable {
    let file_path: String
    let iso_639_1: String?
    let vote_average: Double?
    let width: Int?
    let height: Int?
}

/// A title's logo among TMDB's.
enum TMDBLogo {

    /// The most readable (`LogoLanguage`), then the best voted and largest. SVGs are passed over:
    /// TMDB serves them as SVG at every size, and the app's images can't draw one.
    static func pick(_ logos: [TMDBImage], originalLanguage: String?) -> String? {
        let drawable = logos.filter { !$0.file_path.lowercased().hasSuffix(".svg") }
        for isReadable in LogoLanguage.tiers(originalLanguage: originalLanguage) {
            let best = drawable.filter { isReadable($0.iso_639_1) }.sorted { a, b in
                let voteA = a.vote_average ?? 0
                let voteB = b.vote_average ?? 0
                if voteA != voteB { return voteA > voteB }
                return ((a.width ?? 0) * (a.height ?? 0)) > ((b.width ?? 0) * (b.height ?? 0))
            }.first
            if let best { return best.file_path }
        }
        return nil
    }

    static func imageURL(_ path: String) -> String { "https://image.tmdb.org/t/p/w500\(path)" }
}

/// Title logos from TMDB, for titles TVDB has none for — TMDB has far more, most of all for films.
///
/// The key comes from the gitignored `Configurations/Shirox.local.xcconfig` through Info.plist;
/// a build without one skips TMDB and keeps TVDB's logos alone. This product uses the TMDB API
/// but is not endorsed or certified by TMDB (credited in Settings).
@MainActor
final class TMDBLogoService {
    static let shared = TMDBLogoService()

    private static let storageKey = "tmdb_logos_v1"
    private let apiKey: String?
    private var logos: [String: LogoCacheEntry] = [:]
    private var tasks: [String: Task<String?, Never>] = [:]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    private init() {
        apiKey = Self.apiKey(in: Bundle.main.infoDictionary ?? [:])
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: LogoCacheEntry].self, from: data) {
            logos = decoded
        }
    }

    /// The key, or nil when the build has none — an empty setting, or one never substituted.
    nonisolated static func apiKey(in info: [String: Any]) -> String? {
        guard let key = (info["TMDBAPIKey"] as? String)?.trimmingCharacters(in: .whitespaces),
              !key.isEmpty, !key.hasPrefix("$(") else { return nil }
        return key
    }

    /// A title's logo already known — shown at once, before any lookup.
    func cachedLogo(tmdbID: Int, record: TitleRecord) -> String? {
        logos[LogoCacheEntry.tmdbKey(tmdbID, record: record)]?.path.map(TMDBLogo.imageURL)
    }

    /// A title's logo from TMDB. Kept once found; asked for again after a few days when TMDB had
    /// none. nil also when TMDB couldn't be reached, or the build has no key.
    func logo(tmdbID: Int, record: TitleRecord) async -> String? {
        guard let apiKey else { return nil }
        let key = LogoCacheEntry.tmdbKey(tmdbID, record: record)
        if case .known(let path)? = logos[key]?.answer() { return path.map(TMDBLogo.imageURL) }
        // A hero's logo and its preloader ask at once; one lookup answers both.
        let task = tasks[key] ?? Task { await self.lookUp(tmdbID: tmdbID, record: record, key: key, apiKey: apiKey) }
        tasks[key] = task
        let path = await task.value
        tasks[key] = nil
        return path.map(TMDBLogo.imageURL)
    }

    private struct Details: Decodable {
        struct Images: Decodable { let logos: [TMDBImage]? }
        let original_language: String?
        let images: Images?
    }

    private struct Images: Decodable { let logos: [TMDBImage]? }

    private func lookUp(tmdbID: Int, record: TitleRecord, key: String, apiKey: String) async -> String? {
        let base = "https://api.themoviedb.org/3/\(record.tmdbPath)/\(tmdbID)"
        do {
            var path: String?
            // The title's own language, with its English and language-free logos, in one request.
            switch try await get(Details.self, "\(base)?api_key=\(apiKey)&append_to_response=images&include_image_language=en,null") {
            case .failed:
                return nil
            case .notFound:
                path = nil
            case .found(let details):
                path = TMDBLogo.pick(details.images?.logos ?? [], originalLanguage: details.original_language)
                // No English logo: one in the title's own language, if it has another.
                if path == nil, let original = details.original_language, original != "en" {
                    switch try await get(Images.self, "\(base)/images?api_key=\(apiKey)&include_image_language=\(original)") {
                    case .found(let images): path = TMDBLogo.pick(images.logos ?? [], originalLanguage: original)
                    case .notFound: break
                    case .failed: return nil
                    }
                }
            }
            logos[key] = LogoCacheEntry(path: path, checked: Date())
            save()
            return path
        } catch where (error as? URLError)?.code == .cancelled || error is CancellationError {
            return nil
        } catch {
            Logger.shared.log("TMDB logo error (\(record.tmdbPath) \(tmdbID)): \(error)", type: "Error")
            return nil
        }
    }

    /// A 404 is an answer — TMDB has no such title. Anything else unanswered is asked again
    /// next time.
    private enum Fetched<T> { case found(T), notFound, failed }

    private func get<T: Decodable>(_ type: T.Type, _ address: String) async throws -> Fetched<T> {
        guard let url = URL(string: address) else { return .failed }
        let (data, response) = try await Self.session.data(from: url)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return (try? JSONDecoder().decode(T.self, from: data)).map { .found($0) } ?? .failed
        case 404: return .notFound
        default: return .failed
        }
    }

    private func save() {
        let snapshot = logos
        let key = Self.storageKey
        Task.detached(priority: .background) {
            guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
}

/// A Simkl show's or movie's logo: TVDB's, else TMDB's.
@MainActor
enum SimklTitleLogo {
    static func cached(for media: Media) -> String? {
        guard let kind = media.simklTitleKind else { return nil }
        let tvdb = media.tvdbID.flatMap { TVDBMappingService.shared.cachedTitleLogo(tvdbID: $0, kind: kind) }
        return tvdb ?? media.tmdbID.flatMap {
            TMDBLogoService.shared.cachedLogo(tmdbID: $0, record: TitleRecord(kind: kind))
        }
    }

    static func find(for media: Media) async -> String? {
        guard let kind = media.simklTitleKind else { return nil }
        if let tvdbID = media.tvdbID, let logo = await TVDBMappingService.shared.titleLogo(tvdbID: tvdbID, kind: kind) {
            return logo
        }
        guard let tmdbID = media.tmdbID else { return nil }
        return await TMDBLogoService.shared.logo(tmdbID: tmdbID, record: TitleRecord(kind: kind))
    }
}
