package com.noop.analytics

import kotlin.math.abs
import kotlin.math.floor

// RecoveryDrivers.kt - the USER-FACING "What shaped it" breakdown for the Charge (recovery) score.
//
// Kotlin twin of the Swift RecoveryScorer chargeDrivers reference. Where RecoveryScorerTrace emits a
// terse engineer-facing strap-log trace, this produces the ordered, plain-English driver rows the
// dashboard renders UNDER the Charge ring: one row per real term, each carrying the signed point
// contribution to the score (deltaPoints), the night's value, the personal baseline it was scored
// against, and a short verdict.
//
// HONEST BY CONSTRUCTION. Every row is recomputed from the SAME inputs RecoveryScorer.recovery reads,
// with the SAME zScore call, weights and logistic, so a driver can never describe a term the score
// did not actually use. A MISSING input yields NO row (never a fabricated zero-contribution row): the
// term simply drops, exactly as it drops + renormalizes inside recovery(...). deltaPoints is the
// term's MARGINAL effect on the final 0-100 score: score(actual) minus score(this term neutralized to
// its personal baseline, i.e. z = 0), holding the other terms. That is a real local sensitivity, not a
// linear apportionment, so the signed points are exactly "how many points this signal moved Charge
// versus sitting at your baseline". Pure + side-effect-free (no clock, no I/O), so a fixture night pins
// the exact rows. No em-dashes, no PII (values + baselines are the user's own, never logged here).

/**
 * One semantic driver row behind the Charge (recovery) score. Presentation layers map its enums and
 * measurements to localized copy and locale-aware formatting.
 *
 * @property label stable semantic identity of the signal.
 * @property deltaPoints signed contribution to the 0-100 Charge score versus this signal sitting at
 *   the personal baseline (positive = lifted Charge, negative = pulled it down). A real marginal
 *   sensitivity, never a fabricated apportionment.
 * @property value the night's numeric value in [unit].
 * @property baseline the personal baseline the value was scored against, or null when the value is
 *   already relative to its reference (skin temperature) or uses a fixed centre (sleep quality).
 * @property unit semantic measurement unit shared by [value] and [baseline].
 * @property verdict semantic interpretation for presentation by the UI layer.
 */
enum class ChargeDriverLabel {
    HEART_RATE_VARIABILITY,
    RESTING_HEART_RATE,
    SLEEP_QUALITY,
    RESPIRATORY_RATE,
    SKIN_TEMPERATURE,
}

enum class ChargeDriverUnit {
    MILLISECONDS,
    BEATS_PER_MINUTE,
    PERCENT,
    BREATHS_PER_MINUTE,
    CELSIUS_DEVIATION,
}

enum class ChargeDriverVerdict {
    ABOVE_BASELINE_SUPPORTING,
    BELOW_BASELINE_SUPPORTING,
    ABOVE_BASELINE_LIMITING,
    BELOW_BASELINE_LIMITING,
    AT_BASELINE,
    HRV_SATURATION_LIMITING,
    STRONG_NIGHT_SUPPORTING,
    BELOW_GOOD_NIGHT_LIMITING,
    TYPICAL_NIGHT,
    NEAR_BASELINE,
    WARMER_THAN_BASELINE_LIMITING,
    COOLER_THAN_BASELINE_LIMITING,
    SLIGHTLY_ABOVE_BASELINE_SUPPORTING,
    SLIGHTLY_BELOW_BASELINE_SUPPORTING,
    SLIGHTLY_ABOVE_BASELINE_LIMITING,
    SLIGHTLY_BELOW_BASELINE_LIMITING,
    ABOVE_BASELINE_TOO_SMALL,
    BELOW_BASELINE_TOO_SMALL,
}

data class ChargeDriver(
    val label: ChargeDriverLabel,
    val deltaPoints: Int,
    val value: Double,
    val baseline: Double?,
    val unit: ChargeDriverUnit,
    val verdict: ChargeDriverVerdict,
)

object RecoveryDrivers {

