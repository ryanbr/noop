package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import kotlin.math.abs

// AutoWorkoutDetectorTrace.kt - Kotlin twin of AutoWorkoutDetector+Trace.swift. The Workouts & GPS
// test-mode auto-detect trace + line formatters.
//
// detectTrace(...) is the side-effect-free twin of AutoWorkoutDetector.detect(...): it returns the SAME
// List<DetectedWorkout> detect would (it reuses detect verbatim), plus a trace that names the detector's
// inputs (HR sample count, resting floor), the thresholds it applied, and WHY each candidate window was
// offered or dropped (too short, motion-not-confirmed, overlaps a saved session). So a "workout went
// missing / auto-detect didn't fire" report shows exactly which gate kept or dropped each window.
//
// WorkoutsTrace adds the line formatters the app emitters use for the session lifecycle, the GPS-fix count
// and the cross-source dedup decisions. WorkoutsReadout parses the WORKOUTS-tagged log tail back into the
// lastSessionSummary id. Everything is pure, no clock, no IO, no PII. Byte-aligned with the Swift line
// shapes so a shared report reads identically on either platform. No em-dashes.

object AutoWorkoutDetectorTrace {

    private data class ShadowOption(
        val candidate: Int,
        val saved: Int,
        val overlapS: Long,
    )

