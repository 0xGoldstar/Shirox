import XCTest
@testable import Shirox

/// Simkl's free allowance: 500 metered requests a day, the day being US Eastern's.
@MainActor
final class SimklBudgetTests: XCTestCase {
    private var clock = SimklBudgetTests.date("2026-09-26T12:00:00Z")

    private static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private lazy var defaults: UserDefaults = {
        let name = "SimklBudgetTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }()

    private func budget() -> SimklBudget {
        SimklBudget(defaults: defaults, now: { [unowned self] in self.clock })
    }

    func testCountsWhatsSent() {
        let budget = budget()
        budget.recordSent(); budget.recordSent(); budget.recordSent()
        XCTAssertEqual(budget.used, 3)
    }

    func testTheCountStartsAgainOnANewEasternDay() {
        let budget = budget()
        budget.recordSent()
        clock = Self.date("2026-09-27T03:59:00Z")   // 23:59 in New York, same day
        budget.refresh()
        XCTAssertEqual(budget.used, 1)
        clock = Self.date("2026-09-27T04:00:00Z")   // midnight in New York
        budget.refresh()
        XCTAssertEqual(budget.used, 0)
    }

    func testAutomaticRequestsStopAtTheReserve() throws {
        let budget = budget()
        for _ in 0..<399 { budget.recordSent() }
        XCTAssertNoThrow(try budget.permit(.automatic))
        XCTAssertFalse(budget.automaticPaused)
        budget.recordSent()
        XCTAssertThrowsError(try budget.permit(.automatic)) { XCTAssertEqual($0 as? SimklError, .budgetReserved) }
        XCTAssertNoThrow(try budget.permit(.own), "The last 100 are the user's")
        XCTAssertTrue(budget.automaticPaused)
    }

    func testASpentDayRefusesEverythingUntilTheReset() {
        let budget = budget()
        budget.markSpent()
        XCTAssertEqual(budget.used, SimklBudget.limit)
        XCTAssertThrowsError(try budget.permit(.own)) { XCTAssertEqual($0 as? SimklError, .dailyLimit) }
        clock = Self.date("2026-09-27T04:00:00Z")
        XCTAssertNoThrow(try budget.permit(.own))
        XCTAssertEqual(budget.used, 0)
        XCTAssertFalse(budget.spent)
    }

    func testTheCountIsKeptAcrossLaunches() {
        let first = budget()
        first.recordSent(); first.recordSent()
        XCTAssertEqual(budget().used, 2)
    }

    func testAnotherAccountStartsAtZero() {
        let budget = budget()
        budget.recordSent(); budget.markSpent()
        budget.reset()
        XCTAssertEqual(budget.used, 0)
        XCTAssertFalse(budget.spent)
    }

    func testTheResetIsMidnightInNewYork() {
        XCTAssertEqual(SimklBudget.reset(after: Self.date("2026-09-26T12:00:00Z")), Self.date("2026-09-27T04:00:00Z"),
                       "EDT, UTC−4")
        XCTAssertEqual(SimklBudget.reset(after: Self.date("2026-12-01T12:00:00Z")), Self.date("2026-12-02T05:00:00Z"),
                       "EST, UTC−5")
        XCTAssertEqual(SimklBudget.day(of: Self.date("2026-09-27T03:59:00Z")), "2026-09-26")
    }

    func testPriorityIsOwnUnlessSetAndReachesTasksStartedInside() async {
        XCTAssertEqual(SimklRequestPriority.current, .own)
        await SimklRequestPriority.$current.withValue(.automatic) {
            let inner = await Task { SimklRequestPriority.current }.value
            XCTAssertEqual(inner, .automatic)
        }
        XCTAssertEqual(SimklRequestPriority.current, .own)
    }

    func testTheSummaryGivesTheResetInLocalTime() {
        let summary = SimklBudget.summary(used: 42, resetsAt: Self.date("2026-09-27T04:00:00Z"),
                                          timeZone: TimeZone(identifier: "Europe/Berlin")!,
                                          locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(summary, "Requests today: 42 of 500 · resets at 06:00")
    }

    func testTheNoteSaysWhatsPaused() {
        XCTAssertNil(SimklBudget.note(used: 399, spent: false))
        XCTAssertEqual(SimklBudget.note(used: 400, spent: false), "Automatic checks are paused until then.")
        XCTAssertEqual(SimklBudget.note(used: 500, spent: true),
                       "Today's allowance is used up. Changes are sent after the reset.")
    }
}
