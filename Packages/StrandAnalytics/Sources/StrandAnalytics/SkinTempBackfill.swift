import Foundation
import WhoopProtocol

/// #1853: backfill the nightly ABSOLUTE skin temperature (`skinTempC`) for nights the 21-night
/// `analyzeRecent` rescore window never reaches.
///
/// `skinTempC` is written only by the scoring pass (`IntelligenceEngine`, #1663, 2026-08-27), which
/// covers a rolling 21-night window. Nights already outside that window when the column shipped were
/// never revisited, and nothing walks them since — so a night is missing its absolute if it fell
/// outside every window that ran after 27 Aug, regardless of whether its raw `skinTempSample` rows
/// are still on disk (they are: `skinTempSample` has no age-based retention).
///
/// This file holds the PURE, database-free half of the backfill: the session-attribution rule and the
/// per-night plan. The walker that reads from / writes to `WhoopStore` lives in `Strand/Data`.
///
/// Three correctness rules (all re-review findings from the Android twin, #1852 — reproduced verbatim
/// or the Swift backfill will be wrong in the same ways):
///
/// 1. **Attribute sessions by END.** The night window is 54 h wide (30 h before local midnight through
///    the next), so it contains the PREVIOUS night as well. The engine's rule is
///    `matched = allSessions.filter { tsInDay(it.end) }`; handing the funnel the whole window averages
///    two nights into one temperature and stores it as the wrong day's.
///
/// 2. **Page the candidates.** A plain "oldest N" returns the same nights every pass, and the oldest
///    are the ones most likely to have lost their raw samples — the sweep latches on page one and never
///    reaches the newer nights that can fill.
///
/// 3. **The WHOOP 4.0 anchor comes from the CURRENT window.** It is learned window-wide, and the
///    engine's note says that is safe because the offset "cancels in the deviation" — true for a delta,
///    not for an absolute. A re-learned anchor puts backfilled nights on a different offset from the
///    stored ones and the chart plots two scales as one line. **No anchor ⇒ decline, never the global
///    default.**
public enum SkinTempBackfill {

    /// One night the backfill is considering: the day key, the night's read window (from/to in unix
    /// seconds), and the device owner whose raw streams should be read. The walker builds these from
    /// `DailyMetric` rows that have a `skinTempDevC` but no `skinTempC`; the pure plan below decides
    /// which sessions and samples belong to each.
    public struct NightCandidate: Equatable, Sendable {
        public let day: String           // yyyy-MM-dd (local-day key, matching DailyMetric.day)
        public let from: Int             // unix seconds: dayStart - StreamReadCap.lookbackSeconds
        public let to: Int               // unix seconds: dayStart + 24h (or now for today)
        public let owner: String         // the device id whose raw streams wrote this night
        public init(day: String, from: Int, to: Int, owner: String) {
            self.day = day; self.from = from; self.to = to; self.owner = owner
        }
    }

    /// The result of attempting one night's backfill.
    public struct NightResult: Equatable, Sendable {
        public let day: String
        /// The re-derived absolute (°C), or nil when the night declined (no anchor, too few worn
        /// samples, no sessions, etc.). The walker writes `skinTempC` ONLY when this is non-nil.
        public let skinTempC: Double?
        /// Why the night declined, for the diagnostic report. nil when it filled.
        public let declineReason: String?
        public init(day: String, skinTempC: Double?, declineReason: String? = nil) {
            self.day = day; self.skinTempC = skinTempC; self.declineReason = declineReason
        }
    }

    /// Rule 1: attribute sessions by END timestamp. The night window is 54 h wide and contains the
    /// PREVIOUS night as well, so handing the funnel every session in the window averages two nights
    /// into one temperature. The engine's rule is `matched = allSessions.filter { tsInDay(it.end) }`:
    /// a session belongs to `day` iff its END falls in `[dayStart, dayStart + 86400)`.
    ///
    /// `dayStart` is the LOCAL-midnight unix seconds for the day key (the same `dayStart` the engine's
    /// per-day loop computes). `sessions` are the raw `SleepSession`s read from the 54 h window.
    /// Pure + deterministic; the walker tests this directly.
    public static func sessionsForDay(_ sessions: [SleepSession], dayStart: Int) -> [SleepSession] {
        let dayEnd = dayStart + 86_400
        return sessions.filter { $0.end >= dayStart && $0.end < dayEnd }
    }

