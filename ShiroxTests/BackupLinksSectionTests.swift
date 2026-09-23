import XCTest
@testable import Shirox

/// AniList matches were in no backup at all; tracking links join them in one section.
@MainActor
final class BackupLinksSectionTests: XCTestCase {

    private var savedMatches: [String: Int] = [:]
    private var savedLinks: [String: TrackingLinks] = [:]

    override func setUp() {
        super.setUp()
        savedMatches = AniListMappingManager.shared.allMappings
        savedLinks = TrackingLinkStore.shared.all
    }

    override func tearDown() {
        AniListMappingManager.shared.replaceAll(savedMatches)
        TrackingLinkStore.shared.replaceAll(savedLinks)
        super.tearDown()
    }

    func testSectionIdIsLinks() {
        XCTAssertEqual(LinksBackupSection.id, BackupSectionID.links)
    }

    func testNothingToRecordLeavesTheSectionOut() throws {
        AniListMappingManager.shared.replaceAll([:])
        TrackingLinkStore.shared.replaceAll([:])
        XCTAssertNil(try LinksBackupSection().export())
    }

    func testMatchesAndLinksRoundTrip() async throws {
        AniListMappingManager.shared.replaceAll(["death parade": 20931])
        TrackingLinkStore.shared.replaceAll(["anilist:20931": TrackingLinks(mal: 28223, simkl: 37145)])
        let payload = try XCTUnwrap(LinksBackupSection().export())

        AniListMappingManager.shared.replaceAll([:])
        TrackingLinkStore.shared.replaceAll([:])
        _ = try await LinksBackupSection().apply(payload)

        XCTAssertEqual(AniListMappingManager.shared.getMapping(title: "Death Parade"), 20931)
        XCTAssertEqual(TrackingLinkStore.shared.links(for: "anilist:20931"), TrackingLinks(mal: 28223, simkl: 37145))
    }
}
