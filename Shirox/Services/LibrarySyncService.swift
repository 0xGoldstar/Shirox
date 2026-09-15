import Foundation
import Combine

/// Reconciles a whole tracking library between AniList and MyAnimeList.
///
/// Distinct from the `dualSync` setting, which mirrors *edits you make from here* to both
/// accounts going forward. This is the backfill for everything that happened before that:
/// somebody who tracked on MyAnimeList for years and just signed into AniList wants their
/// history carried across once, not re-entered by hand.
///
/// The sync runs go through ``LibrarySyncPlanner/decide(source:target:)``, which only ever moves
/// an entry forward — running one in the wrong direction is a no-op rather than a way to wipe a
/// library, and running it twice changes nothing the second time. That property is what makes
/// the all-ways merge safe: it is the same decision run once per side.
///
/// The overwrite and mirror runs deliberately give that up. They exist because sometimes one
/// account is simply the one you want, and they destroy whatever the other held.
@MainActor
final class LibrarySyncService: ObservableObject {
    static let shared = LibrarySyncService()

    /// What happened to one title on one side.
    fileprivate enum Outcome { case upToDate, keptAhead, leftDiffering, created, advanced, deleted, failed }

    /// Pause between writes, in nanoseconds. Both APIs rate-limit, and a few hundred titles
    /// hammered back to back gets the account throttled — which mid-run looks exactly like
    /// data loss. (`Duration` would read better but is iOS 16+; this ships to iOS 15.)
    private static let writeIntervalNanos: UInt64 = 350_000_000

    @Published private(set) var isRunning = false
    /// "Syncing 42 of 310" while a run is in flight, for the settings row.
    @Published private(set) var statusText = ""
    @Published private(set) var lastSummary: LibrarySyncSummary?

    private init() {}

    func sync(_ run: SyncRun) async {
        guard !isRunning else { return }
        isRunning = true
        statusText = "Reading libraries…"
        defer { isRunning = false; statusText = "" }

        guard let entriesBySide = await readLibraries() else { return }
        let anilistEntries = entriesBySide[.anilist] ?? []
        let malEntries = entriesBySide[.mal] ?? []

        statusText = "Matching titles…"
        // The reverse lookups only earn their keep when AniList entries may be written, or when a
        // mirror has to prove a MyAnimeList entry really is absent before deleting it.
        let needsReverseIds = run.writes(to: .anilist) || run.kind == .mirror
        let malForAniList = await malIds(for: anilistEntries)
        let anilistForMAL = needsReverseIds ? await anilistIds(for: malEntries) : [:]
        let pairing = LibrarySyncPlanner.pair(
            entries: entriesBySide,
            ids: { side, entry in
                switch side {
                case .anilist:
                    var ids: [LibrarySide: Int] = [.anilist: entry.media.id]
                    if let mal = malForAniList[entry.media.id] { ids[.mal] = mal }
                    return ids
                case .mal:
                    var ids: [LibrarySide: Int] = [.mal: entry.media.id]
                    if let anilist = anilistForMAL[entry.media.id] { ids[.anilist] = anilist }
                    return ids
                }
            })

        var summaries: [LibrarySide: LibrarySyncSummary] = [:]

        switch run.kind {
        case .merge, .copyForward:
            summaries = await runSync(run, pairing)
        case .overwrite, .mirror:
            // A destructive run names both ends explicitly; there is no "the other side" to infer.
            guard let target = run.target, let source = run.source else { return }
            let plan = LibrarySyncPlanner.overwritePlan(
                from: pairing,
                writing: target,
                reading: source,
                sourceMediaIds: Set((entriesBySide[source] ?? []).map(\.media.id)),
                deletingExtras: run.kind == .mirror)
            summaries[target] = await execute(plan)
        }

        report(run, summaries: summaries)
    }