    /**
     * Side-effect-free diagnostic twin of [AutoWorkoutDetector.detect]: returns the SAME
     * List<DetectedWorkout> detect would (it reuses detect verbatim), plus the trace. The trace logs the
     * inputs + thresholds, then walks the detector's own gates (sustained-minutes, motion-confirm,
     * saved-overlap) to name why each merged window survived or dropped, mirroring the algorithm exactly.
     * Mirrors the Swift AutoWorkoutDetector.detectTrace. [path] tags the entry point.
     */
    fun detectTrace(
        hr: List<HrSample>,
        restingHR: Int? = null,
        gravity: List<GravitySample> = emptyList(),
        savedWorkouts: List<Pair<Long, Long>> = emptyList(),
        path: String = "autoDetect",
        minimumSustainedMinutes: Double = AutoWorkoutDetector.minSustainedMin,
    ): Pair<List<AutoWorkoutDetector.DetectedWorkout>, List<String>> {
        // The result the Today card reads, verbatim, so the trace cannot diverge from it.
        val results = AutoWorkoutDetector.detect(
            hr, restingHR, gravity, savedWorkouts, minimumSustainedMinutes,
        )

        val lines = ArrayList<String>()
        val floor = (restingHR ?: AutoWorkoutDetector.defaultRestingHR) + AutoWorkoutDetector.elevatedMarginBPM
        val hasMotion = gravity.isNotEmpty()

        lines.add(
            "autoDetect path=$path hrSamples=${hr.size} " +
                "restingBpm=${restingHR?.toString() ?: "default(${AutoWorkoutDetector.defaultRestingHR})"} " +
                "elevatedFloor=${floor}bpm motion=${if (hasMotion) "supplied" else "hrOnly"} " +
                "savedSpans=${savedWorkouts.size}",
        )
        lines.add(
            "autoDetect thresholds elevatedMargin=${AutoWorkoutDetector.elevatedMarginBPM}bpm " +
                "minSustainedMin=$minimumSustainedMinutes maxDipS=${AutoWorkoutDetector.maxDipS} " +
                "mergeGapS=${AutoWorkoutDetector.mergeGapS} motionConfirmMean=${AutoWorkoutDetector.motionConfirmMean}",
        )

        // Rebuild the SAME merged windows the detector forms (steps 1-4), to name each verdict (steps 5-6).
        val seg = hr.sortedBy { it.ts }
        if (seg.isEmpty()) {
            lines.add("autoDetect result windows=0 (no HR samples)")
            return results to lines
        }

        val spans = ArrayList<Pair<Long, Long>>()
        var spanStart: Long? = null
        var spanEnd = 0L
        var dipStart: Long? = null
        fun closeSpan() {
            val s = spanStart
            if (s != null && (spanEnd - s) >= minimumSustainedMinutes * 60.0) spans.add(s to spanEnd)
            spanStart = null
            dipStart = null
        }
        for (sample in seg) {
            if (sample.bpm >= floor) {
                if (spanStart == null) spanStart = sample.ts
                spanEnd = sample.ts
                dipStart = null
            } else if (spanStart != null) {
                val d = dipStart ?: sample.ts.also { dipStart = it }
                if ((sample.ts - d) > AutoWorkoutDetector.maxDipS) closeSpan()
            }
        }
        closeSpan()

        if (spans.isEmpty()) {
            lines.add(
                "autoDetect why=noSustainedSpan " +
                    "(no contiguous run held >=${minimumSustainedMinutes}min above ${floor}bpm)",
            )
            lines.add("autoDetect result windows=0")
            return results to lines
        }

        val merged = ArrayList<Pair<Long, Long>>()
        var curStart = spans[0].first
        var curEnd = spans[0].second
        for (k in 1 until spans.size) {
            val next = spans[k]
            if ((next.first - curEnd) < AutoWorkoutDetector.mergeGapS) {
                curEnd = maxOf(curEnd, next.second)
            } else {
                merged.add(curStart to curEnd)
                curStart = next.first
                curEnd = next.second
            }
        }
        merged.add(curStart to curEnd)

        // Per-window verdict (the autoDetectWhy capture), mirroring detect steps 5-6. The motion series is
        // built the SAME way detect does (motionIntensityByTs), so the mean comparison matches exactly.
        val motion = if (hasMotion) AutoWorkoutDetector.motionIntensityByTs(gravity) else emptyMap()
        for ((start, end) in merged) {
            val durMin = ((end - start) / 60L).toInt()
            if (savedWorkouts.any { AutoWorkoutDetector.overlaps(start, end, it.first, it.second) }) {
                lines.add("autoDetect window durMin=$durMin verdict=dropped why=overlapsSavedWorkout")
                continue
            }
            if (motion.isNotEmpty()) {
                val inWin = motion.entries.filter { it.key in start..end }.map { it.value }
                val meanMotion = if (inWin.isEmpty()) 0.0 else inWin.sum() / inWin.size.toDouble()
                if (meanMotion < AutoWorkoutDetector.motionConfirmMean) {
                    lines.add(
                        "autoDetect window durMin=$durMin verdict=dropped why=motionNotConfirmed " +
                            "(mean=${Math.round(meanMotion * 1000.0) / 1000.0} < ${AutoWorkoutDetector.motionConfirmMean})",
                    )
                    continue
                }
            }
            lines.add("autoDetect window durMin=$durMin verdict=offered")
        }
        lines.add(
            "autoDetect result windows=${results.size} " +
                "(offered the most recent that is not saved or dismissed)",
        )
        return results to lines
    }

