import XCTest
@testable import Shirox

/// Decoding against the shape Simkl actually returns, not the one its docs imply.
///
/// The first live read failed with `Expected to decode Int but found a string instead` at
/// `anime[0].show.ids.mal` — Simkl sends external ids as strings. These fixtures are taken from
/// that response so the mismatch cannot come back.
final class SimklDecodingTests: XCTestCase {

    private func entries(from json: String) throws -> [LibraryEntry] {
        try SimklLibraryService.decodeLibrary(from: Data(json.utf8))
    }

    /// The shape that broke: ids as strings.
    func testDecodesIdsSentAsStrings() throws {
        let entries = try self.entries(from: """
        {"anime":[{"show":{"title":"Frieren","ids":{"simkl":1234,"mal":"52991","anilist":"154587"}},
          "status":"watching","watched_episodes_count":13,"total_episodes_count":28,"user_rating":9}]}
        """)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].media.idMal, 52991)
        XCTAssertEqual(entries[0].progress, 13)
        XCTAssertEqual(entries[0].status, .current)
        XCTAssertEqual(entries[0].score, 9)
    }

    /// Numeric ids must keep working — Simkl is inconsistent about which form it sends.
    func testDecodesIdsSentAsNumbers() throws {
        let entries = try self.entries(from: """
        {"anime":[{"show":{"title":"Frieren","ids":{"simkl":1234,"mal":52991}},
          "status":"completed","watched_episodes_count":28,"total_episodes_count":28}]}
        """)

        XCTAssertEqual(entries[0].media.idMal, 52991)
        XCTAssertEqual(entries[0].status, .completed)
    }

    /// An unrated title is score 0, not a spurious rating.
    func testMissingRatingIsUnrated() throws {
        let entries = try self.entries(from: """
        {"anime":[{"show":{"title":"X","ids":{"mal":"1"}},"status":"hold","watched_episodes_count":2}]}
        """)

        XCTAssertEqual(entries[0].score, 0)
        XCTAssertEqual(entries[0].status, .paused)
    }

    /// A title with no usable id cannot be paired with anything, so it is dropped rather than
    /// failing the whole read.
    func testEntryWithNoUsableIdIsSkippedNotFatal() throws {
        let entries = try self.entries(from: """
        {"anime":[{"show":{"title":"X","ids":{"simkl":99}},"status":"watching","watched_episodes_count":1},
                  {"show":{"title":"Y","ids":{"mal":"7"}},"status":"watching","watched_episodes_count":1}]}
        """)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].media.idMal, 7)
    }

    /// An empty library is a valid answer, not an error.
    func testEmptyLibraryDecodes() throws {
        XCTAssertTrue(try entries(from: #"{"anime":[]}"#).isEmpty)
        XCTAssertTrue(try entries(from: #"{}"#).isEmpty)
    }

    /// Every status Simkl can send maps back; anything unknown falls back to the numbers.
    func testEveryStatusMapsBack() {
        XCTAssertEqual(SimklLibraryService.status(from: "plantowatch", progress: 0, total: 12), .planning)
        XCTAssertEqual(SimklLibraryService.status(from: "completed", progress: 12, total: 12), .completed)
        XCTAssertEqual(SimklLibraryService.status(from: "dropped", progress: 3, total: 12), .dropped)
        XCTAssertEqual(SimklLibraryService.status(from: "hold", progress: 3, total: 12), .paused)
        XCTAssertEqual(SimklLibraryService.status(from: "watching", progress: 3, total: 12), .current)
        XCTAssertEqual(SimklLibraryService.status(from: nil, progress: 12, total: 12), .completed)
        XCTAssertEqual(SimklLibraryService.status(from: nil, progress: 3, total: 12), .current)
    }
}