    /// Works out everything an overwrite or mirror would do **without writing anything**, so it can
    /// be shown to somebody first. These runs can't be undone; this is the last point at which a
    /// mistake is still free.
    func preview(_ run: SyncRun) async -> LibraryOverwritePlan? {
        guard !isRunning, run.isDestructive else { return nil }
        guard let target = run.target, let source = run.source else { return nil }
        isRunning = true
        statusText = "Checking…"
        defer { isRunning = false; statusText = "" }

        guard let entriesBySide = await readLibraries() else { return nil }
        let anilistEntries = entriesBySide[.anilist] ?? []
        let malEntries = entriesBySide[.mal] ?? []
        let malForAniList = await malIds(for: anilistEntries)
        let anilistForMAL = (target == .anilist || run.kind == .mirror)
            ? await anilistIds(for: malEntries) : [:]
        let pairing = LibrarySyncPlanner.pair(
            entries: entriesBySide,
            ids: { side, entry in
                switch side {
                case .anilist:
                    var ids: [LibrarySide: Int] = [.anilist: entry.media.id]
                    if let mal = malForAniList[entry.media.id] { ids[.mal] = mal }
                    return ids
                case .mal:
                    var ids: [LibrarySide: Int] = [.mal: entry.media.id]
                    if let anilist = anilistForMAL[entry.media.id] { ids[.anilist] = anilist }
                    return ids
                }
            })
        return LibrarySyncPlanner.overwritePlan(
            from: pairing,
            writing: target,
            reading: source,
            sourceMediaIds: Set((entriesBySide[source] ?? []).map(\.media.id)),
            deletingExtras: run.kind == .mirror)
    }

    /// Carries out exactly the plan that was shown — not a freshly recomputed one, so what gets
    /// written is what was agreed to.
    func apply(_ plan: LibraryOverwritePlan, for run: SyncRun) async {
        guard !isRunning, let target = run.target else { return }
        isRunning = true
        defer { isRunning = false; statusText = "" }

        let summary = await execute(plan)
        report(run, summaries: [target: summary])
    }

    // MARK: - Forward-only runs

    private func runSync(
        _ run: SyncRun, _ pairing: LibraryPairing
    ) async -> [LibrarySide: LibrarySyncSummary] {
        var anilist = LibrarySyncSummary()
        var mal = LibrarySyncSummary()
        if run.writes(to: .mal) { mal.unmatched = pairing.unmatched(writingTo: .mal) }
        if run.writes(to: .anilist) { anilist.unmatched = pairing.unmatched(writingTo: .anilist) }

        // A pair with nothing on the side being read from has nothing to contribute.
        let workable = pairing.pairs.filter { pair in
            (run.writes(to: .mal) && pair.entry(on: .anilist) != nil)
                || (run.writes(to: .anilist) && pair.entry(on: .mal) != nil)
        }

        for (index, pair) in workable.enumerated() {
            statusText = "Syncing \(index + 1) of \(workable.count)"

            if run.writes(to: .mal), let source = pair.entry(on: .anilist), let malId = pair.id(on: .mal) {
                mal.record(await apply(
                    LibrarySyncPlanner.decide(source: source, target: pair.entry(on: .mal)),
                    to: .mal, id: malId,
                    title: source.media.title.displayTitle, hadEntry: pair.entry(on: .mal) != nil))
            }

            if run.writes(to: .anilist), let source = pair.entry(on: .mal), let anilistId = pair.id(on: .anilist) {
                anilist.record(await apply(
                    LibrarySyncPlanner.decide(source: source, target: pair.entry(on: .anilist)),
                    to: .anilist, id: anilistId,
                    title: source.media.title.displayTitle, hadEntry: pair.entry(on: .anilist) != nil))
            }
        }

        // Only the sides this run actually wrote to belong in the report.
        var summaries: [LibrarySide: LibrarySyncSummary] = [:]
        if run.writes(to: .anilist) { summaries[.anilist] = anilist }
        if run.writes(to: .mal) { summaries[.mal] = mal }
        return summaries
    }

    private func apply(
        _ decision: LibrarySyncDecision, to side: LibrarySide,
        id: Int, title: String, hadEntry: Bool
    ) async -> Outcome {
        switch decision {
        case .skipUpToDate:
            return .upToDate

        case .skipWouldRegress(let from, let to):
            Logger.shared.log(
                "[LibrarySync] Kept \(title) at \(to) on \(side.name) (other side had \(from))",
                type: "Debug")
            return .keptAhead

        case .skipLeftDiffering(let source, let target):
            Logger.shared.log(
                "[LibrarySync] Left \(title) differing: \(source.displayName) vs \(target.displayName) on \(side.name)",
                type: "Debug")
            return .leftDiffering

        case .create(let status, let progress, let score, let timesRewatched),
             .advance(let status, let progress, let score, let timesRewatched):
            return await performWrite(
                to: side, id: id, title: title, hadEntry: hadEntry,
                status: status, progress: progress, score: score, timesRewatched: timesRewatched)
        }
    }

