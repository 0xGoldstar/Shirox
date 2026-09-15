import Foundation

/// What a one-directional library sync should do with a single title.
enum LibrarySyncDecision: Equatable {
    /// The target has no entry for this title — copy the source's across.
    case create(status: MediaListStatus, progress: Int, score: Double, timesRewatched: Int?)
    /// The target is behind — move it forward.
    case advance(status: MediaListStatus, progress: Int, score: Double, timesRewatched: Int?)
    /// Both sides already agree.
    case skipUpToDate
    /// The target is *ahead*. Copying would destroy progress, so it is left alone.
    case skipWouldRegress(sourceProgress: Int, targetProgress: Int)
    /// The two sides disagree in a way nothing in the data can settle — paused on one,
    /// dropped on the other. Reported rather than guessed at.
    case skipLeftDiffering(source: MediaListStatus, target: MediaListStatus)
}

/// Which account a decision applies to.
///
/// `String`-backed and `CaseIterable` so the pairing containers below can be keyed by side and
/// iterated in a stable order. The name used to be a ternary — `self == .anilist ? … : …` —
/// which silently labelled any future third side "MyAnimeList".
enum LibrarySide: String, CaseIterable {
    case anilist, mal

    var name: String {
        switch self {
        case .anilist: return "AniList"
        case .mal:     return "MyAnimeList"
        }
    }
}

/// What an *overwrite* run should do with a single title. Unlike ``LibrarySyncDecision`` this
/// carries no notion of "ahead": the destination is made to match the source, full stop.
enum LibraryOverwriteDecision: Equatable {
    case create(status: MediaListStatus, progress: Int, score: Double, timesRewatched: Int?)
    case overwrite(status: MediaListStatus, progress: Int, score: Double, timesRewatched: Int?)
    /// Already identical. Not a safety check — it keeps a re-run from spending hundreds of
    /// writes against a rate-limited API setting values that are already correct.
    case skipIdentical
}

/// One write an overwrite or mirror run intends to make, resolved down to what the API needs.
struct PlannedWrite: Equatable {
    let side: LibrarySide
    /// Media id on `side` — what both services' update calls take.
    let id: Int
    let title: String
    /// True when the destination has no entry yet, so the run will add rather than overwrite.
    let isNew: Bool
    let status: MediaListStatus
    let progress: Int
    let score: Double
    let timesRewatched: Int?
}

/// One entry a mirror run intends to remove.
struct PlannedDeletion: Equatable {
    let side: LibrarySide
    /// AniList deletes by *list entry* id, MyAnimeList by media id. Resolved here so the caller
    /// can't pass the wrong one.
    let id: Int
    let title: String
}

/// Everything an overwrite or mirror run would do, worked out before anything is written, so it can
/// be shown to somebody before they commit to it.
struct LibraryOverwritePlan {
    var writes: [PlannedWrite] = []
    var deletions: [PlannedDeletion] = []
    /// Entries already identical, which the run will skip.
    var unchanged = 0
    /// Source titles with no id on the destination, so there is nothing to write to.
    var unmatched: [String] = []
    /// Destination entries a mirror keeps because it can't confirm the source lacks them.
    var keptUnverified = 0

    var isEmpty: Bool { writes.isEmpty && deletions.isEmpty }
}

/// A title's identity across sides.
///
/// MyAnimeList's id is the spine because every side speaks it: a MyAnimeList entry's `media.id`
/// *is* the id, AniList entries carry `media.idMal`, and Simkl returns it under
/// `extended=ids_only`. AniList's id is the fallback so a title MyAnimeList has never heard of
/// still pairs rather than vanishing.
struct CanonicalKey: Hashable {
    private let value: String

    /// nil when nothing can identify the title — the one genuinely unpairable case, which is
    /// reported rather than dropped.
    init?(ids: [LibrarySide: Int]) {
        if let mal = ids[.mal] {
            value = "mal:\(mal)"
        } else if let anilist = ids[.anilist] {
            value = "anilist:\(anilist)"
        } else {
            return nil
        }
    }
}

/// One title as it stands on each side, ready to be merged.
///
/// A side may have an id but no entry, which is how "that service has never seen this title"
/// is represented. A side with neither is simply absent from both dictionaries — there is
/// nowhere to write to, so there is nothing to merge.
struct LibraryPair {
    /// This title's id on each side that has an id for it.
    var ids: [LibrarySide: Int]
    /// The entry each side actually holds. A side can have an id here but no entry — that is
    /// exactly how "the target has never seen this title" is represented, and `decide` relies on
    /// it by taking an optional target.
    var entries: [LibrarySide: LibraryEntry]

