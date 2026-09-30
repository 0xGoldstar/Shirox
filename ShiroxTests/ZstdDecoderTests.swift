import XCTest
@testable import Shirox

/// zstd bodies, which URLSession hands over still compressed.
final class ZstdDecoderTests: XCTestCase {

    /// `{"ok":true,"title":"Frieren"}` as one frame with no declared size, the way a streaming server sends it.
    private let json = Data(base64Encoded: "KLUv/QBY6QAAeyJvayI6dHJ1ZSwidGl0bGUiOiJGcmllcmVuIn0=")!
    /// "one " and "two" as two frames back to back.
    private let twoFrames = Data(base64Encoded: "KLUv/QRYIQAAb25lICmSP9c=")!
        + Data(base64Encoded: "KLUv/QRYGQAAdHdvi0T07A==")!
    /// 100,000 zero bytes in 22.
    private let zeros = Data(base64Encoded: "KLUv/QRoTQAACAABAJyGORAC2yNO8w==")!

    private func response(encoding: String?) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com/api")!, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: encoding.map { ["Content-Encoding": $0] } ?? [:])!
    }

    // MARK: - Decoder

    func testAFrameDecodes() throws {
        XCTAssertEqual(String(decoding: try ZstdDecoder.decompress(json), as: UTF8.self),
                       #"{"ok":true,"title":"Frieren"}"#)
    }

    func testFramesBackToBackAllDecode() throws {
        XCTAssertEqual(String(decoding: try ZstdDecoder.decompress(twoFrames), as: UTF8.self), "one two")
    }

    func testOutputBiggerThanTheScratchBufferComesThroughWhole() throws {
        let out = try ZstdDecoder.decompress(zeros)
        XCTAssertEqual(out.count, 100_000)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }

    func testABodyCutShortIsRefused() {
        XCTAssertThrowsError(try ZstdDecoder.decompress(json.prefix(10))) {
            XCTAssertEqual($0 as? ZstdDecoder.Failure, .truncated)
        }
    }

    func testBytesThatArentZstdAreRefused() {
        XCTAssertThrowsError(try ZstdDecoder.decompress(Data("not zstd".utf8))) {
            guard case .corrupt? = $0 as? ZstdDecoder.Failure else { return XCTFail("\($0)") }
        }
    }

    func testABombStopsAtTheCap() {
        XCTAssertThrowsError(try ZstdDecoder.decompress(zeros, maxOutputBytes: 1_000)) {
            XCTAssertEqual($0 as? ZstdDecoder.Failure, .tooLarge(limit: 1_000))
        }
    }

    func testTheErrorSaysWhatFailed() {
        XCTAssertEqual(ZstdDecoder.Failure.truncated.localizedDescription,
                       "Could not decode zstd response: it ends mid-frame")
    }

    // MARK: - Response bodies

    func testAZstdResponseIsDecoded() throws {
        let body = try HTTPBodyDecoding.decoded(json, response: response(encoding: "zstd"))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"ok":true,"title":"Frieren"}"#)
    }

    func testTheHeaderIsReadInAnyCaseAndInAList() throws {
        XCTAssertEqual(try HTTPBodyDecoding.decoded(json, response: response(encoding: "ZSTD")).count, 29)
        XCTAssertEqual(try HTTPBodyDecoding.decoded(json, response: response(encoding: "identity, zstd")).count, 29)
    }

    func testWithoutTheHeaderTheBodyIsLeftAlone() throws {
        XCTAssertEqual(try HTTPBodyDecoding.decoded(json, response: response(encoding: nil)), json)
        XCTAssertEqual(try HTTPBodyDecoding.decoded(json, response: response(encoding: "gzip")), json)
    }

    /// The header alone isn't enough: a body the system already decoded can keep the header but
    /// loses the magic, and decoding it a second time would fail.
    func testABodyAlreadyDecodedIsLeftAlone() throws {
        let plain = Data(#"{"ok":true}"#.utf8)
        XCTAssertEqual(try HTTPBodyDecoding.decoded(plain, response: response(encoding: "zstd")), plain)
    }

    func testACorruptZstdBodyThrows() {
        XCTAssertThrowsError(try HTTPBodyDecoding.decoded(json.prefix(10), response: response(encoding: "zstd")))
    }
}

/// Serves one canned response to any request, bytes exactly as given, the way a server puts them
/// on the wire. A custom protocol means the system does no content decoding of its own.
private final class CannedResponseProtocol: URLProtocol {
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

final class ZstdSessionTests: XCTestCase {

    private func session(body: Data, headers: [String: String]) -> URLSession {
        CannedResponseProtocol.body = body
        CannedResponseProtocol.headers = headers
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CannedResponseProtocol.self]
        return URLSession(configuration: config)
    }

    private let request = URLRequest(url: URL(string: "https://example.com/api")!)
    private let json = Data(base64Encoded: "KLUv/QBY6QAAeyJvayI6dHJ1ZSwidGl0bGUiOiJGcmllcmVuIn0=")!

    func testASessionHandsBackTheDecodedBody() async throws {
        let (data, _) = try await session(body: json, headers: ["Content-Encoding": "zstd"]).decodedData(for: request)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"ok":true,"title":"Frieren"}"#)
    }

    func testAPlainBodyComesBackAsSent() async throws {
        let plain = Data("hello".utf8)
        let (data, _) = try await session(body: plain, headers: [:]).decodedData(for: request)
        XCTAssertEqual(data, plain)
    }

    func testABrokenZstdBodyFailsTheRequestWithAReason() async {
        do {
            _ = try await session(body: json.prefix(10), headers: ["Content-Encoding": "zstd"]).decodedData(for: request)
            XCTFail("Expected a decode failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Could not decode zstd response: "), "\(error)")
        }
    }
}
