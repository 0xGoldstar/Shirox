import Foundation

/// One artwork from a TVDB series', season's or movie's extended record.
struct TVDBArtwork: Decodable, Equatable, Sendable {
    let image: String
    let type: Int
    let language: String?
    let width: Int?
    let height: Int?
    let includesText: Bool?
    let score: Double?

    /// The best scored first, then the largest.
    static func bySizeOrScore(_ a: TVDBArtwork, _ b: TVDBArtwork) -> Bool {
        let scoreA = a.score ?? 0
        let scoreB = b.score ?? 0
        if scoreA != scoreB { return scoreA > scoreB }
        return ((a.width ?? 0) * (a.height ?? 0)) > ((b.width ?? 0) * (b.height ?? 0))
    }
}

/// Whether a title is a series or a movie — TVDB and TMDB keep the two apart, with different
/// paths and, on TVDB, different artwork types.
enum TitleRecord: String, Sendable {
    case series, movie

    init(kind: MediaKind) { self = kind == .movie ? .movie : .series }

    /// TVDB's artwork types: 23 and 22 for a series, 25 and 24 for a movie. (14 is a movie's
    /// poster, not a logo.)
    var clearLogoType: Int { self == .movie ? 25 : 23 }
    var clearArtType: Int { self == .movie ? 24 : 22 }

    /// The record's path in TVDB's API.
    var tvdbPath: String { self == .movie ? "movies" : "series" }
    /// The record's path in TMDB's API.
    var tmdbPath: String { self == .movie ? "movie" : "tv" }
}

/// Which logos can be read: one in English, else in the title's own language (so an anime keeps
/// its Japanese logo), else one without a language. One only in some other language is no
/// logo — an English film shows its title rather than a Chinese logo.
enum LogoLanguage {
    /// Most readable first. TVDB writes languages in three letters ("eng", "jpn"), TMDB in two
    /// ("en", "ja"); a title's own language comes from the same service as its logos.
    static func tiers(originalLanguage: String?) -> [(String?) -> Bool] {
        [
            { $0 == "eng" || $0 == "en" },
            { originalLanguage != nil && $0 == originalLanguage },
            { $0 == nil },
        ]
    }
}

/// A title's logo among its TVDB artwork.
enum TVDBLogo {

    /// A ClearLogo, or failing that a ClearArt — the season's before the series'. Within each, the
    /// most readable (`LogoLanguage`), then the best scored and largest.
    static func pick(season: [TVDBArtwork] = [], record: [TVDBArtwork], kind: TitleRecord,
                     originalLanguage: String?) -> String? {
        for type in [kind.clearLogoType, kind.clearArtType] {
            for artworks in [season, record] {
                if let image = best(artworks.filter { $0.type == type }, originalLanguage: originalLanguage) {
                    return image
                }
            }
        }
        return nil
    }

    private static func best(_ artworks: [TVDBArtwork], originalLanguage: String?) -> String? {
        for isReadable in LogoLanguage.tiers(originalLanguage: originalLanguage) {
            if let artwork = artworks.filter({ isReadable($0.language) }).sorted(by: TVDBArtwork.bySizeOrScore).first {
                return artwork.image
            }
        }
        return nil
    }
}

/// What's known of a title's logo from one source.
struct LogoCacheEntry: Codable, Equatable {
    /// nil: the source had none.
    let path: String?
    let checked: Date

    enum Answer: Equatable {
        case known(String?)
        case askAgain
    }

    /// A logo found is kept. The source is asked again about one it had none for after this
    /// long — logos are added after a title's release.
    static let retryAfter: TimeInterval = 3 * 24 * 60 * 60

    func answer(now: Date = Date()) -> Answer {
        if path != nil || now.timeIntervalSince(checked) < Self.retryAfter { return .known(path) }
        return .askAgain
    }

    static func tvdbKey(_ tvdbID: Int, record: TitleRecord) -> String { "\(record.rawValue)-\(tvdbID)" }
    static func tmdbKey(_ tmdbID: Int, record: TitleRecord) -> String { "tmdb-\(record.tmdbPath)-\(tmdbID)" }
}
