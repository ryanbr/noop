package com.noop.analytics

import org.json.JSONArray
import org.json.JSONObject

/**
 * Decode a sleep session's `stagesJSON` into stage MINUTE totals, and aggregate a night's blocks into
 * the sleep-derived daily fields. Pure + deterministic, so the daily-aggregate recompute that honors a
 * user's bed/wake-time edit can run off the stored (reshaped) stages — no raw streams needed.
 *
 * Faithful Kotlin port of StrandAnalytics/Sources/StrandAnalytics/SleepStageTotals.swift (the iOS
 * `dailyAggregateHonoringEdits` seam from PR #395), adapted to Android's two stagesJSON shapes:
 *   - on-device COMPUTED (what the IntelligenceEngine writes via [AnalyticsEngine.encodeStages]):
 *     `[{start,end,stage}]` — per-segment unix SECONDS spans;
 *   - IMPORTED (WhoopCsvImporter.stagesJson): `[{stage,min}]` — per-stage MINUTE totals.
 * The on-device stager calls awake "wake"; the importer "awake" — both map to `awake`.
 *
 * The edit/recompute path only ever feeds the COMPUTED (`-noop`) source's `[{start,end,stage}]` stages
 * here (the daily override is computed-source-only, mirroring iOS scope), but [minutes] handles both
 * shapes so the helper is a complete twin of the Swift one and is robust to either input.
 */
object SleepStageTotals {

    /** Stage minute totals for one session. `asleep` = light+deep+rem; `inBed` = asleep+awake. */
    data class Minutes(
        var awake: Double = 0.0,
        var light: Double = 0.0,
        var deep: Double = 0.0,
        var rem: Double = 0.0,
    ) {
        val asleep: Double get() = light + deep + rem
        val inBed: Double get() = asleep + awake
    }

    /**
     * The sleep-derived daily fields for a night, or null if nothing decodes. `efficiency` is
     * asleep / in-bed (TST / Σ stage minutes) in [0,1]. For the segment stages noop stores (which TILE
     * the window), Σ stage minutes equals the clock span, so this coincides with the SleepStager's
     * TST/(end−start). Mirrors Swift `SleepStageTotals.DailySleep`.
     */
    data class DailySleep(
        val totalSleepMin: Double,
        val efficiency: Double,
        val deepMin: Double,
        val remMin: Double,
        val lightMin: Double,
    )

    /**
     * Stage minutes for one session's `stagesJSON`, or null if it decodes to nothing usable.
     * Handles both Android shapes — `[{start,end,stage}]` (seconds spans) and `[{stage,min}]`
     * (minute totals). Mirrors Swift `minutes(fromStagesJSON:)`.
     */
    fun minutes(stagesJSON: String?): Minutes? {
        val json = stagesJSON ?: return null
        val arr = try {
            JSONArray(json)
        } catch (_: Throwable) {
            // Object/dict shape {"awake":N,"light":N,"deep":N,"rem":N} of minute totals (imported
            // sessions). Mirrors Swift minutes(fromStagesJSON:)'s dict branch so imported sleep decodes
            // on Android too, not just the segment-array shapes.
            val dict = try { JSONObject(json) } catch (_: Throwable) { return null }
            val md = Minutes()
            md.awake = dict.optDouble("awake", 0.0)
            md.light = dict.optDouble("light", 0.0)
            md.deep = dict.optDouble("deep", 0.0)
            md.rem = dict.optDouble("rem", 0.0)
            return if (md.inBed > 0.0) md else null
        }
        val m = Minutes()
        for (i in 0 until arr.length()) {
            val seg = arr.optJSONObject(i) ?: continue
            val name = seg.optString("stage", "")
            // Per-segment SECONDS span (computed/edited) → minutes; else a direct minute total (imported).
            val mins = when {
                seg.has("start") && seg.has("end") -> {
                    val s = seg.optLong("start")
                    val e = seg.optLong("end")
                    if (e > s) (e - s) / 60.0 else continue
                }
                seg.has("min") -> seg.optDouble("min", 0.0)
                else -> continue
            }
            if (mins <= 0.0) continue
            when (name) {
                "wake", "awake" -> m.awake += mins
                "light" -> m.light += mins
                "deep" -> m.deep += mins
                "rem" -> m.rem += mins
                else -> continue
            }
        }
        return if (m.inBed > 0.0) m else null
    }

    /**
     * #259: return `stagesJSON` with its `[{start,end,stage}]` segments trimmed to begin no earlier than
     * [onsetSec] — segments fully before the onset are dropped, one straddling it is cut to `[onsetSec, end]`.
     * Only the computed segment-array shape carries the timestamps a trim needs, so the `{stage,min}` /
     * dict (imported) shapes and any unparseable JSON are returned UNCHANGED. A no-op when every segment
     * already starts at/after the onset (the common, already-consistent case). The result is re-parsed by
     * [minutes] / [dailyAggregate] on the SAME platform, so only the decoded minute totals need
     * cross-platform parity, not the exact string. Mirrors Swift `clampStagesToOnset`.
     */
    internal fun clampStagesToOnset(stagesJSON: String?, onsetSec: Long): String? {
        val json = stagesJSON ?: return null
        val arr = try { JSONArray(json) } catch (_: Throwable) { return stagesJSON }
        val out = JSONArray()
        for (i in 0 until arr.length()) {
            val seg = arr.optJSONObject(i) ?: continue
            if (!seg.has("start") || !seg.has("end")) return stagesJSON   // {stage,min} shape → unchanged
            val e = seg.optLong("end")
            val s = maxOf(seg.optLong("start"), onsetSec)
            if (e <= s) continue                                          // fully before the onset → drop
            out.put(JSONObject().put("start", s).put("end", e).put("stage", seg.optString("stage", "")))
        }
        return out.toString()
    }

    // ── Canonical main-night selection (#525 / #547 — learned-timing scored pick) ────────────────────

