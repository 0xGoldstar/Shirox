import Foundation

struct MediaDetail {
    let title: String
    let image: String
    let description: String
    let aliases: String
    let airdate: String
    var episodes: [EpisodeLink]
}

extension MediaDetail {
    /// A module that sends no poster or synopsis (every Seanime anime provider) borrows them
    /// from the show's AniList match; whatever the module did send is kept.
    func borrowing(from media: Media?) -> MediaDetail {
        guard let media else { return self }
        let hasSynopsis = !description.isEmpty && description != "N/A"
        return MediaDetail(
            title: title,
            image: image.isEmpty ? (media.coverImage.best ?? "") : image,
            description: hasSynopsis ? description : (media.plainDescription ?? description),
            aliases: aliases,
            airdate: airdate,
            episodes: episodes
        )
    }
}
