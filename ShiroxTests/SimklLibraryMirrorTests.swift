import XCTest
@testable import Shirox

/// Mirror Edits from the Simkl list: where they go, and what they must not undo on arrival.
@MainActor
final class SimklLibraryMirrorTests: XCTestCase {

    private let everyone: [LibrarySide] = [.anilist, .mal, .simkl]

    func testSimklEditsMirrorWhereSyncTargetsSays() {
        XCTAssertEqual(SimklLibraryMirror.targets(in: [.simkl, .anilist, .mal], signedIn: everyone), [.anilist, .mal])
        XCTAssertEqual(SimklLibraryMirror.targets(in: [.simkl, .mal], signedIn: everyone), [.mal])
    }

    func testNoMirroringWhenSimklIsNotATarget() {
        XCTAssertEqual(SimklLibraryMirror.targets(in: [.anilist, .mal], signedIn: everyone), [])
    }

    func testASignedOutSideIsNotWritten() {
        XCTAssertEqual(SimklLibraryMirror.targets(in: [.simkl, .anilist, .mal], signedIn: [.mal, .simkl]), [.mal])
    }

    /// Simkl can't say "rewatching": its Watching is what a rewatch looks like there.
    func testWatchingNeverDemotesARewatch() {
        XCTAssertEqual(SimklLibraryMirror.mirroredStatus(.current, over: .repeating), .repeating)
        XCTAssertEqual(SimklLibraryMirror.mirroredStatus(.completed, over: .repeating), .completed)
        XCTAssertEqual(SimklLibraryMirror.mirroredStatus(.current, over: nil), .current)
    }

    func testUnratedLeavesTheOtherScoreAlone() {
        XCTAssertNil(SimklLibraryMirror.mirroredScore(0, in: .point100))
    }

    func testScoresConvertToTheOtherScale() {
        XCTAssertEqual(SimklLibraryMirror.mirroredScore(8, in: .point100), 80)
        XCTAssertEqual(SimklLibraryMirror.mirroredScore(8, in: .point5), 4)
        XCTAssertEqual(SimklLibraryMirror.mirroredScore(8, in: .point10), 8)
    }
}
