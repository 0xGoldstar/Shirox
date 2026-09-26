import Foundation

/// Headers a manga module gave for its pages — a Seanime provider's `Referer`, say — kept by page
/// address for this run of the app. The image-header builder the reader and downloads share sends
/// them; pages without keep today's rule.
final class MangaPageHeaders: @unchecked Sendable {
    static let shared = MangaPageHeaders()

    private let lock = NSLock()
    private var byURL: [String: [String: String]] = [:]

    func record(_ headers: [String: String], for url: String) {
        guard !headers.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        byURL[url] = headers
    }

    func headers(for url: String) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        return byURL[url]
    }
}
