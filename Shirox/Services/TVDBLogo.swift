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

/// Which kind of TVDB record a title is — a series' artwork types differ from a movie's.
enum TVDBRecord: String, Sendable {
    case series, movie

    init(kind: MediaKind) { self = kind == .movie ? .movie : .series }

    /// TVDB's artwork types: 23 and 22 for a series, 25 and 24 for a movie. (14 is a movie's
    /// poster, not a logo.)
    var clearLogoType: Int { self == .movie ? 25 : 23 }
    var clearArtType: Int { self == .movie ? 24 : 22 }

    /// The record's path in TVDB's API.
    var path: String { self == .movie ? "movies" : "series" }
}

/// A title's logo among its TVDB artwork.
enum TVDBLogo {

    /// A ClearLogo, or failing that a ClearArt — the season's before the series'. Within each, one
    /// in English, else in the title's own language (so an anime keeps its Japanese logo), else
    /// one without a language. A logo only in some other language is no logo: an English film
    /// shows its title rather than a Chinese logo.
    static func pick(season: [TVDBArtwork] = [], record: [TVDBArtwork], kind: TVDBRecord,
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
        let readable: [(TVDBArtwork) -> Bool] = [
            { $0.language == "eng" || $0.language == "en" },
            { originalLanguage != nil && $0.language == originalLanguage },
            { $0.language == nil },
        ]
        for isReadable in readable {
            if let artwork = artworks.filter(isReadable).sorted(by: TVDBArtwork.bySizeOrScore).first {
                return artwork.image
            }
        }
        return nil
    }
}

/// What's known of a Simkl show's or movie's TVDB logo.
struct TVDBTitleLogoEntry: Codable, Equatable {
    /// nil: TVDB had none.
    let path: String?
    let checked: Date

    enum Answer: Equatable {
        case known(String?)
        case askAgain
    }

    /// A logo found is kept. TVDB is asked again about one it had none for after this long —
    /// logos are added after a title's release.
    static let retryAfter: TimeInterval = 3 * 24 * 60 * 60

    func answer(now: Date = Date()) -> Answer {
        if path != nil || now.timeIntervalSince(checked) < Self.retryAfter { return .known(path) }
        return .askAgain
    }

    static func key(tvdbID: Int, record: TVDBRecord) -> String { "\(record.rawValue)-\(tvdbID)" }
}
