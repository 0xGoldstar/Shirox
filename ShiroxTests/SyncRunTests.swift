import XCTest
@testable import Shirox

/// Guards the users who will never connect a third service: with exactly two sides signed in,
/// the generated run list must offer the same runs the old fixed `Direction` cases did.
final class SyncRunTests: XCTestCase {

    private let bothSides: [LibrarySide] = [.anilist, .mal]

    func testSyncSectionOffersTheAllWaysMergeAndBothOneWayCopies() {
        let runs = SyncRun.runs(in: .sync, among: bothSides)

        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs.first, SyncRun(source: nil, target: nil, kind: .merge, sides: bothSides))
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
        // The merge names the sides actually signed in, never every case the enum has.
        XCTAssertEqual(
            SyncRun.runs(in: .sync, among: bothSides).first?.title,
            "AniList ⇄ MyAnimeList")
        XCTAssertEqual(
            SyncRun.runs(in: .sync, among: [.anilist, .mal, .simkl]).first?.title,
            "AniList ⇄ MyAnimeList ⇄ Simkl")
    }

    /// A copy-forward and an overwrite between the same two sides share a title, so a log line
    /// carrying only the title cannot say which ran. That ambiguity hid a bug where overwrite
    /// runs queued their Simkl writes and never sent them: the logs were indistinguishable from
    /// the copy-forward path, which did flush.
    func testCopyForwardAndOverwriteShareATitleButNotAnIdentity() {
        let copy = SyncRun(source: .anilist, target: .simkl, kind: .copyForward)
        let overwrite = SyncRun(source: .anilist, target: .simkl, kind: .overwrite)

        XCTAssertEqual(copy.title, overwrite.title, "the titles really are identical")
        XCTAssertNotEqual(copy.id, overwrite.id, "so identity must come from the kind")
        XCTAssertNotEqual(copy.kind.rawValue, overwrite.kind.rawValue)
    }

    /// Every run that writes to Simkl must be one the flush covers, whichever path it takes.
    func testEveryKindThatWritesToSimklIsIdentifiable() {
        for kind in [SyncRun.Kind.copyForward, .overwrite, .mirror] {
            let run = SyncRun(source: .anilist, target: .simkl, kind: kind)
            XCTAssertTrue(run.writes(to: .simkl))
            XCTAssertFalse(run.kind.rawValue.isEmpty)
        }
        XCTAssertTrue(SyncRun(source: nil, target: nil, kind: .merge, sides: [.anilist, .simkl])
            .writes(to: .simkl))
    }

    /// Each run needs a stable identity of its own, or SwiftUI's ForEach reuses rows between
    /// two runs that differ only in direction.
    func testRunsHaveDistinctIdentities() {
        let all = SyncRun.Section.allCases.flatMap { SyncRun.runs(in: $0, among: bothSides) }
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }
}
