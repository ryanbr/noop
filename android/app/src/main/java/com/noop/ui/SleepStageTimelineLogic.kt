package com.noop.ui

import org.json.JSONArray
import com.noop.analytics.SleepStageVocabulary

/** One persisted per-epoch stage segment (wall-clock unix seconds). */
internal data class PersistedSegment(val start: Long, val end: Long, val stage: String)

/**
 * Parse the verbatim per-epoch segments array the on-device stager persists
 * ([{"start","end","stage"}], unix seconds, stage ∈ wake|light|deep|rem — see
 * AnalyticsEngine.encodeStages). Returns null for the imported minutes shapes
 * (the macOS {"light",…} dict and the CSV-import [{stage,min}] array) and any
 * malformed input, so callers keep the synthesized fallback. Pure + unit-tested
 * (see SleepStageSegmentsTest).
 */
internal fun parsePersistedSegments(json: String?): List<PersistedSegment>? {
    if (json.isNullOrBlank()) return null
    val trimmed = json.trim()
    if (!trimmed.startsWith("[")) return null
    return runCatching {
        val arr = JSONArray(trimmed)
        val out = ArrayList<PersistedSegment>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: return@runCatching null
            val start = o.optLong("start", Long.MIN_VALUE)
            val end = o.optLong("end", Long.MIN_VALUE)
            val stage = o.optString("stage", "")
            if (start == Long.MIN_VALUE || end <= start || stage.isEmpty()) return@runCatching null
            out.add(PersistedSegment(start, end, stage))
        }
        out.takeIf { it.size >= 2 }
    }.getOrNull()
}

// MARK: - Stage timeline logic (iOS #988 port — pure, unit-tested)

/** One contiguous run of a single sleep stage, in seconds from the night's onset. */
internal data class StageInterval(val stage: String, val startSec: Double, val endSec: Double) {
    val durationSec: Double get() = endSec - startSec
}

/**
 * Reconstruct absolute (stage, startSec, endSec) intervals from the hero's ordered
 * `realSegments` weight pairs (name, minutes) by walking cumulative fractions across [spanSec]
 * (design 2026-07-10, §Real-stage nights item 3). Non-finite / non-positive weights are skipped —
 * they carry no drawable width. Returns [] when nothing is drawable.
 */
internal fun stageIntervalsFromWeights(
    segments: List<Pair<String, Float>>,
    spanSec: Double,
): List<StageInterval> {
    if (segments.isEmpty() || !spanSec.isFinite() || spanSec <= 0.0) return emptyList()
    val weights = segments.map { (_, wt) -> if (wt.isFinite() && wt > 0f) wt.toDouble() else 0.0 }
    val total = weights.sum()
    if (total <= 0.0) return emptyList()
    val out = ArrayList<StageInterval>(segments.size)
    var cum = 0.0
    segments.forEachIndexed { i, (name, _) ->
        val w = weights[i]
        if (w <= 0.0) return@forEachIndexed
        val start = spanSec * (cum / total)
        cum += w
        out.add(StageInterval(name, start, spanSec * (cum / total)))
    }
    return out
}

/**
 * Display-time smoothing — a straight port of Swift `Hypnogram.displaySmoothed` (WHOOP-style,
 * Packages/StrandDesign/Sources/StrandDesign/Hypnogram.swift:92). The on-device stager emits
 * 30 s-epoch runs, so a real night arrives as 60–100 fragments; brief flickers are absorbed into
 * their surroundings AT DISPLAY TIME. Render-only: totals, percentages and stored data are
 * computed from the raw segments elsewhere and are untouched. Pass minDurationSec = 0 for raw.
 */
internal fun displaySmoothed(
    intervals: List<StageInterval>,
    minDurationSec: Double,
): List<StageInterval> {
    // Match Swift `Hypnogram.displaySmoothed`: guard ONLY on count. A minDurationSec <= 0 ("raw") must
    // still fall through to coalesce() — Swift returns the coalesced timeline, not the un-merged epoch
    // fragments. Short-circuiting on <= 0 here returned 60-100 raw fragments (the "comb"), diverging from
    // the port. With minDurationSec = 0 the absorb loop's `duration < 0` filter is empty, so it breaks
    // right after the first coalesce — same result as Swift.
    if (intervals.size <= 2) return intervals   // Swift: guard count > 2

    // Coalesce adjacent same-stage runs (also bridges the zero-length seams between epochs).
    fun coalesce(ivs: List<StageInterval>): MutableList<StageInterval> {
        val out = mutableListOf<StageInterval>()
        for (iv in ivs) {
            val last = out.lastOrNull()
            if (last != null && last.stage == iv.stage && iv.startSec - last.endSec < 1.0) {
                out[out.size - 1] = StageInterval(last.stage, last.startSec, iv.endSec)
            } else {
                out.add(iv)
            }
        }
        return out
    }

    var ivs = coalesce(intervals)
    // Repeatedly absorb the shortest sub-threshold fragment into its longer neighbour,
    // re-coalescing after each pass, until every remaining block clears the threshold.
    while (ivs.size > 1) {
        val idx = ivs.indices
            .filter { ivs[it].durationSec < minDurationSec }
            .minByOrNull { ivs[it].durationSec } ?: break
        val victim = ivs[idx]
        val prev = if (idx > 0) ivs[idx - 1] else null
        val next = if (idx < ivs.size - 1) ivs[idx + 1] else null
        when {
            prev != null && next != null ->
                // Absorb into the longer neighbour so the dominant surrounding stage wins.
                if (prev.durationSec >= next.durationSec) {
                    ivs[idx - 1] = StageInterval(prev.stage, prev.startSec, victim.endSec)
                } else {
                    ivs[idx + 1] = StageInterval(next.stage, victim.startSec, next.endSec)
                }
            prev != null -> ivs[idx - 1] = StageInterval(prev.stage, prev.startSec, victim.endSec)
            next != null -> ivs[idx + 1] = StageInterval(next.stage, victim.startSec, next.endSec)
            else -> break
        }
        ivs.removeAt(idx)
        ivs = coalesce(ivs)
    }
    return ivs
}

/** Canonical stage key: trims, lowercases, and folds the "wake"/"awake" alias. The single definition of
 *  a stage key in the UI layer — `stageColorFor` (SleepStageBreakdownUi.kt) keys off this rather than
 *  repeating the rule, so adding an alias here is all that is needed. Written as code rather than a
 *  KDoc link because the target is private in another file and would not resolve. */
internal fun canonicalStage(name: String): String {
    // #979: the alias rule has ONE definition — SleepStageVocabulary. This still folds toward
    // "awake" because that is the key the stage-colour table and the minutes dictionaries use.
    val n = name.trim().lowercase()
    return if (SleepStageVocabulary.isWake(n)) "awake" else n
}

/**
 * The (startFraction, widthFraction) spans of [rowStage]'s intervals within the night — one entry
 * per solid segment in that stage's timeline row track. Fractions of [spanSec]; the draw side
 * applies the min-width floor and canvas clamping.
 */
internal fun stageRowSpans(
    intervals: List<StageInterval>,
    rowStage: String,
    spanSec: Double,
): List<Pair<Float, Float>> {
    if (spanSec <= 0.0 || !spanSec.isFinite()) return emptyList()
    val key = canonicalStage(rowStage)
    return intervals
        .filter { canonicalStage(it.stage) == key }
        .map { iv -> (iv.startSec / spanSec).toFloat() to (iv.durationSec / spanSec).toFloat() }
}