    /**
     * Compare one shadow duration policy with real, already-saved workout spans. This formats only
     * aggregate counts: it performs no I/O and cannot publish a candidate or mutate workout history.
     * Matching is deterministic and one-to-one: inputs are first put in canonical order, then a weighted
     * assignment maximises cardinality first and total overlap second. A match requires strictly positive
     * overlap; endpoint-only contact is not evidence that the detector found the labelled workout.
     *
     * When [hrForObservability] is supplied, a label is observable only when its longest recorded HR run
     * (no sample gap above the detector's 90-second dip tolerance) spans the shorter of the label duration
     * and this policy's qualification duration. This retains genuinely short labelled workouts as evidence,
     * but two isolated points cannot manufacture a policy miss. Unobservable labels are reported separately
     * and never counted as misses.
     */
    fun shadowComparisonLine(
        policyMinutes: Double,
        candidates: List<AutoWorkoutDetector.DetectedWorkout>,
        savedSpans: List<Pair<Long, Long>>,
        hrForObservability: List<HrSample>? = null,
    ): String {
        val orderedCandidates = candidates.sortedWith(
            compareBy<AutoWorkoutDetector.DetectedWorkout> { it.startSec }
                .thenBy { it.endSec }
                .thenBy { it.avgBpm }
                .thenBy { it.peakBpm }
                .thenBy { it.durationMin },
        )
        val (observableSaved, unobservableCount) = shadowLabelPartition(
            savedSpans,
            hrForObservability,
            policyMinutes,
        )
        val orderedSaved = observableSaved.sortedWith(
            compareBy<Pair<Long, Long>> { it.first }.thenBy { it.second },
        )
        val optionsByCandidate = List(orderedCandidates.size) { ArrayList<ShadowOption>() }
        for ((candidateIndex, candidate) in orderedCandidates.withIndex()) {
            for ((savedIndex, saved) in orderedSaved.withIndex()) {
                val overlapS = minOf(candidate.endSec, saved.second) -
                    maxOf(candidate.startSec, saved.first)
                if (overlapS <= 0L) continue
                optionsByCandidate[candidateIndex] += ShadowOption(
                    candidateIndex,
                    savedIndex,
                    overlapS,
                )
            }
        }
        val matchedPairs = maximumCardinalityOverlapPairs(optionsByCandidate, orderedSaved.size)
        val onsetErrors = ArrayList<Long>()
        val endErrors = ArrayList<Long>()
        for (option in matchedPairs) {
            val candidate = orderedCandidates[option.candidate]
            val saved = orderedSaved[option.saved]
            onsetErrors += abs(candidate.startSec - saved.first)
            endErrors += abs(candidate.endSec - saved.second)
        }
        val matched = matchedPairs.size
        val policy = if (policyMinutes % 1.0 == 0.0) {
            policyMinutes.toInt().toString()
        } else {
            policyMinutes.toString()
        }
        return "workout shadow policy=${policy}min candidates=${candidates.size} " +
            "matched=$matched missed=${orderedSaved.size - matched} unobservable=$unobservableCount " +
            "unmatched=${candidates.size - matched} " +
            "medianOnsetErrorS=${medianError(onsetErrors)} medianEndErrorS=${medianError(endErrors)}"
    }

    /** Split labels by whether the detector input has enough contiguous-in-time HR to evaluate this policy. */
    private fun shadowLabelPartition(
        savedSpans: List<Pair<Long, Long>>,
        hr: List<HrSample>?,
        policyMinutes: Double,
    ): Pair<List<Pair<Long, Long>>, Int> {
        if (hr == null) return savedSpans to 0
        val timestamps = hr.map { it.ts }.distinct().sorted()
        val observable = savedSpans.filter { span ->
            val labelDuration = maxOf(0L, span.second - span.first)
            val requiredCoverage = minOf(labelDuration.toDouble(), maxOf(0.0, policyMinutes * 60.0))
            var runStart: Long? = null
            var previousTimestamp: Long? = null
            var longestRun = 0L
            for (timestamp in timestamps) {
                if (timestamp < span.first) continue
                if (timestamp > span.second) break
                val previous = previousTimestamp
                val currentRunStart = if (
                    previous != null && timestamp - previous > AutoWorkoutDetector.maxDipS
                ) {
                    timestamp
                } else {
                    runStart ?: timestamp
                }
                runStart = currentRunStart
                longestRun = maxOf(longestRun, timestamp - currentRunStart)
                previousTimestamp = timestamp
            }
            longestRun > 0L && longestRun.toDouble() >= requiredCoverage
        }
        return observable to (savedSpans.size - observable.size)
    }

