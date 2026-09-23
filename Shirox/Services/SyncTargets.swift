import Foundation

/// Which tracking services an edit made in the app is written across.
///
/// Replaces `dualSync`, a Bool meaning "AniList and MyAnimeList" that stopped being a meaningful
/// question once there were three services. Stored comma-joined, since `AppStorage` cannot hold a
/// `Set`.
///
/// Distinct from the library sync runs, which reconcile whole libraries on request. This is
/// forward mirroring: one edit, made here, written to each service in the set.
enum SyncTargets {
    static let key = "syncTargets"
    /// Kept in step with the set rather than deleted, so a downgrade to a build that only knows
    /// `dualSync` still finds the AniList ↔ MyAnimeList half of the setting.
    static let legacyKey = "dualSync"

    static func decode(_ raw: String) -> Set<LibrarySide> {
        Set(raw.split(separator: ",").compactMap { LibrarySide(rawValue: String($0)) })
    }

    static func encode(_ sides: Set<LibrarySide>) -> String {
        LibrarySide.allCases.filter(sides.contains).map(\.rawValue).joined(separator: ",")
    }

    /// Seeds the set from `dualSync`, once per install.
    static func migrateIfNeeded(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: key) == nil else { return }
        let seeded: Set<LibrarySide> = defaults.bool(forKey: legacyKey) ? [.anilist, .mal] : []
        defaults.set(encode(seeded), forKey: key)
    }

    static func load(_ defaults: UserDefaults = .standard) -> Set<LibrarySide> {
        migrateIfNeeded(defaults)
        return decode(defaults.string(forKey: key) ?? "")
    }

    static func save(_ sides: Set<LibrarySide>, _ defaults: UserDefaults = .standard) {
        defaults.set(encode(sides), forKey: key)
        defaults.set(mirrors(.anilist, .mal, in: sides), forKey: legacyKey)
    }

    static func mirrors(_ a: LibrarySide, _ b: LibrarySide, in sides: Set<LibrarySide>) -> Bool {
        sides.contains(a) && sides.contains(b)
    }

    /// Where an edit made on `side` is also written: every *other* signed-in service in the set —
    /// and nowhere when `side` itself is not in it.
    static func mirrorTargets(for side: LibrarySide, in sides: Set<LibrarySide>,
                              signedIn: [LibrarySide]) -> [LibrarySide] {
        guard sides.contains(side) else { return [] }
        return signedIn.filter { $0 != side && sides.contains($0) }
    }
}
