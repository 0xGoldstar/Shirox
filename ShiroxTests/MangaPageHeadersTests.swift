import XCTest
@testable import Shirox

/// A page may carry its own headers — a Seanime provider's Referer — which the reader and
/// downloads send. Pages without keep today's rule.
@MainActor
final class MangaPageHeadersTests: XCTestCase {
    func testPagesAreReadAsAddressesOrWithHeaders() {
        let pages = JSEngine.parseMangaPages(["https://a/1.png", ["url": "https://a/2.png", "headers": ["Referer": "https://site/"]], "", 7])
        XCTAssertEqual(pages.map(\.url), ["https://a/1.png", "https://a/2.png"])
        XCTAssertEqual(pages.map(\.headers), [[:], ["Referer": "https://site/"]])
    }

    func testAPagesHeadersWinOverTodaysRule() {
        let store = MangaPageHeaders.shared
        store.record(["Referer": "https://mangak.io/"], for: "https://cdn.example/p1.webp")
        let headers = KingfisherImageCache.headers(for: URL(string: "https://cdn.example/p1.webp")!,
                                                   cookieHeader: nil, bypassUserAgent: nil,
                                                   refererOverride: "https://other.example/")
        XCTAssertEqual(headers["Referer"], "https://mangak.io/")
    }

    func testAPageWithoutHeadersKeepsTodaysRule() {
        let headers = KingfisherImageCache.headers(for: URL(string: "https://cdn.example/unrecorded.webp")!,
                                                   cookieHeader: nil, bypassUserAgent: nil,
                                                   refererOverride: "https://other.example/")
        XCTAssertEqual(headers["Referer"], "https://other.example/")
    }
}
