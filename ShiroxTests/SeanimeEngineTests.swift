import XCTest
@testable import Shirox

/// A Seanime provider installed as a module runs in Shirox's engines, as any module does.
@MainActor
final class SeanimeEngineTests: XCTestCase {
    private func module(kind: String, script: String) async throws -> ModuleDefinition {
        let manifest = SeanimeManifest.detect(try JSONSerialization.data(withJSONObject: [
            "id": "fake-\(kind)", "name": "Fake", "version": "1", "language": "javascript",
            "type": kind == "manga" ? "manga-provider" : "onlinestream-provider",
            "payloadURI": "https://example.com/\(kind).js",
        ]))!
        return try await SeanimeInstaller.module(from: manifest, manifestURL: URL(string: "https://example.com/m.json")!,
                                                 fetch: { _ in Data(script.utf8) })
    }

    func testAnAnimeProviderSearchesListsAndStreamsThroughTheRunner() async throws {
        let module = try await module(kind: "anime", script: """
        class Provider {
          getSettings() { return { episodeServers: ["s"], supportsDub: false }; }
          async search(opts) { return [{ id: "show-" + opts.media.romajiTitle, title: "Show", url: "", subOrDub: "sub" }]; }
          async findEpisodes(id) { return [{ id: "e1", number: 1, url: "u" }]; }
          async findEpisodeServer(ep, server) { return { server: "S", headers: { Referer: "https://r/" },
            videoSources: [{ url: "https://cdn/" + ep.id + ".m3u8", type: "m3u8", quality: "720p", subtitles: [] }] }; }
        }
        """)
        let runner = ModuleJSRunner()
        try await runner.load(module: module)
        runner.seanimeMedia = SeanimeSearchMedia(id: 1, idMal: nil, romajiTitle: "Sousou", englishTitle: "Frieren",
                                                 synonyms: [], episodeCount: 28, format: "TV", status: "FINISHED",
                                                 year: 2023, isAdult: false)
        let results = try await runner.search(keyword: "Frieren")
        XCTAssertEqual(results.first?.href, "show-Sousou")
        let episodes = try await runner.fetchEpisodes(url: results[0].href)
        XCTAssertEqual(episodes.map(\.number), [1])
        let streams = try await runner.fetchStreams(episodeUrl: episodes[0].href)
        XCTAssertEqual(streams.first?.url.absoluteString, "https://cdn/e1.m3u8")
        XCTAssertEqual(streams.first?.headers, ["Referer": "https://r/"])
    }

    func testAMangaProviderReadsThroughTheEngineAndRecordsPageHeaders() async throws {
        let module = try await module(kind: "manga", script: """
        class Provider {
          async search(opts) { return [{ id: "m1", title: opts.query, image: "" }]; }
          async findChapters(id) { return [{ id: "c1", url: "", title: "One", chapter: "1", index: 0 }]; }
          async findChapterPages(id) { return [{ url: "https://cdn.test/seanime-engine-p1.png", index: 0, headers: { Referer: "https://site.test/" } }]; }
        }
        """)
        try await JSEngine.shared.loadModule(module)
        let results = try await JSEngine.shared.mangaSearch(keyword: "Frieren")
        XCTAssertEqual(results.first?.href, "m1")
        let chapters = try await JSEngine.shared.mangaChapters(url: "m1")
        XCTAssertEqual(chapters.map(\.href), ["c1"])
        let pages = try await JSEngine.shared.mangaImages(url: "c1")
        XCTAssertEqual(pages, ["https://cdn.test/seanime-engine-p1.png"])
        XCTAssertEqual(MangaPageHeaders.shared.headers(for: pages[0]), ["Referer": "https://site.test/"])
    }

    func testDubIsRememberedPerProvider() {
        let name = "SeanimeEngineTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        XCTAssertFalse(SeanimeProviderSettings.dub(for: "a", defaults: defaults), "Sub by default")
        SeanimeProviderSettings.setDub(true, for: "a", defaults: defaults)
        XCTAssertTrue(SeanimeProviderSettings.dub(for: "a", defaults: defaults))
        XCTAssertFalse(SeanimeProviderSettings.dub(for: "b", defaults: defaults))
    }

    func testTheAnimePagesEntryBecomesTheShow() {
        let media = Media(id: 154587, idMal: 52991, provider: .anilist,
                          title: MediaTitle(romaji: "Sousou no Frieren", english: "Frieren", native: nil),
                          coverImage: MediaCoverImage(large: nil, extraLarge: nil), bannerImage: nil, description: nil,
                          episodes: 28, status: "FINISHED", averageScore: nil, genres: nil, season: nil, seasonYear: 2023,
                          nextAiringEpisode: nil, relations: nil, type: "ANIME", format: "TV")
        let show = SeanimeSearchMedia(media: media)
        XCTAssertEqual(show.jsonObject["romajiTitle"] as? String, "Sousou no Frieren")
        XCTAssertEqual(show.jsonObject["idMal"] as? Int, 52991)
        XCTAssertEqual(show.jsonObject["year"] as? Int, 2023)
        XCTAssertEqual(show.jsonObject["episodeCount"] as? Int, 28)
    }
}
