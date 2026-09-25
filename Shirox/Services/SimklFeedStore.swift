import Foundation

/// Simkl's lists for Home, kept on the device until Simkl makes new ones.
///
/// The CDN files cost no one any allowance, but Simkl regenerates them on a schedule — hourly at
/// most — so fetching one sooner only gets the same file again. Top Rated comes from the API with
/// the user's token, so it's kept for a day and a pull to refresh doesn't fetch it again sooner.
@MainActor
final class SimklFeedStore {
    static let shared = SimklFeedStore()

    typealias Download = @MainActor (SimklFeedList, _ path: String) async throws -> Data

    private let directory: URL
    private let download: Download
    private let now: @MainActor () -> Date
    /// Downloads running now, by file — Airing Today and New Premieres read the same calendar.
    private var inFlight: [URL: Task<[SimklDiscoverItem], Error>] = [:]

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("simkl-feed", isDirectory: true),
         download: @escaping Download = SimklFeedStore.fetch,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.directory = directory
        self.download = download
        self.now = now
    }

    /// The saved copy while it's fresh, else a new download — or, when that fails, the saved
    /// copy however old. Throws only when there's neither. `forceRefresh` skips the freshness
    /// check, except for a list that costs the user's allowance.
    func items(_ list: SimklFeedList, full: Bool = false, forceRefresh: Bool = false) async throws -> [SimklDiscoverItem] {
        let file = url(list, full: full)
        if !forceRefresh || list.needsToken, let savedAt = savedDate(file),
           now().timeIntervalSince(savedAt) < list.refreshInterval, let saved = read(file) {
            return saved
        }
        if let running = inFlight[file] { return try await running.value }
        let download = self.download
        // The calendar's v1 file stands in when v2 can't be had; the saved copy reads as either.
        let paths = [list.path(full: full)] + [list.fallbackPath(full: full)].compactMap { $0 }
        let task = Task { () throws -> [SimklDiscoverItem] in
            var failure: Error?
            for path in paths {
                do {
                    let data = try await download(list, path)
                    let items = try SimklDiscoverItem.decodeList(data)
                    self.save(data, to: file)
                    return items
                } catch {
                    failure = error
                }
            }
            if let saved = self.read(file) { return saved }
            throw failure ?? CancellationError()
        }
        inFlight[file] = task
        defer { inFlight[file] = nil }
        return try await task.value
    }

    /// The saved copy, however old, without asking the network — for Home's first paint.
    func savedItems(_ list: SimklFeedList, full: Bool = false) -> [SimklDiscoverItem]? {
        read(url(list, full: full))
    }

    /// A CDN file without a token; an API list with the user's, through the sender that
    /// refreshes it — and that list's refusal in Simkl's words, as search's is.
    static func fetch(_ list: SimklFeedList, path: String) async throws -> Data {
        let auth = SimklAuthManager.shared
        if list.needsToken {
            let (data, http) = try await auth.send {
                try auth.authorizedRequest(path: path, query: list.query)
            }
            guard (200...299).contains(http.statusCode) else {
                let failure = SimklLibraryService.classify(status: http.statusCode, body: data,
                                                           retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                throw SimklLibraryService.thrownError(for: failure, status: http.statusCode)
            }
            return data
        }
        let (data, response) = try await URLSession.shared.data(for: auth.dataRequest(path: path))
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
