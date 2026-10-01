import XCTest
@testable import Shirox

final class HostBlocklistTests: XCTestCase {

    func testParseHandlesHostsFileAndBareLinesAndComments() {
        let contents = """
        # a comment
        127.0.0.1 badporn.com
        0.0.0.0 evil-hentai.net
        another-adult.org

        127.0.0.1 localhost
        """
        let set = HostBlocklist.parse(contents)
        XCTAssertTrue(set.contains("badporn.com"))
        XCTAssertTrue(set.contains("evil-hentai.net"))
        XCTAssertTrue(set.contains("another-adult.org"))
        XCTAssertFalse(set.contains("localhost"))   // skipped
        XCTAssertFalse(set.contains(""))            // blank line skipped
    }

    func testParseLowercasesHosts() {
        XCTAssertTrue(HostBlocklist.parse("0.0.0.0 BadPorn.COM").contains("badporn.com"))
    }

    func testParseHandlesInlineCommentsTabsAndCRLF() {
        let set = HostBlocklist.parse("0.0.0.0 first.com # why\r\n0.0.0.0\tsecond.net\t\r\n  third.org  \r\n#0.0.0.0 fourth.com")
        XCTAssertEqual(set, ["first.com", "second.net", "third.org"])
    }

    /// Parsed on every launch, so it was made faster; it must still read the shipped list exactly
    /// as the Foundation-based parser it replaced did.
    func testParseMatchesTheOriginalParserOnTheShippedList() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "adult_hosts", withExtension: "txt"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(HostBlocklist.parse(contents), Self.originalParse(contents))
    }

    private static func originalParse(_ contents: String) -> Set<String> {
        var result = Set<String>()
        contents.enumerateLines { line, _ in
            var s = line
            if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
            s = s.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return }
            let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let host = (parts.last ?? "").lowercased()
            guard !host.isEmpty, host != "localhost", host.contains(".") else { return }
            result.insert(host)
        }
        return result
    }

    func testExactHostBlocked() {
        let set: Set<String> = ["badporn.com"]
        XCTAssertTrue(HostBlocklist.isHostBlocked("badporn.com", in: set))
    }

    func testSubdomainBlocked() {
        let set: Set<String> = ["badporn.com"]
        XCTAssertTrue(HostBlocklist.isHostBlocked("cdn.videos.badporn.com", in: set))
    }

    func testLookalikeNotBlocked() {
        let set: Set<String> = ["porn.com"]
        XCTAssertFalse(HostBlocklist.isHostBlocked("notporn.com", in: set))
        XCTAssertFalse(HostBlocklist.isHostBlocked("pornial.com", in: set))
    }

    func testUnrelatedHostNotBlocked() {
        let set: Set<String> = ["badporn.com"]
        XCTAssertFalse(HostBlocklist.isHostBlocked("anilist.co", in: set))
    }

    func testCaseInsensitiveMatch() {
        let set: Set<String> = ["badporn.com"]
        XCTAssertTrue(HostBlocklist.isHostBlocked("CDN.BadPorn.Com", in: set))
    }

    func testDoesNotBlockBareTLD() {
        let set: Set<String> = ["com"]   // pathological entry must not nuke everything
        XCTAssertFalse(HostBlocklist.isHostBlocked("anilist.com", in: set))
    }

    func testLoadForTestingPopulatesIsBlocked() {
        HostBlocklist.loadForTesting(["badporn.com"])
        XCTAssertTrue(HostBlocklist.shared.isBlocked(URL(string: "https://cdn.badporn.com/a.m3u8")!))
        XCTAssertFalse(HostBlocklist.shared.isBlocked(URL(string: "https://anilist.co")!))
    }
}