    /// Rule 3: the WHOOP 4.0 anchor MUST come from the current scoring window. If no per-device anchor
    /// could be learned (too few in-band samples), DECLINE the night — do NOT fall back to the global
    /// 826 anchor. A re-learned anchor puts backfilled nights on a different offset from the stored
    /// ones and the chart plots two scales as one line.
    ///
    /// Returns the anchor to use, or nil to decline. For a 5/MG (`.whoop5`) the anchor is always nil
    /// and the night proceeds (centidegree path, no anchor).
    public static func resolveAnchor(family: DeviceFamily, windowAnchorRaw: Double?) -> Double? {
        switch family {
        case .whoop4:
            // No anchor ⇒ decline. The global 826 is NOT a fallback here (rule 3).
            return windowAnchorRaw
        case .whoop5:
            // Centidegree path: no anchor, no decline on anchor grounds.
            return nil
        }
    }

    /// Compute one night's backfill absolute, applying all three rules. Pure + deterministic; the
    /// walker supplies the raw inputs and writes the result.
    ///
    /// - Parameters:
    ///   - candidate: the night to backfill (day, window, owner).
    ///   - sessions: ALL sleep sessions in the 54 h window (the walker reads them once); rule 1
    ///     filters to this day's by end timestamp.
    ///   - hr: HR samples for the night's window.
    ///   - skinTemp: raw skin-temp samples for the night's window.
    ///   - family: the device family that wrote the owner's skin-temp rows (`.whoop4` vs `.whoop5`).
    ///   - windowAnchorRaw: the per-device WHOOP 4.0 anchor learned from the CURRENT scoring window
    ///     (rule 3). nil for a 5/MG or when the current window couldn't learn one.
    ///   - dayStart: the LOCAL-midnight unix seconds for `candidate.day`.
    ///   - wornToleranceSec: the worn-gate timestamp tolerance (0 for WHOOP, >0 for Oura).
    /// - Returns: the nightly mean (°C) or nil with a decline reason.
    public static func computeNight(
        candidate: NightCandidate,
        sessions: [SleepSession],
        hr: [HRSample],
        skinTemp: [SkinTempSample],
        family: DeviceFamily,
        windowAnchorRaw: Double?,
        dayStart: Int,
        wornToleranceSec: Int = 0
    ) -> NightResult {
        // Rule 1: attribute sessions by END. Don't hand the funnel the whole 54 h window.
        let matched = sessionsForDay(sessions, dayStart: dayStart)
        if matched.isEmpty {
            return NightResult(day: candidate.day, skinTempC: nil,
                               declineReason: "no sleep session ends on this day")
        }
        // Rule 3: the WHOOP 4.0 anchor comes from the current window. No anchor ⇒ decline.
        let anchor = resolveAnchor(family: family, windowAnchorRaw: windowAnchorRaw)
        if family == .whoop4 && anchor == nil {
            return NightResult(day: candidate.day, skinTempC: nil,
                               declineReason: "no per-device 4.0 anchor from the current window (rule 3: decline, not global fallback)")
        }
        // Run the SAME funnel the scoring pass uses — identical inputs, identical result, no second
        // derivation that could disagree.
        let diag = AnalyticsEngine.skinTempFunnel(
            matched, hr: hr, skinTemp: skinTemp, family: family,
            anchorRaw: anchor, wornToleranceSec: wornToleranceSec)
        if let mean = diag.mean {
            return NightResult(day: candidate.day, skinTempC: mean)
        }
        // Decline with the funnel's own explanation so the diagnostic report is self-attesting.
        let reason = diag.kept < diag.minSamples
            ? "only \(diag.kept)/\(diag.minSamples) worn samples"
            : "funnel returned no mean"
        return NightResult(day: candidate.day, skinTempC: nil, declineReason: reason)
    }

    /// Rule 2: page the candidates so the sweep doesn't latch on the oldest N (which are the most
    /// likely to have lost their raw samples). Returns the candidates for one page, oldest-first
    /// within the page. The walker calls this repeatedly with increasing `page` (0-based) until a page
    /// comes back empty.
    ///
    /// `pageSize` caps the per-pass cost (one sleep-window sample read per night). The issue's open
    /// question on cost is answered by keeping this modest (default 50) and letting the caller decide
    /// how many pages to run.
    public static func page(_ candidates: [NightCandidate], page: Int, pageSize: Int = 50) -> [NightCandidate] {
        let start = page * pageSize
        guard start < candidates.count else { return [] }
        let end = min(start + pageSize, candidates.count)
        return Array(candidates[start..<end])
    }
}
