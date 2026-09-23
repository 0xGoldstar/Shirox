import XCTest
@testable import Shirox

/// Progress is typed now, not only stepped — adding 200 episodes was 200 taps. What the field
/// accepts is pinned here: digits only, never past what the title has.
final class ProgressInputTests: XCTestCase {

    func testATypedNumberIsTaken() {
        XCTAssertEqual(LibraryEntryEditSheet.typedProgress("200", max: 9999), 200)
    }

    func testItNeverGoesPastTheTitlesTotal() {
        XCTAssertEqual(LibraryEntryEditSheet.typedProgress("25", max: 12), 12)
    }

    func testAClearedOrJunkFieldIsZero() {
        XCTAssertEqual(LibraryEntryEditSheet.typedProgress("", max: 12), 0)
        XCTAssertEqual(LibraryEntryEditSheet.typedProgress("abc", max: 12), 0)
    }

    /// A stray character doesn't throw the number away.
    func testNonDigitsAreIgnored() {
        XCTAssertEqual(LibraryEntryEditSheet.typedProgress("1 2", max: 9999), 12)
    }
}
