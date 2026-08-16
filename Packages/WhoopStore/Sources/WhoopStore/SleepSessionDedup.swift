import Foundation

/// Overlap-aware de-duplication of banked sleep sessions (#899).
///
/// An unstable strap clock can re-bank the SAME night's raw data under a shifted timebase across
/// syncs, so successive analyze passes detect the night at shifted bounds and the sleepSession
/// table accumulates two (or more) OVERLAPPING copies of one night under different `startTs` keys.
/// The exact (deviceId, startTs) primary-key upsert cannot collapse them (the keys differ), day
/// assignment then keys the stale copy to the wrong wake day, and Charge/Rest pin to the old night.
///
/// This is the shared collapse rule, applied wherever banked sessions are assembled before day
/// assignment / scoring (habitual-midsleep learning, band sleep-state consumption, and the
/// post-upsert store heal in IntelligenceEngine). Pure + deterministic so it is unit-tested
/// directly and the Kotlin twin (`com.noop.analytics.SleepSessionDedup`) mirrors it byte-for-byte.
public enum SleepSessionDedup {

    /// Absolute overlap (seconds) at or above which two sessions are copies of the same night.
    /// On one honest timeline two REAL sleeps can never overlap at all; material overlap only
    /// arises from re-detected bound drift or a timebase-shifted re-bank. 30 min keeps the rule
    /// conservative at the seams: sub-30-min grazes from boundary jitter are never collapsed.
    public static let minOverlapSeconds = 30 * 60

    /// Fractional overlap of the SHORTER session at or above which two sessions are duplicates.
    /// Catches a short duplicate fragment swallowed by a longer copy of the same night even when
    /// the absolute overlap is under the 30 min bar (e.g. a 40 min fragment 60% inside the night).
    public static let minOverlapFractionOfShorter = 0.5

    /// Edge distance (seconds) at or below which a same-night FRAGMENT is still one night (#1284 residual 3).
    /// The Oura SleepNet burst runs a few epochs before the `0x49` onset, so its pre-onset piece can bank as
    /// a short session ending just before — or, when the backward lay overshoots the onset, grazing just
    /// into — the anchored night. This bar catches it on EITHER side of the touch point (see the fragment
    /// rule in `isDuplicate`); 15 min is ~2× the observed pre-onset span, well below any real inter-sleep gap.
    public static let nearAdjacentSeconds = 15 * 60

    /// A shorter session at or below this fraction of the longer one is a re-decode FRAGMENT of that night,
    /// not a second sleep (#1284 residual 3). It is what separates a fragment hugging a night (26 min beside
    /// a 390 min night = 6.7 % → collapse; a 40 min pre-onset piece beside an 8 h night = 8.3 % → collapse)
    /// from two GENUINE adjacent naps of comparable length (20 min beside 33 min = 61 % → kept), which must
    /// never merge. Ratio, not an absolute cap: real naps and re-decode fragments overlap in absolute length
    /// (both ~20–30 min), so only the ratio to the partner night tells them apart. Deliberately conservative
    /// (0.10): the durable fix is generation-side `0x49`-onset keying — this only heals what still slips through.
    public static let fragmentFractionOfLonger = 0.10

    /// Seconds of overlap between the two sessions' EFFECTIVE spans (edited onsets honoured,
    /// mirroring how display / day assignment place the block). 0 when disjoint.
    static func overlapSeconds(_ a: CachedSleepSession, _ b: CachedSleepSession) -> Int {
        max(0, min(a.endTs, b.endTs) - max(a.effectiveStartTs, b.effectiveStartTs))
    }

    /// Edge gap (seconds) between two DISJOINT sessions (the later start minus the earlier end); 0 when
    /// they touch or overlap. Only meaningful when `overlapSeconds == 0`.
    static func edgeGapSeconds(_ a: CachedSleepSession, _ b: CachedSleepSession) -> Int {
        max(0, max(a.effectiveStartTs, b.effectiveStartTs) - min(a.endTs, b.endTs))
    }

