package com.noop.analytics

import java.time.LocalDate
import kotlin.math.abs
import kotlin.math.roundToInt

// CyclePhaseEngine.kt — on-device menstrual-cycle PHASE AWARENESS from the nightly skin-temperature series,
// corroborated by the luteal resting-HR rise and the luteal HRV drop.
// Byte-for-byte mirror of Strand/Packages/StrandAnalytics/Sources/StrandAnalytics/CyclePhaseEngine.swift.
//
// INDEPENDENT implementation of a publicly documented method (wrist skin-temperature cycle tracking,
// e.g. PMC11294004, plus the biphasic-ovulatory-shift literature): skin temperature runs ~0.3–0.5 °C
// HIGHER in the luteal phase than the follicular phase, with a nadir around ovulation, mirrored by a
// luteal RESTING-HR RISE and a luteal HRV (RMSSD) DROP. NOOP re-derives this from the user's OWN banked
// signals against their OWN baseline.
//
// WELLNESS / AWARENESS ONLY — APPROXIMATE. NOT contraception, NOT a fertility/ovulation predictor, NOT a
// medical device, NOT a diagnosis. Never a "fertile window" / "safe days", never a single confident period
// DATE (only a probabilistic WINDOW), never a condition verdict — flat/irregular → "no clear pattern".
object CyclePhaseEngine {

    // ── Tuning constants (pinned by test; mirror the Swift twin exactly) ──
    const val wTemp: Double = 0.6
    const val wRHR: Double = 0.2
    const val wHRV: Double = 0.2
    const val elevationK: Double = 0.5
    const val minCycleDays: Int = 21
    const val maxCycleDays: Int = 40
    const val defaultCycleDays: Int = 28
    const val minNightsToClassify: Int = 42
    const val periOvulatoryHalfWidth: Int = 2

    /** Standing awareness-only line shown on every cycle surface (legal/ethical framing). */
    const val awarenessLine =
        "For awareness only. Not a medical device, not contraception, not a substitute for professional care."

    // ── Inputs ──

    /**
     * One night's already-standardized inputs. [tempZ]/[rhrZ]/[hrvZ] are z-scores from
     * Baselines.deviation against each metric's personal baseline. [day] is a "yyyy-MM-dd" key,
     * oldest→newest in the list. A missing signal is null and doesn't contribute to that night's index.
     */
    data class Night(
        val day: String,
        val tempZ: Double?,
        val rhrZ: Double?,
        val hrvZ: Double?,
    )

    // ── Output ──

    enum class Phase(val raw: String) {
        FOLLICULAR("follicular"),
        PERI_OVULATORY("periOvulatory"),
        LUTEAL("luteal"),
        UNKNOWN("unknown"),
        LEARNING("learning"),
    }

    enum class Confidence(val raw: String) {
        LEARNING("learning"),
        BUILDING("building"),
        SOLID("solid"),
    }

    data class ShiftMarker(val day: String)

    data class NextPeriodWindow(val earliestDay: String, val latestDay: String)

    data class Result(
        val phase: Phase,
        val confidence: Confidence,
        val cycleDayLow: Int?,
        val cycleDayHigh: Int?,
        val cycleLengthDays: Int?,
        val nextPeriodWindow: NextPeriodWindow?,
        val shiftMarkers: List<ShiftMarker>,
        val note: String,
    )

    // ── Classify ──

