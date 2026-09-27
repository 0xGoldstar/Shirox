import XCTest
@testable import Shirox

/// A link given to Add Module that isn't a module is named for what it is.
@MainActor
final class ModuleLinkErrorTests: XCTestCase {
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])

    private func response(_ url: URL, status: Int = 200, type: String? = "text/plain") -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                        headerFields: type.map { ["Content-Type": $0] })!
    }

    private func diagnose(_ body: Data, at link: String, status: Int = 200,
                          type: String? = "text/plain") -> ModuleLinkError {
        let url = URL(string: link)!
        return ModuleLinkError.diagnose(body, response: response(url, status: status, type: type), url: url)
    }

    func testAProvidersIconIsAnImage() {
        XCTAssertEqual(diagnose(pngBytes, at: "https://raw.example.com/public/mangabuddy.png", type: "image/png"), .image)
        XCTAssertEqual(diagnose(Data("\0\0\0\u{1C}ftypavif".utf8), at: "https://example.com/icon.avif", type: "image/avif"), .image)
    }

    func testAnImageIsKnownByItsBytesWhateverTheServerCallsIt() {
        XCTAssertEqual(diagnose(pngBytes, at: "https://example.com/download?id=7", type: "application/octet-stream"), .image)
        XCTAssertEqual(diagnose(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]), at: "https://example.com/c", type: nil), .image)
    }

    func testAnSVGIsAnImage() {
        let svg = Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"></svg>"#.utf8)
        XCTAssertEqual(diagnose(svg, at: "https://raw.example.com/icon.svg"), .image)
    }

    func testAGitHubFilePageIsAWebPage() {
        let page = Data("<!DOCTYPE html>\n<html lang=\"en\"><head><script>function x() {}</script></head></html>".utf8)
        XCTAssertEqual(diagnose(page, at: "https://github.com/pal/providers/blob/main/manifest.json",
                                type: "text/html; charset=utf-8"), .webPage)
    }

    func testTheSeanimeMarketplaceIsAList() {
        let list = Data(#"[{"id":"mangabuddy","name":"MangaBuddy","type":"manga-provider","manifestURI":"https://x/manifest.json"}]"#.utf8)
        XCTAssertEqual(diagnose(list, at: "https://raw.example.com/marketplace/main.json"), .seanimeList)
    }

    func testAProvidersScriptIsAScript() {
        let script = Data("/// <reference path=\"./manga-provider.d.ts\" />\nclass Provider {\n  async search() { return [] }\n}".utf8)
        XCTAssertEqual(diagnose(script, at: "https://raw.example.com/mangabuddy/provider.js"), .script)
        XCTAssertEqual(diagnose(Data("export const baseUrl = 'https://example.com'".utf8),
                                at: "https://raw.example.com/animeheaven/utils.ts"), .script)
        XCTAssertEqual(diagnose(Data("async function searchResults(k) { return '[]' }".utf8),
                                at: "https://example.com/raw/abc123"), .script)
    }

    func testAMissingFileSaysSo() {
        XCTAssertEqual(diagnose(Data("404: Not Found".utf8), at: "https://raw.example.com/nope/manifest.json", status: 404),
                       .unreachable(404))
    }

    func testOtherJSONIsNotAModule() {
        XCTAssertEqual(diagnose(Data(#"{"hello":"world"}"#.utf8), at: "https://example.com/config.json"), .notAModule)
        XCTAssertEqual(diagnose(Data("[1, 2, 3]".utf8), at: "https://example.com/list.json"), .notAModule)
    }

    func testAddModuleShowsWhatTheLinkIs() async throws {
        let icon = FileManager.default.temporaryDirectory.appendingPathComponent("mangabuddy.png")
        try pngBytes.write(to: icon)
        defer { try? FileManager.default.removeItem(at: icon) }
        let manager = ModuleManager.shared
        let before = manager.modules

        await manager.addModule(from: icon)

        XCTAssertEqual(manager.errorMessage, ModuleLinkError.image.errorDescription)
        XCTAssertEqual(manager.modules, before)
        manager.errorMessage = nil
    }
}
