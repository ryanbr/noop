import Foundation

/// Why the Rest card's "Pending sync" state is on or off (#2012).
///
/// That state is `backfilling || historyPendingSync`, and only the first half leaves a trace: an offload
/// announces itself with "Backfill: session started" and a run of bursts. The second half flipped in
/// silence, so a report of the note showing hours after waking could not be answered from a strap log at
/// all. #2012 is exactly that: a log arrived, and it could only be read by inferring from what else was
/// happening at the timestamp, which settles nothing.
///
/// So the line names the DECIDING input rather than just the verdict. Four things can decide it, and they
/// mean different bugs: a future-dated strap clock, a phantom gap that advertises records it never banks,
/// being genuinely caught up, or being genuinely behind. Reading "behind by 34210s" in the afternoon is
/// the evidence that the trigger is not scoped to the night being scored, which is the open half of #2012.
///
/// Pure so it is unit-tested directly; byte-identical to the Android twin.
enum PendingSyncDiagnostic {

    /// Where the flag was recomputed. The two sites weigh different evidence, so the line says which.
    static let siteConnect = "connect"
    static let sitePostOffload = "post-offload"

    /// One line for a CHANGE of the flag; callers log it only on a flip, never per evaluation.
    ///
    /// - Parameter persistedRows: nil at ``siteConnect``, which cannot weigh it: no offload has run, so
    ///   there is no row evidence yet. Naming that rather than printing a misleading "no".
    static func line(pending: Bool, site: String, newestUnix: Int?, frontierUnix: Int?,
                     futureDated: Bool, persistedRows: Bool?, thresholdSec: Int) -> String {
        // OPTIONAL deliberately, to match the Android twin. There the flag flips to false when either
        // input is missing, so requiring them would leave that flip silent, which is the exact hole this
        // line exists to close. Apple currently leaves the flag untouched in that case rather than
        // flipping it, a divergence worth its own look; the formatter can express either.
        guard let newest = newestUnix, let frontier = frontierUnix else {
            return "pending-sync \(pending ? "ON" : "OFF") (\(site)): no range to compare "
                + "[newest=\(newestUnix.map { String($0) } ?? "unknown") "
                + "frontier=\(frontierUnix.map { String($0) } ?? "unknown")]"
        }
        let gap = newest - frontier
        let why: String
        if futureDated {
            why = "strap clock reads ahead of now, so the gap could never close (#928/#1012)"
        } else if persistedRows == false {
            why = "strap advertises newer records but banked no rows — phantom gap (#1144)"
        } else if gap > thresholdSec {
            why = "strap is \(gap)s ahead of our frontier, over the \(thresholdSec)s threshold"
        } else {
            why = "caught up — \(gap)s gap, within the \(thresholdSec)s threshold"
        }
        let rows: String
        switch persistedRows {
        case .none: rows = "n/a at connect"
        case .some(true): rows = "yes"
        case .some(false): rows = "no"
        }
        return "pending-sync \(pending ? "ON" : "OFF") (\(site)): \(why) "
            + "[newest=\(newest) frontier=\(frontier) gap=\(gap)s futureDated=\(futureDated) rowsBanked=\(rows)]"
    }
}