    /// True when `a` and `b` are copies of the same night: a substantial overlap (`minOverlapSeconds`
    /// absolute, OR `minOverlapFractionOfShorter` of the shorter session), OR a same-night FRAGMENT — a
    /// session no more than `fragmentFractionOfLonger` of the longer one — sitting at its edge, whether it
    /// grazes in (small overlap) or falls just short (gap within `nearAdjacentSeconds`).
    ///
    /// The fragment term is deliberately continuous across the overlap==0 seam: a pre-onset piece that
    /// overshoots the anchored onset by seconds must not be treated as MORE distinct than one ending seconds
    /// short of it (that discontinuity left a 121 s-grazing fragment un-collapsed on 08-13/14 while a 69 s
    /// gap collapsed — #1284). The ratio gate keeps two GENUINE adjacent naps (comparable length) apart.
    /// All terms use only (effectiveStartTs, endTs), the only time fields the data model carries.
    public static func isDuplicate(_ a: CachedSleepSession, _ b: CachedSleepSession) -> Bool {
        let overlap = overlapSeconds(a, b)
        if overlap >= minOverlapSeconds { return true }
        let aDur = max(a.endTs - a.effectiveStartTs, 0)
        let bDur = max(b.endTs - b.effectiveStartTs, 0)
        let shorter = min(aDur, bDur)
        if overlap > 0, shorter > 0, Double(overlap) >= minOverlapFractionOfShorter * Double(shorter) {
            return true
        }
        // Same-night fragment: short relative to the longer night AND hugging its edge (either side).
        let longer = max(aDur, bDur)
        let isFragment = shorter > 0 && Double(shorter) <= fragmentFractionOfLonger * Double(longer)
        return isFragment && (overlap > 0 || edgeGapSeconds(a, b) <= nearAdjacentSeconds)
    }

    /// The canonical preference key (see `dedupe`): higher tuple wins. Shared by `dedupe` and the
    /// at-persist keying (`planBank`) so both adjudicate a night with the IDENTICAL rule.
    static func rankKey(_ s: CachedSleepSession, freshStarts: Set<Int>) -> (Int, Int, Int, Int, Int) {
        (s.userEdited ? 1 : 0,
         freshStarts.contains(s.startTs) ? 1 : 0,
         s.endTs - s.effectiveStartTs,
         s.endTs,
         s.startTs)
    }

    /// Collapse overlapping duplicates to one canonical survivor per night, deterministically.
    ///
    /// Canonical preference, highest first:
    ///   1. `userEdited`: a hand-corrected night is never dropped (matching the engine's existing
    ///      edited-window upsert guard, where the user's correction always outranks re-detection).
    ///   2. Bank recency: `startTs` in `freshStarts`. The row model has no banked-at column, so
    ///      recency is witnessed by the CALLER passing the keys it banked this pass; the freshly
    ///      detected copy reflects the strap's current timebase and is the truth to keep.
    ///   3. Longest effective duration: the fullest capture of the night.
    ///   4. Latest endTs, then latest startTs: a stable total order so ties break the same way
    ///      on every run and platform.
    ///
    /// Greedy sweep in preference order: a session is kept unless it overlap-duplicates an
    /// already-kept one (edited rows are exempt and always kept). Both outputs are sorted by
    /// startTs. Read-side callers with no bank witness pass no `freshStarts`.
    public static func dedupe(_ sessions: [CachedSleepSession], freshStarts: Set<Int> = [])
        -> (kept: [CachedSleepSession], dropped: [CachedSleepSession]) {
        guard sessions.count > 1 else { return (sessions, []) }
        let ordered = sessions.sorted { rankKey($0, freshStarts: freshStarts) > rankKey($1, freshStarts: freshStarts) }
        var kept: [CachedSleepSession] = []
        var dropped: [CachedSleepSession] = []
        for s in ordered {
            if !s.userEdited, kept.contains(where: { isDuplicate($0, s) }) {
                dropped.append(s)
            } else {
                kept.append(s)
            }
        }
        return (kept.sorted { $0.startTs < $1.startTs },
                dropped.sorted { $0.startTs < $1.startTs })
    }

