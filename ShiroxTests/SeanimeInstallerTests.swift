import XCTest
@testable import Shirox

/// A Seanime manifest link, installed as an ordinary Shirox module.
@MainActor
final class SeanimeInstallerTests: XCTestCase {
    private let manifestURL = URL(string: "https://example.com/mangabuddy/manifest.json")!

    private func manifest(type: String = "manga-provider", language: String = "javascript",
                          payload: String? = "https://example.com/provider.js") -> SeanimeManifest {
        var object: [String: Any] = ["id": "mangabuddy", "name": "MangaBuddy", "version": "1.2.0", "type": type,
                                     "language": language, "lang": "en", "author": "Pal",
                                     "icon": "https://example.com/icon.png"]
        if let payload { object["payloadURI"] = payload }
        return SeanimeManifest.detect(try! JSONSerialization.data(withJSONObject: object))!
    }

    private func install(_ manifest: SeanimeManifest, script: String) async throws -> ModuleDefinition {
        try await SeanimeInstaller.module(from: manifest, manifestURL: manifestURL, fetch: { _ in Data(script.utf8) })
    }

    func testASeanimeManifestIsToldApartFromAShiroxOne() {
        XCTAssertNotNil(SeanimeManifest.detect(Data(#"{"id":"x","name":"X","version":"1","type":"manga-provider","payloadURI":"https://x/p.js"}"#.utf8)))
        XCTAssertNil(SeanimeManifest.detect(Data(#"{"sourceName":"X","version":"1","scriptUrl":"https://x/s.js","type":"anime"}"#.utf8)))
    }

    func testAMangaProviderBecomesAMangaModule() async throws {
        let module = try await install(manifest(), script: "class Provider { async search() { return []; } }")
        XCTAssertEqual(module.sourceName, "MangaBuddy")
        XCTAssertEqual(module.version, "1.2.0")
        XCTAssertEqual(module.type, "manga")
        XCTAssertTrue(module.isManga)
        XCTAssertEqual(module.scriptUrl, "https://example.com/provider.js")
        XCTAssertEqual(module.jsonUrl, manifestURL.absoluteString)
        XCTAssertEqual(module.author?.name, "Pal")
        XCTAssertEqual(module.seanime, SeanimeProviderInfo(id: "mangabuddy", kind: .manga, language: "javascript",
                                                           supportsDub: false))
        XCTAssertEqual(module.scriptContent, "class Provider { async search() { return []; } }")
    }

    func testAStreamingProviderRecordsWhetherItDubs() async throws {
        let module = try await install(manifest(type: "onlinestream-provider"), script: """
        class Provider { getSettings() { return { episodeServers: ["a"], supportsDub: true }; } }
        """)
        XCTAssertEqual(module.type, "anime")
        XCTAssertFalse(module.isManga)
        XCTAssertEqual(module.seanime?.kind, .anime)
        XCTAssertEqual(module.seanime?.supportsDub, true)
    }

    func testTypeScriptIsRemovedAtInstall() async throws {
        let module = try await install(manifest(language: "typescript"), script: """
        class Provider { api: string = "x"; async search(opts: { query: string }): Promise<any[]> { return []; } }
        """)
        XCTAssertFalse(module.scriptContent?.contains(": string") ?? true)
        XCTAssertEqual(SeanimeScripts.probe(module.scriptContent ?? "").definesProvider, true)
    }

    /// No torrenting, and nothing Shirox can't run.
    func testOtherKindsAreRefused() async {
        for type in ["anime-torrent-provider", "custom-source", "plugin"] {
            do {
                _ = try await install(manifest(type: type), script: "class Provider {}")
                XCTFail("\(type) installed")
            } catch {
                XCTAssertEqual(error as? SeanimeInstallError, .unsupportedType)
            }
        }
    }

    func testAScriptNeedingMissingHelpersIsRefused() async {
        do {
            _ = try await install(manifest(), script: "class Provider { go() { return ChromeDP.newBrowser() && CryptoJS.AES; } }")
            XCTFail("installed")
        } catch {
            XCTAssertEqual(error as? SeanimeInstallError, .unsupportedHelpers(["ChromeDP", "CryptoJS"]))
        }
        XCTAssertEqual(SeanimeScripts.unsupportedHelpers(in: "const cryptoJSVersion = 1; // not CryptoJS itself? CryptoJS"), ["CryptoJS"])
        XCTAssertEqual(SeanimeScripts.unsupportedHelpers(in: "const myChromeDPish = 1"), [])
    }

    func testAScriptWithoutAProviderIsRefused() async {
        do {
            _ = try await install(manifest(), script: "function nothing() {}")
            XCTFail("installed")
        } catch {
            XCTAssertEqual(error as? SeanimeInstallError, .noProvider)
        }
    }

    func testASavedModuleKeepsItsSeanimeRecord() throws {
        let json = #"{"sourceName":"X","version":"1","scriptUrl":"https://x/p.js","type":"manga","seanime":{"id":"x","kind":"manga","language":"javascript","supportsDub":false}}"#
        let module = try JSONDecoder().decode(ModuleDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(module.seanime?.id, "x")
        let again = try JSONDecoder().decode(ModuleDefinition.self, from: JSONEncoder().encode(module))
        XCTAssertEqual(again.seanime, module.seanime)
    }
}
