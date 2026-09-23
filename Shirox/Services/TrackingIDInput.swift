import Foundation

/// Reads what the Tracking Links sheet's "Enter ID" field was given: a bare number, or a link to
/// the anime on that service. Anything else — another service's link, a manga link — is refused,
/// because a wrong guess links the wrong show.
enum TrackingIDInput {
    static func parse(_ text: String, for side: LibrarySide) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(trimmed) { return number > 0 ? number : nil }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), let host = url.host?.lowercased() else { return nil }

        let expectedHost: String
        switch side {
        case .anilist: expectedHost = "anilist.co"
        case .mal:     expectedHost = "myanimelist.net"
        case .simkl:   expectedHost = "simkl.com"
        }
        guard host == expectedHost || host == "www." + expectedHost else { return nil }

        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0].lowercased() == "anime",
              let number = Int(parts[1]), number > 0 else { return nil }
        return number
    }
}
