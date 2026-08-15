import Foundation

/// Pure session-identity reconciler for the Oura live hypnogram path (#1284 residual 3).
///
/// THE PROBLEM. `OuraLiveSource.persistHypnogramBurst` sets a session's `startTs` from the matched
/// `0x49` sleep-summary onset and banks under `PK = (deviceId, startTs)`. The ring serves more than
/// one decode of the same night — measured by @pipiche38 over four nights — in two distinct modes:
///
///   • **Re-anchor** (08-12/13): the *same* hypnogram laid backwards from two different `0x49` onsets,
///     boundary-for-boundary identical, offset by a fixed lag (554 s on that night). Two onsets ⇒ two
///     `startTs` ⇒ two rows.
///   • **Partial drain** (08-13/14): a genuinely shorter, divergent decode from an earlier partial
///     burst, with its OWN `0x49` anchor (494 min/89 seg vs 234 min/35 seg, diverging at segment 5).
///
/// `PK=(deviceId,startTs)` mints a second row in both modes; the #899 heal only cleans up afterward.
///
/// THE FIX (validated against @pipiche38's corpus — option (2) collapses 4/4 nights, the 30-min grid
/// only 1/4). Group a ring's sessions by the **noon-anchored sleep-day** (`date(startTs_local + 12h)`),
/// then within a day treat two sessions as the SAME session when they overlap or sit within
/// `mergeGapS` (≈60 min) of each other — and keep the FULLER one (the completeness guard, which is what
/// actually adjudicates the partial-drain mode; the fuller row is the WHOOP-matching one on every night
/// in the corpus). Sessions further apart than `mergeGapS` on the same sleep-day are DISTINCT (a genuine
/// afternoon nap is hours from that night's sleep) and each keeps its own row.
///
/// Why noon-anchor and not plain wake-day: on 08-10/11 the 40-min fragment `22:09:40 → 22:49:40` ENDS
/// before midnight, so its wake-day (Aug 10) differs from the night it belongs to (Aug 11); the noon
/// anchor maps both fragment and full night to the same sleep-day. Why not a grid: two starts 6¼ min
/// apart (08-11/12, 22:26 vs 22:32) straddle a 30-min boundary and fail to collapse, and a grid spends
/// every night's bedtime precision — the precision that let 08-13/14's window be checked against WHOOP
/// to −10 s/+50 s. Proximity needs no estimate of the jitter it corrects (242 s healthy … 2469 s worst).
///
/// This type is PURE (no store, no BLE, no CoreBluetooth) so the decision is unit-testable headlessly on
/// both platforms against the measured nights. The caller (`OuraLiveSource`) supplies the day's already
/// persisted sessions (read from the DB at persist time — the same read that lets the check see
/// cross-connection duplicates, which a per-connection in-memory list cannot) and acts on the decision.
/// Byte-identical twin: Kotlin `OuraSessionReconciler`.
public enum OuraSessionReconciler {

    /// A persisted (or about-to-persist) Oura sleep session, reduced to the fields the reconciler needs.
    /// `codeCount` is the number of laid 30-s stage epochs — the completeness signal (more codes = a
    /// fuller drain of the same night). Ties break toward the NEW session (see `reconcile`).
    public struct SessionWindow: Equatable, Sendable {
        public let startTs: Int
        public let endTs: Int
        public let codeCount: Int
        public init(startTs: Int, endTs: Int, codeCount: Int) {
            self.startTs = startTs
            self.endTs = endTs
            self.codeCount = codeCount
        }
    }

    /// What the caller should do with the new session relative to the day's existing rows.
    public enum Decision: Equatable, Sendable {
        /// No existing session is the same as the new one — persist it as a fresh row.
        case insert
        /// An existing same-session row is at least as complete — drop the new one, keep what's stored.
        case skip
        /// The new session is the fullest decode of a same-session it collides with — persist it and
        /// delete the superseded rows at these `startTs` keys (the earlier/shorter duplicates).
        case replace(supersededStartTs: [Int])
    }

    /// Default same-session proximity: sessions within this many seconds (or overlapping) are the same
    /// night's sleep; further apart on the same sleep-day is a distinct session (nap). 60 min clears the
    /// widest measured duplicate gap (2469 s) with margin and is far below any real nap-to-sleep gap.
    public static let defaultMergeGapSeconds = 3600

