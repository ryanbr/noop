import Foundation

/// Decode a sleep session's `stagesJSON` (either the on-device segment array `[{start,end,stage}]` or
/// the imported minute dict `{light,deep,rem,awake}`) into stage MINUTE totals, and aggregate a night's
/// blocks into the sleep-derived daily fields. Pure + deterministic, so the daily-aggregate recompute
/// that honors a user's wake-time edit can run off the stored (reshaped) stages — no raw streams needed.
public enum SleepStageTotals {

    public struct Minutes: Equatable {
        public var awake: Double, light: Double, deep: Double, rem: Double
        public var asleep: Double { light + deep + rem }
        public var inBed: Double { asleep + awake }
        public init(awake: Double = 0, light: Double = 0, deep: Double = 0, rem: Double = 0) {
            self.awake = awake; self.light = light; self.deep = deep; self.rem = rem
        }
    }

    /// Stage minutes for one session's `stagesJSON`, or nil if it decodes to nothing usable. The on-device
    /// stager calls awake "wake"; the importer "awake" — both map to `awake`.
    public static func minutes(fromStagesJSON json: String?) -> Minutes? {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = obj as? [[String: Any]] {                 // segment array (computed)
            var m = Minutes()
            for seg in arr {
                guard let s = (seg["start"] as? NSNumber)?.intValue,
                      let e = (seg["end"] as? NSNumber)?.intValue, e > s,
                      let name = seg["stage"] as? String else { continue }
                let mins = Double(e - s) / 60.0
                switch name {
                case "wake", "awake": m.awake += mins
                case "light": m.light += mins
                case "deep": m.deep += mins
                case "rem": m.rem += mins
                default: continue
                }
            }
            return m.inBed > 0 ? m : nil
        }
        if let dict = obj as? [String: Any] {                  // minute dict (imported)
            func v(_ k: String) -> Double { (dict[k] as? NSNumber)?.doubleValue ?? 0 }
            let m = Minutes(awake: v("awake"), light: v("light"), deep: v("deep"), rem: v("rem"))
            return m.inBed > 0 ? m : nil
        }
        return nil
    }