    // MARK: - #1284 residual 3: generation-side 0x49-onset keying (at-persist, no schema migration)

    /// The grid (seconds) the 0x49 onset is rounded to before it becomes a session's `startTs`. The ring
    /// re-serves one night's `0x49` summary many times as its END chases wall-clock; the ONSET is stable
    /// across those re-serves (measured 21 s spread over 11 servings on 08-16), so rounding it to a coarse
    /// grid gives every re-serve of one night the SAME `startTs` → the `(deviceId, startTs)` PK collapses
    /// them instead of minting a row per drain. 60 s ≫ the 21 s jitter (re-serves land in one bucket) yet
    /// keeps the displayed bedtime accurate to the minute — and the bedtime becomes the TRUE onset, fixing
    /// the current end-anchored drift (`startTs = end − laidCodes·30 s`).
    public static let onsetKeyGridSeconds = 60

    /// Round a `0x49` onset (Unix seconds) to `onsetKeyGridSeconds` — the stable per-night key. Rounds to
    /// nearest so a jittering onset lands in one bucket; a rare straddle at a bucket edge is caught by the
    /// completeness guard (`planBank`), which matches the night by overlap, not by the PK.
    public static func keyedStart(onsetUnixSeconds: Int, gridSeconds: Int = onsetKeyGridSeconds) -> Int {
        let g = max(1, gridSeconds)
        return ((onsetUnixSeconds + g / 2) / g) * g
    }

    /// Decide, at persist time, whether a freshly reconstructed `candidate` night should be banked and
    /// which already-stored rows it supersedes — the generation-side twin of the `dedupe` heal, so a
    /// duplicate is suppressed BEFORE it is banked (closing the window where the wrong night shows until
    /// the next analyze pass). Same collapse rule as `dedupe` with NO bank-recency witness (ring rows fall
    /// back to longest-, then latest-end-wins):
    ///   • bank the candidate unless an existing same-night row is at least as complete (ties keep the
    ///     stored row — an exact re-serve is a no-op; a partial re-drain never clobbers a fuller night);
    ///   • when the candidate wins (fuller, or a later-waking copy of the same night), delete the
    ///     same-night rows it supersedes so exactly one row per night survives.
    /// Pure; the caller does the actual store delete + upsert only when `bank` is true.
    /// `existing` MUST be the UNFILTERED stored set for the night's window — INCLUDING a row that already
    /// sits at the candidate's keyed `startTs`. Since keying rounds re-serves of one night to the same
    /// bucket, that same-PK row is the *common* collision, and it has to be weighed here: otherwise the
    /// upsert would replace a fuller stored night with a partial re-drain by PK (the exact clobber this
    /// guard exists to prevent). The `supersededStarts` deliberately EXCLUDE the candidate's own `startTs` —
    /// the upsert replaces that row in place, so listing it would delete the row we just banked.
    public static func planBank(candidate: CachedSleepSession, existing: [CachedSleepSession])
        -> (bank: Bool, supersededStarts: [Int]) {
        let sameNight = existing.filter { isDuplicate(candidate, $0) }
        let candidateRank = rankKey(candidate, freshStarts: [])
        // Suppress the candidate if any stored same-night row (same PK or not) ties or outranks it.
        if sameNight.contains(where: { rankKey($0, freshStarts: []) >= candidateRank }) {
            return (bank: false, supersededStarts: [])
        }
        // Candidate is the fullest: bank it (the upsert replaces any same-PK row) and retire the OTHER
        // same-night rows it supersedes.
        return (bank: true, supersededStarts: sameNight.filter { $0.startTs != candidate.startTs }.map(\.startTs))
    }
}
