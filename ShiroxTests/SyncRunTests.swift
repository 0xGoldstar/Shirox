import XCTest
@testable import Shirox

/// Guards the users who will never connect a third service: with exactly two sides signed in,
/// the generated run list must offer the same runs the old fixed `Direction` cases did.
final class SyncRunTests: XCTestCase {

    private let bothSides: [LibrarySide] = [.anilist, .mal]

    func testSyncSectionOffersTheAllWaysMergeAndBothOneWayCopies() {
        let runs = SyncRun.runs(in: .sync, among: bothSides)

        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs.first, SyncRun(source: nil, target: nil, kind: .merge))
        XCTAssertEqual(
            Set(runs.dropFirst().map { "\($0.source!.rawValue)->\($0.target!.rawValue)" }),
            ["anilist->mal", "mal->anilist"])
        XCTAssertTrue(runs.dropFirst().allSatisfy { $0.kind == .copyForward })
    }

    func testOverwriteSectionOffersOneRunPerTarget() {
        let runs = SyncRun.runs(in: .overwrite, among: bothSides)

        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.map(\.target), [.anilist, .mal])
        XCTAssertEqual(runs.map(\.source), [.mal, .anilist])
        XCTAssertTrue(runs.allSatisfy { $0.kind == .overwrite })
    }

    func testMirrorSectionOffersOneRunPerTarget() {
        let runs = SyncRun.runs(in: .mirror, among: bothSides)

        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.map(\.target), [.anilist, .mal])
        XCTAssertTrue(runs.allSatisfy { $0.kind == .mirror })
    }

    /// A single signed-in service has nothing to sync against, so no run is offered at all.
    func testOneSideOffersNothing() {
        for section in SyncRun.Section.allCases {
            XCTAssertTrue(SyncRun.runs(in: section, among: [.anilist]).isEmpty)
        }
    }

    /// Only overwrite and mirror can destroy history; merges and copies never can.
    func testOnlyOverwriteAndMirrorAreDestructive() {
        XCTAssertFalse(SyncRun(source: nil, target: nil, kind: .merge).isDestructive)
        XCTAssertFalse(SyncRun(source: .anilist, target: .mal, kind: .copyForward).isDestructive)
        XCTAssertTrue(SyncRun(source: .anilist, target: .mal, kind: .overwrite).isDestructive)
        XCTAssertTrue(SyncRun(source: .anilist, target: .mal, kind: .mirror).isDestructive)
    }

    /// The all-ways merge writes to every side; a targeted run writes only to its target.
    func testWritesToOnlyTheTargetUnlessItIsTheAllWaysMerge() {
        let merge = SyncRun(source: nil, target: nil, kind: .merge)
        XCTAssertTrue(merge.writes(to: .anilist))
        XCTAssertTrue(merge.writes(to: .mal))

        let intoMAL = SyncRun(source: .anilist, target: .mal, kind: .copyForward)
        XCTAssertFalse(intoMAL.writes(to: .anilist))
        XCTAssertTrue(intoMAL.writes(to: .mal))
    }

    /// The arrow always reads source -> target, so the head points at the account that changes.
    func testTitleReadsSourceToTarget() {
        XCTAssertEqual(
            SyncRun(source: .anilist, target: .mal, kind: .copyForward).title,
            "AniList → MyAnimeList")
        XCTAssertEqual(
            SyncRun(source: nil, target: nil, kind: .merge).title,
            "AniList ⇄ MyAnimeList")
    }

    /// Each run needs a stable identity of its own, or SwiftUI's ForEach reuses rows between
    /// two runs that differ only in direction.
    func testRunsHaveDistinctIdentities() {
        let all = SyncRun.Section.allCases.flatMap { SyncRun.runs(in: $0, among: bothSides) }
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }
}
