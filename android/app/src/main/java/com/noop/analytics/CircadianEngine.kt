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
    /**
     * #982 — RELATIVE, applied to mean HR (mesor ~45-75 bpm), not to a near-zero-mesor motion volume. The
     * effective bar is `0.10 x mesor`: ~6.5 bpm at a 65 bpm mesor, ~4.5 bpm at 45. It scales WITH the
     * mesor, so a low-resting wearer faces a LOWER absolute bar — the opposite of the concern in #982.
     * The VALUE is still not re-tuned — every candidate remains unvalidated. What changed is the SHAPE:
     * [minAbsoluteAmplitudeBpm] now passes a swing that is large enough in bpm regardless of mesor,
     * because a measured wearer showed the relative test refusing a coherent rhythm purely for having a
     * high baseline. "Nobody is currently silenced by it" was true when written and is no longer.
     * `CircadianEngineTest` pins what it costs at each mesor. Mirrors the Swift twin exactly.
     */
    const val minRelativeAmplitude: Double = 0.10
    /**
     * Absolute amplitude (bpm) that reads as rhythmic whatever the mesor — the relative bar's escape hatch.
     *
     * The relative test scales the requirement WITH resting HR, so the identical swing is accepted on one
     * body and refused on another: 5.5 bpm passes at a 55 bpm mesor and fails at 74.7. That is not a
     * judgement about the rhythm, it is a judgement about the baseline, and a measured wearer sat exactly
     * there — 5.5 bpm on a 74.7 bpm mesor, acrophase 16.1 h implying a CBTmin near 04:06, a textbook phase
     * rather than noise. [minRelativeAmplitude]'s own note called for precisely that observation ("a
     * wearer whose amplitude is disproportionately small for their mesor") before the shape could be
     * revisited.
     *
     * 4.5 bpm is NOT a new tuning constant: it is the absolute amplitude the relative gate ALREADY accepts
     * at the bottom of the ~45-75 bpm mesor range it was described against. The rule this encodes is
     * internal consistency — an amplitude good enough for some wearer is good enough for all — so the
     * change is strictly more permissive and no one who reads rhythmic today stops.
     * Mirrors the Swift twin exactly.
     */
    const val minAbsoluteAmplitudeBpm: Double = 4.5
    const val maxShiftPerDayHours: Double = 1.0
    const val cbtMinBeforeWakeHours: Double = 2.5
    const val acrophaseAfterCbtMinHours: Double = 12.0
    /**
     * Population-typical wake hour, used ONLY to place the chronotype reference point.
     *
     * [PhaseEstimate.offsetVsScheduleMinutes] compares the clock to the USER'S OWN schedule, so it cannot
     * name a chronotype: someone reliably asleep 03:00-11:00 has an offset near zero and would read
     * "intermediate" while being strongly evening-type. A named lean needs an ABSOLUTE phase, so it is
     * bucketed from [PhaseEstimate.tempMinHour] against a population reference instead.
     * Mirrors the Swift twin exactly.
     */
    const val chronotypeReferenceWakeHour: Double = 7.0
    /**
     * Half-width of the "intermediate" band around the reference CBTmin, in hours.
     *
     * Deliberately wide. `tempMinHour` is derived from an activity cosinor (`acrophase - 12 h`) unless a
     * measured `observedTempMinHour` is supplied, and NO production caller supplies one today — so this is
     * a lean inferred from movement, not a thermal measurement. A one-hour band either side keeps the
     * three buckets coarse enough to be honest about that. Mirrors the Swift twin exactly.
     */
    const val chronotypeBandHours: Double = 1.0

    // ── Inputs ──

    /**
     * One per-hour rest-activity sample: local clock hour (0..<24, may be fractional) + the rhythm signal.
     *
     * #982 — this said "motion volume". It has never been fed that: the only production caller pools
     * per-hour MEAN HEART RATE in bpm, and that is the right choice on this hardware (WHOOP 4.0 motion is
     * too sparse to stage sleep at all, #345). The domain matters because [minRelativeAmplitude] gates on
     * `amplitude / |mesor|` and HR arrives with a large DC offset motion does not have — see that constant.
     */
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
        // Rhythmic on EITHER measure: a proportional swing, or an absolute one large enough to read on any
        // baseline. See [minAbsoluteAmplitudeBpm] for why the relative test alone was self-inconsistent.
        val rhythmic =
            relativeAmplitude >= minRelativeAmplitude || fit.amplitude >= minAbsoluteAmplitudeBpm
        if (daysObserved < minDaysForFit || !rhythmic) {
            val tmin = observedTempMinHour ?: wrap24(fit.acrophaseHours - acrophaseAfterCbtMinHours)
            return PhaseEstimate(tmin, fit.acrophaseHours, 0.0, PhaseConfidence.UNREADABLE,
                "Your rhythm is hard to read right now - keep wearing it for a clearer picture.")
        }

        val derivedTempMin = wrap24(fit.acrophaseHours - acrophaseAfterCbtMinHours)
        val tempMinHour = observedTempMinHour ?: derivedTempMin

        val idealTempMin = wrap24(habitualWakeHour - cbtMinBeforeWakeHours)
        val offsetHours = signedHourDelta(idealTempMin, tempMinHour)
        val offsetMinutes = offsetHours * 60.0

        // SOLID means strong on BOTH axes, not just enough days. A rhythm admitted by
        // [minAbsoluteAmplitudeBpm] alone is real but modest, and a smaller swing pins its acrophase less
        // tightly — so it stays WIDE. That matters because WIDE is what withholds [chronotype], which
        // names a category off exactly that acrophase: widening the readable gate should give more people
        // a body clock, not give a thinner fit a firmer label.
        val confidence = if (daysObserved >= goodDaysForFit && relativeAmplitude >= minRelativeAmplitude) {
            PhaseConfidence.SOLID
        } else {
            PhaseConfidence.WIDE
        }
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
                "No meaningful body-clock shift needed - you're about aligned.")
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
                guidance = "Get bright light early after waking and keep the evening dim - this nudges your " +
                    "clock earlier. Aim for lights-out around ${clock(sleep)}."
            } else {
                brightStart = wrap24(sleep - 3.0)
                brightEnd = wrap24(sleep - 1.0)
                dimFrom = wrap24(wake)
                guidance = "Get bright light in the evening and go easy on bright morning light - this nudges " +
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

    /**
     * A coarse, ABSOLUTE body-clock category: where the temperature minimum sits on the clock.
     *
     * NOT the "chronotype lean" wording used elsewhere. [estimatePhase] builds a `lean` string from
     * [PhaseEstimate.offsetVsScheduleMinutes] ("a night-owl lean"), and the v5 skin-temp design spec
     * defines chronotype lean as "earlier/later than your sleep schedule implies" — both RELATIVE to the
     * wearer's own schedule. This is relative to the CLOCK, and the two genuinely disagree: a consistent
     * 03:00-11:00 sleeper is well-aligned by the relative read and EVENING by this one. Keep the
     * vocabularies disjoint in anything user-facing, or the two readings look like a contradiction (#1409).
     *
     * Three buckets, not a score: the underlying phase estimate is an activity fit, and a finer grain
     * would imply precision it does not have. Twin of Swift `CircadianEngine.Chronotype`.
     */
    enum class Chronotype(val raw: String) {
        MORNING("morning"),          // CBTmin earlier than the population reference
        INTERMEDIATE("intermediate"),
        EVENING("evening"),          // CBTmin later than the population reference
    }

    /**
     * The reference CBTmin clock hour a lean is measured against: the population wake hour minus the same
     * [cbtMinBeforeWakeHours] the phase estimator already uses, so the anchor moves with the engine's own
     * model rather than being a second, independently-drifting constant.
     */
    val chronotypeAnchorHour: Double get() = wrap24(chronotypeReferenceWakeHour - cbtMinBeforeWakeHours)

    /** A chronotype-ideal sleep window on the 24 h clock. Twin of the Swift tuple return. */
    data class IdealSleepWindow(val bedHour: Double, val wakeHour: Double)

    /**
     * The chronotype-ideal sleep window for a night of [durationHours], as clock hours.
     *
     * Anchored on the temperature minimum: a well-entrained sleeper wakes about [cbtMinBeforeWakeHours]
     * after CBTmin, so the ideal wake is `tempMinHour + cbtMinBeforeWakeHours` and the ideal bedtime is
     * that minus the night's own length.
     *
     * USING THE ACTUAL DURATION IS THE POINT. Giving the ideal arc the same length as the real one makes
     * the comparison purely about PHASE — did you sleep at the right TIME — so a short night reads as
     * aligned-but-short rather than as misaligned. Feeding a "needed" duration instead would fold two
     * different failures into one arc and make a debt look like a body-clock problem.
     *
     * null for a non-positive or impossible duration; a window longer than a day cannot be placed on a
     * 24 h ring, and silently wrapping it would draw a full circle that means nothing.
     * Mirrors the Swift twin exactly.
     */
    fun idealSleepWindow(tempMinHour: Double, durationHours: Double): IdealSleepWindow? {
        if (durationHours <= 0.0 || durationHours >= 24.0) return null
        val wake = wrap24(tempMinHour + cbtMinBeforeWakeHours)
        return IdealSleepWindow(bedHour = wrap24(wake - durationHours), wakeHour = wake)
    }

    /**
     * Signed hours the ACTUAL sleep window sits later (+) or earlier (−) than the chronotype-ideal one.
     *
     * Deliberately NOT [PhaseEstimate.offsetVsScheduleMinutes]. That field compares the body clock to the
     * wearer's own SCHEDULE; this compares the night actually slept to where the CLOCK wanted it. A dial
     * that draws an actual arc against an ideal arc must caption itself with the distance between those
     * two arcs, or the number contradicts the picture — the two disagree exactly when someone keeps a
     * consistent schedule that does not suit their clock, which is the case the dial exists to show.
     *
     * Anchored on wake rather than bedtime because [idealSleepWindow] builds the ideal window from the
     * wake end; comparing bedtimes would fold the night's DURATION into a phase reading.
     * Mirrors the Swift twin exactly.
     */
    fun sleepWindowOffsetHours(tempMinHour: Double, actualWakeHour: Double): Double =
        signedHourDelta(wrap24(tempMinHour + cbtMinBeforeWakeHours), wrap24(actualWakeHour))

    /**
     * Bucket an ABSOLUTE temperature-minimum clock hour into a lean.
     *
     * Compared CIRCULARLY. A [tempMinHour] of 23:30 is five hours BEFORE the 04:30 anchor — a strong
     * morning lean — and a naive `23.5 > 5.5` would call it evening instead. Pure, so the boundaries are
     * assertable without building a fit.
     */
    fun chronotype(tempMinHour: Double): Chronotype {
        val delta = signedHourDelta(chronotypeAnchorHour, wrap24(tempMinHour))
        if (delta < -chronotypeBandHours) return Chronotype.MORNING
        if (delta > chronotypeBandHours) return Chronotype.EVENING
        return Chronotype.INTERMEDIATE
    }

    /**
     * The lean for a phase estimate, or null when the fit is not strong enough to name one.
     *
     * Gated to [PhaseConfidence.SOLID] on purpose. WIDE is a real fit on thin data and is fine for the
     * continuous offset the card already shows, but a NAMED category reads as a fact about the person
     * rather than a reading of the week, so it waits for the stronger tier. UNREADABLE never names one.
     */
    fun chronotype(estimate: PhaseEstimate): Chronotype? {
        if (estimate.confidence != PhaseConfidence.SOLID) return null
        return chronotype(estimate.tempMinHour)
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
