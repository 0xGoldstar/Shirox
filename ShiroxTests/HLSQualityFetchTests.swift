import XCTest
@testable import Shirox

/// The quality ladder is read from the stream's own URL — which, for a direct MP4 or MKV link, is
/// the episode file. That file used to be downloaded whole into memory beside the player, a
/// second full download of every episode competing with playback for the connection.
final class HLSQualityFetchTests: XCTestCase {

    private func session(_ protocolClass: AnyClass) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        return URLSession(configuration: config)
    }

    private let url = URL(string: "https://cdn.invalid/direct/external/abc")!

    func testAVideoFileIsLeftUnread() async {
        VideoFileProtocol.reset()
        let levels = await HLSQualityParser.parse(url: url, headers: [:], session: session(VideoFileProtocol.self))
        XCTAssertTrue(levels.isEmpty)
        XCTAssertLessThan(VideoFileProtocol.chunksSent, VideoFileProtocol.totalChunks / 4,
                          "the parser read on past the start of a file that isn't a playlist")
    }

    func testAMasterPlaylistIsStillParsed() async {
        PlaylistProtocol.body = Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        720/index.m3u8
        """.utf8)
        PlaylistProtocol.headers = ["Content-Type": "application/vnd.apple.mpegurl"]
        let levels = await HLSQualityParser.parse(url: url, headers: [:], session: session(PlaylistProtocol.self))
        XCTAssertEqual(levels.map(\.label), ["1080p", "720p"])
    }

    func testAZstdPlaylistIsStillParsed() async {
        // "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n360.m3u8\n", zstd -19.
        PlaylistProtocol.body = Data(base64Encoded:
            "KLUv/QRoOQIAI0VYVE0zVQojRVhULVgtU1RSRUFNLUlORjpCQU5EV0lEVEg9ODAwMDAwLFJFU09MVVRJT049NjQweDM2MAozNjAubTN1OAqt6L1X")!
        PlaylistProtocol.headers = ["Content-Encoding": "zstd"]
        let levels = await HLSQualityParser.parse(url: url, headers: [:], session: session(PlaylistProtocol.self))
        XCTAssertEqual(levels.map(\.label), ["360p"])
    }
}

/// A 16 MB video file, sent a chunk at a time; counts how much went out before the client
/// hung up.
private final class VideoFileProtocol: URLProtocol {
    static let totalChunks = 256
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sent = 0
    nonisolated(unsafe) private static var stopped = false

    static var chunksSent: Int { lock.lock(); defer { lock.unlock() }; return sent }
    static func reset() { lock.lock(); sent = 0; stopped = false; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "video/x-matroska",
                                                      "Content-Length": "\(Self.totalChunks * 65_536)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { [self] in
            // An EBML header, as an MKV starts, then filler.
            var chunk = Data([0x1A, 0x45, 0xDF, 0xA3])
            chunk.append(Data(repeating: 0, count: 65_536 - 4))
            for _ in 0..<Self.totalChunks {
                Self.lock.lock()
                let stop = Self.stopped
                if !stop { Self.sent += 1 }
                Self.lock.unlock()
                if stop { return }
                client?.urlProtocol(self, didLoad: chunk)
                usleep(2_000)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.lock.lock(); Self.stopped = true; Self.lock.unlock()
    }
}

private final class PlaylistProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var headers: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