    /** Broad overnight band for the cold-start timing bonus and physiological-day eligibility.
     *  The 19:00 edge admits early bedtimes (#2626); the 11:00 closing edge retains late-morning onsets.
     *  The raw detector has its own onset band, unchanged by this selection policy. */
    const val OVERNIGHT_START_HOUR = 19

    /** Local hour (exclusive) that closes the cold-start overnight band. Now 11 (was 10) to match the
     *  detector's late-morning edge. A block onset in [OVERNIGHT_END_HOUR, OVERNIGHT_START_HOUR)
     *  is daytime; everything else is overnight. */
    const val OVERNIGHT_END_HOUR = 11

    /** Seconds in a day, for circular time-of-day math. */
    const val SECONDS_PER_DAY = 86_400L

    /** Fixed alignment credit (MINUTES) added to a block's asleep minutes when its midpoint sits on the
     *  habitual midsleep (or, cold-start, the overnight band center). A BONUS, not a gate — a long enough
     *  off-timing block can still out-score a short well-timed one. ~90 min ≈ one sleep cycle. Mirrors
     *  Swift `alignmentBonusMin`. (#547) */
    const val ALIGNMENT_BONUS_MIN: Double = 90.0

    /** Full alignment bonus within this many seconds (circular) of the habitual midsleep; decays linearly
     *  to 0 at [ALIGNMENT_ZERO_SEC]. ±2h full, →0 by ±5h. Mirrors Swift. */
    const val ALIGNMENT_FULL_WINDOW_SEC = 2 * 3_600L

    /** Circular distance (seconds) at/after which the alignment bonus is 0. Mirrors Swift. */
    const val ALIGNMENT_ZERO_SEC = 5 * 3_600L

    /** A block is treated as having a MEANINGFUL alignment bonus when it earns ANY positive credit, i.e.
     *  its midpoint sits inside the bonus window (circular distance < [ALIGNMENT_ZERO_SEC]). Outside the
     *  window the bonus is exactly 0 and contributes nothing to the pick. Tiny epsilon so floating-point
     *  noise at the window edge can't be mistaken for credit. Identical cross-platform. Mirrors Swift
     *  `meaningfulBonusEpsilon`. (spec 2026-06-20) */
    const val MEANINGFUL_BONUS_EPSILON = 1e-9

    /** Adjacent sleep runs separated by a wake gap shorter than this (minutes) are bridged into one block
     *  for selection, so a biphasic / briefly-interrupted main sleep is scored as one night. Matches the
     *  research's <60 min "same sleep period" threshold. Mirrors Swift `gapBridgeMaxMin`. (#547) */
    const val GAP_BRIDGE_MAX_MIN = 60

    /** Wider wake-gap bridge (minutes) applied ONLY to an overnight night-tail fragment, so a single
     *  overnight sleep broken by a real but longer mid-night wake (>= [GAP_BRIDGE_MAX_MIN], < this) is not
     *  over-fragmented into a NAP + a main sleep, the #861 report ("night sleeps are split into naps and
     *  sleep"). Mirrors the detector's own `SleepStager.nightContinuationGapMin` (90 min), the same "this is
     *  the night's tail, not an isolated nap" threshold the detection spine already trusts. Applied (in
     *  [mainNightGroupIndices]) ONLY when the later fragment's onset is still in the overnight band
     *  ([isOvernightOnset]), so a genuine daytime nap (hours away AND begun in daytime) can never be
     *  folded into the night. Below [GAP_BRIDGE_MAX_MIN] the unconditional bridge is unchanged (so
     *  [bridgeAdjacent] and its golden tests stay byte-identical). Mirrors Swift `nightTailBridgeMaxMin`. (#861) */
    const val NIGHT_TAIL_BRIDGE_MAX_MIN = 90

    /** One candidate block for main-night selection: its effective onset and end (unix seconds). A user
     *  wake/bed edit moves [end], never the detected onset key. */
    data class NightBlock(val start: Long, val end: Long) {
        val durationS: Long get() = end - start
        val midpointSec: Long get() = start + (end - start) / 2
    }

    /** True when a block's onset falls in the cold-start overnight band (>= [OVERNIGHT_START_HOUR] or
     *  < [OVERNIGHT_END_HOUR], local). Retained for callers/tests that still ask the binary question, but
     *  the scored selector no longer GATES on it. Physiological-day classification still uses this
     *  band to exclude unclassified daytime naps; its early edge admits 19:00 bedtimes (#2626). [offsetSec] is seconds EAST of UTC. (#525 / #547) */
    fun isOvernightOnset(ts: Long, offsetSec: Long): Boolean {
        val local = ts + offsetSec
        val secOfDay = ((local % SECONDS_PER_DAY) + SECONDS_PER_DAY) % SECONDS_PER_DAY
        val hour = (secOfDay / 3_600L).toInt()
        return hour >= OVERNIGHT_START_HOUR || hour < OVERNIGHT_END_HOUR
    }

    /** Local time-of-day, in seconds [0, 86400), of a unix timestamp shifted east by [offsetSec].
     *  Mirrors Swift `localSecOfDay`. */
    internal fun localSecOfDay(ts: Long, offsetSec: Long): Long {
        val local = ts + offsetSec
        return ((local % SECONDS_PER_DAY) + SECONDS_PER_DAY) % SECONDS_PER_DAY
    }

    /** Smallest circular distance (seconds, 0..43200) between two times-of-day, so 23:30 and 00:30 are
     *  3600s apart, not 82800. Both inputs are seconds-of-day in [0, 86400). Mirrors Swift. */
    internal fun circularDistanceSec(a: Long, b: Long): Long {
        val raw = Math.abs(a - b) % SECONDS_PER_DAY
        return minOf(raw, SECONDS_PER_DAY - raw)
    }

