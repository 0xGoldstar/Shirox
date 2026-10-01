#if os(iOS)
import XCTest
import Network
@testable import Shirox

/// The proxy's port can be taken — by another app, or by a second copy of this one in another
/// simulator on the same Mac. Its listener then never comes up, and waiting for it used to hang
/// forever: mpv sat on a black screen with nothing logged.
final class CastProxyBusyPortTests: XCTestCase {

    private let proxy = CastProxyServer.shared
    private var blocker: NWListener!
    private var savedPort: NWEndpoint.Port!

    override func setUp() async throws {
        savedPort = proxy.port
        blocker = try NWListener(using: .tcp, on: 18767)
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            var resumed = false
            blocker.stateUpdateHandler = { state in
                guard case .ready = state, !resumed else { return }
                resumed = true
                ready.resume()
            }
            blocker.newConnectionHandler = { $0.cancel() }
            blocker.start(queue: .global())
        }
        proxy.port = 18767
    }

    override func tearDown() async throws {
        proxy.port = savedPort
        blocker.cancel()
    }

    func testWaitingForAListenerThatCantBindGivesUp() async {
        let started = Date()
        let up = await proxy.startAndWait(headers: [:], reason: "test", timeout: 0.5)
        proxy.stop(reason: "test")
        XCTAssertFalse(up)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    /// mpv then fetches the stream itself, headers and all, rather than not at all.
    @MainActor
    func testMPVGoesDirectWhenTheProxyWontComeUp() async {
        let router = MPVProxyRouter(readyTimeout: 0.5)
        let source = PlaybackSource(url: URL(string: "https://cdn.invalid/ep1.mkv")!,
                                    headers: ["Referer": "https://site.invalid/"])
        let routed = await router.route(source)
        router.release()
        XCTAssertEqual(routed.url, source.url)
        XCTAssertEqual(routed.headers, source.headers)
    }
}
#endif
