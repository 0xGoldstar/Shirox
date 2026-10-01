#if os(iOS)
import XCTest
import Network
@testable import Shirox

/// Long responses through the proxy. mpv reads a whole episode file over one request, and the
/// proxy used to cut it after its idle timeout even while bytes were flowing — mpv logged
/// "Stream ends prematurely" and reconnected once a minute.
final class CastProxyStreamingTests: XCTestCase {

    private let proxy = CastProxyServer.shared
    private var upstream: DribblingServer!
    private var savedPort: NWEndpoint.Port!
    private var savedIdleTimeout: TimeInterval!

    override func setUp() async throws {
        savedPort = proxy.port
        savedIdleTimeout = proxy.idleTimeout
        // Clear of the app's own port, which a copy running in a simulator on this Mac may hold.
        proxy.port = 18766
        proxy.idleTimeout = 0.5
        upstream = try await DribblingServer.start(chunks: 12, chunkSize: 1024, interval: 0.15)
        await proxy.startAndWait(headers: [:], reason: "test")
    }

    override func tearDown() async throws {
        proxy.stop(reason: "test")
        upstream.stop()
        proxy.port = savedPort
        proxy.idleTimeout = savedIdleTimeout
    }

    func testABodyThatTakesLongerThanTheIdleTimeoutArrivesWhole() async throws {
        let url = try XCTUnwrap(proxy.loopbackURL(for: upstream.url))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data.count, 12 * 1024, "the proxy hung up part way through")
    }

    /// iOS takes a suspended app's listening socket back without the listener hearing of it: it
    /// still reads as ready while every connection is refused. After the phone had been locked a
    /// while, mpv's reopen was refused on every retry until the player was closed.
    ///
    /// Moving the port under the running proxy stands in for that: nothing answers where its URLs
    /// point, though its listener still reads as ready.
    func testAListenerThatStoppedTakingConnectionsIsReopened() async throws {
        proxy.port = 18768
        let up = await proxy.startAndWait(headers: [:], reason: "test")
        XCTAssertTrue(up)
        let url = try XCTUnwrap(proxy.loopbackURL(for: upstream.url))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data.count, 12 * 1024)
    }

    /// A connection with nothing moving on it is still reclaimed.
    func testAConnectionWithNothingMovingIsClosed() async throws {
        let closed = expectation(description: "closed")
        closed.assertForOverFulfill = false
        let connection = NWConnection(host: "127.0.0.1", port: proxy.port, using: .tcp)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
                    if isComplete || error != nil { closed.fulfill() }
                }
            }
        }
        connection.start(queue: .global())
        await fulfillment(of: [closed], timeout: 5)
        connection.cancel()
    }
}

/// An upstream that sends its body a chunk at a time, `interval` apart.
final class DribblingServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.dribbling-server")
    private let chunks: Int
    private let chunkSize: Int
    private let interval: TimeInterval
    private(set) var url: URL!

    private init(listener: NWListener, chunks: Int, chunkSize: Int, interval: TimeInterval) {
        self.listener = listener
        self.chunks = chunks
        self.chunkSize = chunkSize
        self.interval = interval
    }

    static func start(chunks: Int, chunkSize: Int, interval: TimeInterval) async throws -> DribblingServer {
        let server = DribblingServer(listener: try NWListener(using: .tcp, on: .any),
                                     chunks: chunks, chunkSize: chunkSize, interval: interval)
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            var resumed = false
            server.listener.stateUpdateHandler = { state in
                guard case .ready = state, !resumed else { return }
                resumed = true
                ready.resume()
            }
            server.listener.newConnectionHandler = { [weak server] in server?.serve($0) }
            server.listener.start(queue: server.queue)
        }
        server.url = URL(string: "http://127.0.0.1:\(server.listener.port!.rawValue)/episode.mkv")
        return server
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] _, _, _, _ in
            let head = "HTTP/1.1 200 OK\r\nContent-Type: video/x-matroska\r\n" +
                "Content-Length: \(chunks * chunkSize)\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .idempotent)
            send(chunk: 0, on: connection)
        }
    }

    private func send(chunk: Int, on connection: NWConnection) {
        guard chunk < chunks else { return }
        queue.asyncAfter(deadline: .now() + interval) { [self] in
            connection.send(content: Data(repeating: 0x41, count: chunkSize), completion: .idempotent)
            send(chunk: chunk + 1, on: connection)
        }
    }
}
#endif
