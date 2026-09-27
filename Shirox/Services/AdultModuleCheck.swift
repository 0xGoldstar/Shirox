import Foundation

/// Whether a module is an adult one, which Shirox won't add, update into, or keep: by an
/// adult word in its name or links, or by an adult site among those it reaches.
enum AdultModuleCheck {
    /// Words that mark a module adult even inside a longer name — "nhentai", "HentaiHaven".
    static let adultStems = ["hentai", "porn", "xxx", "nsfw", "rule34", "adult"]

    /// Adult by name: a whole word from the search filter's list (or "adult"), or one of the
    /// stems anywhere in a word. Camel case counts as separate words; "Adult Swim" doesn't count.
    static func hasAdultName(_ text: String) -> Bool {
        let spaced = text.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        let words = spaced.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\badult swim\b"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
        return words.contains { word in
            NSFWContentFilter.blockedKeywords.contains(word) || adultStems.contains { word.contains($0) }
        }
    }

    static func isAdult(_ module: ModuleDefinition, blockedHost: (String) -> Bool) -> Bool {
        let names = [module.sourceName, module.seanime?.id]
            + [module.jsonUrl, module.scriptUrl].map { $0.flatMap(URL.init(string:))?.path }
        if names.contains(where: { $0.map(hasAdultName) == true }) { return true }
        return hosts(of: module).contains(where: blockedHost)
    }

    /// The sites a module reaches: its declared ones, and every address in its script.
    static func hosts(of module: ModuleDefinition) -> Set<String> {
        var hosts = Set([module.baseUrl, module.searchBaseUrl, module.scriptUrl, module.jsonUrl]
            .compactMap { $0.flatMap(URL.init(string:))?.host?.lowercased() })
        if let script = module.scriptContent,
           let pattern = try? NSRegularExpression(pattern: #"https?://([A-Za-z0-9.-]+\.[A-Za-z]{2,})"#) {
            let range = NSRange(script.startIndex..., in: script)
            for match in pattern.matches(in: script, range: range) {
                if let host = Range(match.range(at: 1), in: script) { hosts.insert(script[host].lowercased()) }
            }
        }
        return hosts
    }
}
