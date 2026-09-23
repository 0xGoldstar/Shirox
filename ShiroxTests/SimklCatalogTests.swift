import XCTest
@testable import Shirox

/// Simkl's catalog, as the Tracking Links sheet reads it. Its docs name the id both `simkl` and
/// `simkl_id`, and a missing id comes back `200 []` rather than a 404 — both are handled here.
@MainActor
final class SimklCatalogTests: XCTestCase {

    func testSearchResultsDecodeEitherIdSpelling() throws {
        let json = #"""
        [{"title":"Death Parade","year":2015,"endpoint_type":"anime","type":"tv","poster":"74/7412345abc","ids":{"simkl_id":37145,"slug":"death-parade"}},
         {"title":"Death Billiards","year":2013,"endpoint_type":"anime","type":"movie","ids":{"simkl":38000,"slug":"death-billiards"}}]
        """#
        let items = try SimklCatalog.decodeSearch(Data(json.utf8))
        XCTAssertEqual(items.map(\.simklID), [37145, 38000])
        XCTAssertEqual(items.first?.year, 2015)
        XCTAssertEqual(items.first?.posterURL?.absoluteString,
                       "https://wsrv.nl/?url=https://simkl.in/posters/74/7412345abc_m.webp&q=90")
        XCTAssertNil(items.last?.posterURL)
    }

    func testALookupOfAMissingIdIsNil() throws {
        XCTAssertNil(try SimklCatalog.decodeLookup(Data("[]".utf8)))
    }

    func testALookupDecodesTheItem() throws {
        let json = #"{"title":"Death Parade","year":2015,"ids":{"simkl":37145,"mal":"28223"}}"#
        XCTAssertEqual(try SimklCatalog.decodeLookup(Data(json.utf8))?.simklID, 37145)
    }

    /// Simkl asks for Authorization to be left off cached catalog calls, which are free.
    func testCatalogRequestsCarryNoToken() throws {
        let request = SimklAuthManager.shared.catalogRequest(path: "/anime/37145")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains { $0.name == "client_id" })
    }
}