    /// #259: return `stagesJSON` with its `[{start,end,stage}]` segments trimmed to begin no earlier than
    /// `onsetSec` — segments fully before the onset are dropped, one straddling it is cut to `[onsetSec, end]`.
    /// Only the computed segment-array shape carries the timestamps a trim needs, so the `{stage:min}` /
    /// dict (imported) shape and any unparseable JSON are returned UNCHANGED. A no-op when every segment
    /// already starts at/after the onset (the common, already-consistent case). The result is re-parsed by
    /// `minutes` / `dailyAggregate` on the SAME platform, so only the decoded minute totals need
    /// cross-platform parity, not the exact string. Mirrors Kotlin `clampStagesToOnset`.
    public static func clampStagesToOnset(_ stagesJSON: String?, onsetSec: Int) -> String? {
        guard let stagesJSON, let data = stagesJSON.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return stagesJSON   // dict/imported shape or unparseable → unchanged
        }
        var out: [[String: Any]] = []
        for seg in arr {
            // Shape check is start+end only (matches Kotlin): a {stage:min} entry has neither → bail
            // unchanged. A malformed segment missing only `stage` defaults to "" (minutes() ignores it),
            // exactly as the Kotlin twin's `optString("stage", "")` does.
            guard let rawS = (seg["start"] as? NSNumber)?.intValue,
                  let e = (seg["end"] as? NSNumber)?.intValue else { return stagesJSON }
            let name = seg["stage"] as? String ?? ""
            let s = max(rawS, onsetSec)
            guard e > s else { continue }                                        // fully before the onset → drop
            out.append(["start": s, "end": e, "stage": name])
        }
        guard let outData = try? JSONSerialization.data(withJSONObject: out),
              let str = String(data: outData, encoding: .utf8) else { return stagesJSON }
        return str
    }

    /// The sleep-derived daily fields for a night made of these blocks' `stagesJSON`, or nil if none
    /// decode. `efficiency` is asleep / in-bed (TST / Σ stage minutes) in [0,1]. For the segment stages
    /// noop stores (which TILE the window, last segment clamped to the wake), Σ stage minutes equals the
    /// clock span, so this coincides with `AnalyticsEngine.analyzeDay`'s TST/(end−start); it is not the
    /// literal same expression, and would diverge only for malformed non-tiling stages.
    public struct DailySleep: Equatable {
        public let totalSleepMin: Double, efficiency: Double
        public let deepMin: Double, remMin: Double, lightMin: Double
    }

    public static func dailyAggregate(_ stagesJSONs: [String?]) -> DailySleep? {
        dailyAggregate(stagesJSONs, interFragmentAwakeSeconds: 0)
    }

    /// As `dailyAggregate(_:)`, but folds the OUT-OF-BED time between bridged main-night fragments into the
    /// night's AWAKE total (and therefore its in-bed denominator). #777/#705 regression fix: when a main
    /// sleep is bridged from two fragments split by a 20-min wake gap, that gap is real time the user was
    /// awake/out of bed - it must show as ~20 min awake, not vanish. The fragments' own stages tile only
    /// their individual `[start,end)` spans, so the inter-fragment gap is in NO fragment; the caller computes
    /// it once (sum of gaps between consecutive fragments' effective ends and onsets) and passes it here so
    /// both the analytics rollup and the edit/recompute seam apply ONE consistent definition: gap → awake →
    /// in-bed. `interFragmentAwakeSeconds` ≤ 0 reproduces the legacy sum-of-stages behaviour. (#777/#705)
    public static func dailyAggregate(_ stagesJSONs: [String?],
                                      interFragmentAwakeSeconds: Double) -> DailySleep? {
        var total = Minutes()
        var any = false
        for j in stagesJSONs {
            if let m = minutes(fromStagesJSON: j) {
                total.awake += m.awake; total.light += m.light
                total.deep += m.deep; total.rem += m.rem
                any = true
            }
        }
        if interFragmentAwakeSeconds > 0 { total.awake += interFragmentAwakeSeconds / 60.0 }
        guard any, total.inBed > 0 else { return nil }
        return DailySleep(totalSleepMin: total.asleep, efficiency: total.asleep / total.inBed,
                          deepMin: total.deep, remMin: total.rem, lightMin: total.light)
    }

    /// The OUT-OF-BED time (seconds) BETWEEN consecutive bridged sleep fragments - the inter-fragment wake
    /// gaps the #561 gap-bridge spans but no fragment's own `[start,end)` covers. Each fragment is one
    /// `(start,end)` span; sorted by start, the gap after fragment i is `max(0, start[i+1] - end[i])`. Sums
    /// only positive gaps (overlapping/abutting fragments contribute 0). This is the single shared definition
    /// of "awake between fragments" both `analyzeDay` and the edit/recompute seam fold into AWAKE, so the two
    /// paths agree (no seam double-count). Pure + deterministic; cross-platform identical. (#777/#705)
    public static func interFragmentAwakeSeconds(_ spans: [(start: Int, end: Int)]) -> Double {
        guard spans.count > 1 else { return 0 }
        let sorted = spans.sorted { $0.start < $1.start }
        var gap = 0
        for i in 1..<sorted.count {
            let g = sorted[i].start - sorted[i - 1].end
            if g > 0 { gap += g }
        }
        return Double(gap)
    }

    // MARK: - Canonical main-night selection (#525 / #547 — learned-timing scored pick)

    /// Broad overnight band for the cold-start timing bonus and physiological-day eligibility.
    /// The 19:00 edge admits early bedtimes (#2626); the 11:00 closing edge retains late-morning onsets.
    /// The raw detector has its own onset band, which is unchanged by this selection policy.
    public static let overnightStartHour = 19
    /// Local hour (exclusive) that closes the cold-start overnight band at 11, matching the
    /// detector's late-morning edge. A block onset in [`overnightEndHour`, `overnightStartHour`)
    /// is daytime; everything else is overnight.
    public static let overnightEndHour = 11

    /// Seconds in a day, for circular time-of-day math.
    public static let secondsPerDay = 86_400

    /// The fixed alignment credit (in MINUTES) added to a block's asleep minutes when its midpoint sits
    /// right on the user's habitual midsleep (or, cold-start, the overnight band center). This is a BONUS,
    /// not an infinite gate: a long enough off-timing block can still out-score a short well-timed one, so
    /// a genuine 7h daytime sleep beats a 1.5h overnight fragment, while a normal 4h night beats a longer
    /// daytime nap. ~90 min is one sleep-cycle's worth of credit. (#547)
    public static let alignmentBonusMin: Double = 90.0

    /// Full alignment bonus is paid when the block midpoint is within this many seconds (circular) of the
    /// habitual midsleep; the bonus then decays LINEARLY to 0 at `alignmentZeroSec`. ±2h full, →0 by ±5h.
    public static let alignmentFullWindowSec = 2 * 3_600
    /// Circular distance (seconds) at/after which the alignment bonus is 0.
    public static let alignmentZeroSec = 5 * 3_600

    /// Adjacent sleep runs separated by a wake gap shorter than this are bridged into one block for
    /// selection, so a biphasic / briefly-interrupted main sleep is scored as a single night rather than
    /// two fragments. Matches the sleep-staging research's <60 min "same sleep period" threshold. The
    /// detector already bridges sparse-gravity gaps up to 90 min (`SleepStager.sparseBridgeGapMin`); this
    /// is the selector-side backstop for blocks that reach the selector still split. (#547)
    public static let gapBridgeMaxMin = 60

    /// Wider wake-gap bridge (minutes) applied ONLY to an overnight night-tail fragment, so a single
    /// overnight sleep broken by a real but longer mid-night wake (at/over `gapBridgeMaxMin`, under this) is
    /// not over-fragmented into a NAP + a main sleep, the #861 report ("night sleeps are split into naps and
    /// sleep"). This mirrors the detector's own `SleepStager.nightContinuationGapMin` (90 min), the same
    /// "this is the night's tail, not an isolated nap" threshold the detection spine already trusts. It is
    /// applied (in `mainNightGroupIndices`) ONLY when the later fragment's onset is still in the overnight
    /// band (`isOvernightOnset`), so a genuine daytime nap (which is hours away AND begins in daytime)
    /// can never be folded into the night. Below `gapBridgeMaxMin` the unconditional bridge is unchanged
    /// (so `bridgeAdjacent` and its golden tests stay byte-identical). (#861)
    public static let nightTailBridgeMaxMin = 90

    /// One candidate block for main-night selection. The `start` is the EFFECTIVE onset (a user wake/
    /// bed edit moves `end`, never the detected onset key), and `tzOffsetSeconds` turns it local so the
    /// timing test reads the user's clock, not UTC.
    public struct NightBlock {
        public let start: Int, end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
        public var durationS: Int { end - start }
        public var midpointSec: Int { start + (end - start) / 2 }
    }

    // MARK: - Selection reason (explainability — WHY this block is the main night) (spec 2026-06-20)

    /// Why the selector chose the block it did, derived from the EXACT signals the score used, so the UI
    /// can explain the pick in plain English without re-deriving anything. Identical cases + identical
    /// ordering as the Kotlin `MainNightReason` (cross-platform parity is mandatory). (spec 2026-06-20)
    public enum MainNightReason: String, Equatable {
        /// The day has a single sleep block, so there is nothing to choose between.
        case onlyBlock
        /// The chosen block is the longest by asleep duration and there is no meaningful timing credit
        /// behind the pick (cold-start with no learned habitual, or the longest block is outside the
        /// alignment-bonus window). Duration alone decided it.
        case longest
        /// The chosen block is the longest by asleep duration AND it earned a meaningful alignment bonus
        /// (a learned habitual midsleep exists and the block's midpoint sits inside the bonus window).
        /// Duration would have picked it anyway, and the timing agrees.
        case longestNearUsual
        /// The chosen block is NOT the longest by asleep duration; the alignment bonus (not raw duration)
        /// is what flipped the pick away from the longest block toward this one.
        case alignedToUsual
    }

    /// A block is treated as having a MEANINGFUL alignment bonus when it earns ANY positive credit, i.e.
    /// its midpoint sits inside the bonus window (circular distance < `alignmentZeroSec`). Outside the
    /// window the bonus is exactly 0 and contributes nothing to the pick. Tiny epsilon so floating-point
    /// noise at the window edge can't be mistaken for credit. Identical cross-platform. (spec 2026-06-20)
    static let meaningfulBonusEpsilon: Double = 1e-9

    /// The result of main-night selection enriched with the explainability fields the UI renders: the
    /// chosen block's index, the reason it won, and the chosen block's ASLEEP duration so the copy can
    /// fill {DUR} (Xh Ym) without re-decoding. `asleepSeconds`/`asleepMinutes` are the SAME duration the
    /// score used for that block (clock span for the `NightBlock` overload; decoded asleep minutes for the
    /// stages overload). Mirrors the Kotlin `MainNightSelection`. (spec 2026-06-20)
    public struct MainNightSelection: Equatable {
        public let index: Int
        public let reason: MainNightReason
        /// The chosen block's asleep duration in SECONDS (the figure the score ranked on).
        public let asleepSeconds: Int
        public init(index: Int, reason: MainNightReason, asleepSeconds: Int) {
            self.index = index; self.reason = reason; self.asleepSeconds = asleepSeconds
        }
        /// The chosen block's asleep duration in MINUTES, for copy that fills {DUR} as Xh Ym.
        public var asleepMinutes: Double { Double(asleepSeconds) / 60.0 }
    }

    /// True when a block's onset falls in the cold-start overnight band (≥ `overnightStartHour` or
    /// < `overnightEndHour`, local). Retained for callers/tests that still ask the binary question, but
    /// the scored selector no longer GATES on it. Physiological-day classification still uses this band
    /// to exclude unclassified daytime naps; the early edge admits 19:00 bedtimes (#2626).
    /// `offsetSec` is seconds EAST of UTC.
    public static func isOvernightOnset(_ ts: Int, offsetSec: Int) -> Bool {
        let local = ts + offsetSec
        let secOfDay = ((local % secondsPerDay) + secondsPerDay) % secondsPerDay
        let hour = secOfDay / 3_600
        return hour >= overnightStartHour || hour < overnightEndHour
    }

    /// Local time-of-day, in seconds [0, 86400), of a unix timestamp shifted east by `offsetSec`.
    static func localSecOfDay(_ ts: Int, offsetSec: Int) -> Int {
        let local = ts + offsetSec
        return ((local % secondsPerDay) + secondsPerDay) % secondsPerDay
    }

    /// Smallest circular distance (seconds, 0...43200) between two times-of-day, so 23:30 and 00:30 are
    /// 3600s apart, not 82800. Both inputs are seconds-of-day in [0, 86400).
    static func circularDistanceSec(_ a: Int, _ b: Int) -> Int {
        let raw = abs(a - b) % secondsPerDay
        return min(raw, secondsPerDay - raw)
    }

    /// The cold-start anchor: the CENTER of the overnight band [overnightStartHour, overnightEndHour),
    /// as a time-of-day in seconds. With the band wrapping midnight (20:00 → 11:00 = 15h wide) the center
    /// is 03:30 local. Used as the habitual-midsleep stand-in before enough history exists. (#547)
    static var coldStartAnchorSec: Int {
        let startSec = overnightStartHour * 3_600
        let span = ((overnightEndHour - overnightStartHour) * 3_600 + secondsPerDay) % secondsPerDay // wrap
        return (startSec + span / 2) % secondsPerDay
    }

    /// The alignment bonus (MINUTES) a block earns for sitting near the target midsleep. Full
    /// `alignmentBonusMin` within `alignmentFullWindowSec`, decaying linearly to 0 by `alignmentZeroSec`.
    /// `blockMidSec` and `targetMidSec` are local times-of-day in seconds. (#547)
    static func alignmentBonusMinutes(blockMidSec: Int, targetMidSec: Int) -> Double {
        let d = circularDistanceSec(blockMidSec, targetMidSec)
        if d <= alignmentFullWindowSec { return alignmentBonusMin }
        if d >= alignmentZeroSec { return 0 }
        let frac = Double(alignmentZeroSec - d) / Double(alignmentZeroSec - alignmentFullWindowSec)
        return alignmentBonusMin * frac
    }

    /// The target midsleep time-of-day (seconds) the scorer aligns to: the learned `habitualMidsleepSec`
    /// when supplied (a late/shift sleeper's real bedtime), else the cold-start overnight-band center.
    static func targetMidsleepSec(_ habitualMidsleepSec: Int?) -> Int {
        habitualMidsleepSec ?? coldStartAnchorSec
    }

    // MARK: - Gap-bridging (biphasic / briefly-interrupted nights → one block)

    /// Merge adjacent `NightBlock`s separated by a wake gap shorter than `gapBridgeMaxMin` into single
    /// blocks for selection, so a fragmented main sleep is scored as one night. Input order is preserved
    /// by sorting on `start` first (the selector is order-independent, but bridging must see neighbours).
    /// Pure + deterministic. (#547)
    public static func bridgeAdjacent(_ blocks: [NightBlock]) -> [NightBlock] {
        guard blocks.count > 1 else { return blocks }
        let sorted = blocks.sorted { $0.start < $1.start }
        let bridgeS = gapBridgeMaxMin * 60
        var out: [NightBlock] = [sorted[0]]
        for b in sorted.dropFirst() {
            let last = out[out.count - 1]
            let gap = b.start - last.end
            if gap >= 0 && gap < bridgeS {
                out[out.count - 1] = NightBlock(start: last.start, end: max(last.end, b.end))
            } else {
                out.append(b)
            }
        }
        return out
    }

    /// One bridged night group over the whole input: the fragments (as ORIGINAL indices, ascending)
    /// plus the group's inter-fragment wake seams. Produced by `bridgedNightGroups` for the consumers
    /// that must present a briefly-interrupted night as ONE night — the Health write-back and the
    /// sleep screens — so they group exactly as the day totals do and can fold each seam in as an
    /// explicit `wake` segment. (#364)
    public struct BridgedNightGroup: Equatable {
        public let indices: [Int]
        public let gaps: [GapSpan]
        /// One inter-fragment seam: (previous bridged end, next fragment start), end > start always.
        public struct GapSpan: Equatable {
            public let start: Int, end: Int
            public init(start: Int, end: Int) { self.start = start; self.end = end }
        }
        public init(indices: [Int], gaps: [GapSpan]) { self.indices = indices; self.gaps = gaps }
    }

    /// EVERY bridged group over `blocks` — the same two-tier bridge `mainNightGroupIndices` applies
    /// (#561 short-wake, plus the #861 overnight night-tail widening), WITHOUT the winner pick. A
    /// negative gap (a block starting inside the previous span) does not bridge — pinned legacy
    /// semantics, `gap >= 0` — and never fabricates a seam. Groups ordered by start; pure and
    /// deterministic; Kotlin twin `bridgedNightGroups`. (#364)
    public static func bridgedNightGroups(_ blocks: [NightBlock], offsetSec: Int) -> [BridgedNightGroup] {
        guard !blocks.isEmpty else { return [] }
        // Sort indices by onset so bridging sees neighbours, exactly as `bridgeAdjacent` sorts the blocks.
        let order = blocks.indices.sorted { blocks[$0].start < blocks[$1].start }
        let bridgeS = gapBridgeMaxMin * 60
        let nightTailBridgeS = nightTailBridgeMaxMin * 60
        // Build the bridged spans AND the original indices that compose each one, in one pass over `order`.
        var bridged: [NightBlock] = []
        var groups: [[Int]] = []
        var gaps: [[BridgedNightGroup.GapSpan]] = []
        for idx in order {
            let b = blocks[idx]
            if let last = bridged.last {
                let gap = b.start - last.end
                // Unconditional short-wake bridge (< gapBridgeMaxMin), byte-identical to `bridgeAdjacent`.
                // Then a WIDER bridge for a true overnight night-tail (#861): a gap in
                // [gapBridgeMaxMin, nightTailBridgeMaxMin) folds the fragment in ONLY when its onset is
                // still in the overnight band: a real mid-night wake, not an isolated daytime nap. This
                // stops one overnight sleep being split into a nap + a main sleep, while a daytime nap
                // (daytime onset, or a gap at/over nightTailBridgeMaxMin) still stands as its own block.
                let bridges = gap >= 0
                    && (gap < bridgeS
                        || (gap < nightTailBridgeS && isOvernightOnset(b.start, offsetSec: offsetSec)))
                if bridges {
                    if gap > 0 {
                        gaps[gaps.count - 1].append(.init(start: last.end, end: b.start))
                    }
                    bridged[bridged.count - 1] = NightBlock(start: last.start, end: max(last.end, b.end))
                    groups[groups.count - 1].append(idx)
                    continue
                }
            }
            bridged.append(b)
            groups.append([idx])
            gaps.append([])
        }
        return zip(groups, gaps).map { BridgedNightGroup(indices: $0.sorted(), gaps: $1) }
    }

    /// The indices (into the ORIGINAL `blocks`) of the MAIN-NIGHT GROUP: the main night plus any adjacent
    /// fragments bridged into it. A biphasic / briefly-interrupted main sleep that reaches the selector still
    /// split into two blocks (a wake gap shorter than `gapBridgeMaxMin` between them) is scored as ONE night
    /// rather than two competing fragments, then the winning bridged group's fragments are ALL returned so the
    /// caller can SUM their stages for the day's headline figure. (#561)
    ///
    /// Pipeline:
    ///   1. `bridgedNightGroups` merges blocks whose gap is in `[0, gapBridgeMaxMin*60)` (or the #861
    ///      night-tail window) into bridged groups, in `start` order.
    ///   2. `mainNightIndex` scores the BRIDGED spans (so a two-fragment night's combined span out-scores a
    ///      lone nap) and picks the winning bridged group.
    ///   3. The original indices of that winning group are returned, ascending.
    ///
    /// Returns nil only for an empty list. A day with no bridgeable gap collapses to the single-block group the
    /// bare `mainNightIndex` would pick — byte-identical to the old behaviour for the common case. Pure +
    /// deterministic; shares the `bridgedNightGroups` pass + `mainNightIndex` so the bridged pick stays
    /// cross-platform stable. (#561)
    public static func mainNightGroupIndices(_ blocks: [NightBlock], offsetSec: Int,
                                             habitualMidsleepSec: Int? = nil) -> [Int]? {
        guard !blocks.isEmpty else { return nil }
        let all = bridgedNightGroups(blocks, offsetSec: offsetSec)
        // Rebuild each group's bridged span for scoring: sorted-ascending fragments make the span
        // (first start, running-max end) — identical to the span the one-pass loop accumulated.
        let bridgedSpans = all.map { g -> NightBlock in
            NightBlock(start: g.indices.map { blocks[$0].start }.min() ?? 0,
                       end: g.indices.map { blocks[$0].end }.max() ?? 0)
        }
        guard let winner = mainNightIndex(bridgedSpans, offsetSec: offsetSec,
                                          habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        return all[winner].indices
    }

    /// Index of the day's MAIN night among `blocks`, by the LEARNED-TIMING SCORE (replaces the old hard
    /// overnight gate). score(block) = asleepMinutes + alignmentBonus, where the bonus credits a block
    /// whose midpoint sits near the user's habitual midsleep (`habitualMidsleepSec`), or — cold-start —
    /// near the broad overnight-band center. There is NO hard duration floor and NO overnight gate: a
    /// short main sleep or a nap-only day still resolves to a main block, and a genuine long daytime sleep
    /// can win on score. The highest score wins; exact ties break toward the EARLIER onset (stable across
    /// platforms). Returns nil only for an empty list. This `NightBlock` overload has no decoded stages,
    /// so "asleep minutes" is the block's clock span — preserving the prior duration semantics for callers
    /// that rank by span (`analyzeDay`). Pass `habitualMidsleepSec` from `habitualMidsleepSec(...)` once
    /// enough history exists; leave nil for the cold-start band. (#525 / #547)
    public static func mainNightIndex(_ blocks: [NightBlock], offsetSec: Int,
                                      habitualMidsleepSec: Int? = nil) -> Int? {
        guard !blocks.isEmpty else { return nil }
        let target = targetMidsleepSec(habitualMidsleepSec)
        func score(_ b: NightBlock) -> Double {
            let asleepMin = Double(b.durationS) / 60.0
            let midSec = localSecOfDay(b.midpointSec, offsetSec: offsetSec)
            return asleepMin + alignmentBonusMinutes(blockMidSec: midSec, targetMidSec: target)
        }
        var bestIdx = 0
        for i in 1..<blocks.count {
            let cand = blocks[i], best = blocks[bestIdx]
            let cs = score(cand), bs = score(best)
            let candWins: Bool
            if cs != bs {
                candWins = cs > bs                       // higher score wins
            } else {
                candWins = cand.start < best.start       // exact tie → earlier onset (stable)
            }
            if candWins { bestIdx = i }
        }
        return bestIdx
    }

    /// Main-night selection ENRICHED with the explainability reason + the chosen block's asleep duration,
    /// for the "why this is your main sleep" UI. The `index` is byte-identical to `mainNightIndex(...)`
    /// (same score, same earlier-onset tie-break) — this is the same pick, just annotated, so callers on
    /// the bare `mainNightIndex` are unaffected. The reason is decided from the SAME signals the score
    /// used (no re-derivation):
    ///   - `onlyBlock` — a single block.
    ///   - `alignedToUsual` — the chosen block is NOT the longest by asleep duration; the alignment bonus
    ///     flipped the pick away from the duration-only winner toward this one.
    ///   - `longestNearUsual` — the chosen block IS the longest by asleep duration AND a learned habitual
    ///     midsleep exists AND the chosen block's midpoint earns a meaningful (positive) alignment bonus.
    ///   - `longest` — otherwise (incl. cold-start with no learned habitual, or the longest block outside
    ///     the bonus window).
    /// The "longest" comparison ranks by the SAME duration the score adds (clock span for this overload),
    /// tie-broken by earlier onset exactly like the score, so the duration-only winner is well-defined and
    /// platform-stable. `asleepSeconds` is the chosen block's clock span. (spec 2026-06-20)
    public static func mainNightSelection(_ blocks: [NightBlock], offsetSec: Int,
                                          habitualMidsleepSec: Int? = nil) -> MainNightSelection? {
        guard let idx = mainNightIndex(blocks, offsetSec: offsetSec,
                                       habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        let chosen = blocks[idx]
        let reason = mainNightReason(
            chosenAsleepSec: chosen.durationS, chosenOnset: chosen.start,
            chosenMidLocalSec: localSecOfDay(chosen.midpointSec, offsetSec: offsetSec),
            blockCount: blocks.count,
            // duration-only winner over the SAME asleep figure (clock span) + same earlier-onset tie-break.
            longestAsleepSec: blocks.map(\.durationS).max() ?? chosen.durationS,
            longestOnset: durationOnlyWinnerOnset(asleepSecs: blocks.map(\.durationS),
                                                  onsets: blocks.map(\.start)),
            chosenIsDurationWinnerOnset: chosen.start,
            habitualMidsleepSec: habitualMidsleepSec)
        return MainNightSelection(index: idx, reason: reason, asleepSeconds: chosen.durationS)
    }

    /// The onset of the DURATION-ONLY winner among parallel `asleepSecs`/`onsets` arrays: the block with
    /// the greatest asleep figure, ties broken toward the EARLIER onset — the same tie-break the score
    /// uses, so "would duration alone have picked this same block?" is decided identically on both
    /// platforms. Returns the first onset when empty (callers never pass empty). (spec 2026-06-20)
    static func durationOnlyWinnerOnset(asleepSecs: [Int], onsets: [Int]) -> Int {
        guard !asleepSecs.isEmpty else { return 0 }
        var bestIdx = 0
        for i in 1..<asleepSecs.count {
            let candDur = asleepSecs[i], bestDur = asleepSecs[bestIdx]
            let candWins: Bool
            if candDur != bestDur {
                candWins = candDur > bestDur
            } else {
                candWins = onsets[i] < onsets[bestIdx]
            }
            if candWins { bestIdx = i }
        }
        return onsets[bestIdx]
    }

    /// Decide the `MainNightReason` from the chosen block + the duration-only winner, using ONLY signals
    /// the score already computed. Pure so it is unit-tested directly and shared byte-for-byte with Kotlin.
    /// `chosenIsDurationWinnerOnset` is the chosen block's onset; the chosen block IS the duration-only
    /// winner iff (its asleep == the longest asleep) AND (its onset == the duration-only winner's onset) —
    /// matching the longest figure and the earlier-onset tie-break the duration-only ranking uses.
    /// (spec 2026-06-20)
    static func mainNightReason(chosenAsleepSec: Int, chosenOnset: Int, chosenMidLocalSec: Int,
                                blockCount: Int, longestAsleepSec: Int, longestOnset: Int,
                                chosenIsDurationWinnerOnset: Int, habitualMidsleepSec: Int?) -> MainNightReason {
        if blockCount <= 1 { return .onlyBlock }
        let chosenIsLongest = (chosenAsleepSec == longestAsleepSec)
            && (chosenIsDurationWinnerOnset == longestOnset)
        if !chosenIsLongest {
            // Duration alone would NOT have picked this block; the alignment bonus flipped the pick.
            return .alignedToUsual
        }
        // The chosen block is the longest. It is "near usual" only when a learned habitual exists AND the
        // block earns a meaningful (positive) alignment bonus — cold-start (nil habitual) is plain longest.
        if let habitual = habitualMidsleepSec {
            let bonus = alignmentBonusMinutes(blockMidSec: chosenMidLocalSec, targetMidSec: habitual)
            if bonus > meaningfulBonusEpsilon { return .longestNearUsual }
        }
        return .longest
    }

    /// The night's daily sleep aggregate, substituting any USER-EDITED block for its detected twin
    /// before summing, then UNIONING in any user-added block that has no detected twin. `detected` is
    /// the auto-detected blocks (their stable startTs + stages); `edited` maps a block's startTs → its
    /// hand-corrected (reshaped) stages — a wake-time edit never moves startTs, so the edited block
    /// lands exactly on its detected twin. `manual` is user-added blocks (e.g. a hand-logged nap) that
    /// the detector never found; each is keyed by its own stable startTs and FOLDED IN so its minutes
    /// count toward the day's totals (a detector-found nap already folds via `detected`). De-duped by
    /// startTs so a block already represented in `detected` (or substituted via `edited`) is never
    /// double-counted. Returns the aggregate plus whether an edit OR a manual block actually contributed
    /// (so the caller only overrides the day when it did), or nil when nothing decodes. This is the
    /// integration seam between the edit and the daily recompute — kept pure so it's unit-tested with
    /// synthetic data, no store or stager needed. (#518 / #508)
    public static func dailyAggregateHonoringEdits(
        detected: [(startTs: Int, stagesJSON: String?)],
        edited: [Int: String?],
        manual: [(startTs: Int, stagesJSON: String?)] = [],
        // The block's effective onset (a wake/bed edit moves end, not the detected start key) plus the
        // device's UTC offset, so the MAIN-NIGHT pick reads the user's local clock. When a caller can't
        // supply onsets, leave nil and the legacy SUM-of-all-blocks behaviour is preserved (no regression
        // for older callers); the day rollup passes them so the daily total matches the Sleep tab. (#525)
        onsetByStart: [Int: Int]? = nil,
        offsetSec: Int = 0,
        // The learned habitual midsleep (local time-of-day seconds) so the scored pick aligns to the
        // user's real bedtime, not a fixed clock band. nil = cold-start (fall back to the overnight-band
        // bonus). Existing callers compile unchanged. (#547)
        habitualMidsleepSec: Int? = nil
    ) -> (sleep: DailySleep, editApplied: Bool)? {
        // Substitute an edited block's stages ONLY when the edit has usable (non-nil) stages — an edit
        // that reshaped to nil must fall back to the detected stages, never drop the block (which would
        // collapse the night's sleep total). `editApplied` likewise reflects a real substitution. We keep
        // each block's identity (its startTs + effective stages) so the main-night pick can run after.
        var applied = false
        // (startTs, effective stages) for every block on the day — detected (edit-substituted) then any
        // twinless manual block UNIONED in. Identity is preserved for the main-night selection.
        var blocks: [(startTs: Int, stagesJSON: String?)] = detected.map { d in
            if let stages = edited[d.startTs] ?? nil {   // flatten String?? → String?, then require non-nil
                applied = true
                return (startTs: d.startTs, stagesJSON: stages)
            }
            return (startTs: d.startTs, stagesJSON: d.stagesJSON)
        }
        // Union: a user-added block the detector never found (no detected twin) must still be on the day
        // so the main-night pick (or the legacy sum) sees it — otherwise a manually-logged nap is dropped.
        // Match on the stable startTs and add ONLY rows absent from `detected`, with usable stages.
        let detectedStarts = Set(detected.map(\.startTs))
        for m in manual where !detectedStarts.contains(m.startTs) {
            if let stages = m.stagesJSON {
                blocks.append((startTs: m.startTs, stagesJSON: stages))
                applied = true
            }
        }
        // Canonical per-day total (#525): when the caller supplies block onsets, the daily figure is the
        // MAIN NIGHT only (the longest, overnight-preferring block — the SAME block the Sleep tab shows),
        // so Intelligence / Sleep Need / the debt ledger / the card all read the same number as the Sleep
        // tab. Nap blocks stay their own session rows elsewhere; they are NOT summed into this figure.
        // No onsets supplied → the legacy sum-of-all-blocks total (older callers unchanged).
        if let onsetByStart {
            // Pick by the same LEARNED-TIMING score the Sleep tab uses (asleep minutes + alignment bonus,
            // measured by each block's decoded in-bed span). BIPHASIC GAP-BRIDGE (#561): bridge adjacent
            // blocks split by a short wake gap into the main-night GROUP and SUM that group's stages, so the
            // edit/recompute seam reports the SAME night `analyzeDay` does (a briefly-interrupted main sleep
            // is one night, not the longer fragment only). Naps outside the group remain their own rows.
            let group = mainNightGroupIndicesByStages(blocks, onsetByStart: onsetByStart, offsetSec: offsetSec,
                                                      habitualMidsleepSec: habitualMidsleepSec)
            // OUT-OF-BED time between the bridged fragments counts as AWAKE (#777/#705), using the SAME
            // single definition `analyzeDay` applies so the seam can't double-count it. Each fragment's
            // effective span is `[onset, onset + decoded in-bed]`; the gap between consecutive fragments is
            // awake the fragments' own stages don't cover.
            if let group {
                // #259: trim each SELECTED block's stages to its EFFECTIVE onset before summing. A hand-edited
                // or onset-trimmed bedtime that the raw was too sparse to re-stage (WHOOP 4.0) leaves pre-onset
                // segments in the stored stagesJSON; summing them in full pushes asleep past time-in-bed (the
                // impossible "6h41m asleep / 4h33m in bed" card). Selection above ran on the ORIGINAL blocks,
                // so no #525/#547 pick regression — only the SUMMED main-night total is clamped. A block
                // already staged from its onset (the common case) is unchanged. Mirrors Kotlin.
                let clampedStages: [String?] = group.map { i in
                    if let onset = onsetByStart[blocks[i].startTs] {
                        return clampStagesToOnset(blocks[i].stagesJSON, onsetSec: onset)
                    }
                    return blocks[i].stagesJSON
                }
                let spans: [(start: Int, end: Int)] = group.enumerated().map { (gi, i) in
                    let onset = onsetByStart[blocks[i].startTs] ?? blocks[i].startTs
                    let inBedSec = Int((minutes(fromStagesJSON: clampedStages[gi])?.inBed ?? 0) * 60.0)
                    return (start: onset, end: onset + inBedSec)
                }
                let gapAwakeS = interFragmentAwakeSeconds(spans)
                if let agg = dailyAggregate(clampedStages, interFragmentAwakeSeconds: gapAwakeS) {
                    return (agg, applied)
                }
            }
            return nil
        }
        guard let agg = dailyAggregate(blocks.map(\.stagesJSON)) else { return nil }
        return (agg, applied)
    }

    /// The original-index group (ascending) of the day's MAIN night on the STAGES path: the main night plus
    /// any adjacent fragments bridged into it (a wake gap shorter than `gapBridgeMaxMin`), so the edit/
    /// recompute seam SUMS the same fragments `analyzeDay` does for a biphasic night. Each block's effective
    /// span is `[onset, onset + decoded in-bed]`; bridging tests the gap between one block's effective end and
    /// the next block's onset. The bridged spans are then scored by `mainNightIndexByStages` (decoded asleep
    /// minutes + alignment), and the winning group's original indices are returned. nil only for an empty list.
    /// A day with no bridgeable gap returns the single block `mainNightIndexByStages` would pick — no #525
    /// regression. (#561)
    static func mainNightGroupIndicesByStages(_ blocks: [(startTs: Int, stagesJSON: String?)],
                                              onsetByStart: [Int: Int], offsetSec: Int,
                                              habitualMidsleepSec: Int? = nil) -> [Int]? {
        guard !blocks.isEmpty else { return nil }
        func onset(_ b: (startTs: Int, stagesJSON: String?)) -> Int { onsetByStart[b.startTs] ?? b.startTs }
        func effEnd(_ b: (startTs: Int, stagesJSON: String?)) -> Int {
            onset(b) + Int((minutes(fromStagesJSON: b.stagesJSON)?.inBed ?? 0) * 60.0)
        }
        // Order by effective onset so bridging sees neighbours.
        let order = blocks.indices.sorted { onset(blocks[$0]) < onset(blocks[$1]) }
        let bridgeS = gapBridgeMaxMin * 60
        let nightTailBridgeS = nightTailBridgeMaxMin * 60
        // Bridged groups of ORIGINAL indices, plus the representative (startTs, stages) the score reads.
        var groups: [[Int]] = []
        var groupEnd: [Int] = []     // running effective end of each bridged group
        for idx in order {
            let b = blocks[idx]
            if let last = groupEnd.last {
                let gap = onset(b) - last
                // Same two-tier bridge as `mainNightGroupIndices` so the summed daily total folds in EXACTLY
                // the fragments the Sleep tab folds into the main night (no nap/total divergence): the
                // unconditional short-wake bridge (< gapBridgeMaxMin), then the wider overnight night-tail
                // bridge ([gapBridgeMaxMin, nightTailBridgeMaxMin) only when the fragment's onset is still in
                // the overnight band) that stops one night being split into a nap + a main sleep. (#861)
                let bridges = gap >= 0
                    && (gap < bridgeS
                        || (gap < nightTailBridgeS && isOvernightOnset(onset(b), offsetSec: offsetSec)))
                if bridges {
                    groups[groups.count - 1].append(idx)
                    groupEnd[groupEnd.count - 1] = max(last, effEnd(b))
                    continue
                }
            }
            groups.append([idx])
            groupEnd.append(effEnd(b))
        }
        // Score each bridged group by its FIRST fragment's onset + the group's SUMMED decoded minutes, via
        // the same per-stages scorer (asleep minutes + alignment), so the pick matches the bare path on a
        // single-block day and prefers the well-timed, longest combined night otherwise.
        let groupBlocks: [(startTs: Int, stagesJSON: String?)] = groups.map { g in
            // Representative block: its startTs is the group's EARLIEST-onset fragment (so the score's
            // midpoint anchors on the group's onset + its SUMMED in-bed span), and its stages are the group's
            // SUMMED stages so the scorer ranks the combined night, not a single fragment.
            let summed = SleepStageTotals.summedStagesJSON(g.map { blocks[$0].stagesJSON })
            let anchor = g.min(by: { onset(blocks[$0]) < onset(blocks[$1]) }) ?? g[0]
            return (startTs: blocks[anchor].startTs, stagesJSON: summed)
        }
        // The group's anchor onsets feed `onsetByStart` so the score reads each group's earliest onset.
        var groupOnsets: [Int: Int] = [:]
        for (gi, g) in groups.enumerated() {
            let anchor = g.min(by: { onset(blocks[$0]) < onset(blocks[$1]) }) ?? g[0]
            groupOnsets[groupBlocks[gi].startTs] = onset(blocks[anchor])
        }
        guard let winner = mainNightIndexByStages(groupBlocks, onsetByStart: groupOnsets, offsetSec: offsetSec,
                                                  habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        return groups[winner].sorted()
    }

    /// A synthetic minute-dict `stagesJSON` whose per-stage minutes are the SUM of the inputs' decoded
    /// minutes — used only to SCORE a bridged group as one block (decoded asleep minutes + in-bed span). Pure;
    /// returns nil when nothing decodes (the group then scores 0, like an undecodable block). (#561)
    static func summedStagesJSON(_ stagesJSONs: [String?]) -> String? {
        var total = Minutes()
        var any = false
        for j in stagesJSONs {
            if let m = minutes(fromStagesJSON: j) {
                total.awake += m.awake; total.light += m.light
                total.deep += m.deep; total.rem += m.rem
                any = true
            }
        }
        guard any else { return nil }
        let dict: [String: Double] = ["awake": total.awake, "light": total.light,
                                      "deep": total.deep, "rem": total.rem]
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Index into `blocks` of the day's MAIN night, by the LEARNED-TIMING SCORE: score(block) =
    /// asleepMinutes + alignmentBonus, where "asleepMinutes" is the block's decoded ASLEEP minutes (the
    /// real restorative sleep, not in-bed) and the bonus credits a midpoint near `habitualMidsleepSec`
    /// (or, cold-start, the overnight band). `onsetByStart` gives each block's effective onset; the
    /// midpoint is `onset + (in-bed span)/2` from the decoded minutes (a wake/bed edit moved the end into
    /// the stages, so this tracks the corrected span). Blocks whose stages don't decode are still
    /// candidates with a 0-minute score, so a day of only-undecodable blocks still resolves
    /// deterministically. Exact-score ties break toward the EARLIER onset (stable across platforms).
    /// (#525 / #547)
    static func mainNightIndexByStages(_ blocks: [(startTs: Int, stagesJSON: String?)],
                                       onsetByStart: [Int: Int], offsetSec: Int,
                                       habitualMidsleepSec: Int? = nil) -> Int? {
        guard !blocks.isEmpty else { return nil }
        let target = targetMidsleepSec(habitualMidsleepSec)
        func onset(_ b: (startTs: Int, stagesJSON: String?)) -> Int { onsetByStart[b.startTs] ?? b.startTs }
        func score(_ b: (startTs: Int, stagesJSON: String?)) -> Double {
            let m = minutes(fromStagesJSON: b.stagesJSON)
            let asleepMin = m?.asleep ?? 0
            let inBedSec = Int((m?.inBed ?? 0) * 60.0)
            let midSec = localSecOfDay(onset(b) + inBedSec / 2, offsetSec: offsetSec)
            return asleepMin + alignmentBonusMinutes(blockMidSec: midSec, targetMidSec: target)
        }
        var bestIdx = 0
        for i in 1..<blocks.count {
            let cand = blocks[i], best = blocks[bestIdx]
            let cs = score(cand), bs = score(best)
            let candWins: Bool
            if cs != bs {
                candWins = cs > bs
            } else {
                candWins = onset(cand) < onset(best)
            }
            if candWins { bestIdx = i }
        }
        return bestIdx
    }

    /// Stages-path main-night selection ENRICHED with the explainability reason + the chosen block's
    /// DECODED asleep duration, mirroring `mainNightSelection` for the seam. The `index` is byte-identical
    /// to `mainNightIndexByStages(...)`. Here the "longest" comparison ranks by DECODED asleep seconds (the
    /// same figure this overload's score adds), tie-broken by effective onset, so the reason matches what
    /// the seam actually scored. Returns the chosen block's decoded asleep seconds for {DUR}; a block whose
    /// stages don't decode contributes 0 asleep seconds (same as the score). (spec 2026-06-20)
    static func mainNightSelectionByStages(_ blocks: [(startTs: Int, stagesJSON: String?)],
                                           onsetByStart: [Int: Int], offsetSec: Int,
                                           habitualMidsleepSec: Int? = nil) -> MainNightSelection? {
        guard let idx = mainNightIndexByStages(blocks, onsetByStart: onsetByStart, offsetSec: offsetSec,
                                               habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        func onset(_ b: (startTs: Int, stagesJSON: String?)) -> Int { onsetByStart[b.startTs] ?? b.startTs }
        // Per-block decoded asleep seconds + local midpoint (onset + in-bed span / 2), the SAME figures the
        // score used, so the reason is the exact truth of the pick.
        let asleepSecs: [Int] = blocks.map { Int((minutes(fromStagesJSON: $0.stagesJSON)?.asleep ?? 0) * 60.0) }
        let onsets: [Int] = blocks.map(onset)
        let chosen = blocks[idx]
        let chosenAsleepSec = asleepSecs[idx]
        let chosenInBedSec = Int((minutes(fromStagesJSON: chosen.stagesJSON)?.inBed ?? 0) * 60.0)
        let chosenMidLocalSec = localSecOfDay(onset(chosen) + chosenInBedSec / 2, offsetSec: offsetSec)
        let reason = mainNightReason(
            chosenAsleepSec: chosenAsleepSec, chosenOnset: onset(chosen),
            chosenMidLocalSec: chosenMidLocalSec, blockCount: blocks.count,
            longestAsleepSec: asleepSecs.max() ?? chosenAsleepSec,
            longestOnset: durationOnlyWinnerOnset(asleepSecs: asleepSecs, onsets: onsets),
            chosenIsDurationWinnerOnset: onset(chosen),
            habitualMidsleepSec: habitualMidsleepSec)
        return MainNightSelection(index: idx, reason: reason, asleepSeconds: chosenAsleepSec)
    }

    // MARK: - Habitual midsleep (learned timing — non-circular dependency)

    /// One detected sleep block from the trailing history, for learning the user's habitual timing.
    /// `start`/`end` are unix seconds; `dayKey` groups blocks by local calendar day so the LONGEST block
    /// per day can be picked selection-independently (no chicken-and-egg with main-night selection).
    public struct HistoryBlock {
        public let start: Int, end: Int, dayKey: String
        public init(start: Int, end: Int, dayKey: String) {
            self.start = start; self.end = end; self.dayKey = dayKey
        }
        public var durationS: Int { end - start }
        public var midpointSec: Int { start + (end - start) / 2 }
    }

    /// Minimum number of DAYS (with at least one block) needed before a habitual midsleep is trusted; a
    /// shorter history returns nil (cold-start → the scorer uses the overnight band). ~2 weeks of nights
    /// is the lower bound the sleep-timing literature uses for a stable midpoint. (#547)
    public static let habitualMinDays = 14

    /// The user's habitual midsleep as a LOCAL TIME-OF-DAY (seconds in [0, 86400)), or nil when there is
    /// too little history (cold-start). Computed as the CIRCULAR MEAN of the midpoint-time-of-day of the
    /// LONGEST block per local day across `history` (the mean direction of the midpoint angles — the
    /// natural circular central tendency for clock times). Longest-per-day is selection-INDEPENDENT, so
    /// this has no circular dependency on main-night selection. Circular math (mean of the angle, then
    /// back to seconds) makes 23:30 and 00:30 an hour apart, not 23h, so a near-midnight sleeper's midsleep
    /// is learned correctly. `offsetSec` turns each midpoint local; `minDays` is the cold-start floor. (#547)
    public static func habitualMidsleepSec(_ history: [HistoryBlock], offsetSec: Int,
                                           minDays: Int = habitualMinDays) -> Int? {
        guard !history.isEmpty else { return nil }
        // Longest block per local day (selection-independent). Ties within a day → earlier onset (stable).
        var longestByDay: [String: HistoryBlock] = [:]
        for b in history {
            if let cur = longestByDay[b.dayKey] {
                if b.durationS > cur.durationS || (b.durationS == cur.durationS && b.start < cur.start) {
                    longestByDay[b.dayKey] = b
                }
            } else {
                longestByDay[b.dayKey] = b
            }
        }
        guard longestByDay.count >= minDays else { return nil }
        // Circular mean of each day's midpoint time-of-day: convert each to an angle, take the mean
        // direction via the unit-vector sum (order-independent), map back to seconds-of-day. nil when
        // the resultant vector is degenerate (antipodal/uniform midpoints) — falls back to cold-start.
        let midSecs = longestByDay.values.map { localSecOfDay($0.midpointSec, offsetSec: offsetSec) }
        return circularMeanSec(midSecs)
    }

    /// Minimum mean-resultant-vector length (R = |Σ(sin,cos)| / n, in [0, 1]) for a circular mean to be
    /// meaningful. Below this the midpoint angles are antipodal/uniform: their resultant is ~0 so atan2
    /// returns an arbitrary direction that Swift and Kotlin can disagree on (a parity break in the
    /// degenerate case). Tiny and identical cross-platform so both sides reject the SAME inputs. (#547)
    static let circularMeanMinResultant = 1e-9

    /// Circular mean of times-of-day (seconds in [0, 86400)) via the mean unit vector (atan2 of summed
    /// sin/cos). Returns the mean direction as seconds-of-day in [0, 86400), or nil when the resultant
    /// vector is degenerate (empty, or antipodal/uniform so its magnitude is below
    /// `circularMeanMinResultant` and the angle is meaningless). nil makes `habitualMidsleepSec` fall
    /// back to cold-start rather than emit a meaningless (and cross-platform-divergent) anchor. Used for
    /// the habitual-midsleep anchor so near-midnight times average correctly. (#547)
    static func circularMeanSec(_ secs: [Int]) -> Int? {
        guard !secs.isEmpty else { return nil }
        var sumSin = 0.0, sumCos = 0.0
        let k = 2.0 * Double.pi / Double(secondsPerDay)
        for s in secs {
            let a = Double(s) * k
            sumSin += sin(a); sumCos += cos(a)
        }
        // Resultant length R = |(Σsin, Σcos)| / n. Below epsilon the direction is meaningless.
        let resultant = (sumSin * sumSin + sumCos * sumCos).squareRoot() / Double(secs.count)
        guard resultant >= circularMeanMinResultant else { return nil }
        var ang = atan2(sumSin, sumCos)               // [-π, π]
        if ang < 0 { ang += 2.0 * Double.pi }         // → [0, 2π)
        let sec = Int((ang / k).rounded()) % secondsPerDay
        return (sec + secondsPerDay) % secondsPerDay
    }
}
