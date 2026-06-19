package com.noop.analytics

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

// CircadianEngine.kt — on-device body-clock phase estimate + a jet-lag / shift-work LIGHT & SLEEP-TIMING plan.
// Byte-for-byte mirror of Strand/Packages/StrandAnalytics/Sources/StrandAnalytics/CircadianEngine.swift.
//
// INDEPENDENT implementation of published methods:
//   • Single-component COSINOR (Halberg's cosine fit) over the rest-activity rhythm → acrophase + amplitude.
//     The accelerometer rest-activity rhythm is the primary phase signal; the nightly skin-temperature
//     minimum corroborates it (wrist skin temp runs broadly ANTI-phase to core temperature; CBTmin is the
//     canonical phase marker ~2–3 h before habitual wake).
//   • Phase-response-curve DIRECTION rule for the advisory: ADVANCE (eastward / earlier) → morning bright
//     light, dim evenings, earlier sleep, stepped ~1 h/day; DELAY (westward / later) → the reverse.
//
// WELLNESS / BEHAVIOURAL AWARENESS ONLY — APPROXIMATE. Light + sleep TIMING only. NEVER melatonin or any
// supplement/drug; never a guarantee. Irregular schedules → "your rhythm is hard to read right now."
object CircadianEngine {

    // ── Tuning constants (pinned by test; mirror the Swift twin exactly) ──
    const val minDaysForFit: Int = 7
    const val goodDaysForFit: Int = 14
    const val minRelativeAmplitude: Double = 0.10
    const val maxShiftPerDayHours: Double = 1.0
    const val cbtMinBeforeWakeHours: Double = 2.5
    const val acrophaseAfterCbtMinHours: Double = 12.0

    // ── Inputs ──

    /** One per-hour rest-activity sample: local clock hour (0..<24, may be fractional) + motion volume. */
    data class ActivityBin(val hour: Double, val activity: Double)

    // ── Cosinor ──

    /** A single-component cosinor fit: y ≈ mesor + amplitude·cos(2π(hour − acrophaseHours)/24). */
    data class CosinorFit(
        val mesor: Double,
        val amplitude: Double,
        val acrophaseHours: Double,
    )

    /** Fit a single 24 h cosine to the (hour, activity) bins by ordinary least squares. null if degenerate. */
    fun cosinor(bins: List<ActivityBin>): CosinorFit? {
        if (bins.size < 3) return null
        val w = 2.0 * PI / 24.0
        val n = bins.size.toDouble()

        var sumY = 0.0; var sumC = 0.0; var sumS = 0.0
        var sumCC = 0.0; var sumSS = 0.0; var sumCS = 0.0
        var sumYC = 0.0; var sumYS = 0.0
        for (b in bins) {
            val c = cos(w * b.hour)
            val s = sin(w * b.hour)
            val y = b.activity
            sumY += y; sumC += c; sumS += s
            sumCC += c * c; sumSS += s * s; sumCS += c * s
            sumYC += y * c; sumYS += y * s
        }

        // Cramer's rule on the 3×3 normal equations for (M, β, γ).
        val a11 = n; val a12 = sumC; val a13 = sumS
        val a21 = sumC; val a22 = sumCC; val a23 = sumCS
        val a31 = sumS; val a32 = sumCS; val a33 = sumSS
        val det = a11 * (a22 * a33 - a23 * a32) -
            a12 * (a21 * a33 - a23 * a31) +
            a13 * (a21 * a32 - a22 * a31)
        if (abs(det) <= 1e-12) return null

        val detM = sumY * (a22 * a33 - a23 * a32) -
            a12 * (sumYC * a33 - a23 * sumYS) +
            a13 * (sumYC * a32 - a22 * sumYS)
        val detB = a11 * (sumYC * a33 - a23 * sumYS) -
            sumY * (a21 * a33 - a23 * a31) +
            a13 * (a21 * sumYS - sumYC * a31)
        val detG = a11 * (a22 * sumYS - sumYC * a32) -
            a12 * (a21 * sumYS - sumYC * a31) +
            sumY * (a21 * a32 - a22 * a31)

        val m = detM / det
        val beta = detB / det
        val gamma = detG / det

        val amplitude = sqrt(beta * beta + gamma * gamma)
        var phase = (atan2(gamma, beta) / w) % 24.0
        if (phase < 0) phase += 24.0
        return CosinorFit(m, amplitude, phase)
    }

    // ── Phase estimate ──

    enum class PhaseConfidence(val raw: String) {
        UNREADABLE("unreadable"),
        WIDE("wide"),
        SOLID("solid"),
    }

    data class PhaseEstimate(
        val tempMinHour: Double,
        val acrophaseHours: Double,
        val offsetVsScheduleMinutes: Double,
        val confidence: PhaseConfidence,
        val note: String,
    )