    func id(on side: LibrarySide) -> Int? { ids[side] }
    func entry(on side: LibrarySide) -> LibraryEntry? { entries[side] }
}

/// The union of both libraries, plus the titles that could not be placed.
struct LibraryPairing {
    var pairs: [LibraryPair] = []
    /// Titles no side could identify at all, by the side they came from.
    var unidentified: [LibrarySide: [String]] = [:]

    /// Titles that exist somewhere but have no id on `side`, so a run writing to `side` has
    /// nowhere to put them.
    ///
    /// Relative to the destination, not the source. The old `unmatched(on:)` was named for the
    /// side a title came from but consumed as the *other* side's shortfall, which only reads
    /// sensibly while there are exactly two sides.
    func unmatched(writingTo side: LibrarySide) -> [String] {
        let noIdThere = pairs
            .filter { $0.id(on: side) == nil && !$0.entries.isEmpty }
            .compactMap { pair in
                LibrarySide.allCases.compactMap { pair.entry(on: $0) }.first?.media.title.displayTitle
            }
        return (unidentified[side] ?? []) + noIdThere
    }

    /// Everything that couldn't be placed anywhere, ordered by `LibrarySide.allCases` so a
    /// summary sentence reads the same way on every run.
    var unmatched: [String] { LibrarySide.allCases.flatMap { unidentified[$0] ?? [] } }
}

/// Pure decision logic for merging a tracking library between AniList and MyAnimeList.
///
/// This writes to somebody's real account, where a wrong call silently destroys watch history
/// that can't be recovered from inside the app. So the planner is deliberately one-way:
/// **it only ever moves an entry forward.** If the target is further along than the source —
/// which is the normal state of affairs when someone has been using both services — the entry
/// is reported and skipped rather than overwritten. That makes running a sync in the wrong
/// direction a no-op instead of a catastrophe, and makes running it twice harmless.
enum LibrarySyncPlanner {

    /// How far along an entry is, across rewatches.
    ///
    /// Raw episode numbers can't be compared once rewatches are involved: episode 4 of a third
    /// rewatch is *further along* than episode 12 of a second, even though 4 < 12. So "ahead"
    /// means the number of complete viewings first, and only then progress within the current,
    /// unfinished one.
    struct Viewing: Comparable {
        /// Complete passes through the series, original included.
        let finished: Int
        /// Episodes into the pass currently underway; 0 once it's finished.
        let partial: Int

        static func < (a: Viewing, b: Viewing) -> Bool {
            (a.finished, a.partial) < (b.finished, b.partial)
        }
    }

    /// How far along `entry` is.
    ///
    /// A repeat count above zero is the tell that the series has been round at least once
    /// before — which matters because MyAnimeList has no "rewatching" status and reports a
    /// rewatch as plain `watching`. Keying off the count rather than the status is what lets
    /// a MyAnimeList rewatch be recognised at all.
    static func viewing(_ entry: LibraryEntry) -> Viewing {
        let rewatches = entry.timesRewatched ?? 0
        let hasBeenRoundOnce = entry.status == .completed || entry.status == .repeating || rewatches > 0
        return Viewing(
            finished: hasBeenRoundOnce ? rewatches + 1 : 0,
            partial: entry.status == .completed ? 0 : entry.progress
        )
    }

    /// How deliberate a status is. Used only to decide which status survives when both sides are
    /// equally far along — never to move progress.
    ///
    /// `current` ranks low because it is mostly automatic: watching an episode puts you there.
    /// Pausing or dropping something takes a decision, so it outranks the residue of progress
    /// tracking. Paused and dropped tie with each other — neither is more deliberate than the
    /// other, so there is no honest way to pick between them.
    static func rank(_ status: MediaListStatus) -> Int {
        switch status {
        case .planning:              return 0
        case .current, .repeating:   return 1
        case .paused, .dropped:      return 2
        case .completed:             return 3
        }
    }

    /// Whether two statuses genuinely disagree, as opposed to merely differing.
    ///
    /// `current` vs `repeating` differs on paper but only because MyAnimeList cannot express a
    /// rewatch; reporting it would mean flagging the same titles on every single run.
    private static func isConflict(_ a: MediaListStatus, _ b: MediaListStatus) -> Bool {
        guard a != b, rank(a) == rank(b) else { return false }
        let watching: Set<MediaListStatus> = [.current, .repeating]
        return !(watching.contains(a) && watching.contains(b))
    }