    /**
     * The ordered "What shaped it" driver rows for one night's Charge score, or an EMPTY list when the
     * score itself can't compute (cold-start HRV baseline not usable, or a missing hard input) - the same
     * gate RecoveryScorer.recovery returns null on. Each present term gets exactly one row; a term whose
     * input is missing yields NO row.
     *
     * Mirrors RecoveryScorer.recovery / RecoveryScorerTrace argument-for-argument so the rows are scored
     * against the identical inputs as the headline number. Takes [BaselineState] so each row can name the
     * personal baseline (mean) it was measured against.
     *
     * @param hrv tonight's HRV (RMSSD, ms).
     * @param rhr tonight's resting HR (bpm).
     * @param resp tonight's respiration (rpm); null drops the resp row.
     * @param hrvBaseline HRV baseline (required; an unusable one yields an empty list, matching the
     *   recovery cold-start gate).
     * @param rhrBaseline resting-HR baseline; null drops the RHR row, and an UNUSABLE one (#1988) is
     *   treated as null, so a synthetic cold-start midpoint never scores a row.
     * @param respBaseline respiration baseline; null drops the resp row.
     * @param sleepPerf rest-quality proxy in 0..1 (Rest composite / 100, or efficiency); null drops the
     *   Sleep row.
     * @param skinTempDev tonight's skin-temperature deviation from the personal baseline (raw +/- C);
     *   null drops the Skin temp row. Surfaced as a RELATIVE deviation, never an absolute temperature.
     */
    fun chargeDrivers(
        hrv: Double,
        rhr: Double,
        resp: Double?,
        hrvBaseline: BaselineState,
        rhrBaseline: BaselineState?,
        respBaseline: BaselineState?,
        sleepPerf: Double?,
        skinTempDev: Double? = null,
    ): List<ChargeDriver> {
        // No score => no real contributions to attribute (cold-start). recovery(...) enforces the usable
        // gate; mirror it so a nil headline never yields fabricated driver rows.
        // #1988: the ROW is built from this baseline directly (its z, its mean, its verdict), not only
        // through recovery(...), so gating the scorer alone would emit an RHR row scored against the
        // synthetic midpoint while the headline excluded it. Normalised once here so every use below,
        // score and row alike, sees the same thing. Named rather than shadowing the parameter, which
        // would warn.
        val rhrB = rhrBaseline?.takeIf { it.usable }
        val full = RecoveryScorer.recovery(
            hrv = hrv, rhr = rhr, resp = resp,
            hrvBaseline = hrvBaseline, rhrBaseline = rhrB,
            respBaseline = respBaseline, sleepPerf = sleepPerf, skinTempDev = skinTempDev,
        ) ?: return emptyList()

        // Marginal-vs-neutral attribution: a term's deltaPoints is the full score minus the score
        // recomputed with THAT term held at its personal baseline (its z forced to 0) while every term,
        // including this one, keeps its weight. Routes through recovery(...) itself (same terms, same
        // weighting, same logistic) so the points can never drift from the headline. A term reaches
        // z = 0 at: HRV / resting HR / respiration = the baseline mean, Rest quality = sleepPerfCenter,
        // skin-temp deviation = 0. Mirrors the Swift ChargeDrivers `points(...)` helper.
        fun points(neutralised: Double?): Int {
            val delta = full - (neutralised ?: full)
            // Shared Swift/Kotlin rule: nearest integer, with exact half-ties away from zero.
            return if (delta < 0.0) -Math.round(-delta).toInt() else Math.round(delta).toInt()
        }

        // Swift `Double.rounded()` (nearest, half away from zero): the precision each row prints its value
        // and baseline at, which the verdicts compare, so the words and the printed numbers agree.
        val roundHalfAway: (Double) -> Double = { x -> if (x >= 0.0) floor(x + 0.5) else -floor(-x + 0.5) }

        // Did the parasympathetic-saturation signature fire on THIS night (low HRV corroborated by a low,
        // decoupled resting HR)? Detection ONLY: the guard's easing is not applied, so deltaPoints below is
        // the full, unguarded HRV penalty. The verdict merely NAMES the detected pattern so the UI can
        // surface it while real firings accumulate. See the header in RecoveryScorer.kt.
        val hrvZFull = RecoveryScorer.zScore(hrv, hrvBaseline.baseline, hrvBaseline.spread)
        val rhrZFull: Double? = rhrB?.let { RecoveryScorer.zScore(it.baseline, rhr, it.spread) }
        val hrvSaturationDetected =
            RecoveryScorer.parasympatheticSaturation(hrvZ = hrvZFull, rhrZ = rhrZFull).active

        // One row per present term, appended in the SAME order the iOS twin uses (HRV, resting HR, Sleep,
        // respiration, skin temp), then sorted biggest-mover-first so the row that explains the most sits on
        // top. The semantic cases retain the same distinctions as the Swift canonical.
        val drivers = ArrayList<ChargeDriver>()

        // HRV (dominant driver; always present once the score exists). Neutral = HRV at the baseline mean.
        val hrvPoints = points(
            RecoveryScorer.recovery(
                hrv = hrvBaseline.baseline, rhr = rhr, resp = resp,
                hrvBaseline = hrvBaseline, rhrBaseline = rhrB,
                respBaseline = respBaseline, sleepPerf = sleepPerf, skinTempDev = skinTempDev,
            ),
        )
        drivers.add(
            ChargeDriver(
                label = ChargeDriverLabel.HEART_RATE_VARIABILITY,
                deltaPoints = hrvPoints,
                value = hrv,
                baseline = hrvBaseline.baseline,
                unit = ChargeDriverUnit.MILLISECONDS,
                verdict = hrvVerdict(
                    value = hrv,
                    baseline = hrvBaseline.baseline,
                    shown = roundHalfAway(hrv),
                    shownBaseline = roundHalfAway(hrvBaseline.baseline),
                    points = hrvPoints,
                    saturationDetected = hrvSaturationDetected,
                ),
            ),
        )
        // Resting HR (lower vs baseline supports recovery). Neutral = resting HR at the baseline mean.
        if (rhrB != null) {
            val rhrPoints = points(
                RecoveryScorer.recovery(
                    hrv = hrv, rhr = rhrB.baseline, resp = resp,
                    hrvBaseline = hrvBaseline, rhrBaseline = rhrB,
                    respBaseline = respBaseline, sleepPerf = sleepPerf, skinTempDev = skinTempDev,
                ),
            )
            drivers.add(
                ChargeDriver(
                    label = ChargeDriverLabel.RESTING_HEART_RATE,
                    deltaPoints = rhrPoints,
                    value = rhr,
                    baseline = rhrB.baseline,
                    unit = ChargeDriverUnit.BEATS_PER_MINUTE,
                    verdict = lowerIsBetterVerdict(
                        value = rhr, baseline = rhrB.baseline,
                        shown = roundHalfAway(rhr), shownBaseline = roundHalfAway(rhrB.baseline),
                        points = rhrPoints,
                    ),
                ),
            )
        }
        // Rest quality (the Rest composite; neutral at sleepPerfCenter).
        if (sleepPerf != null) {
            val sleepPoints = points(
                RecoveryScorer.recovery(
                    hrv = hrv, rhr = rhr, resp = resp,
                    hrvBaseline = hrvBaseline, rhrBaseline = rhrB,
                    respBaseline = respBaseline, sleepPerf = RecoveryScorer.sleepPerfCenter,
                    skinTempDev = skinTempDev,
                ),
            )
            drivers.add(
                ChargeDriver(
                    label = ChargeDriverLabel.SLEEP_QUALITY,
                    deltaPoints = sleepPoints,
                    value = sleepPerf * 100.0,
                    baseline = null,
                    unit = ChargeDriverUnit.PERCENT,
                    verdict = sleepVerdict(sleepPoints),
                ),
            )
        }
        // Respiration (lower vs baseline supports recovery). Neutral = respiration at the baseline mean.
        if (resp != null && respBaseline != null) {
            val respPoints = points(
                RecoveryScorer.recovery(
                    hrv = hrv, rhr = rhr, resp = respBaseline.baseline,
                    hrvBaseline = hrvBaseline, rhrBaseline = rhrB,
                    respBaseline = respBaseline, sleepPerf = sleepPerf, skinTempDev = skinTempDev,
                ),
            )
            drivers.add(
                ChargeDriver(
                    label = ChargeDriverLabel.RESPIRATORY_RATE,
                    deltaPoints = respPoints,
                    value = resp,
                    baseline = respBaseline.baseline,
                    unit = ChargeDriverUnit.BREATHS_PER_MINUTE,
                    verdict = lowerIsBetterVerdict(
                        value = resp, baseline = respBaseline.baseline,
                        shown = roundHalfAway(resp * 10.0) / 10.0,
                        shownBaseline = roundHalfAway(respBaseline.baseline * 10.0) / 10.0,
                        points = respPoints,
                    ),
                ),
            )
        }
        // Skin-temp deviation (symmetric penalty: any drift lowers Charge). Neutral = zero drift, so the
        // delta is always <= 0 (a penalty removed). Surface it as a RELATIVE deviation, never an absolute.
        if (skinTempDev != null) {
            val skinPoints = points(
                RecoveryScorer.recovery(
                    hrv = hrv, rhr = rhr, resp = resp,
                    hrvBaseline = hrvBaseline, rhrBaseline = rhrB,
                    respBaseline = respBaseline, sleepPerf = sleepPerf, skinTempDev = 0.0,
                ),
            )
            drivers.add(
                ChargeDriver(
                    label = ChargeDriverLabel.SKIN_TEMPERATURE,
                    deltaPoints = skinPoints,
                    value = skinTempDev,
                    baseline = null,
                    unit = ChargeDriverUnit.CELSIUS_DEVIATION,
                    verdict = skinTempVerdict(skinTempDev, skinPoints),
                ),
            )
        }

        // Biggest mover first; a stable sort preserves the iOS append order on ties.
        return drivers.sortedByDescending { abs(it.deltaPoints) }
    }

