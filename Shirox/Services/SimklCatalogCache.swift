import Foundation

/// Simkl catalog records saved on the device by Simkl id.
///
/// Catalog data is the same for every user, so it is keyed by id alone — Simkl's own guidance:
/// "cache catalog data by URL", for hours. The page shows a saved copy at once and refreshes it.
@MainActor
final class SimklCatalogCache {
    static let shared = SimklCatalogCache()

    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("simkl-catalog", isDirectory: true)) {
        self.directory = directory
    }

    func details(_ kind: MediaKind, simklID: Int) -> SimklTitleDetails? {
        read("\(kind.rawValue)-\(simklID)")
    }

    func store(_ details: SimklTitleDetails, kind: MediaKind) {
        write(details, "\(kind.rawValue)-\(details.simklID)")
    }

    func episodes(simklID: Int) -> [SimklEpisode]? {
        read("episodes-\(simklID)")
    }

    func store(episodes: [SimklEpisode], simklID: Int) {
        write(episodes, "episodes-\(simklID)")
    }

    private func read<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(name).json")) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ name: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
        } catch {
            Logger.shared.log("[Simkl] Could not save catalog data: \(error)", type: "Error")
        }
    }
}