    /// The decision for one title. `target` is nil when the other service has never seen it.
    static func decide(source: LibraryEntry, target: LibraryEntry?) -> LibrarySyncDecision {
        guard let target else {
            return .create(
                status: source.status, progress: source.progress,
                score: source.score, timesRewatched: source.timesRewatched)
        }

        let sourceViewing = viewing(source)
        let targetViewing = viewing(target)

        if sourceViewing > targetViewing {
            return .advance(
                status: source.status,
                progress: source.progress,
                // An unrated source must not wipe a rating the target already has.
                score: source.score > 0 ? source.score : target.score,
                timesRewatched: source.timesRewatched ?? target.timesRewatched
            )
        }

        if sourceViewing < targetViewing {
            // The target stays where it is — but a rating it lacks is still worth taking, or a
            // score would only ever travel towards whichever side happens to be behind.
            guard target.score <= 0, source.score > 0 else {
                return .skipWouldRegress(sourceProgress: source.progress, targetProgress: target.progress)
            }
            return .advance(
                status: target.status, progress: target.progress,
                score: source.score, timesRewatched: target.timesRewatched)
        }

        // Equally far along. Only write when the source fills in something the target is
        // missing: a more deliberate status, or a score where it has none.
        let statusIsAhead = rank(source.status) > rank(target.status)
        let fillsInScore = target.score <= 0 && source.score > 0
        guard statusIsAhead || fillsInScore else {
            return isConflict(source.status, target.status)
                ? .skipLeftDiffering(source: source.status, target: target.status)
                : .skipUpToDate
        }

        return .advance(
            status: statusIsAhead ? source.status : target.status,
            // Both are equally far along, so this is normally a no-op. It matters for the one
            // case where it isn't: finishing a rewatch that had reset progress to 0, where
            // taking the lower number would write "completed, episode 0".
            progress: max(source.progress, target.progress),
            score: fillsInScore ? source.score : target.score,
            timesRewatched: source.timesRewatched ?? target.timesRewatched
        )
    }

    /// Lines up every side's library title by title, covering the union of all of them.
    ///
    /// Joined on a canonical key rather than pairwise id maps: with more than two sides there is
    /// no "the other service" to resolve an id against. Ids are resolved by the caller, because
    /// the lookups are async and this stays pure.
    static func pair(
        entries: [LibrarySide: [LibraryEntry]],
        ids resolve: (LibrarySide, LibraryEntry) -> [LibrarySide: Int]
    ) -> LibraryPairing {
        var pairing = LibraryPairing()
        var byKey: [CanonicalKey: LibraryPair] = [:]
        var order: [CanonicalKey] = []

        for side in LibrarySide.allCases {
            for entry in entries[side] ?? [] {
                let ids = resolve(side, entry)
                guard let key = CanonicalKey(ids: ids) else {
                    pairing.unidentified[side, default: []].append(entry.media.title.displayTitle)
                    continue
                }
                if byKey[key] == nil {
                    byKey[key] = LibraryPair(ids: [:], entries: [:])
                    order.append(key)
                }
                // First writer wins on ids: a later side must not relabel a title's identity.
                byKey[key]?.ids.merge(ids) { existing, _ in existing }
                byKey[key]?.entries[side] = entry
            }
        }

        pairing.pairs = order.compactMap { byKey[$0] }
        return pairing
    }

    // MARK: - Replacing one library with the other

    /// Makes the destination match the source exactly, backwards steps included.
    ///
    /// Every safeguard in ``decide(source:target:)`` is deliberately absent here: progress moves
    /// down as readily as up, and an unrated source clears a rating. That is what the caller
    /// asked for, and it cannot be undone from inside the app.
    static func overwrite(source: LibraryEntry, target: LibraryEntry?) -> LibraryOverwriteDecision {
        guard let target else {
            return .create(
                status: source.status, progress: source.progress,
                score: source.score, timesRewatched: source.timesRewatched)
        }

        let identical = source.status == target.status
            && source.progress == target.progress
            && source.score == target.score
            && (source.timesRewatched ?? 0) == (target.timesRewatched ?? 0)
        guard !identical else { return .skipIdentical }

        return .overwrite(
            status: source.status, progress: source.progress,
            score: source.score, timesRewatched: source.timesRewatched)
    }