    /** The cold-start anchor: the CENTER of the overnight band [OVERNIGHT_START_HOUR, OVERNIGHT_END_HOUR),
     *  as a time-of-day in seconds. The band wraps midnight (20:00 → 11:00 = 15h wide) so the center is
     *  03:30 local. Mirrors Swift `coldStartAnchorSec`. (#547) */
    val coldStartAnchorSec: Long
        get() {
            val startSec = OVERNIGHT_START_HOUR * 3_600L
            val span = ((OVERNIGHT_END_HOUR - OVERNIGHT_START_HOUR) * 3_600L + SECONDS_PER_DAY) % SECONDS_PER_DAY
            return (startSec + span / 2) % SECONDS_PER_DAY
        }

    /** The alignment bonus (MINUTES) a block earns for sitting near the target midsleep. Full
     *  [ALIGNMENT_BONUS_MIN] within [ALIGNMENT_FULL_WINDOW_SEC], decaying linearly to 0 by
     *  [ALIGNMENT_ZERO_SEC]. [blockMidSec]/[targetMidSec] are local times-of-day in seconds. Mirrors
     *  Swift `alignmentBonusMinutes`. (#547) */
    internal fun alignmentBonusMinutes(blockMidSec: Long, targetMidSec: Long): Double {
        val d = circularDistanceSec(blockMidSec, targetMidSec)
        if (d <= ALIGNMENT_FULL_WINDOW_SEC) return ALIGNMENT_BONUS_MIN
        if (d >= ALIGNMENT_ZERO_SEC) return 0.0
        val frac = (ALIGNMENT_ZERO_SEC - d).toDouble() / (ALIGNMENT_ZERO_SEC - ALIGNMENT_FULL_WINDOW_SEC).toDouble()
        return ALIGNMENT_BONUS_MIN * frac
    }

    /** The target midsleep time-of-day (seconds) the scorer aligns to: the learned [habitualMidsleepSec]
     *  when supplied, else the cold-start overnight-band center. Mirrors Swift `targetMidsleepSec`. */
    internal fun targetMidsleepSec(habitualMidsleepSec: Long?): Long =
        habitualMidsleepSec ?: coldStartAnchorSec

    /** Merge adjacent [NightBlock]s separated by a wake gap shorter than [GAP_BRIDGE_MAX_MIN] into single
     *  blocks for selection, so a fragmented main sleep is scored as one night. Sorts on [NightBlock.start]
     *  first so neighbours are adjacent. Pure + deterministic. Mirrors Swift `bridgeAdjacent`. (#547) */
    fun bridgeAdjacent(blocks: List<NightBlock>): List<NightBlock> {
        if (blocks.size <= 1) return blocks
        val sorted = blocks.sortedBy { it.start }
        val bridgeS = GAP_BRIDGE_MAX_MIN * 60L
        val out = mutableListOf(sorted[0])
        for (b in sorted.drop(1)) {
            val last = out[out.size - 1]
            val gap = b.start - last.end
            if (gap in 0 until bridgeS) {
                out[out.size - 1] = NightBlock(last.start, maxOf(last.end, b.end))
            } else {
                out.add(b)
            }
        }
        return out
    }

    /** One bridged night group over the whole input: the fragments (as ORIGINAL indices, ascending) plus
     *  the group's inter-fragment wake seams (start, end) pairs. Produced by [bridgedNightGroups] for the
     *  consumers that must present a briefly-interrupted night as ONE night — the Health Connect export
     *  and the Sleep screen — so they group exactly as the day totals do and can fold each seam in as an
     *  explicit wake segment. Mirrors Swift `BridgedNightGroup`. (#364) */
    data class BridgedNightGroup(val indices: List<Int>, val gaps: List<Pair<Long, Long>>)

    /** EVERY bridged group over [blocks] — the same two-tier bridge [mainNightGroupIndices] applies (#561
     *  short-wake, plus the #861 overnight night-tail widening), WITHOUT the winner pick. A negative gap
     *  (a block starting inside the previous span) does not bridge — pinned legacy semantics, `gap >= 0` —
     *  and never fabricates a seam. Groups ordered by start; pure and deterministic. Mirrors Swift
     *  `bridgedNightGroups`. (#364) */
    fun bridgedNightGroups(blocks: List<NightBlock>, offsetSec: Long): List<BridgedNightGroup> {
        if (blocks.isEmpty()) return emptyList()
        // Sort indices by onset so bridging sees neighbours, exactly as `bridgeAdjacent` sorts the blocks.
        val order = blocks.indices.sortedBy { blocks[it].start }
        val bridgeS = GAP_BRIDGE_MAX_MIN * 60L
        val nightTailBridgeS = NIGHT_TAIL_BRIDGE_MAX_MIN * 60L
        // Build the bridged spans AND the original indices that compose each one, in one pass over `order`.
        val bridged = ArrayList<NightBlock>()
        val groups = ArrayList<MutableList<Int>>()
        val gaps = ArrayList<MutableList<Pair<Long, Long>>>()
        for (idx in order) {
            val b = blocks[idx]
            val last = bridged.lastOrNull()
            if (last != null) {
                val gap = b.start - last.end
                // Unconditional short-wake bridge (< GAP_BRIDGE_MAX_MIN), byte-identical to `bridgeAdjacent`.
                // Then a WIDER bridge for a true overnight night-tail (#861): a gap in
                // [GAP_BRIDGE_MAX_MIN, NIGHT_TAIL_BRIDGE_MAX_MIN) folds the fragment in ONLY when its onset is
                // still in the overnight band: a real mid-night wake, not an isolated daytime nap. This stops
                // one overnight sleep being split into a nap + a main sleep, while a daytime nap (daytime
                // onset, or a gap >= NIGHT_TAIL_BRIDGE_MAX_MIN) still stands as its own block.
                val bridges = gap >= 0 &&
                    (gap < bridgeS ||
                        (gap < nightTailBridgeS && isOvernightOnset(b.start, offsetSec)))
                if (bridges) {
                    if (gap > 0) gaps[gaps.size - 1].add(last.end to b.start)
                    bridged[bridged.size - 1] = NightBlock(last.start, maxOf(last.end, b.end))
                    groups[groups.size - 1].add(idx)
                    continue
                }
            }
            bridged.add(b)
            groups.add(mutableListOf(idx))
            gaps.add(mutableListOf())
        }
        return groups.zip(gaps).map { (g, gp) -> BridgedNightGroup(g.sorted(), gp) }
    }