    /**
     * Hungarian assignment over candidate rows and saved-label + dummy columns. Every positive-overlap
     * edge receives a cardinality bonus larger than the maximum possible total overlap, making the scalar
     * objective exactly lexicographic: match count first, summed overlap second. Canonical input order and
     * lowest-column tie breaks keep equal optima deterministic across Kotlin and Swift.
     */
    private fun maximumCardinalityOverlapPairs(
        optionsByCandidate: List<List<ShadowOption>>,
        savedCount: Int,
    ): List<ShadowOption> {
        val candidateCount = optionsByCandidate.size
        val maxOverlap = optionsByCandidate.flatten().maxOfOrNull { it.overlapS }
        if (candidateCount == 0 || savedCount == 0 || maxOverlap == null) return emptyList()

        val maximumMatches = minOf(candidateCount, savedCount)
        val cardinalityBonus = maxOverlap * maximumMatches.toLong() + 1L
        val columnCount = savedCount + candidateCount
        val weights = Array(candidateCount) { LongArray(columnCount) }
        for (options in optionsByCandidate) {
            for (option in options) {
                weights[option.candidate][option.saved] = cardinalityBonus + option.overlapS
            }
        }

        // Minimum-cost Hungarian algorithm over negated weights. assignedRow[column] is 1-based.
        val rowPotential = LongArray(candidateCount + 1)
        val columnPotential = LongArray(columnCount + 1)
        val assignedRow = IntArray(columnCount + 1)
        val previousColumn = IntArray(columnCount + 1)
        val infinity = Long.MAX_VALUE / 4L
        for (row in 1..candidateCount) {
            assignedRow[0] = row
            var currentColumn = 0
            val minimumReducedCost = LongArray(columnCount + 1) { infinity }
            val usedColumn = BooleanArray(columnCount + 1)
            do {
                usedColumn[currentColumn] = true
                val currentRow = assignedRow[currentColumn]
                var delta = infinity
                var nextColumn = 0
                for (column in 1..columnCount) {
                    if (usedColumn[column]) continue
                    val cost = -weights[currentRow - 1][column - 1]
                    val reducedCost = cost - rowPotential[currentRow] - columnPotential[column]
                    if (reducedCost < minimumReducedCost[column]) {
                        minimumReducedCost[column] = reducedCost
                        previousColumn[column] = currentColumn
                    }
                    if (minimumReducedCost[column] < delta) {
                        delta = minimumReducedCost[column]
                        nextColumn = column
                    }
                }
                for (column in 0..columnCount) {
                    if (usedColumn[column]) {
                        rowPotential[assignedRow[column]] += delta
                        columnPotential[column] -= delta
                    } else {
                        minimumReducedCost[column] -= delta
                    }
                }
                currentColumn = nextColumn
            } while (assignedRow[currentColumn] != 0)

            do {
                val prior = previousColumn[currentColumn]
                assignedRow[currentColumn] = assignedRow[prior]
                currentColumn = prior
            } while (currentColumn != 0)
        }

        return (1..savedCount).mapNotNull { savedColumn ->
            val candidateRow = assignedRow[savedColumn]
            if (candidateRow == 0) null else optionsByCandidate[candidateRow - 1]
                .firstOrNull { it.saved == savedColumn - 1 }
        }.sortedWith(compareBy<ShadowOption> { it.candidate }.thenBy { it.saved })
    }

    /** Median of non-negative whole-second errors; even samples can produce a `.5` value. */
    private fun medianError(values: List<Long>): String {
        if (values.isEmpty()) return "n/a"
        val sorted = values.sorted()
        val middle = sorted.size / 2
        if (sorted.size % 2 == 1) return sorted[middle].toString()
        val lower = sorted[middle - 1]
        val upper = sorted[middle]
        val whole = lower / 2 + upper / 2
        return if (lower % 2L == upper % 2L) {
            (whole + lower % 2L).toString()
        } else {
            "$whole.5"
        }
    }
}

