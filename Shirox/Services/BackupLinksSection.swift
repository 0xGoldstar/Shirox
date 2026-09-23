import Foundation

struct LinksBackupPayload: Codable {
    /// Module title (lowercased) → AniList id: the "Link with AniList" matches.
    var aniListMatches: [String: Int]
    var trackingLinks: [String: TrackingLinks]
}

/// Which entry each show is on each service — the AniList matches, which were in no backup
/// before, and the tracking links beside them.
struct LinksBackupSection: BackupSection {
    typealias Payload = LinksBackupPayload
    static var id: String { BackupSectionID.links }

    @MainActor func export() throws -> LinksBackupPayload? {
        let matches = AniListMappingManager.shared.allMappings
        let links = TrackingLinkStore.shared.all
        guard !matches.isEmpty || !links.isEmpty else { return nil }
        return LinksBackupPayload(aniListMatches: matches, trackingLinks: links)
    }

    @MainActor func apply(_ payload: LinksBackupPayload) async throws -> [String] {
        AniListMappingManager.shared.replaceAll(payload.aniListMatches)
        TrackingLinkStore.shared.replaceAll(payload.trackingLinks)
        return []
    }
}