    /** The indices (into the ORIGINAL [blocks]) of the MAIN-NIGHT GROUP: the main night plus any adjacent
     *  fragments bridged into it. A biphasic / briefly-interrupted main sleep that reaches the selector still
     *  split into two blocks (a wake gap shorter than [GAP_BRIDGE_MAX_MIN] between them) is scored as ONE
     *  night rather than two competing fragments, then the winning bridged group's fragments are ALL returned
     *  so the caller can SUM their stages for the day's headline figure. (#561)
     *
     *  Pipeline:
     *   1. [bridgedNightGroups] merges blocks whose gap is in `[0, GAP_BRIDGE_MAX_MIN*60)` (or the #861
     *      night-tail window) into bridged groups, in `start` order;
     *   2. [mainNightIndex] scores the BRIDGED spans (so a two-fragment night's combined span out-scores a
     *      lone nap) and picks the winning bridged group;
     *   3. the original indices of that winning group are returned, ascending.
     *
     *  Null only for an empty list. A day with no bridgeable gap collapses to the single-block group the bare
     *  [mainNightIndex] would pick — byte-identical to the old behaviour for the common case. Pure +
     *  deterministic; shares the [bridgedNightGroups] pass + [mainNightIndex] so the pick stays
     *  cross-platform stable. Mirrors Swift `mainNightGroupIndices`. (#561) */
    fun mainNightGroupIndices(blocks: List<NightBlock>, offsetSec: Long, habitualMidsleepSec: Long? = null): List<Int>? {
        if (blocks.isEmpty()) return null
        val all = bridgedNightGroups(blocks, offsetSec)
        // Rebuild each group's bridged span for scoring: sorted-ascending fragments make the span
        // (first start, running-max end) — identical to the span the one-pass loop accumulated.
        val bridgedSpans = all.map { g ->
            NightBlock(g.indices.minOf { blocks[it].start }, g.indices.maxOf { blocks[it].end })
        }
        val winner = mainNightIndex(bridgedSpans, offsetSec, habitualMidsleepSec) ?: return null
        return all[winner].indices
    }

    /** Index of the day's MAIN night among [blocks], by the LEARNED-TIMING SCORE (replaces the old hard
     *  overnight gate). score(block) = asleepMinutes + alignmentBonus, crediting a block whose midpoint
     *  sits near [habitualMidsleepSec] (or, cold-start, the overnight-band center). No hard duration floor
     *  and no overnight gate: a short main sleep or a nap-only day still resolves, and a genuine long
     *  daytime sleep can win on score. Highest score wins; exact ties break toward the EARLIER onset
     *  (stable across platforms). Null only for an empty list. This `NightBlock` overload has no decoded
     *  stages, so "asleep minutes" is the clock span — preserving the prior duration semantics for callers
     *  that rank by span (`analyzeDay`). Mirrors Swift `mainNightIndex`. (#525 / #547) */
    fun mainNightIndex(blocks: List<NightBlock>, offsetSec: Long, habitualMidsleepSec: Long? = null): Int? {
        if (blocks.isEmpty()) return null
        val target = targetMidsleepSec(habitualMidsleepSec)
        fun score(b: NightBlock): Double {
            val asleepMin = b.durationS.toDouble() / 60.0
            val midSec = localSecOfDay(b.midpointSec, offsetSec)
            return asleepMin + alignmentBonusMinutes(midSec, target)
        }
        var bestIdx = 0
        for (i in 1 until blocks.size) {
            val cand = blocks[i]
            val best = blocks[bestIdx]
            val cs = score(cand)
            val bs = score(best)
            val candWins = when {
                cs != bs -> cs > bs                    // higher score wins
                else -> cand.start < best.start        // exact tie → earlier onset (stable)
            }
            if (candWins) bestIdx = i
        }
        return bestIdx
    }

    // ── Selection REASON (explainability — why THIS block won) ───────────────────────────────────────

    /** Why the main-night selector chose the block it chose, the EXACT truth the score used, so the UI can
     *  explain the pick in plain English. Computed from the SAME signals the score does (asleep duration vs
     *  the alignment bonus). Mirrors Swift `MainNightReason`. (#547 explainability)
     *  - [onlyBlock]        — the day had a single block, so there was nothing to choose between.
     *  - [longest]          — the chosen block won on raw asleep duration (cold-start, or no meaningful
     *                         timing credit); it is simply the longest. The default / fallback reason.
     *  - [longestNearUsual] — the chosen block was BOTH the longest by duration AND earned a meaningful
     *                         alignment bonus (a learned habitual is present and the block sits within the
     *                         bonus window of it): longest, and near the usual sleep time.
     *  - [alignedToUsual]   — the alignment bonus (NOT raw duration) flipped the pick: a shorter block that
     *                         sits near the usual sleep time out-scored the longest block. Timing decided it. */
    enum class MainNightReason { onlyBlock, longest, longestNearUsual, alignedToUsual }

    /** The resolved main-night pick PLUS the truth needed to explain it: which block won ([index]), WHY it
     *  won ([reason]), and the chosen block's ASLEEP duration ([asleepSec]) so the UI can fill "Xh Ym". For
     *  the [NightBlock] overload "asleep" is the block's clock span (no decoded stages), matching
     *  [mainNightIndex]'s scoring semantics exactly. Mirrors Swift `MainNightSelection`. (#547) */
    data class MainNightSelection(val index: Int, val reason: MainNightReason, val asleepSec: Long) {
        /** The chosen block's asleep duration in whole MINUTES (floored), for "Xh Ym" copy. */
        val asleepMin: Long get() = asleepSec / 60L
    }