    /// Everything an overwrite or mirror run would do, without doing any of it.
    ///
    /// Working the whole plan out up front is what lets the app show somebody the damage before
    /// they authorise it — these runs can't be undone, so "N entries will be deleted, here they
    /// are" is the last point at which a mistake is still cheap.
    static func overwritePlan(
        from pairing: LibraryPairing,
        writing target: LibrarySide,
        reading source: LibrarySide,
        sourceMediaIds: Set<Int>,
        deletingExtras: Bool
    ) -> LibraryOverwritePlan {
        var plan = LibraryOverwritePlan()
        plan.unmatched = pairing.unmatched(writingTo: target)

        for pair in pairing.pairs {
            guard let sourceEntry = pair.entry(on: source) else { continue }
            guard let targetId = pair.id(on: target) else { continue }
            let existing = pair.entry(on: target)

            switch overwrite(source: sourceEntry, target: existing) {
            case .skipIdentical:
                plan.unchanged += 1
            case .create(let status, let progress, let score, let timesRewatched),
                 .overwrite(let status, let progress, let score, let timesRewatched):
                plan.writes.append(PlannedWrite(
                    side: target,
                    id: targetId,
                    title: sourceEntry.media.title.displayTitle,
                    isNew: existing == nil,
                    status: status, progress: progress,
                    score: score, timesRewatched: timesRewatched))
            }
        }

        guard deletingExtras else { return plan }

        plan.keptUnverified = pairing.unmatched(writingTo: source).count
        plan.deletions = deletions(
            from: pairing, writing: target, reading: source, sourceMediaIds: sourceMediaIds)
            .compactMap { pair in
                guard let doomed = pair.entry(on: target),
                      let id = deletionId(for: target, pair: pair, entry: doomed) else { return nil }
                return PlannedDeletion(
                    side: target, id: id, title: doomed.media.title.displayTitle)
            }
        return plan
    }

    /// The id `side` deletes by. AniList needs the *list entry's* own id; MyAnimeList deletes by
    /// media id. Resolved in one place so a caller cannot pass the wrong one.
    static func deletionId(for side: LibrarySide, pair: LibraryPair, entry: LibraryEntry) -> Int? {
        switch side {
        case .anilist: return entry.id
        case .mal:     return pair.id(on: .mal)
        }
    }

    /// The destination entries a mirror run should delete.
    ///
    /// Absence is not proof: a destination entry looks orphaned both when the source genuinely
    /// lacks it *and* when the source has it under an id that failed to resolve. Treating those
    /// alike would turn one failed lookup into deleted watch history. So deletion needs positive
    /// proof — the entry resolves to a source-side id, and `sourceMediaIds` shows that id really
    /// is absent. Anything unverifiable is kept.
    static func deletions(
        from pairing: LibraryPairing,
        writing target: LibrarySide,
        reading source: LibrarySide,
        sourceMediaIds: Set<Int>
    ) -> [LibraryPair] {
        pairing.pairs.filter { pair in
            // The target holds it and the source does not — necessary, but not sufficient.
            guard pair.entry(on: target) != nil, pair.entry(on: source) == nil else { return false }
            // Deletion needs positive proof: the entry resolves to a source-side id, and that id
            // really is absent from the source. No id at all means unverifiable, so it is kept.
            guard let sourceId = pair.id(on: source) else { return false }
            return !sourceMediaIds.contains(sourceId)
        }
    }
}

/// Tally of one sync run, for the summary shown when it finishes.
struct LibrarySyncSummary: Equatable {
    var created = 0
    var advanced = 0
    var upToDate = 0
    /// Entries left alone because the destination was further along.
    var keptAhead = 0
    /// Entries where the two services disagree and nothing in the data can settle it.
    var leftDiffering = 0
    /// Entries removed by a mirror run.
    var deleted = 0
    /// Entries a mirror run kept because it could not confirm the source lacks them.
    var keptUnverified = 0
    /// Titles with no id on the other service, so there was nothing to write to.
    var unmatched: [String] = []
    var failed = 0

    var changed: Int { created + advanced }

    /// Plain-language result, in the same voice as the rest of the app.
    var sentence: String {
        if changed == 0 && leftDiffering == 0 && deleted == 0
            && keptUnverified == 0 && unmatched.isEmpty && failed == 0 {
            return "Everything was already up to date."
        }
        var parts: [String] = []
        if created > 0 { parts.append("\(created) added") }
        if advanced > 0 { parts.append("\(advanced) updated") }
        if deleted > 0 { parts.append("\(deleted) deleted") }
        if keptAhead > 0 { parts.append("\(keptAhead) left ahead") }
        if leftDiffering > 0 { parts.append("\(leftDiffering) left differing") }
        if keptUnverified > 0 { parts.append("\(keptUnverified) kept unverified") }
        if !unmatched.isEmpty { parts.append("\(unmatched.count) not found") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: ", ")
    }
}