    /**
     * A verdict must agree with the two things its row shows: the value against its baseline at the
     * precision printed, and the rounded points. The EFFECT (supporting / limiting) comes from the points;
     * the DIRECTION from the printed values, falling back to the raw ones only when the printed values tie
     * and the term still moved the score ("slightly"). Twin of the Swift `RecoveryScorer.direction`.
     *
     * @return null when the row honestly reads as at baseline, else (higher, slight).
     */
    private fun direction(
        value: Double,
        baseline: Double,
        shown: Double,
        shownBaseline: Double,
        points: Int,
    ): Pair<Boolean, Boolean>? {
        if (shown != shownBaseline) return (shown > shownBaseline) to false
        if (points == 0 || value == baseline) return null
        return (value > baseline) to true
    }

    /**
     * HRV verdict. Twin of the Swift `RecoveryScorer.hrvVerdict`.
     * When the parasympathetic-saturation signature fired (low HRV corroborated by a low, decoupled resting
     * HR) the pattern is NAMED, but the "limiting recovery" read stays, because that is what the score
     * actually did: the easing is detected-only and did NOT change these points. The hedge is deliberate
     * too, since the same low-HRV + low-RHR pattern is also reported for non-functional overreaching,
     * which is the opposite of benign.
     */
    private fun hrvVerdict(
        value: Double,
        baseline: Double,
        shown: Double,
        shownBaseline: Double,
        points: Int,
        saturationDetected: Boolean,
    ): ChargeDriverVerdict {
        val (higher, slight) = direction(value, baseline, shown, shownBaseline, points)
            ?: return ChargeDriverVerdict.AT_BASELINE
        if (points == 0) {
            return if (higher) ChargeDriverVerdict.ABOVE_BASELINE_TOO_SMALL else ChargeDriverVerdict.BELOW_BASELINE_TOO_SMALL
        }
        if (higher) {
            return if (slight) ChargeDriverVerdict.SLIGHTLY_ABOVE_BASELINE_SUPPORTING
            else ChargeDriverVerdict.ABOVE_BASELINE_SUPPORTING
        }
        if (saturationDetected) return ChargeDriverVerdict.HRV_SATURATION_LIMITING
        return if (slight) ChargeDriverVerdict.SLIGHTLY_BELOW_BASELINE_LIMITING
        else ChargeDriverVerdict.BELOW_BASELINE_LIMITING
    }