    /** The day's MAIN night AND why it won, over [blocks]. A sibling to [mainNightIndex] (same score, same
     *  tie-break, same null-on-empty) that additionally returns the [MainNightReason] derived from the SAME
     *  signals the score used, and the chosen block's asleep duration, so the UI can explain the pick without
     *  re-deriving anything. Existing [mainNightIndex] callers are untouched.
     *
     *  The reason is decided exactly as the spec lays out, in this order:
     *   1. one block            → [MainNightReason.onlyBlock];
     *   2. the bonus flipped it  → [MainNightReason.alignedToUsual]  (the score winner differs from the
     *      duration-only winner, so timing — not raw duration — decided the pick);
     *   3. longest + near usual  → [MainNightReason.longestNearUsual] (the score winner IS the duration-only
     *      winner AND a learned [habitualMidsleepSec] is present AND the chosen block earns a non-zero
     *      alignment bonus, i.e. its midpoint is within the bonus window of the learned habitual);
     *   4. otherwise             → [MainNightReason.longest] (incl. cold-start: no learned habitual, or the
     *      chosen longest block earns no meaningful timing credit).
     *
     *  Mirrors Swift `mainNightSelection`. (#547 explainability) */
    fun mainNightSelection(blocks: List<NightBlock>, offsetSec: Long, habitualMidsleepSec: Long? = null): MainNightSelection? {
        val idx = mainNightIndex(blocks, offsetSec, habitualMidsleepSec) ?: return null
        val chosen = blocks[idx]
        val asleepSec = chosen.durationS
        val reason = if (blocks.size == 1) {
            MainNightReason.onlyBlock
        } else {
            // The duration-only winner: highest asleep CLOCK SPAN, exact ties → earlier onset (the SAME
            // tie-break the score uses), so "flipped vs duration-only" is a clean, deterministic comparison.
            var durIdx = 0
            for (i in 1 until blocks.size) {
                val c = blocks[i]
                val b = blocks[durIdx]
                val cWins = when {
                    c.durationS != b.durationS -> c.durationS > b.durationS
                    else -> c.start < b.start
                }
                if (cWins) durIdx = i
            }
            val target = targetMidsleepSec(habitualMidsleepSec)
            val chosenMidSec = localSecOfDay(chosen.midpointSec, offsetSec)
            val chosenBonus = alignmentBonusMinutes(chosenMidSec, target)
            when {
                idx != durIdx -> MainNightReason.alignedToUsual                       // timing flipped the pick
                habitualMidsleepSec != null && chosenBonus > MEANINGFUL_BONUS_EPSILON -> MainNightReason.longestNearUsual
                else -> MainNightReason.longest                                       // incl. cold-start
            }
        }
        return MainNightSelection(idx, reason, asleepSec)
    }

    /** The night's daily sleep aggregate over these blocks' `stagesJSON`, or null if none decode.
     *  Mirrors Swift `dailyAggregate`. */
    fun dailyAggregate(stagesJSONs: List<String?>): DailySleep? =
        dailyAggregate(stagesJSONs, interFragmentAwakeSeconds = 0.0)

    /** As [dailyAggregate], but folds the OUT-OF-BED time between bridged main-night fragments into the
     *  night's AWAKE total (and therefore its in-bed denominator). #777/#705 regression fix: a main sleep
     *  bridged from two fragments split by a 20-min wake gap was reporting that gap as nowhere (it is in no
     *  fragment's own span), so 20+ min of real awake read as ~4 min. The caller computes the gap once
     *  (sum of gaps between consecutive fragments' effective ends and onsets) and passes it here so both the
     *  analytics rollup and the edit/recompute seam apply ONE consistent definition: gap → awake → in-bed.
     *  `interFragmentAwakeSeconds` <= 0 reproduces the legacy sum-of-stages behaviour. Mirrors Swift. */
    fun dailyAggregate(stagesJSONs: List<String?>, interFragmentAwakeSeconds: Double): DailySleep? {
        val total = Minutes()
        var any = false
        for (j in stagesJSONs) {
            val mm = minutes(j) ?: continue
            total.awake += mm.awake
            total.light += mm.light
            total.deep += mm.deep
            total.rem += mm.rem
            any = true
        }
        if (interFragmentAwakeSeconds > 0.0) total.awake += interFragmentAwakeSeconds / 60.0
        if (!any || total.inBed <= 0.0) return null
        return DailySleep(
            totalSleepMin = total.asleep,
            efficiency = total.asleep / total.inBed,
            deepMin = total.deep,
            remMin = total.rem,
            lightMin = total.light,
        )
    }

    /** The OUT-OF-BED time (seconds) BETWEEN consecutive bridged sleep fragments - the inter-fragment wake
     *  gaps the #561 gap-bridge spans but no fragment's own `[start,end)` covers. Each fragment is one
     *  (start,end) span; sorted by start, the gap after fragment i is `max(0, start[i+1] - end[i])`. Sums
     *  only positive gaps. The single shared definition of "awake between fragments" both `analyzeDay` and
     *  the edit/recompute seam fold into AWAKE, so the two paths agree (no seam double-count). Mirrors
     *  Swift `interFragmentAwakeSeconds`. (#777/#705) */
    fun interFragmentAwakeSeconds(spans: List<Pair<Long, Long>>): Double {
        if (spans.size <= 1) return 0.0
        val sorted = spans.sortedBy { it.first }
        var gap = 0L
        for (i in 1 until sorted.size) {
            val g = sorted[i].first - sorted[i - 1].second
            if (g > 0L) gap += g
        }
        return gap.toDouble()
    }

    /** Result of [dailyAggregateHonoringEdits]: the aggregate plus whether an edit actually applied. */
    data class HonoredAggregate(val sleep: DailySleep, val editApplied: Boolean)

