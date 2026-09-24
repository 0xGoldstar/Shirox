import XCTest
@testable import Shirox

final class SimklPlayContextTests: XCTestCase {

    private let savedItem = """
    {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","mediaTitle":"Dark Season 2","episodeNumber":5,
     "imageUrl":"","streamUrl":"https://example.com/v.m3u8","watchedSeconds":120,"totalSeconds":2400,
     "lastWatchedAt":0}
    """

    /// Items saved before this change carry no Simkl reference, and must still load.
    func testAnItemSavedBeforeThisStillDecodes() throws {
        let item = try JSONDecoder().decode(ContinueWatchingItem.self, from: Data(savedItem.utf8))
        XCTAssertNil(item.simklTitle)
        XCTAssertEqual(item.episodeNumber, 5)
    }

    func testAnItemKeepsItsSimklReference() throws {
        var item = try JSONDecoder().decode(ContinueWatchingItem.self, from: Data(savedItem.utf8))
        item.simklTitle = SimklPlayRef(simklID: 2090, kind: .tv, season: 2)
        let decoded = try JSONDecoder().decode(ContinueWatchingItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.simklTitle, SimklPlayRef(simklID: 2090, kind: .tv, season: 2))
    }
}
