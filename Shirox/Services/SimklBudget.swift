import Foundation
import Combine

/// Whether a Simkl request is the user's own doing or something the app does by itself.
///
/// Automatic work is wrapped in `SimklRequestPriority.$current.withValue(.automatic) { … }`, and
/// `SimklAuthManager.send` reads it — so nothing in between passes it along. Tasks started inside
/// inherit it.
enum SimklRequestPriority: Sendable {
    case own, automatic

    @TaskLocal static var current: SimklRequestPriority = .own
}

/// Simkl's free allowance: 500 metered requests a day, the day being US Eastern's. Counted as
/// requests are answered; the last `reserve` are kept for the user's own actions and for marking
/// what's watched.
@MainActor
final class SimklBudget: ObservableObject {
    static let shared = SimklBudget()

    nonisolated static let limit = 500
    nonisolated static let reserve = 100
    /// Automatic requests stop once this many have been sent today.
    nonisolated static var automaticCeiling: Int { limit - reserve }

    @Published private(set) var used: Int
    /// Simkl said the day's allowance is used up.
    @Published private(set) var spent: Bool

    private var day: String
    private let defaults: UserDefaults
    private let now: () -> Date

    private enum Keys {
        static let day = "simkl_budget_day"
        static let used = "simkl_budget_used"
        static let spent = "simkl_budget_spent"
    }

    private nonisolated static let eastern = TimeZone(identifier: "America/New_York")!

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        day = defaults.string(forKey: Keys.day) ?? ""
        used = defaults.integer(forKey: Keys.used)
        spent = defaults.bool(forKey: Keys.spent)
        refresh()
    }

    /// Simkl's day for `date`: the date in New York, as "yyyy-MM-dd".
    nonisolated static func day(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eastern
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// When Simkl's next day starts — midnight in New York.
    nonisolated static func reset(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eastern
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
    }

    /// Throws when a request of this priority mustn't be sent: any request once Simkl has said the
    /// day is used up, an automatic one once the reserve is reached.
    func permit(_ priority: SimklRequestPriority) throws {
        refresh()
        if spent { throw SimklError.dailyLimit }
        if priority == .automatic, used >= Self.automaticCeiling { throw SimklError.budgetReserved }
    }

    func recordSent() {
        refresh()
        used += 1
        save()
    }

    /// Simkl answered that the day's allowance is used up.
    func markSpent() {
        refresh()
        spent = true
        used = max(used, Self.limit)
        save()
    }

    /// A different account has an allowance of its own.
    func reset() {
        day = Self.day(of: now())
        used = 0
        spent = false
        save()
    }

    /// Starts the count again when Simkl's day has changed.
    func refresh() {
        let today = Self.day(of: now())
        guard today != day else { return }
        day = today
        used = 0
        spent = false
        save()
    }

    var automaticPaused: Bool { spent || used >= Self.automaticCeiling }
    var resetsAt: Date { Self.reset(after: now()) }

    private func save() {
        defaults.set(day, forKey: Keys.day)
        defaults.set(used, forKey: Keys.used)
        defaults.set(spent, forKey: Keys.spent)
    }
}