    // MARK: - Overwrite and mirror runs

    /// Runs a plan: overwrites first, then removals.
    private func execute(_ plan: LibraryOverwritePlan) async -> LibrarySyncSummary {
        var summary = LibrarySyncSummary()
        summary.unmatched = plan.unmatched
        summary.upToDate = plan.unchanged
        summary.keptUnverified = plan.keptUnverified

        let total = plan.writes.count + plan.deletions.count
        for (index, write) in plan.writes.enumerated() {
            statusText = "Copying \(index + 1) of \(total)"
            summary.record(await performWrite(
                to: write.side, id: write.id, title: write.title, hadEntry: !write.isNew,
                status: write.status, progress: write.progress,
                score: write.score, timesRewatched: write.timesRewatched))
        }

        for (index, deletion) in plan.deletions.enumerated() {
            statusText = "Removing \(index + 1) of \(plan.deletions.count)"
            summary.record(await remove(deletion))
        }
        return summary
    }

    private func remove(_ deletion: PlannedDeletion) async -> Outcome {
        do {
            switch deletion.side {
            case .anilist:
                try await AniListLibraryService.shared.deleteEntry(entryId: deletion.id)
            case .mal:
                try await MALLibraryService.shared.deleteEntry(malId: deletion.id)
            }
            try? await Task.sleep(nanoseconds: Self.writeIntervalNanos)
            return .deleted
        } catch {
            Logger.shared.log(
                "[LibrarySync] Failed to delete \(deletion.title) from \(deletion.side.name): \(error)",
                type: "Error")
            try? await Task.sleep(nanoseconds: Self.writeIntervalNanos)
            return .failed
        }
    }

    // MARK: - Writing

    /// Writes through the per-service libraries rather than `MediaProvider`, which has no repeat
    /// parameter — without it rewatch counts could never be brought level.
    private func performWrite(
        to side: LibrarySide, id: Int, title: String, hadEntry: Bool,
        status: MediaListStatus, progress: Int, score: Double, timesRewatched: Int?
    ) async -> Outcome {
        do {
            switch side {
            case .anilist:
                try await AniListLibraryService.shared.updateEntry(
                    mediaId: id, status: status, progress: progress,
                    score: score, repeat: timesRewatched)
            case .mal:
                try await MALLibraryService.shared.updateEntry(
                    malId: id, status: status, progress: progress,
                    score: score, numTimesRewatched: timesRewatched)
            }
            try? await Task.sleep(nanoseconds: Self.writeIntervalNanos)
            return hadEntry ? .advanced : .created
        } catch {
            Logger.shared.log("[LibrarySync] Failed \(title) on \(side.name): \(error)", type: "Error")
            try? await Task.sleep(nanoseconds: Self.writeIntervalNanos)
            return .failed
        }
    }

    // MARK: - Reading and reporting

    private func readLibraries() async -> [LibrarySide: [LibraryEntry]]? {
        // Read each side under its own catch. Collapsing them into one message was what made a
        // failure impossible to act on — it named neither the service nor the reason.
        var result: [LibrarySide: [LibraryEntry]] = [:]
        for side in LibrarySide.allCases {
            do {
                result[side] = try await provider(for: side).fetchLibrary()
            } catch {
                reportReadFailure(side: side, error: error)
                return nil
            }
        }
        return result
    }

    /// The provider that serves one side's library.
    private func provider(for side: LibrarySide) -> any MediaProvider {
        switch side {
        case .anilist: return AniListProvider.shared
        case .mal:     return MALProvider.shared
        }
    }

    private func reportReadFailure(side: LibrarySide, error: Error) {
        let message = Self.readFailureMessage(side: side, error: error)
        Logger.shared.log("[LibrarySync] \(message) — \(error)", type: "Error")
        // `ToastManager` lives in an iOS-only file; elsewhere the log is the report, same as the
        // app's other cross-platform surfaces.
        #if os(iOS)
        ToastManager.shared.show(message: message, type: .error, duration: 6)
        #endif
    }

