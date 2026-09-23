import XCTest
@testable import Shirox

/// `dualSync` meant "AniList and MyAnimeList", which stopped being a question with an answer once
/// there were three services. Its replacement has to carry every existing user's choice across
/// exactly, and never write an edit to a service the user left out.
final class SyncTargetsTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SyncTargetsTests")
        defaults.removePersistentDomain(forName: "SyncTargetsTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "SyncTargetsTests")
        super.tearDown()
    }

    func testEncodingIsCanonicalAndRoundTrips() {
        XCTAssertEqual(SyncTargets.encode([.simkl, .anilist]), "anilist,simkl")
        XCTAssertEqual(SyncTargets.decode("anilist,simkl"), [.anilist, .simkl])
    }

    func testUnknownAndEmptyPiecesAreIgnored() {
        XCTAssertEqual(SyncTargets.decode("anilist,,trakt"), [.anilist])
        XCTAssertEqual(SyncTargets.decode(""), [])
    }

    func testDualSyncOnMigratesToAniListAndMAL() {
        defaults.set(true, forKey: SyncTargets.legacyKey)
        XCTAssertEqual(SyncTargets.load(defaults), [.anilist, .mal])
    }

    func testDualSyncOffOrNeverSetMigratesToNothing() {
        XCTAssertEqual(SyncTargets.load(defaults), [])
        defaults.removePersistentDomain(forName: "SyncTargetsTests")
        defaults.set(false, forKey: SyncTargets.legacyKey)
        XCTAssertEqual(SyncTargets.load(defaults), [])
    }

    /// Runs once. A user who later emptied the set must not have it re-seeded.
    func testMigrationNeverOverwritesAnExistingChoice() {
        defaults.set("", forKey: SyncTargets.key)
        defaults.set(true, forKey: SyncTargets.legacyKey)
        XCTAssertEqual(SyncTargets.load(defaults), [])
    }

    /// Left in place so a downgrade keeps the AniList ↔ MyAnimeList half of the choice.
    func testLegacyKeyIsKeptInStep() {
        SyncTargets.save([.anilist, .simkl], defaults)
        XCTAssertFalse(defaults.bool(forKey: SyncTargets.legacyKey))
        SyncTargets.save([.anilist, .mal], defaults)
        XCTAssertTrue(defaults.bool(forKey: SyncTargets.legacyKey))
    }

    func testAnEditIsMirroredToEveryOtherSignedInTarget() {
        XCTAssertEqual(SyncTargets.mirrorTargets(for: .anilist, in: [.anilist, .mal, .simkl],
                                                 signedIn: [.anilist, .mal, .simkl]), [.mal, .simkl])
    }

    /// Leaving a service out means edits made there stay there.
    func testAnEditOnAServiceOutsideTheSetGoesNowhere() {
        XCTAssertEqual(SyncTargets.mirrorTargets(for: .mal, in: [.anilist, .simkl],
                                                 signedIn: [.anilist, .mal, .simkl]), [])
    }

    func testSignedOutServicesAreSkipped() {
        XCTAssertEqual(SyncTargets.mirrorTargets(for: .anilist, in: [.anilist, .mal, .simkl],
                                                 signedIn: [.anilist, .simkl]), [.simkl])
    }
}