/**
 * Pure line formatters + the live-readout parser for the Workouts & GPS test mode. Kotlin twin of the Swift
 * WorkoutsTrace / WorkoutsReadout. The app emitters own the live state; these own the line SHAPE so both
 * platforms read identically. No state, no IO, no PII. No em-dashes.
 */
object WorkoutsTrace {

    /** A session-lifecycle line. [event] is "start" / "end" / "discarded"; the counts are the captured HR
     *  window size and (for an end) the duration + accepted GPS points. Sport is the normalised key. */
    fun sessionLine(
        event: String,
        sportKey: String,
        hrSamples: Int,
        durationSec: Int? = null,
        gpsPoints: Int? = null,
    ): String {
        val sb = StringBuilder("session event=$event sport=$sportKey hrSamples=$hrSamples")
        if (durationSec != null) sb.append(" durationSec=$durationSec")
        if (gpsPoints != null) sb.append(" gpsPoints=$gpsPoints")
        return sb.toString()
    }

    /**
     * A GPS-fix-progress line: raw fixes seen, how many the filter accepted, and the running distance.
     *
     * [rawFixes] is OPTIONAL: macOS sees the pre-filter raw stream and passes a real count so the line shows
     * a true accept rate. Android's LocationTracker pre-filters upstream, so the raw count is NOT available
     * at the GpsSession seam (every fix here is already accepted); it passes null and the line renders
     * `rawFixes=n/a` rather than implying an accept rate the platform cannot measure. Mirrors Swift gpsLine.
     */
    fun gpsLine(rawFixes: Int?, acceptedPoints: Int, distanceM: Double): String =
        "gps rawFixes=${rawFixes?.toString() ?: "n/a"} accepted=$acceptedPoints " +
            "distanceM=${Math.round(distanceM)} (filter: accuracy+speed gate)"

    /** A cross-source dedup decision line: two same-activity rows collapsed to the richer one. */
    fun dedupLine(
        sportKey: String,
        keptSource: String,
        droppedSource: String,
        keptRichness: Int,
        droppedRichness: Int,
    ): String =
        "dedup sport=$sportKey kept=$keptSource(richness=$keptRichness) " +
            "dropped=$droppedSource(richness=$droppedRichness) (same activity, richer kept)"

    /**
     * An analytics detected-bout decision line (#975/#2187): the IntelligenceEngine derives a bout from raw
     * HR for metrics only. A non-overlap is `analyticsOnly`; an overlap with a real manual/imported session
     * is `droppedOverlap` or `droppedOverlapBackfilled` when missing fields were enriched. `durMin` is the
     * whole-minute bout length; on an overlap, `overlapSource` names the real row it collided with. No PII
     * (a source label + minutes + bpm only). Swift twin WorkoutsTrace.detectedBoutLine.
     */
    fun detectedBoutLine(
        verdict: String,
        durMin: Int,
        avgBpm: Int,
        overlapSource: String? = null,
    ): String {
        var line = "detectedBout verdict=$verdict durMin=$durMin avgBpm=$avgBpm"
        if (overlapSource != null) line += " overlapSource=$overlapSource"
        return line
    }
}

/**
 * Pure values for the Workouts & GPS live-readout panel. Kotlin twin of the Swift WorkoutsReadout. Parses
 * the WORKOUTS-tagged log tail the emitters write. No state, no IO, no em-dashes. (Android defers the Compose
 * readout panel for ALL modes, matching the existing split; this twin exists for parity + tests.)
 */
object WorkoutsReadout {

    /** The last session summary for the `lastSessionSummary` id: the most recent session-lifecycle line's
     *  fragment, or null when none is present. */
    fun lastSessionSummary(taggedTail: List<String>): String? {
        for (line in taggedTail.asReversed()) {
            val i = line.indexOf("session ")
            if (i >= 0) {
                val frag = line.substring(i + "session ".length).trim()
                if (frag.isNotEmpty()) return frag
            }
        }
        return null
    }
}
