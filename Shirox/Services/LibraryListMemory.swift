import Foundation

/// The list the Library was last on, per source and type — so switching back, or reopening the
/// app, lands where you left instead of on Watching.
enum LibraryListMemory {
    struct Place: Codable, Equatable {
        var status: MediaListStatus
        var customList: String? = nil
    }

    static let defaultsKey = "libraryLastLists"

    static func key(for source: LibrarySource, _ kind: MediaKind) -> String {
        let name: String
        switch source {
        case .local:              name = "local"
        case .simkl:              name = "simkl"
        case .provider(let type): name = "provider-\(type.rawValue)"
        }
        return "\(name)|\(kind.rawValue)"
    }

    static func load(for source: LibrarySource, _ kind: MediaKind,
                     in defaults: UserDefaults = .standard) -> Place? {
        all(in: defaults)[key(for: source, kind)]
    }

    static func save(_ place: Place, for source: LibrarySource, _ kind: MediaKind,
                     in defaults: UserDefaults = .standard) {
        var places = all(in: defaults)
        places[key(for: source, kind)] = place
        defaults.set(try? JSONEncoder().encode(places), forKey: defaultsKey)
    }

    /// A remembered place, if this source can still show its list. A custom list is checked once
    /// the source's lists are known (`LibraryViewModel.rebuildCustomListNames`).
    static func restorable(_ place: Place?, source: LibrarySource, kind: MediaKind) -> Place? {
        guard let place, source.statuses(in: MediaListStatus.allCases, for: kind).contains(place.status) else { return nil }
        return place
    }

    private static func all(in defaults: UserDefaults) -> [String: Place] {
        guard let data = defaults.data(forKey: defaultsKey),
              let places = try? JSONDecoder().decode([String: Place].self, from: data) else { return [:] }
        return places
    }
}
