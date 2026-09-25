import Foundation

/// Matching a module page to a Simkl show or movie by title, and guessing which season it holds.
///
/// A wrong match marks the wrong show watched, so only an exact title counts: the page's title or
/// an alias equal to Simkl's once case and punctuation are set aside, and the same year when both
/// have one.
enum SimklModuleMatch {
    /// Lowercased, letters and digits only.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    /// The first year (1900–2099) in a page's air date.
    static func year(inAirdate airdate: String) -> Int? {
        guard let range = airdate.range(of: #"(19|20)\d{2}"#, options: .regularExpression) else { return nil }
        return Int(airdate[range])
    }

    /// A page's aliases, however the module separated them.
    static func aliases(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;|\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Movies for a page of one episode or none, shows otherwise.
    static func searchKind(episodeCount: Int) -> MediaKind {
        episodeCount <= 1 ? .movie : .tv
    }

    /// The first result whose title is the page's title or an alias, in the same year when both
    /// have one. A "(2021)" at the end of the page's title is its year.
    static func match(title: String, aliases: String, airdate: String,
                      in results: [SimklCatalogItem]) -> SimklCatalogItem? {
        let (bareTitle, titleYear) = splittingYear(title)
        let names = Set(([bareTitle] + self.aliases(aliases)).map(normalized).filter { !$0.isEmpty })
        let year = titleYear ?? self.year(inAirdate: airdate)
        return results.first { item in
            guard item.simklID != nil, let name = item.title, names.contains(normalized(name)) else { return false }
            if let year, let itemYear = item.year, year != itemYear { return false }
            return true
        }
    }

    /// "Dune (2021)" → ("Dune", 2021).
    private static func splittingYear(_ title: String) -> (String, Int?) {
        guard let range = title.range(of: #"\s*\((19|20)\d{2}\)\s*$"#, options: .regularExpression) else {
            return (title, nil)
        }
        return (String(title[..<range.lowerBound]), Int(title[range].filter(\.isNumber)))
    }

    /// A season the title names: "Season 2", "Season 02", "2nd Season", "S2".
    static func namedSeason(in title: String) -> Int? {
        let patterns = [#"(?i)\bseason\s*0*(\d{1,2})\b"#, #"(?i)\b(\d{1,2})(?:st|nd|rd|th)\s+season\b"#, #"(?i)\bs0*(\d{1,2})\b"#]
        let range = NSRange(title.startIndex..., in: title)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let found = regex.firstMatch(in: title, range: range),
                  let group = Range(found.range(at: 1), in: title),
                  let season = Int(title[group]), season > 0 else { continue }
            return season
        }
        return nil
    }

    /// The season a show's page holds, or nil for every season in order: the season its title
    /// names; else every season when it lists more episodes than Simkl's season 1 has; else 1.
    static func seasonGuess(title: String, moduleEpisodeCount: Int, simklEpisodes: [SimklEpisode]?) -> Int? {
        if let named = namedSeason(in: title) { return named }
        if let simklEpisodes {
            let firstSeason = SimklEpisodePlanner.regular(simklEpisodes).filter { $0.season == 1 }.count
            if firstSeason > 0, moduleEpisodeCount > firstSeason { return nil }
        }
        return 1
    }
}