    /** Estimate the body-clock phase from a pooled activity profile and the user's habitual wake time. */
    fun estimatePhase(
        bins: List<ActivityBin>,
        daysObserved: Int,
        habitualWakeHour: Double,
        observedTempMinHour: Double? = null,
    ): PhaseEstimate? {
        val fit = cosinor(bins) ?: return null

        val relativeAmplitude = if (fit.mesor != 0.0) fit.amplitude / abs(fit.mesor) else 0.0
        if (daysObserved < minDaysForFit || relativeAmplitude < minRelativeAmplitude) {
            val tmin = observedTempMinHour ?: wrap24(fit.acrophaseHours - acrophaseAfterCbtMinHours)
            return PhaseEstimate(tmin, fit.acrophaseHours, 0.0, PhaseConfidence.UNREADABLE,
                "Your rhythm is hard to read right now — keep wearing it for a clearer picture.")
        }

        val derivedTempMin = wrap24(fit.acrophaseHours - acrophaseAfterCbtMinHours)
        val tempMinHour = observedTempMinHour ?: derivedTempMin

        val idealTempMin = wrap24(habitualWakeHour - cbtMinBeforeWakeHours)
        val offsetHours = signedHourDelta(idealTempMin, tempMinHour)
        val offsetMinutes = offsetHours * 60.0

        val confidence = if (daysObserved >= goodDaysForFit) PhaseConfidence.SOLID else PhaseConfidence.WIDE
        val lean = when {
            offsetMinutes > 20 -> "later (a night-owl lean)"
            offsetMinutes < -20 -> "earlier (a morning-lark lean)"
            else -> "well-aligned with your schedule"
        }
        val note = "Your body clock looks $lean."

        return PhaseEstimate(tempMinHour, fit.acrophaseHours, offsetMinutes, confidence, note)
    }

    // ── Jet-lag / shift planner ──

    enum class ShiftDirection(val raw: String) {
        ADVANCE("advance"),
        DELAY("delay"),
        NONE("none"),
    }

    data class DayPlan(
        val dayIndex: Int,
        val brightLightStartHour: Double,
        val brightLightEndHour: Double,
        val dimFromHour: Double,
        val targetSleepHour: Double,
        val targetWakeHour: Double,
        val guidance: String,
    )

    data class JetLagPlan(
        val direction: ShiftDirection,
        val totalShiftHours: Double,
        val estimatedDays: Int,
        val days: List<DayPlan>,
        val note: String,
    )

    /**
     * Build a stepped light + sleep-timing plan to absorb a required clock shift. [shiftHours] POSITIVE =
     * ADVANCE (earlier; eastward), NEGATIVE = DELAY (later; westward).
     */
    fun planShift(shiftHours: Double, currentSleepHour: Double, currentWakeHour: Double): JetLagPlan {
        val magnitude = abs(shiftHours)
        if (magnitude < 0.5) {
            return JetLagPlan(ShiftDirection.NONE, 0.0, 0, emptyList(),
                "No meaningful body-clock shift needed — you're about aligned.")
        }

        val advancing = shiftHours > 0
        val direction = if (advancing) ShiftDirection.ADVANCE else ShiftDirection.DELAY
        val days = ceil(magnitude / maxShiftPerDayHours).toInt()

        val plan = mutableListOf<DayPlan>()
        var cumulative = 0.0
        for (i in 1..days) {
            val stepRemaining = magnitude - cumulative
            val step = minOf(maxShiftPerDayHours, stepRemaining)
            cumulative += step
            val signed = if (advancing) -cumulative else cumulative
            val sleep = wrap24(currentSleepHour + signed)
            val wake = wrap24(currentWakeHour + signed)

            val brightStart: Double
            val brightEnd: Double
            val dimFrom: Double
            val guidance: String
            if (advancing) {
                brightStart = wake
                brightEnd = wrap24(wake + 2.0)
                dimFrom = wrap24(sleep - 2.0)
                guidance = "Get bright light early after waking and keep the evening dim — this nudges your " +
                    "clock earlier. Aim for lights-out around ${clock(sleep)}."
            } else {
                brightStart = wrap24(sleep - 3.0)
                brightEnd = wrap24(sleep - 1.0)
                dimFrom = wrap24(wake)
                guidance = "Get bright light in the evening and go easy on bright morning light — this nudges " +
                    "your clock later. Aim for lights-out around ${clock(sleep)}."
            }
            plan.add(DayPlan(i, brightStart, brightEnd, dimFrom, sleep, wake, guidance))
        }

        val dirWord = if (advancing) "earlier" else "later"
        val magStr = formatOneDecimal(magnitude)
        val rate = if (maxShiftPerDayHours == 1.0) "an hour" else "$maxShiftPerDayHours h"
        val note = "Shifting your clock $magStr h $dirWord, about $rate a day. Light and sleep " +
            "timing only."
        return JetLagPlan(direction, magnitude, days, plan, note)
    }

    // ── Helpers ──

    /** Wrap an hour value into [0, 24). */
    internal fun wrap24(h: Double): Double {
        var x = h % 24.0
        if (x < 0) x += 24.0
        return x
    }

    /** Signed shortest delta in hours from [a] to [b] on the 24 h clock, in (−12, 12]. */
    internal fun signedHourDelta(a: Double, b: Double): Double {
        var d = (b - a) % 24.0
        if (d > 12.0) d -= 24.0
        if (d <= -12.0) d += 24.0
        return d
    }

    /** Format a clock hour as "HH:MM" (24 h). Locale-free for cross-platform string parity. */
    internal fun clock(hour: Double): String {
        val h = wrap24(hour)
        var hh = h.toInt()
        var mm = ((h - hh.toDouble()) * 60.0).roundToInt()
        if (mm == 60) { mm = 0; hh = (hh + 1) % 24 }
        val hp = hh.toString().padStart(2, '0')
        val mpad = mm.toString().padStart(2, '0')
        return "$hp:$mpad"
    }

    /** "%.1f" without locale surprises (Swift String(format:) uses '.'); mirror it for parity. */
    internal fun formatOneDecimal(x: Double): String {
        val scaled = (x * 10.0).roundToInt()
        val whole = scaled / 10
        val frac = abs(scaled % 10)
        return "$whole.$frac"
    }
}