    /**
     * Classify the most recent night from the trailing series. [baselineUsable] is the caller's
     * BaselineState.usable. [loggedPeriodStarts] are optional "yyyy-MM-dd" period-start days; the most
     * recent anchors cycle-day 1 and is CROSS-VALIDATED against the detected shift.
     */
    fun classify(
        nights: List<Night>,
        baselineUsable: Boolean,
        loggedPeriodStarts: List<String> = emptyList(),
    ): Result {
        if (!baselineUsable || nights.size < minNightsToClassify) {
            return Result(Phase.LEARNING, Confidence.LEARNING, null, null, null, null, emptyList(),
                "Learning your pattern from your nightly temperature — keep wearing it overnight.")
        }

        val fused: List<Pair<String, Double?>> = nights.map { n ->
            n.day to fusedIndex(n.tempZ, n.rhrZ, n.hrvZ)
        }
        val values = fused.mapNotNull { it.second }
        if (values.size < minNightsToClassify) {
            return Result(Phase.LEARNING, Confidence.LEARNING, null, null, null, null, emptyList(),
                "Learning your pattern from your nightly temperature — keep wearing it overnight.")
        }

        val center = median(values)
        val spread = maxOf(1e-9, medianAbsoluteDeviation(values, center))

        val elevated: List<Boolean> = fused.map { row ->
            val v = row.second ?: return@map false
            (v - center) >= elevationK * spread
        }

        val onsets = mutableListOf<Int>()
        for (i in fused.indices) {
            if (elevated[i] && (i == 0 || !elevated[i - 1])) onsets.add(i)
        }
        val shiftMarkers = onsets.map { ShiftMarker(fused[it].first) }

        val lastOnsetIdx = onsets.lastOrNull()
            ?: return Result(Phase.UNKNOWN, Confidence.BUILDING, null, null, null, null, shiftMarkers,
                "No clear temperature pattern yet — this can happen with irregular cycles, " +
                    "hormonal birth control, or shift work.")

        val onsetGaps = mutableListOf<Int>()
        if (onsets.size >= 2) {
            for (k in 1 until onsets.size) {
                daysBetween(fused[onsets[k - 1]].first, fused[onsets[k]].first)?.let { onsetGaps.add(it) }
            }
        }
        val medianGap = if (onsetGaps.isEmpty()) null else median(onsetGaps.map { it.toDouble() }).roundToInt()
        val cycleLength: Int? = medianGap?.takeIf { it in minCycleDays..maxCycleDays }
        val confidence = if (cycleLength != null) Confidence.SOLID else Confidence.BUILDING

        val lastNightDay = fused.last().first
        var note = ""
        var anchorDay = fused[lastOnsetIdx].first
        var anchoredByLog = false
        mostRecentOnOrBefore(loggedPeriodStarts, lastNightDay)?.let { loggedStart ->
            anchorDay = loggedStart
            anchoredByLog = true
            // Implausible onset offset OR a logged start older than a full cycle before the latest night
            // (a newer period is overdue) means the log is likely mistimed — FLAG it, don't trust blindly.
            val delta = daysBetween(loggedStart, fused[lastOnsetIdx].first)
            val sinceLog = daysBetween(loggedStart, lastNightDay) ?: 0
            if ((delta != null && (delta < 0 || delta > maxCycleDays)) || sinceLog > maxCycleDays) {
                note = "Your temperature shift came at a different time than your logged date — " +
                    "the logged start may be off."
            }
        }

        val daysSinceAnchor = daysBetween(anchorDay, lastNightDay) ?: 0
        val cycleDayLow: Int?
        val cycleDayHigh: Int?
        if (anchoredByLog) {
            val d = maxOf(1, daysSinceAnchor + 1)
            cycleDayLow = maxOf(1, d - 1); cycleDayHigh = d + 1
        } else {
            val lutealStartDay = (cycleLength ?: defaultCycleDays) / 2
            val d = lutealStartDay + daysSinceAnchor
            cycleDayLow = maxOf(1, d - 2); cycleDayHigh = d + 2
        }

        val daysSinceOnset = daysBetween(fused[lastOnsetIdx].first, lastNightDay) ?: 0
        val phase: Phase = if (elevated[fused.size - 1]) {
            if (daysSinceOnset <= periOvulatoryHalfWidth) Phase.PERI_OVULATORY else Phase.LUTEAL
        } else {
            if (daysSinceOnset <= periOvulatoryHalfWidth) Phase.PERI_OVULATORY else Phase.FOLLICULAR
        }

        var window: NextPeriodWindow? = null
        if (cycleLength != null) {
            val earliest = shiftDay(anchorDay, cycleLength - 2)
            val latest = shiftDay(anchorDay, cycleLength + 2)
            if (earliest != null && latest != null && latest >= lastNightDay) {
                window = NextPeriodWindow(maxOf(lastNightDay, earliest), latest)
            }
        }

        if (note.isEmpty()) note = phaseNote(phase)

        return Result(phase, confidence, cycleDayLow, cycleDayHigh, cycleLength, window, shiftMarkers, note)
    }

    // ── Fusion ──

    /** Weighted fused luteal index for one night (HRV z negated; renormalised over present signals). */
    fun fusedIndex(tempZ: Double?, rhrZ: Double?, hrvZ: Double?): Double? {
        var weighted = 0.0
        var wSum = 0.0
        if (tempZ != null) { weighted += wTemp * tempZ; wSum += wTemp }
        if (rhrZ != null) { weighted += wRHR * rhrZ; wSum += wRHR }
        if (hrvZ != null) { weighted += wHRV * (-hrvZ); wSum += wHRV }
        if (wSum <= 0) return null
        return weighted / wSum
    }

    // ── Copy ──

    internal fun phaseNote(phase: Phase): String = when (phase) {
        Phase.FOLLICULAR -> "Follicular range — temperature sitting at your baseline."
        Phase.PERI_OVULATORY -> "Around your mid-cycle shift — temperature is turning."
        Phase.LUTEAL -> "Luteal range — temperature is running above your baseline."
        Phase.UNKNOWN -> "No clear pattern yet."
        Phase.LEARNING -> "Learning your pattern — keep wearing it overnight."
    }

    // ── Small stats / day helpers (self-contained, parity-clean) ──

    internal fun median(xs: List<Double>): Double {
        if (xs.isEmpty()) return 0.0
        val s = xs.sorted()
        val n = s.size
        return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    internal fun medianAbsoluteDeviation(xs: List<Double>, center: Double): Double {
        if (xs.isEmpty()) return 0.0
        return median(xs.map { abs(it - center) })
    }

    /** Calendar days from [a] to [b] ("yyyy-MM-dd"), b − a. null if unparseable. UTC, pure. */
    internal fun daysBetween(a: String, b: String): Int? {
        val da = parseDay(a) ?: return null
        val db = parseDay(b) ?: return null
        return (db.toEpochDay() - da.toEpochDay()).toInt()
    }

    /** Most recent entry in [days] on or before [day] (ISO string compare is valid). */
    internal fun mostRecentOnOrBefore(days: List<String>, day: String): String? =
        days.filter { it <= day }.maxOrNull()

    internal fun parseDay(day: String): LocalDate? = runCatching { LocalDate.parse(day) }.getOrNull()

    /** Shift a "yyyy-MM-dd" by [delta] days. UTC, deterministic. null if unparseable. */
    internal fun shiftDay(day: String, delta: Int): String? =
        parseDay(day)?.plusDays(delta.toLong())?.toString()
}
