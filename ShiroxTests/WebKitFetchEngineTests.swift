import XCTest
@testable import Shirox

/// A module's `fetchv2(url, { engine: "webview" })` runs through a WebView, and its answer comes back.
@MainActor
final class WebKitFetchEngineTests: XCTestCase {
    func testTheWebViewsAnswerComesBack() async throws {
        let answer = try await WebKitFetchEngine.shared.fetch(url: URL(string: "data:text/plain,hello%20shirox")!)
        XCTAssertEqual(String(data: answer.data, encoding: .utf8), "hello shirox")
        XCTAssertEqual(answer.statusCode, 200)
    }
}