    /**
     * The night's daily sleep aggregate, substituting any USER-EDITED block for its detected twin before
     * summing, then UNIONING in any user-added block that has no detected twin. [detected] is the
     * auto-detected blocks (their stable startTs + stages); [edited] maps a block's startTs → its
     * hand-corrected (reshaped) stages — a bed/wake-time edit never moves startTs, so the edited block
     * lands exactly on its detected twin. [manual] is user-added blocks (e.g. a hand-logged nap) the
     * detector never found; each is keyed by its own stable startTs and FOLDED IN so its minutes count
     * toward the day's totals (a detector-found nap already folds via [detected]). De-duped by startTs
     * so a block already in [detected] (or substituted via [edited]) is never double-counted. Returns the
     * aggregate plus whether an edit OR a manual block actually contributed (so the caller only overrides
     * the day when it did), or null when nothing decodes.
     *
     * Faithful twin of Swift `dailyAggregateHonoringEdits` (#518 / #508): substitute an edited block's
     * stages ONLY when the edit has usable (non-null) stages — an edit that reshaped to null must fall
     * back to the detected stages, never DROP the block (which would collapse the night's sleep total).
     * `editApplied` likewise reflects a real substitution or a folded manual block. Pure: unit-tested
     * with synthetic data, no store/stager.
     */
    fun dailyAggregateHonoringEdits(
        detected: List<Pair<Long, String?>>,
        edited: Map<Long, String?>,
        manual: List<Pair<Long, String?>> = emptyList(),
        // The block's effective onset (a wake/bed edit moves end, not the detected start key) keyed by
        // startTs, plus the device's UTC offset, so the MAIN-NIGHT pick reads the user's local clock.
        // When a caller can't supply onsets, leave null and the legacy SUM-of-all-blocks behaviour is
        // preserved (no regression for older callers); the day rollup passes them so the daily total
        // matches the Sleep tab. Mirrors Swift `onsetByStart` / `offsetSec`. (#525)
        onsetByStart: Map<Long, Long>? = null,
        offsetSec: Long = 0L,
        // The learned habitual midsleep (local time-of-day seconds) so the scored pick aligns to the
        // user's real bedtime, not a fixed clock band. null = cold-start. Existing callers compile
        // unchanged. Mirrors Swift `habitualMidsleepSec`. (#547)
        habitualMidsleepSec: Long? = null,
    ): HonoredAggregate? {
        var applied = false
        // (startTs, effective stages) for every block on the day — detected (edit-substituted) then any
        // twinless manual block UNIONED in. Identity is preserved for the main-night selection.
        val blocks = detected.map { (startTs, detectedStages) ->
            // `edited[startTs]` is null both when the key is ABSENT and when it maps to NULL stages
            // (an edit that reshaped to nothing) — in both cases we fall back to the detected stages
            // and do NOT mark `applied`. Only a present, non-null edit substitutes, mirroring Swift's
            // `edited[d.startTs] ?? nil` requiring a non-nil value.
            val editStages = edited[startTs]
            if (editStages != null) {
                applied = true
                startTs to editStages
            } else {
                startTs to detectedStages
            }
        }.toMutableList()
        // Union: a user-added block the detector never found (no detected twin) must still be on the day
        // so the main-night pick (or the legacy sum) sees it — otherwise a manually-logged nap is dropped.
        // Match on the stable startTs and add ONLY rows absent from [detected], with usable stages.
        val detectedStarts = detected.map { it.first }.toHashSet()
        for ((startTs, manualStages) in manual) {
            if (startTs in detectedStarts) continue
            if (manualStages != null) {
                blocks.add(startTs to manualStages)
                applied = true
            }
        }
        // Canonical per-day total (#525): with block onsets supplied, the daily figure is the MAIN NIGHT
        // only (the longest, overnight-preferring block — the SAME block the Sleep tab shows), so
        // Intelligence / Sleep Need / the debt ledger / the card all read the same number as the Sleep
        // tab. Nap blocks stay their own session rows elsewhere; they are NOT summed into this figure.
        // No onsets supplied → the legacy sum-of-all-blocks total (older callers unchanged).
        if (onsetByStart != null) {
            // BIPHASIC GAP-BRIDGE (#561): bridge adjacent blocks split by a short wake gap into the
            // main-night GROUP and SUM that group's stages, so the edit/recompute seam reports the SAME
            // night `analyzeDay` does. Naps outside the group remain their own rows. Mirrors Swift.
            val group = mainNightGroupIndicesByStages(blocks, onsetByStart, offsetSec, habitualMidsleepSec)
                ?: return null
            // #259: trim each SELECTED block's stages to its EFFECTIVE onset before summing. A hand-edited
            // or onset-trimmed bedtime that the raw was too sparse to re-stage (WHOOP 4.0) leaves pre-onset
            // segments in the stored stagesJSON; summing them in full pushes asleep past time-in-bed (the
            // impossible "6h41m asleep / 4h33m in bed" card). Selection above ran on the ORIGINAL blocks, so
            // no #525/#547 pick regression — only the SUMMED main-night total is clamped. A block already
            // staged from its onset (the common case) is unchanged. Mirrors Swift.
            val clampedStages = group.map { i ->
                val onset = onsetByStart[blocks[i].first]
                if (onset != null) clampStagesToOnset(blocks[i].second, onset) else blocks[i].second
            }
            // OUT-OF-BED time between the bridged fragments counts as AWAKE (#777/#705), using the SAME
            // single definition `analyzeDay` applies so the seam can't double-count it. Each fragment's
            // effective span is `[onset, onset + decoded in-bed]`; the gap between consecutive fragments is
            // awake the fragments' own stages don't cover. Mirrors Swift.
            val spans = group.mapIndexed { gi, i ->
                val onset = onsetByStart[blocks[i].first] ?: blocks[i].first
                val inBedSec = ((minutes(clampedStages[gi])?.inBed ?: 0.0) * 60.0).toLong()
                onset to (onset + inBedSec)
            }
            val gapAwakeS = interFragmentAwakeSeconds(spans)
            val agg = dailyAggregate(clampedStages, gapAwakeS) ?: return null
            return HonoredAggregate(agg, applied)
        }
        val agg = dailyAggregate(blocks.map { it.second }) ?: return null
        return HonoredAggregate(agg, applied)
    }

