import XCTest
@testable import Shirox

/// Every Simkl mapping decision, tested without a network. The removal-radius and batching cases
/// are the ones that matter most: one wipes a user's library, the other gets the app's shared
/// client_id suspended.
final class SimklPayloadBuilderTests: XCTestCase {

    // MARK: - Status

    func testStatusMapsOneToOneWhereSimklHasAnEquivalent() {
        XCTAssertEqual(SimklPayloadBuilder.status(for: .current), .watching)
        XCTAssertEqual(SimklPayloadBuilder.status(for: .planning), .plantowatch)
        XCTAssertEqual(SimklPayloadBuilder.status(for: .completed), .completed)
        XCTAssertEqual(SimklPayloadBuilder.status(for: .dropped), .dropped)
        XCTAssertEqual(SimklPayloadBuilder.status(for: .paused), .hold)
    }

    /// Simkl has no "rewatching": it models a rewatch as a separate session behind a Pro-only
    /// flag. A repeating entry is written as plain watching rather than silently dropped.
    func testRepeatingIsWrittenAsWatching() {
        XCTAssertEqual(SimklPayloadBuilder.status(for: .repeating), .watching)
    }

    // MARK: - Score

    /// `LibraryEntry.score` is in the *account's* display format, not a canonical scale, so the
    /// format has to be applied before a 1-10 rating can be produced.
    func testEveryScoreFormatConvertsIntoSimklsOneToTenRange() {
        XCTAssertEqual(SimklPayloadBuilder.rating(from: 85, format: .point100), 9)
        XCTAssertEqual(SimklPayloadBuilder.rating(from: 8, format: .point10), 8)
        XCTAssertEqual(SimklPayloadBuilder.rating(from: 4, format: .point5), 8)
        XCTAssertEqual(SimklPayloadBuilder.rating(from: 2, format: .point3), 7)
        XCTAssertEqual(SimklPayloadBuilder.rating(from: 8.5, format: .point10Decimal), 9)
    }

    /// Unrated is nil, never a literal 0 — Simkl rejects 0 and it would read as "rated terrible".
    func testUnratedProducesNoRating() {
        for format in [ScoreFormat.point100, .point10, .point10Decimal, .point5, .point3] {
            XCTAssertNil(SimklPayloadBuilder.rating(from: 0, format: format))
        }
    }

    func testRatingNeverLeavesOneToTenForAnyInput() {
        for format in [ScoreFormat.point100, .point10, .point10Decimal, .point5, .point3] {
            for raw in stride(from: 0.5, through: 100, by: 0.5) {
                guard let r = SimklPayloadBuilder.rating(from: raw, format: format) else { continue }
                XCTAssertTrue((1...10).contains(r), "format \(format) raw \(raw) gave \(r)")
            }
        }
    }

    func testRatingRoundTripsBackThroughTheSameFormat() {
        XCTAssertEqual(SimklPayloadBuilder.score(fromRating: 8, format: .point10), 8)
        XCTAssertEqual(SimklPayloadBuilder.score(fromRating: nil, format: .point10), 0)
    }

    // MARK: - Episodes

    /// Simkl's default anime numbering is AniDB sequential — one flat season — so flat progress
    /// maps straight across with no offset arithmetic.
    func testFirstSyncSendsTheWholeRange() {
        XCTAssertEqual(SimklPayloadBuilder.episodeNumbers(from: nil, to: 3), [1, 2, 3])
    }

    /// Only the delta when previous progress is known: re-sending a thousand episodes of a
    /// long-running show on every write is avoidable, and counts against a 1 POST/sec budget.
    func testKnownProgressSendsOnlyTheDelta() {
        XCTAssertEqual(SimklPayloadBuilder.episodeNumbers(from: 10, to: 13), [11, 12, 13])
    }

    func testNoForwardProgressSendsNothing() {
        XCTAssertTrue(SimklPayloadBuilder.episodeNumbers(from: 13, to: 13).isEmpty)
        XCTAssertTrue(SimklPayloadBuilder.episodeNumbers(from: 13, to: 5).isEmpty)
        XCTAssertTrue(SimklPayloadBuilder.episodeNumbers(from: nil, to: 0).isEmpty)
    }

    // MARK: - Removal radius (the dangerous one)

    /// With episodes named, only those episodes are un-marked; the title stays in the library.
    func testPartialRemovalNamesItsEpisodes() {
        let body = SimklPayloadBuilder.removalBody(ids: ["mal": 38000], episodes: [6, 7, 8])
        let shows = body[SimklPayloadBuilder.animeKey] as? [[String: Any]]
        XCTAssertNotNil(shows?.first?["seasons"], "naming episodes is what keeps this partial")
    }

    /// With no episodes, Simkl removes the title from the user's library entirely — history and
    /// watchlist entry both. These two must never be confusable.
    func testWholeEntryRemovalNamesNoEpisodes() {
        let body = SimklPayloadBuilder.removalBody(ids: ["mal": 38000], episodes: nil)
        let shows = body[SimklPayloadBuilder.animeKey] as? [[String: Any]]
        XCTAssertNil(shows?.first?["seasons"])
        XCTAssertNil(shows?.first?["episodes"])
    }

