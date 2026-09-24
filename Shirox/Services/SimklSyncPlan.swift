import Foundation

/// Simkl's two-phase sync rules for one kind, as decisions. Pure.
///
/// Their guide: pull each list once with no `date_from`, then call `/sync/activities` and read only
/// the lists whose timestamp moved, with `date_from` set to the saved one. `date_from` never
/// reports deletions — those take an ids-only read, diffed against the copy.
enum SimklSyncPlan {
    enum Read: Equatable {
        case upToDate
        case full
        case delta(since: String)
    }

    /// No copy yet, or no saved stamp to take a delta from: one full read. Otherwise a delta only
    /// when the kind's `all` moved.
    static func read(saved: String?, current: String?, hasCache: Bool) -> Read {
        guard hasCache, let saved else { return .full }
        guard let current, current != saved else { return .upToDate }
        return .delta(since: saved)
    }

    /// Whether to diff an ids-only read for deletions: only when `removed_from_list` moved, and
    /// never for a copy a full read is about to replace.
    static func checkRemovals(saved: String?, current: String?, read: Read) -> Bool {
        if case .full = read { return false }
        guard let current else { return false }
        return current != saved
    }

    /// The copy minus every title the ids-only read no longer lists. A title whose Simkl id isn't
    /// known is kept: it can't be matched, so it can't be proven gone.
    static func applyRemovals(keeping present: Set<Int>, to entries: [LibraryEntry],
                              simklID: (LibraryEntry) -> Int?) -> [LibraryEntry] {
        entries.filter { entry in
            guard let id = simklID(entry) else { return true }
            return present.contains(id)
        }
    }
}
