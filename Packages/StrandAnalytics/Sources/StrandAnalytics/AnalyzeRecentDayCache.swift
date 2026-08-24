import Foundation

/// Per-day reuse identity for `IntelligenceEngine.analyzeRecent`'s pass-1 loop.
///
/// The drain this closes (#1005): on a heavy user (21 nights of history, ~178 k HR rows/night, a 1.26 GB
/// store) every `newData` re-score re-read *every* night's raw streams and re-ran `analyzeDay`, even though
/// a post-offload only ever adds rows to the 1–2 most-recent days — measured at a median ~4.6 min / pass,
/// all CPU, and it fires back-to-back through an offload storm. Pass 1 already keeps only each night's small
/// result and NOT the raw streams, and — by that loop's own design note — "every field except recovery is
/// baseline-independent, so pass 2 only re-scores the cheap recovery composite". So a night whose scored
/// inputs are unchanged since it was last scored re-produces a byte-identical result: the engine keeps an
/// in-memory `[day: (key, DayScan)]` cache and reuses the scan when this key matches, skipping the reads +
/// `analyzeDay`. A miss is byte-for-byte the current full path; the cache never touches banking (every day
/// still flows into pass 2), so there is no data-loss surface.
///
/// The cache is in-memory and per-device — it never persists and never crosses the `.noopbak` boundary — so
/// it only has to invalidate correctly on one platform; the Kotlin twin (`AnalyzeRecentDayCache`) mirrors
/// the shape but the two key strings are NOT required to match byte-for-byte across platforms.
public enum AnalyzeRecentDayCache {
    /// The per-day reuse key. Reuse a cached day iff this string is unchanged since the scan was cached.
    ///
    /// - `hrCount` / `hrMaxTs`: the night-window HR fingerprint (row count + newest timestamp) — the SAME
    ///   change witness the whole-pass gate at the top of `analyzeRecent` already trusts, applied here at
    ///   day granularity. Any new/removed HR row moves one of the two.
    /// - `skinAnchorRaw`: the WHOOP 4.0 window-wide skin-temp anchor (nil for a 5/MG, or when unresolved).
    ///   It is window-wide, so a re-anchor caused by *another* night's skin data shifts this night's skin
    ///   conversion without moving this night's HR fingerprint — folding it in makes that invalidate reuse.
    ///   Encoded by raw bit-pattern so the equality check is exact and locale-free.
    /// - `owner`: the resolved owning device id the fingerprint was measured against. The fingerprint is
    ///   already device-scoped, so this is belt-and-suspenders for the **multi-strap** case (a user with
    ///   both a 4.0 and a 5/MG): when a day's resolved owner flips between straps, keying on the owner makes
    ///   the reuse invalidate **explicitly**, rather than relying on two different devices never producing an
    ///   identical `count`+`maxTs` for the same window.
    ///
    /// Inputs that feed `analyzeDay` but are pass-global rather than per-day (profile, baselines1, sleep
    /// need / consistency, habitual midsleep, tz, stager toggles) are NOT in this key — the engine drops the
    /// whole cache when its pass config signature changes, which covers them.
    public static func cacheKey(owner: String, hrCount: Int, hrMaxTs: Int, skinAnchorRaw: Double?,
                                // #1575: whether this day is the one that emits the PER-WINDOW HRV detail
                                // (`dayStart == nowLocalMidnight`). Now that an active trace no longer
                                // disables reuse, this has to invalidate: the night cached as "today" with
                                // its detailed trace becomes an ordinary night after midnight, and a fresh
                                // scan would emit only the one-line summary for it. Without this the reused
                                // night would keep replaying detail it is no longer entitled to — and the
                                // cache's whole promise is that a reused night is indistinguishable from a
                                // freshly-scored one. Costs one day's re-score per rollover, and only while
                                // a trace mode is on.
                                hrvWindowDetail: Bool) -> String {
        let anchor = skinAnchorRaw.map { String($0.bitPattern) } ?? "nil"
        return "\(owner)|\(hrCount):\(hrMaxTs):\(anchor):\(hrvWindowDetail ? "d" : "s")"
    }
}