    /// Describes a failed library read in terms of what actually went wrong.
    ///
    /// The previous wording — "check you're signed in to both" — asserted one cause for every
    /// failure. A rate limit, an outage or a dropped connection are not sign-in problems, and
    /// sending somebody to re-authenticate over one wastes their time and doesn't fix it.
    nonisolated static func readFailureMessage(side: LibrarySide, error: Error) -> String {
        let prefix = "Couldn't read your \(side.name) library"
        guard let providerError = error as? ProviderError else {
            return "\(prefix): \(error.localizedDescription)"
        }
        switch providerError {
        case .unauthenticated:
            return "\(prefix) — \(side.name) rejected your sign-in. Sign out of \(side.name) and back in."
        case .networkError(let underlying):
            return "\(prefix) — \(underlying.localizedDescription)"
        case .serverError(let code):
            return "\(prefix) — \(side.name) returned an error (\(code)). Try again in a minute."
        default:
            return "\(prefix): \(providerError.localizedDescription)"
        }
    }

    private func report(_ run: SyncRun, summaries: [LibrarySide: LibrarySyncSummary]) {
        // Name only the sides this run actually wrote to. A side that was never touched has
        // nothing to report, and listing it as "nothing changed" reads as a failure.
        let written = LibrarySide.allCases.filter { summaries[$0] != nil }
        let message = written
            .map { "\($0.name): \(summaries[$0]!.sentence)" }
            .joined(separator: " · ")

        let combined = written.reduce(LibrarySyncSummary()) { $0.adding(summaries[$1]!) }
        lastSummary = combined
        Logger.shared.log("[LibrarySync] \(run.title): \(message)", type: "Provider")
        #if os(iOS)
        ToastManager.shared.show(
            message: message,
            type: combined.failed > 0 ? .warning : .success,
            duration: 5
        )
        #endif
    }

    // MARK: - Id resolution

    /// AniList hands back the MyAnimeList id directly for most titles; the mapping service
    /// covers the rest.
    private func malIds(for entries: [LibraryEntry]) async -> [Int: Int] {
        var ids: [Int: Int] = [:]
        for entry in entries {
            if let idMal = entry.media.idMal {
                ids[entry.media.id] = idMal
            } else if let mapped = await IDMappingService.shared.malId(forAnilistId: entry.media.id) {
                ids[entry.media.id] = mapped
            }
        }
        return ids
    }

    private func anilistIds(for entries: [LibraryEntry]) async -> [Int: Int] {
        var ids: [Int: Int] = [:]
        for entry in entries {
            if let mapped = await IDMappingService.shared.anilistId(forMALId: entry.media.id) {
                ids[entry.media.id] = mapped
            }
        }
        return ids
    }
}

private extension LibrarySyncSummary {
    mutating func record(_ outcome: LibrarySyncService.Outcome) {
        switch outcome {
        case .upToDate:      upToDate += 1
        case .keptAhead:     keptAhead += 1
        case .leftDiffering: leftDiffering += 1
        case .created:       created += 1
        case .advanced:      advanced += 1
        case .deleted:       deleted += 1
        case .failed:        failed += 1
        }
    }

    /// Both sides of a two-way run as one tally, for `lastSummary`.
    func adding(_ other: LibrarySyncSummary) -> LibrarySyncSummary {
        var total = self
        total.created += other.created
        total.advanced += other.advanced
        total.upToDate += other.upToDate
        total.keptAhead += other.keptAhead
        total.leftDiffering += other.leftDiffering
        total.deleted += other.deleted
        total.keptUnverified += other.keptUnverified
        total.unmatched += other.unmatched
        total.failed += other.failed
        return total
    }
}

/// One library-sync run: who is read, who is written, and how.
///
/// Replaces the old `Direction` enum, which hand-wrote every AniList↔MyAnimeList permutation.
/// Two services needed seven cases; three would need nineteen. Naming both ends as values
/// instead means the run list is generated from whoever is actually signed in.
struct SyncRun: Identifiable, Equatable {

    enum Kind: String {
        /// Merge every side at once: per title, whichever account is further along wins.
        case merge
        /// Add to and advance one target, never moving it backwards.
        case copyForward
        /// Overwrite the target with the source, extras left in place.
        case overwrite
        /// Overwrite *and* delete, leaving the target an exact copy.
        case mirror
    }