    /// The noon-anchored sleep-day integer (days since the Unix epoch) a session belongs to:
    /// `date(startTs_local + 12h)`. Sessions sharing this value are candidates to be the same night;
    /// it is the grouping key the caller uses to read "this night's" existing rows. `tzOffsetSeconds`
    /// is the wearer's UTC offset at the session (e.g. +7200 for CEST) — the day boundary is LOCAL noon,
    /// so a UTC-only bucket would rebucket evening sleep across the date line.
    public static func noonAnchoredSleepDay(startTs: Int, tzOffsetSeconds: Int) -> Int {
        // floorDiv so pre-1970 / negative-offset instants still floor toward the earlier day.
        let local = startTs + tzOffsetSeconds + 12 * 3600
        return floorDiv(local, 86_400)
    }

    /// Decide how to persist `new` given the ring's already-stored sessions FOR THE SAME NOON-ANCHORED
    /// SLEEP-DAY (`existing`). The caller must pass only same-sleep-day rows (it read them by
    /// `noonAnchoredSleepDay`); this function does the proximity + completeness adjudication.
    ///
    /// - overlap OR gap < `mergeGapS` ⇒ same session as `new`.
    /// - `new` at least as complete (`codeCount >=`) as every same-session it hits ⇒ `.replace` them
    ///   (ties break toward `new`, so the re-anchor mode collapses to the latest/refined onset).
    /// - otherwise a stored same-session is fuller ⇒ `.skip` `new`.
    /// - no same-session ⇒ `.insert` (a distinct session — e.g. a nap hours away).
    ///
    /// Known limitation (not seen in the corpus, requires an implausible shape): a `new` that reaches
    /// within `mergeGapS` of TWO mutually-distinct stored sessions AND is fuller than both would
    /// `.replace` them both — merging a nap and a night. That needs a single session spanning the
    /// nap→night gap and longer than the night, which Oura hypnograms don't produce; if a hardware
    /// capture ever shows it, gate `.replace` on the matched set being mutually same-session too.
    public static func reconcile(new: SessionWindow,
                                 existing: [SessionWindow],
                                 mergeGapS: Int = defaultMergeGapSeconds) -> Decision {
        let sameSession = existing.filter { isSameSession(new, $0, mergeGapS: mergeGapS) }
        guard !sameSession.isEmpty else { return .insert }
        let fullestStored = sameSession.map(\.codeCount).max() ?? 0
        if new.codeCount >= fullestStored {
            return .replace(supersededStartTs: sameSession.map(\.startTs))
        }
        return .skip
    }

    /// The `[from, to]` startTs range the caller should read candidate sessions over, given the new
    /// session's bounds. A hypnogram night is at most ~16 h and a same-session sits within `mergeGapS`,
    /// so a stored session starting earlier than `from` or after `to` cannot be proximate to `new` —
    /// `reconcile` would filter it out anyway. Read is proximity-scoped (a superset of the noon-anchored
    /// sleep-day, and timezone-independent, so a mid-night travel offset change can't split the read).
    public static func candidateReadWindow(newStartTs: Int, newEndTs: Int,
                                           mergeGapS: Int = defaultMergeGapSeconds) -> (from: Int, to: Int) {
        (from: newStartTs - 16 * 3600 - mergeGapS, to: newEndTs + mergeGapS)
    }

    /// Two windows are the same session when they overlap, or the nearest edge gap between them is under
    /// `mergeGapS`. Symmetric; either ordering of the pair gives the same answer.
    static func isSameSession(_ a: SessionWindow, _ b: SessionWindow, mergeGapS: Int) -> Bool {
        if a.startTs < b.endTs && b.startTs < a.endTs { return true }   // overlap
        let gap = a.startTs >= b.endTs ? a.startTs - b.endTs : b.startTs - a.endTs
        return gap < mergeGapS
    }

    /// Floor division toward negative infinity (Swift `/` truncates toward zero), so the sleep-day is
    /// correct for negative operands. Matches Kotlin `Math.floorDiv`.
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}