    /** Resting HR and respiration (lower is better). Twin of the Swift `RecoveryScorer.lowerIsBetterVerdict`. */
    private fun lowerIsBetterVerdict(
        value: Double,
        baseline: Double,
        shown: Double,
        shownBaseline: Double,
        points: Int,
    ): ChargeDriverVerdict {
        val (higher, slight) = direction(value, baseline, shown, shownBaseline, points)
            ?: return ChargeDriverVerdict.AT_BASELINE
        if (points == 0) {
            return if (higher) ChargeDriverVerdict.ABOVE_BASELINE_TOO_SMALL else ChargeDriverVerdict.BELOW_BASELINE_TOO_SMALL
        }
        return when {
            higher && slight -> ChargeDriverVerdict.SLIGHTLY_ABOVE_BASELINE_LIMITING
            higher -> ChargeDriverVerdict.ABOVE_BASELINE_LIMITING
            slight -> ChargeDriverVerdict.SLIGHTLY_BELOW_BASELINE_SUPPORTING
            else -> ChargeDriverVerdict.BELOW_BASELINE_SUPPORTING
        }
    }

    /** Rest-quality verdict from its points. Twin of the Swift `RecoveryScorer.sleepVerdict`. */
    private fun sleepVerdict(points: Int): ChargeDriverVerdict = when {
        points > 0 -> ChargeDriverVerdict.STRONG_NIGHT_SUPPORTING
        points < 0 -> ChargeDriverVerdict.BELOW_GOOD_NIGHT_LIMITING
        else -> ChargeDriverVerdict.TYPICAL_NIGHT
    }

    /** Half-width (C) of the "typical" skin-temp band; matches Swift skinTempTypicalBandC. */
    private const val SKIN_TEMP_TYPICAL_BAND_C: Double = 0.3

    /**
     * Skin-temp verdict: any drift lowers Charge, so it is "near baseline" exactly when it cost 0 points;
     * otherwise the sign of the drift names it. Twin of the Swift `RecoveryScorer.skinTempVerdict`.
     */
    private fun skinTempVerdict(dev: Double, points: Int): ChargeDriverVerdict = when {
        points == 0 -> ChargeDriverVerdict.NEAR_BASELINE
        dev > 0.0 -> ChargeDriverVerdict.WARMER_THAN_BASELINE_LIMITING
        else -> ChargeDriverVerdict.COOLER_THAN_BASELINE_LIMITING
    }
}