    /** The original-index group (ascending) of the day's MAIN night on the STAGES path: the main night plus
     *  any adjacent fragments bridged into it (a wake gap shorter than [GAP_BRIDGE_MAX_MIN]), so the edit/
     *  recompute seam SUMS the same fragments `analyzeDay` does for a biphasic night. Each block's effective
     *  span is `[onset, onset + decoded in-bed]`; bridging tests the gap between one block's effective end and
     *  the next block's onset. The bridged spans are scored by [mainNightIndexByStages] (decoded asleep
     *  minutes + alignment), and the winning group's original indices are returned. Null only for an empty
     *  list. A day with no bridgeable gap returns the single block [mainNightIndexByStages] would pick — no
     *  #525 regression. Mirrors Swift `mainNightGroupIndicesByStages`. (#561) */
    internal fun mainNightGroupIndicesByStages(
        blocks: List<Pair<Long, String?>>,
        onsetByStart: Map<Long, Long>,
        offsetSec: Long,
        habitualMidsleepSec: Long? = null,
    ): List<Int>? {
        if (blocks.isEmpty()) return null
        fun onset(b: Pair<Long, String?>): Long = onsetByStart[b.first] ?: b.first
        fun effEnd(b: Pair<Long, String?>): Long = onset(b) + ((minutes(b.second)?.inBed ?: 0.0) * 60.0).toLong()
        // Order by effective onset so bridging sees neighbours.
        val order = blocks.indices.sortedBy { onset(blocks[it]) }
        val bridgeS = GAP_BRIDGE_MAX_MIN * 60L
        val nightTailBridgeS = NIGHT_TAIL_BRIDGE_MAX_MIN * 60L
        val groups = ArrayList<MutableList<Int>>()
        val groupEnd = ArrayList<Long>()     // running effective end of each bridged group
        for (idx in order) {
            val b = blocks[idx]
            val last = groupEnd.lastOrNull()
            if (last != null) {
                val gap = onset(b) - last
                // Same two-tier bridge as `mainNightGroupIndices` so the summed daily total folds in EXACTLY
                // the fragments the Sleep tab folds into the main night (no nap/total divergence): the
                // unconditional short-wake bridge (< GAP_BRIDGE_MAX_MIN), then the wider overnight night-tail
                // bridge ([GAP_BRIDGE_MAX_MIN, NIGHT_TAIL_BRIDGE_MAX_MIN) only when the fragment's onset is
                // still in the overnight band) that stops one night being split into a nap + a main sleep. (#861)
                val bridges = gap >= 0 &&
                    (gap < bridgeS ||
                        (gap < nightTailBridgeS && isOvernightOnset(onset(b), offsetSec)))
                if (bridges) {
                    groups[groups.size - 1].add(idx)
                    groupEnd[groupEnd.size - 1] = maxOf(last, effEnd(b))
                    continue
                }
            }
            groups.add(mutableListOf(idx))
            groupEnd.add(effEnd(b))
        }
        // Score each bridged group by a synthesized SUMMED block anchored at the group's earliest onset, via
        // the same per-stages scorer, so the pick matches the bare path on a single-block day.
        val groupBlocks = ArrayList<Pair<Long, String?>>()
        val groupOnsets = HashMap<Long, Long>()
        for (g in groups) {
            val anchorIdx = g.minByOrNull { onset(blocks[it]) } ?: g[0]
            val anchorStart = blocks[anchorIdx].first
            val summed = summedStagesJSON(g.map { blocks[it].second })
            groupBlocks.add(anchorStart to summed)
            groupOnsets[anchorStart] = onset(blocks[anchorIdx])
        }
        val winner = mainNightIndexByStages(groupBlocks, groupOnsets, offsetSec, habitualMidsleepSec)
            ?: return null
        return groups[winner].sorted()
    }

    /** A synthetic minute-dict `stagesJSON` whose per-stage minutes are the SUM of the inputs' decoded
     *  minutes — used only to SCORE a bridged group as one block (decoded asleep minutes + in-bed span).
     *  Pure; null when nothing decodes (the group then scores 0, like an undecodable block). Mirrors Swift
     *  `summedStagesJSON`. (#561) */
    internal fun summedStagesJSON(stagesJSONs: List<String?>): String? {
        val total = Minutes()
        var any = false
        for (j in stagesJSONs) {
            val m = minutes(j) ?: continue
            total.awake += m.awake; total.light += m.light
            total.deep += m.deep; total.rem += m.rem
            any = true
        }
        if (!any) return null
        // Keys alphabetical (awake, deep, light, rem) to match Swift's .sortedKeys, though the decoder is
        // key-order-independent — this is only ever fed back into `minutes(...)` to score the group.
        return "{\"awake\":${total.awake},\"deep\":${total.deep},\"light\":${total.light},\"rem\":${total.rem}}"
    }

