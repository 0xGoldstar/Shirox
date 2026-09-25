import Foundation

/// Simkl's free files, kept on the device until Simkl makes new ones.
///
/// They cost no one any allowance, but Simkl regenerates them on a schedule — hourly at most —
/// so fetching one sooner only gets the same file again.
@MainActor
final class SimklFeedStore {
    static let shared = SimklFeedStore()

    typealias Download = @MainActor (URLRequest) async throws -> Data

    private let directory: URL
    private let download: Download
    private let now: @MainActor () -> Date

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("simkl-feed", isDirectory: true),
         download: @escaping Download = SimklFeedStore.fetch,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.directory = directory
        self.download = download
        self.now = now
    }

    /// The saved copy while it's fresh, else a new download — or, when that fails, the saved
    /// copy however old. Throws only when there's neither. `forceRefresh` skips the freshness check.
    func items(_ list: SimklFeedList, full: Bool = false, forceRefresh: Bool = false) async throws -> [SimklDiscoverItem] {
        let file = url(list, full: full)
        if !forceRefresh, let savedAt = savedDate(file),
           now().timeIntervalSince(savedAt) < list.refreshInterval, let saved = read(file) {
            return saved
        }
        do {
            let data = try await download(SimklAuthManager.shared.dataRequest(path: list.path(full: full)))
            let items = try SimklDiscoverItem.decodeList(data)
            save(data, to: file)
            return items
        } catch {
            if let saved = read(file) { return saved }
            throw error
        }
    }

    /// The saved copy, however old, without asking the network — for Home's first paint.
    func savedItems(_ list: SimklFeedList, full: Bool = false) -> [SimklDiscoverItem]? {
        read(url(list, full: full))
    }

    nonisolated static func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { throw ProviderError.serverError(status) }
        return data
    }

    private func url(_ list: SimklFeedList, full: Bool) -> URL {
        let name = list.path(full: full).dropFirst().replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent(name)
    }

    private func read(_ file: URL) -> [SimklDiscoverItem]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? SimklDiscoverItem.decodeList(data)
    }

    private func savedDate(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private func save(_ data: Data, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            // The save time is the fetch time — set rather than left to the clock, so it follows `now`.
            try FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: file.path)
        } catch {
            Logger.shared.log("[Simkl] Could not save \(file.lastPathComponent): \(error)", type: "Error")
        }
    }
}
