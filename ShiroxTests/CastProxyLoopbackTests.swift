#if os(iOS)
import XCTest
@testable import Shirox

/// The proxy for a client on this device — mpv — rather than one on the LAN.
final class CastProxyLoopbackTests: XCTestCase {

    func testALoopbackURLPointsAtThisDeviceWithTheOriginalInside() throws {
        let original = URL(string: "https://vault-08.uwucdn.top/hls/08/14/abc/owo.m3u8")!
        let proxied = try XCTUnwrap(CastProxyServer.shared.loopbackURL(for: original))
        let parts = try XCTUnwrap(URLComponents(url: proxied, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "http")
        XCTAssertEqual(parts.host, "127.0.0.1")
        XCTAssertEqual(parts.port, 8766)
        XCTAssertEqual(parts.path, "/proxy")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "url" }?.value, original.absoluteString)
        XCTAssertNotNil(parts.queryItems?.first { $0.name == "t" }?.value, "signed like every proxied URL")
    }

    /// A playlist fetched over loopback is rewritten with loopback URLs, so its segments work
    /// without Wi-Fi too.
    func testALoopbackClientIsRecognisedByItsHost() {
        XCTAssertTrue(CastProxyServer.isLoopback(hostHeader: "127.0.0.1:8766"))
        XCTAssertTrue(CastProxyServer.isLoopback(hostHeader: "localhost:8766"))
        XCTAssertTrue(CastProxyServer.isLoopback(hostHeader: "LOCALHOST"))
        XCTAssertFalse(CastProxyServer.isLoopback(hostHeader: "192.168.1.20:8766"))
        XCTAssertFalse(CastProxyServer.isLoopback(hostHeader: nil))
    }
}
#endif