    /** Index into [blocks] of the day's MAIN night, by the LEARNED-TIMING SCORE: score(block) =
     *  asleepMinutes + alignmentBonus, where "asleepMinutes" is the block's decoded ASLEEP minutes (the
     *  real restorative sleep, not in-bed) and the bonus credits a midpoint near [habitualMidsleepSec]
     *  (or, cold-start, the overnight band). [onsetByStart] gives each block's effective onset; the
     *  midpoint is `onset + (in-bed span)/2` from the decoded minutes. Blocks whose stages don't decode
     *  are still candidates with a 0-minute score. Exact-score ties break toward the EARLIER onset (stable
     *  across platforms). Mirrors Swift `mainNightIndexByStages`. (#525 / #547) */
    internal fun mainNightIndexByStages(
        blocks: List<Pair<Long, String?>>,
        onsetByStart: Map<Long, Long>,
        offsetSec: Long,
        habitualMidsleepSec: Long? = null,
    ): Int? {
        if (blocks.isEmpty()) return null
        val target = targetMidsleepSec(habitualMidsleepSec)
        fun onset(b: Pair<Long, String?>): Long = onsetByStart[b.first] ?: b.first
        fun score(b: Pair<Long, String?>): Double {
            val m = minutes(b.second)
            val asleepMin = m?.asleep ?: 0.0
            val inBedSec = ((m?.inBed ?: 0.0) * 60.0).toLong()
            val midSec = localSecOfDay(onset(b) + inBedSec / 2, offsetSec)
            return asleepMin + alignmentBonusMinutes(midSec, target)
        }
        var bestIdx = 0
        for (i in 1 until blocks.size) {
            val cand = blocks[i]
            val best = blocks[bestIdx]
            val cs = score(cand)
            val bs = score(best)
            val candWins = when {
                cs != bs -> cs > bs
                else -> onset(cand) < onset(best)
            }
            if (candWins) bestIdx = i
        }
        return bestIdx
    }

    // ── Habitual midsleep (learned timing — non-circular dependency) ──────────────────────────────

    /** One detected sleep block from the trailing history, for learning the user's habitual timing.
     *  [start]/[end] are unix seconds; [dayKey] groups blocks by local calendar day so the LONGEST block
     *  per day can be picked selection-independently (no chicken-and-egg with main-night selection).
     *  Mirrors Swift `HistoryBlock`. (#547) */
    data class HistoryBlock(val start: Long, val end: Long, val dayKey: String) {
        val durationS: Long get() = end - start
        val midpointSec: Long get() = start + (end - start) / 2
    }

    /** Minimum number of DAYS (with at least one block) before a habitual midsleep is trusted; a shorter
     *  history returns null (cold-start). ~2 weeks. Mirrors Swift `habitualMinDays`. (#547) */
    const val HABITUAL_MIN_DAYS = 14

    /** The user's habitual midsleep as a LOCAL TIME-OF-DAY (seconds in [0, 86400)), or null when there is
     *  too little history (cold-start). The CIRCULAR MEAN of the midpoint-time-of-day of the LONGEST block
     *  per local day across [history]. Longest-per-day is selection-INDEPENDENT, so no circular dependency
     *  on main-night selection. Circular math makes 23:30 and 00:30 an hour apart, not 23h. [offsetSec]
     *  turns each midpoint local; [minDays] is the cold-start floor. Mirrors Swift `habitualMidsleepSec`.
     *  (#547) */
    fun habitualMidsleepSec(
        history: List<HistoryBlock>,
        offsetSec: Long,
        minDays: Int = HABITUAL_MIN_DAYS,
    ): Long? {
        if (history.isEmpty()) return null
        // Longest block per local day (selection-independent). Ties within a day → earlier onset (stable).
        val longestByDay = HashMap<String, HistoryBlock>()
        for (b in history) {
            val cur = longestByDay[b.dayKey]
            if (cur == null || b.durationS > cur.durationS || (b.durationS == cur.durationS && b.start < cur.start)) {
                longestByDay[b.dayKey] = b
            }
        }
        if (longestByDay.size < minDays) return null
        // nil when the resultant vector is degenerate (antipodal/uniform midpoints) — falls back to cold-start.
        val midSecs = longestByDay.values.map { localSecOfDay(it.midpointSec, offsetSec) }
        return circularMeanSec(midSecs)
    }

    /** Minimum mean-resultant-vector length (R = |Σ(sin,cos)| / n, in [0, 1]) for a circular mean to be
     *  meaningful. Below this the midpoint angles are antipodal/uniform: their resultant is ~0 so atan2
     *  returns an arbitrary direction that Swift and Kotlin can disagree on (a parity break in the
     *  degenerate case). Tiny and identical cross-platform so both sides reject the SAME inputs. Mirrors
     *  Swift `circularMeanMinResultant`. (#547) */
    const val CIRCULAR_MEAN_MIN_RESULTANT = 1e-9

    /** Circular mean of times-of-day (seconds in [0, 86400)) via the mean unit vector (atan2 of summed
     *  sin/cos). Returns the mean direction as seconds-of-day in [0, 86400), or null when the resultant
     *  vector is degenerate (empty, or antipodal/uniform so its magnitude is below
     *  [CIRCULAR_MEAN_MIN_RESULTANT] and the angle is meaningless). null makes [habitualMidsleepSec] fall
     *  back to cold-start rather than emit a meaningless (and cross-platform-divergent) anchor. Mirrors
     *  Swift `circularMeanSec`. (#547) */
    internal fun circularMeanSec(secs: List<Long>): Long? {
        if (secs.isEmpty()) return null
        var sumSin = 0.0
        var sumCos = 0.0
        val k = 2.0 * Math.PI / SECONDS_PER_DAY.toDouble()
        for (s in secs) {
            val a = s.toDouble() * k
            sumSin += Math.sin(a)
            sumCos += Math.cos(a)
        }
        // Resultant length R = |(Σsin, Σcos)| / n. Below epsilon the direction is meaningless.
        val resultant = Math.sqrt(sumSin * sumSin + sumCos * sumCos) / secs.size.toDouble()
        if (resultant < CIRCULAR_MEAN_MIN_RESULTANT) return null
        var ang = Math.atan2(sumSin, sumCos)          // [-π, π]
        if (ang < 0) ang += 2.0 * Math.PI             // → [0, 2π)
        val sec = Math.round(ang / k) % SECONDS_PER_DAY
        return ((sec % SECONDS_PER_DAY) + SECONDS_PER_DAY) % SECONDS_PER_DAY
    }
}
