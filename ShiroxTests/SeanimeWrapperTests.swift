import XCTest
@testable import Shirox

/// Shirox's module functions, answered by a Seanime provider.
@MainActor
final class SeanimeWrapperTests: XCTestCase {
    private let manga = """
    class Provider {
      async search(opts) { return [{ id: "m1", title: "Frieren " + opts.query, image: "https://x/c.jpg" }]; }
      async findChapters(id) { return [
        { id: id + "/c2", url: "", title: "Chapter 2", chapter: "2", index: 1, language: "en" },
        { id: id + "/c1", url: "", title: "Chapter 1", chapter: "1", index: 0, language: "en", scanlator: "Group" },
        { id: id + "/fr1", url: "", title: "Chapitre 1", chapter: "1", index: 0, language: "fr" },
        { id: id + "/x", url: "", title: "Special", chapter: "special", index: 2, language: "en" } ]; }
      async findChapterPages(id) { return [
        { url: "https://img/2.png", index: 1, headers: { Referer: "https://site/" } },
        { url: "https://img/1.png", index: 0, headers: { Referer: "https://site/" } } ]; }
    }
    """

    private let anime = """
    class Provider {
      getSettings() { return { episodeServers: ["alpha", "beta", "broken"], supportsDub: true }; }
      async search(opts) { globalThis.lastSearch = opts; return [{ id: "a1", title: "Frieren", url: "https://site/a1", subOrDub: "sub" }]; }
      async findEpisodes(id) { return [{ id: "e1", number: 1, url: "https://site/e1", title: "One" }, { id: "e2", number: 2, url: "https://site/e2" }]; }
      async findEpisodeServer(episode, server) {
        if (server === "broken") throw new Error("down");
        return { server: server.toUpperCase(), headers: { Referer: "https://site/" + server }, videoSources: [
          { url: "https://cdn/" + server + "/" + episode.id + ".m3u8", type: "m3u8", quality: "1080p",
            subtitles: server === "beta" ? [{ id: "s1", url: "https://subs/en.vtt", language: "English", isDefault: true }] : [] } ] };
      }
    }
    """

    private func value(_ result: Result<String, SeanimeJSHarness.Failure>) -> Any? {
        guard case .success(let string) = result else { XCTFail("\(result)"); return nil }
        return SeanimeJSHarness.json(string)
    }

    // MARK: - Manga

    func testMangaSearchKeepsTheProvidersId() {
        let context = SeanimeJSHarness.context(provider: manga, kind: "manga")
        let results = value(SeanimeJSHarness.call(context, "searchResults", ["Beyond"])) as? [[String: Any]]
        XCTAssertEqual(results?.first?["id"] as? String, "m1")
        XCTAssertEqual(results?.first?["title"] as? String, "Frieren Beyond")
        XCTAssertEqual(results?.first?["image"] as? String, "https://x/c.jpg")
    }

    func testChaptersAreGroupedByLanguageInShiroxsShape() {
        let context = SeanimeJSHarness.context(provider: manga, kind: "manga")
        let chapters = value(SeanimeJSHarness.call(context, "extractChapters", ["m1"])) as? [String: [[Any]]]
        XCTAssertEqual(chapters?.keys.sorted(), ["en", "fr"])
        let english = chapters?["en"] ?? []
        XCTAssertEqual(english.map { $0.first as? String }, ["2", "1", "special"])
        let first = (english[1][1] as? [[String: Any]])?.first
        XCTAssertEqual(first?["id"] as? String, "m1/c1")
        XCTAssertEqual(first?["chapter"] as? Double, 1)
        XCTAssertEqual(first?["scanlation_group"] as? String, "Group")
        let special = (english[2][1] as? [[String: Any]])?.first
        XCTAssertNil(special?["chapter"], "Unnumbered: Shirox's parser puts it last")
        // Shirox's own parser orders them.
        XCTAssertEqual(JSEngine.parseMangaChapters(chapters as Any).map(\.href), ["m1/c1", "m1/c2", "m1/x"])
    }

    func testPagesAreInOrderWithTheirHeaders() {
        let context = SeanimeJSHarness.context(provider: manga, kind: "manga")
        let pages = value(SeanimeJSHarness.call(context, "extractImages", ["m1/c1"])) as? [[String: Any]]
        XCTAssertEqual(pages?.map { $0["url"] as? String }, ["https://img/1.png", "https://img/2.png"])
        XCTAssertEqual(pages?.first?["headers"] as? [String: String], ["Referer": "https://site/"])
    }

    // MARK: - Anime

    func testAnimeSearchIsJSONAndPassesDubAndTheShow() {
        let context = SeanimeJSHarness.context(provider: anime, kind: "anime", dub: true)
        context.evaluateScript("""
        globalThis.__seanimeMedia = { id: 154587, idMal: 52991, romajiTitle: "Sousou no Frieren",
          englishTitle: "Frieren", synonyms: ["Frieren"], episodeCount: 28, format: "TV", status: "FINISHED",
          year: 2023, isAdult: false };
        """)
        guard case .success(let json) = SeanimeJSHarness.call(context, "searchResults", ["Frieren"]) else {
            return XCTFail("search failed")
        }
        let results = SeanimeJSHarness.json(json) as? [[String: Any]]
        XCTAssertEqual(results?.first?["href"] as? String, "a1")
        XCTAssertEqual(results?.first?["image"] as? String, "", "Seanime results have no poster")
        let opts = context.evaluateScript("JSON.stringify(globalThis.lastSearch)").toString() ?? ""
        let search = SeanimeJSHarness.json(opts) as? [String: Any]
        XCTAssertEqual(search?["dub"] as? Bool, true)
        XCTAssertEqual(search?["year"] as? Int, 2023)
        let media = search?["media"] as? [String: Any]
        XCTAssertEqual(media?["romajiTitle"] as? String, "Sousou no Frieren")
        XCTAssertEqual(media?["idMal"] as? Int, 52991)
    }

