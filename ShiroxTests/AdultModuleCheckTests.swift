import XCTest
@testable import Shirox

/// Adult modules can't be added, updated into, or kept: known by their names, their links,
/// or the adult sites they reach.
@MainActor
final class AdultModuleCheckTests: XCTestCase {
    private func module(name: String, jsonUrl: String? = nil, baseUrl: String? = nil,
                        script: String? = nil) -> ModuleDefinition {
        var object: [String: Any] = ["sourceName": name, "version": "1.0.0", "type": "anime",
                                     "scriptUrl": "https://raw.example.com/\(UUID().uuidString)/provider.js"]
        if let jsonUrl { object["jsonUrl"] = jsonUrl }
        if let baseUrl { object["baseUrl"] = baseUrl }
        if let script { object["scriptContent"] = script }
        return try! JSONDecoder().decode(ModuleDefinition.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private let adultHosts: Set<String> = ["hentaiworld.me", "badsite.com"]
    private func blocked(_ host: String) -> Bool { HostBlocklist.isHostBlocked(host, in: adultHosts) }

    func testTheMarketplacesAdultProvidersHaveAdultNames() {
        for name in ["HentaiSaturn", "HentaiWorld", "MangaWorldAdult", "nhentai", "PornHub Anime",
                     "XXX Streams", "Rule34 Viewer", "NSFW Reader", "hanime-sex"] {
            XCTAssertTrue(AdultModuleCheck.hasAdultName(name), name)
        }
    }

    func testOrdinaryNamesPass() {
        for name in ["AnimeHeaven", "MangaBuddy", "AnimeGG", "Adult Swim", "Toonami AdultSwim",
                     "Eromanga Sensei Fans", "Analog Anime", "Sussex Streams", "Maxx Xander"] {
            XCTAssertFalse(AdultModuleCheck.hasAdultName(name), name)
        }
    }

    func testAModuleIsAdultByItsName() {
        XCTAssertTrue(AdultModuleCheck.isAdult(module(name: "HentaiSaturn"), blockedHost: blocked))
        XCTAssertFalse(AdultModuleCheck.isAdult(module(name: "AnimeGG"), blockedHost: blocked))
    }

    func testAModuleIsAdultByItsLink() {
        let adult = module(name: "Saturn", jsonUrl: "https://raw.example.com/pal/providers/main/src/anime/hentaisaturn/manifest.json")
        XCTAssertTrue(AdultModuleCheck.isAdult(adult, blockedHost: blocked))
    }

    func testAModuleIsAdultByTheSitesItReaches() {
        let script = #"class Provider { constructor() { this.base = "https://www.hentaiworld.me"; } }"#
        XCTAssertTrue(AdultModuleCheck.isAdult(module(name: "World", script: script), blockedHost: blocked))
        XCTAssertTrue(AdultModuleCheck.isAdult(module(name: "Site", baseUrl: "https://badsite.com/"), blockedHost: blocked))
        let ordinary = #"const base = "https://www.animegg.org"; fetch("https://graphql.anilist.co")"#
        XCTAssertFalse(AdultModuleCheck.isAdult(module(name: "AnimeGG", script: ordinary), blockedHost: blocked))
    }

    func testAddModuleRefusesAnAdultModule() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("provider.js")
        try Data("async function searchResults() { return '[]' }".utf8).write(to: script)
        let manifest = folder.appendingPathComponent("module.json")
        let json: [String: Any] = ["sourceName": "HentaiWorld", "version": "1.0.0", "type": "anime",
                                   "scriptUrl": script.absoluteString]
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        let manager = ModuleManager.shared
        let before = manager.modules

        await manager.addModule(from: manifest)

        XCTAssertEqual(manager.errorMessage, ModuleLinkError.adult.errorDescription)
        XCTAssertEqual(manager.modules, before)
        manager.errorMessage = nil
    }

    func testInstalledAdultModulesAreRemovedAndOthersKept() {
        let manager = ModuleManager.shared
        manager.removeAdultModules()
        let before = manager.modules
        let ordinary = module(name: "AnimeGG")
        manager.modules.append(contentsOf: [module(name: "MangaWorldAdult"), ordinary])

        manager.removeAdultModules()

        XCTAssertEqual(manager.modules, before + [ordinary])
        manager.removeModule(ordinary)
    }
}