    /// An empty episode list must not silently become a whole-library delete.
    func testEmptyEpisodeListIsNotAWholeEntryDelete() {
        let body = SimklPayloadBuilder.removalBody(ids: ["mal": 38000], episodes: [])
        let shows = body[SimklPayloadBuilder.animeKey] as? [[String: Any]]
        XCTAssertNotNil(shows?.first?["seasons"],
                        "an empty list must stay the partial form, not become a library delete")
    }

    // MARK: - Batching (protects the shared client_id)

    func testBatchesAreNeverLargerThanFifty() {
        let batches = SimklPayloadBuilder.batches(Array(1...120))
        XCTAssertEqual(batches.map(\.count), [50, 50, 20])
    }

    func testBatchingPreservesEveryItemAndTheirOrder() {
        let input = Array(1...137)
        XCTAssertEqual(SimklPayloadBuilder.batches(input).flatMap { $0 }, input)
    }

    func testEmptyInputProducesNoRequests() {
        XCTAssertTrue(SimklPayloadBuilder.batches([Int]()).isEmpty)
    }

    // MARK: - Body shape

    func testHistoryBodyPutsAnimeUnderShowsWithIdsAndStatus() {
        let body = SimklPayloadBuilder.historyBody(items: [
            SimklWrite(ids: ["mal": 38000], status: .completed, rating: 9, episodes: nil)
        ])
        let shows = body[SimklPayloadBuilder.animeKey] as? [[String: Any]]
        XCTAssertEqual(shows?.count, 1)
        XCTAssertEqual(shows?.first?["status"] as? String, "completed")
        XCTAssertEqual(shows?.first?["rating"] as? Int, 9)
        XCTAssertEqual((shows?.first?["ids"] as? [String: Int])?["mal"], 38000)
    }

    /// Send every id known, per Simkl's own guidance: "Send any/all you have."
    func testBothIdsAreSentWhenBothAreKnown() {
        let body = SimklPayloadBuilder.historyBody(items: [
            SimklWrite(ids: ["mal": 38000, "anilist": 101922],
                       status: .watching, rating: nil, episodes: [1])
        ])
        let ids = (body[SimklPayloadBuilder.animeKey] as? [[String: Any]])?.first?["ids"] as? [String: Int]
        XCTAssertEqual(ids?["mal"], 38000)
        XCTAssertEqual(ids?["anilist"], 101922)
    }

    /// THE ONE THAT MATTERS: Simkl drops episode data from an item that also carries a status.
    /// The app sent ids + rating + 12 episodes + status and Simkl echoed the request back with
    /// no episodes at all, storing none of them while the status landed. So a write carrying
    /// both becomes two entries for the same title.
    func testStatusAndEpisodesAreSentAsSeparateEntries() {
        let body = SimklPayloadBuilder.historyBody(items: [
            SimklWrite(ids: ["mal": 38000], status: .completed, rating: 9, episodes: [1, 2, 3])
        ])
        let shows = body[SimklPayloadBuilder.animeKey] as? [[String: Any]]

        XCTAssertEqual(shows?.count, 2, "one entry for the episodes, one for the status")

        let episodeEntry = shows?.first { $0["seasons"] != nil }
        XCTAssertNotNil(episodeEntry)
        XCTAssertNil(episodeEntry?["status"], "a status on this entry makes Simkl ignore the episodes")
        let season = (episodeEntry?["seasons"] as? [[String: Any]])?.first
        XCTAssertEqual((season?["episodes"] as? [[String: Int]])?.map { $0["number"]! }, [1, 2, 3])

        let stateEntry = shows?.first { $0["status"] != nil }
        XCTAssertEqual(stateEntry?["status"] as? String, "completed")
        XCTAssertEqual(stateEntry?["rating"] as? Int, 9)
        XCTAssertNil(stateEntry?["seasons"])
    }

    /// A status-only write carries no episode key at all.
    func testStatusOnlyWriteCarriesNoEpisodes() {
        let body = SimklPayloadBuilder.historyBody(items: [
            SimklWrite(ids: ["mal": 38000], status: .plantowatch, rating: nil, episodes: nil)
        ])
        let show = (body[SimklPayloadBuilder.animeKey] as? [[String: Any]])?.first

        XCTAssertNil(show?["episodes"])
        XCTAssertNil(show?["seasons"])
        XCTAssertEqual(show?["status"] as? String, "plantowatch")
        XCTAssertEqual((body[SimklPayloadBuilder.animeKey] as? [[String: Any]])?.count, 1, "no episodes, so one entry")
    }

    /// TVDB-style per-season numbering is exactly what this design avoids.
    func testTvdbSeasonModeIsNeverRequested() {
        let body = SimklPayloadBuilder.historyBody(items: [
            SimklWrite(ids: ["mal": 1], status: .watching, rating: nil, episodes: [1])
        ])
        XCTAssertNil(body["use_tvdb_anime_seasons"])
    }
}