    /// The three groups the Settings screen shows, so the safe runs and the destructive ones
    /// never sit in the same tap target.
    enum Section: CaseIterable { case sync, overwrite, mirror }

    /// nil on both ends means the all-ways merge, which reads and writes every side.
    let source: LibrarySide?
    let target: LibrarySide?
    let kind: Kind

    var id: String { "\(kind.rawValue)|\(source?.rawValue ?? "all")|\(target?.rawValue ?? "all")" }

    var sourceName: String { source?.name ?? "" }
    var targetName: String { target?.name ?? "" }

    /// Whether this run can destroy history the app cannot get back.
    var isDestructive: Bool { kind == .overwrite || kind == .mirror }

    /// The all-ways merge writes everywhere; every other run writes only to its target.
    func writes(to side: LibrarySide) -> Bool { target == nil || target == side }

    /// Every run the given section offers for these signed-in sides.
    ///
    /// Ordered by target in `LibrarySide.allCases` order, uniformly across all three sections.
    /// The old fixed lists ordered the sync section by source and the destructive sections by
    /// target; this makes them consistent.
    static func runs(in section: Section, among sides: [LibrarySide]) -> [SyncRun] {
        guard sides.count >= 2 else { return [] }

        let ordered = LibrarySide.allCases.filter(sides.contains)
        let pairs: [(source: LibrarySide, target: LibrarySide)] = ordered.flatMap { target in
            ordered.filter { $0 != target }.map { (source: $0, target: target) }
        }

        switch section {
        case .sync:
            return [SyncRun(source: nil, target: nil, kind: .merge)]
                + pairs.map { SyncRun(source: $0.source, target: $0.target, kind: .copyForward) }
        case .overwrite:
            return pairs.map { SyncRun(source: $0.source, target: $0.target, kind: .overwrite) }
        case .mirror:
            return pairs.map { SyncRun(source: $0.source, target: $0.target, kind: .mirror) }
        }
    }

    /// Always reads *source → target*, so the arrow head points at the account that changes.
    /// "Overwrite AniList with MyAnimeList" was ambiguous in English about which of the two was
    /// about to be overwritten; an arrow isn't.
    var title: String {
        guard let source, let target else {
            return LibrarySide.allCases.map(\.name).joined(separator: " ⇄ ")
        }
        return "\(source.name) → \(target.name)"
    }

    /// Names the account that changes, so the arrow never has to be read twice.
    var subtitle: String {
        switch kind {
        case .merge:       return "Merges all, keeping whichever is further along"
        case .copyForward: return "Adds to and advances \(targetName)"
        case .overwrite:   return "Overwrites \(targetName)"
        case .mirror:      return "Overwrites \(targetName) and deletes its extras"
        }
    }

    var confirmationTitle: String {
        switch kind {
        case .merge:       return "Sync All Ways"
        case .copyForward: return "Copy to \(targetName)"
        case .overwrite:   return "Overwrite \(targetName)?"
        case .mirror:      return "Erase and Replace \(targetName)?"
        }
    }

    var confirmButtonTitle: String {
        switch kind {
        case .merge:       return "Sync"
        case .copyForward: return "Copy"
        case .overwrite:   return "Overwrite \(targetName)"
        case .mirror:      return "Erase and Replace"
        }
    }

    var confirmationMessage: String {
        switch kind {
        case .merge:
            return "Brings every signed-in account level with the others. For every title, "
                 + "whichever account is further along wins — nothing is ever moved backwards."
        case .copyForward:
            return "Adds anything missing from \(targetName) and moves its progress forward "
                 + "to match \(sourceName). Titles already further along on \(targetName) "
                 + "are left untouched."
        case .overwrite:
            return "Overwrites \(targetName) with \(sourceName) — progress, status, score and "
                 + "rewatch count — including where \(targetName) is further along. Titles "
                 + "only \(targetName) has are left alone. This can't be undone."
        case .mirror:
            return "Makes \(targetName) an exact copy of \(sourceName), overwriting it and "
                 + "deleting entries \(sourceName) doesn't have. Entries whose match can't be "
                 + "confirmed are kept. This can't be undone."
        }
    }
}