    func testAnimeSearchFromTheSearchTabUsesTheQuery() {
        let context = SeanimeJSHarness.context(provider: anime, kind: "anime")
        _ = SeanimeJSHarness.call(context, "searchResults", ["Frieren"])
        let opts = SeanimeJSHarness.json(context.evaluateScript("JSON.stringify(globalThis.lastSearch)").toString() ?? "")
            as? [String: Any]
        XCTAssertEqual(opts?["dub"] as? Bool, false)
        let media = opts?["media"] as? [String: Any]
        XCTAssertEqual(media?["englishTitle"] as? String, "Frieren")
        XCTAssertEqual(media?["synonyms"] as? [String], [])
    }

    func testEpisodesRoundTripAndStreamsComeFromEveryServerThatAnswers() {
        let context = SeanimeJSHarness.context(provider: anime, kind: "anime")
        guard case .success(let json) = SeanimeJSHarness.call(context, "extractEpisodes", ["a1"]),
              let episodes = SeanimeJSHarness.json(json) as? [[String: Any]],
              let href = episodes.first?["href"] as? String else { return XCTFail("episodes failed") }
        XCTAssertEqual(episodes.map { $0["number"] as? Int }, [1, 2])
        XCTAssertTrue(href.hasPrefix("seanime-episode:"))

        guard case .success(let streamsJSON) = SeanimeJSHarness.call(context, "extractStreamUrl", [href]),
              let object = SeanimeJSHarness.json(streamsJSON) as? [String: Any] else { return XCTFail("streams failed") }
        let streams = parseStreamResults(from: object)
        XCTAssertEqual(streams.map(\.title), ["ALPHA · 1080p", "BETA · 1080p"], "The broken server is skipped")
        XCTAssertEqual(streams.first?.url.absoluteString, "https://cdn/alpha/e1.m3u8")
        XCTAssertEqual(streams.first?.headers, ["Referer": "https://site/alpha"])
        XCTAssertEqual(streams.first?.subtitle, "https://subs/en.vtt")
        XCTAssertEqual(object["subtitleHeaders"] as? [String: String], ["Referer": "https://site/beta"])
    }

    func testNoServerAnsweringIsAnError() {
        let context = SeanimeJSHarness.context(provider: """
        class Provider {
          getSettings() { return { episodeServers: ["a"], supportsDub: false }; }
          async findEpisodeServer() { throw new Error("down"); }
        }
        """, kind: "anime")
        guard case .failure(let failure) = SeanimeJSHarness.call(context, "extractStreamUrl", ["seanime-episode:{\"id\":\"e1\",\"number\":1}"]) else {
            return XCTFail("Expected an error")
        }
        XCTAssertTrue(failure.message.contains("servers"))
        XCTAssertTrue(failure.message.contains("a: down"), "Each server's reason is kept, for App Logs")
    }

    // MARK: - Cover images

    /// A stand-in for the engine's `fetch`: answers with an empty body.
    private let hostFetch = "globalThis.fetch = async (url, options) => ({ ok: true, status: 200, text: async () => '', json: async () => ({}) });"

    /// MangaBuddy's covers are refused without the Referer the provider sends to its own site —
    /// the one covers get too.
    func testCoversGetTheRefererTheProviderSendsItsSite() {
        let context = SeanimeJSHarness.context(provider: """
        class Provider {
          async search(opts) {
            await fetch("https://api.site.test/search?q=" + opts.query, { headers: { Referer: "https://site.test/" } });
            return [{ id: "m1", title: "One", image: "https://cdn.test/c.webp" }, { id: "m2", title: "Two" }];
          }
        }
        """, kind: "manga", host: hostFetch)
        let results = value(SeanimeJSHarness.call(context, "searchResults", ["x"])) as? [[String: Any]]
        XCTAssertEqual(results?.first?["imageHeaders"] as? [String: String], ["Referer": "https://site.test/"])
        XCTAssertNil(results?.last?["imageHeaders"], "No image, no headers")
    }

    /// A provider that sends no Referer: its site's own address, from its first request.
    func testCoversOtherwiseGetTheSitesAddress() {
        let context = SeanimeJSHarness.context(provider: """
        class Provider {
          async search(opts) {
            await fetch("https://www.site2.test/search/?q=" + opts.query);
            return [{ id: "m1", title: "One", image: "https://img.site2.test/c.jpg" }];
          }
        }
        """, kind: "manga", host: hostFetch)
        let results = value(SeanimeJSHarness.call(context, "searchResults", ["x"])) as? [[String: Any]]
        XCTAssertEqual(results?.first?["imageHeaders"] as? [String: String], ["Referer": "https://www.site2.test/"])
    }

    func testTheEngineRecordsCoverHeaders() {
        let recorded = JSEngine.mangaImageHeaders([
            ["title": "One", "id": "m1", "image": "https://cdn.test/c.webp", "imageHeaders": ["Referer": "https://site.test/"]],
            ["title": "Two", "id": "m2", "image": "https://cdn.test/d.webp"],
        ])
        XCTAssertEqual(recorded, ["https://cdn.test/c.webp": ["Referer": "https://site.test/"]])
    }
}
