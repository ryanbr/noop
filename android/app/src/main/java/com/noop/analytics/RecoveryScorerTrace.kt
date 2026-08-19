package com.noop.analytics

import kotlin.math.abs

// RecoveryScorerTrace.kt - Kotlin twin of RecoveryScorer+Trace.swift. The Charge TERM-BREAKDOWN
// diagnostic for the Recovery test mode.
//
// Recomputes the four-plus-one weighted Charge terms from the SAME inputs RecoveryScorer.recovery
// reads, then reuses recovery(...) verbatim for the final score so the trace can never disagree with
// the number the dashboard shows. Pure and side-effect-free: no clock, no I/O, so a fixture night pins
// the exact lines. The Recovery test mode gates this behind TestCentre.active(RECOVERY) at the call
// site (IntelligenceEngine recomputeRecovery); when the mode is off it is never called, so there is zero
// cost. Byte-aligned with the Swift line shape so the parity test passes. No em-dashes.

object RecoveryScorerTrace {

    /**
     * Trace numbers use nearest rounding with half-ties away from zero on both platforms.
     *
     * Round the MAGNITUDE and reapply the sign, rather than branching on `scaled < 0.0`. Two traps sit
     * here, and Swift's `.rounded(.toNearestOrAwayFromZero)` avoids both for free:
     *
     *  * Math.round returns a Long, which has no negative zero, so negating it before the division
     *    collapses -0.0 to +0.0 for any value that rounds to zero;
     *  * `-0.0 < 0.0` is FALSE, so a sign test cannot even route an exact -0.0 to a negating branch —
     *    and -0.0 is reachable here, since a skin-temp deviation of exactly 0.0 gives z = -|dev| = -0.0.
     *
     * These values are interpolated straight into the trace, so either trap printed `z=0.0` on Android
     * against `z=-0.0` on Apple. copySign carries the IEEE sign bit itself and handles both (#1437
     * follow-up).
     */
    private fun r2(x: Double): Double {
        val scaled = x * 100.0
        return Math.copySign(Math.round(abs(scaled)) / 100.0, scaled)
    }

    /**
     * Side-effect-free diagnostic twin of [RecoveryScorer.recovery]: returns the SAME score recovery(...)
     * would, plus the per-term Charge breakdown trace. The four inputs (hrv / rhr / resp / sleepPerf) plus
     * the skin-temp deviation each get a baseline line (mean / spread / nValid / status), a term line
     * (z * weight), the renormalization (total weight, composite z), and the final logistic score + band.
     * Crucially the trace names WHICH TERM WAS NIL and forced the renorm (or the nil score).
     *
     * Every number is computed with the EXACT same expressions as recovery(...) (the same zScore call, the
     * same skin-temp penalty, the same weights), and the returned score IS recovery(...) verbatim, so the
     * trace and the headline can never diverge. Mirrors the Swift RecoveryScorer.recoveryTrace.
     */
    fun recoveryTrace(
        hrv: Double,
        rhr: Double,
        resp: Double?,
        hrvBaseline: BaselineState,
        rhrBaseline: BaselineState?,
        respBaseline: BaselineState?,
        sleepPerf: Double?,
        skinTempDev: Double? = null,
    ): Pair<Double?, List<String>> {
        val lines = ArrayList<String>()
        val nilTerms = ArrayList<String>()

        // The score the dashboard reads, verbatim, so the trace cannot diverge from it.
        val score = RecoveryScorer.recovery(
            hrv = hrv, rhr = rhr, resp = resp,
            hrvBaseline = hrvBaseline, rhrBaseline = rhrBaseline,
            respBaseline = respBaseline, sleepPerf = sleepPerf, skinTempDev = skinTempDev,
        )

        // Cold-start gate: HRV baseline not usable -> recovery() returns null before any term is built.
        if (!hrvBaseline.usable) {
            lines.add(
                "charge nilScore reason=hrvBaselineNotUsable " +
                    "hrvStatus=${hrvBaseline.status.raw} hrvNValid=${hrvBaseline.nValid} " +
                    "(need nValid>=${Baselines.minNightsSeed})",
            )
            return score to lines
        }

        // Per-driver baseline state lines (mean / spread / nValid / status).
        lines.add(
            "charge baseline hrv mean=${r2(hrvBaseline.baseline)} spread=${r2(hrvBaseline.spread)} " +
                "nValid=${hrvBaseline.nValid} status=${hrvBaseline.status.raw}",
        )
        rhrBaseline?.let { b ->
            lines.add(
                "charge baseline rhr mean=${r2(b.baseline)} spread=${r2(b.spread)} " +
                    "nValid=${b.nValid} status=${b.status.raw}",
            )
        }
        respBaseline?.let { b ->
            lines.add(
                "charge baseline resp mean=${r2(b.baseline)} spread=${r2(b.spread)} " +
                    "nValid=${b.nValid} status=${b.status.raw}",
            )
        }

        // Per-term z * weight, built with the EXACT expressions recovery(...) uses, in the SAME append order.
        val terms = ArrayList<Pair<Double, Double>>() // (z, weight)

        // Resting-HR z, computed up front so the saturation guard can read the HRV<->RHR coupling before
        // the HRV term is built. null when there is no RHR baseline. Numerically identical to the z
        // recovery() builds for the RHR term (same expression, same inputs).
        val rhrZForGuard: Double? = rhrBaseline?.let { RecoveryScorer.zScore(it.baseline, rhr, it.spread) }

        // L9: every WEIGHT / SCALE / centre constant goes through r2() too (not just the z-scores), so a
        // future non-round weight (e.g. 0.333) renders identically on Swift and Kotlin and the parity
        // fixture cannot silently desync. The values render the same as before today.
        // HRV term: higher is better. (Always present once usable; the cold-start guard above returned.)
        // This is the RAW z, exactly as recovery() scores it: the parasympathetic-saturation easing is
        // detected and reported below but NOT applied, so the trace's HRV term matches the scored one.
        // NOTE: the HRV term is always terms[0]; the counterfactual below relies on that.
        val hrvZRaw = RecoveryScorer.zScore(hrv, hrvBaseline.baseline, hrvBaseline.spread)
        val sat = RecoveryScorer.parasympatheticSaturation(hrvZ = hrvZRaw, rhrZ = rhrZForGuard)
        terms.add(hrvZRaw to RecoveryScorer.wHRV)
        lines.add("charge term hrv z=${r2(hrvZRaw)} w=${r2(RecoveryScorer.wHRV)} (higher HRV is better)")

        // RHR term: lower is better -> (mu - x) / sigma. (Reuses the z computed for the guard.)
        if (rhrZForGuard != null) {
            terms.add(rhrZForGuard to RecoveryScorer.wRHR)
            lines.add("charge term rhr z=${r2(rhrZForGuard)} w=${r2(RecoveryScorer.wRHR)} (lower RHR is better)")
        } else {
            nilTerms.add("rhr")
        }

        // Resp term: lower is better, optional (needs BOTH the value and a baseline).
        if (resp != null && respBaseline != null) {
            val z = RecoveryScorer.zScore(respBaseline.baseline, resp, respBaseline.spread)
            terms.add(z to RecoveryScorer.wResp)
            lines.add("charge term resp z=${r2(z)} w=${r2(RecoveryScorer.wResp)} (lower resp is better)")
        } else {
            nilTerms.add("resp")
        }

        // Sleep-performance / Rest-quality term: no baseline needed, centered at sleepPerfCenter.
        if (sleepPerf != null) {
            val z = (sleepPerf - RecoveryScorer.sleepPerfCenter) / RecoveryScorer.sleepPerfScale
            terms.add(z to RecoveryScorer.wSleep)
            lines.add(
                "charge term sleepPerf z=${r2(z)} w=${r2(RecoveryScorer.wSleep)} " +
                    "(rest=${r2(sleepPerf)} center=${r2(RecoveryScorer.sleepPerfCenter)})",
            )
        } else {
            nilTerms.add("sleepPerf")
        }

        // Skin-temp term: SYMMETRIC penalty on |deviation|, added only when supplied.
        if (skinTempDev != null) {
            val z = -abs(skinTempDev) / RecoveryScorer.skinTempDevScale
            terms.add(z to RecoveryScorer.wSkinTemp)
            lines.add(
                "charge term skinTempDev z=${r2(z)} w=${r2(RecoveryScorer.wSkinTemp)} " +
                    "(dev=${r2(skinTempDev)}C penalty=-|dev|/${r2(RecoveryScorer.skinTempDevScale)})",
            )
        } else {
            nilTerms.add("skinTempDev")
        }

        // The nil terms that dropped out and forced the weight renormalization (the killer line).
        lines.add(
            "charge nilTerm dropped=[${nilTerms.joinToString(",")}] " +
                "(each dropped term renormalizes the remaining weights)",
        )

        // Renormalization: total surviving weight and the weighted composite z, the SAME math recovery(...)
        // runs to produce the logistic input.
        val totalWeight = terms.sumOf { it.second }
        val compositeZ = if (totalWeight > 0.0) terms.sumOf { it.first * it.second } / totalWeight else 0.0
        lines.add(
            "charge renorm totalWeight=${r2(totalWeight)} compositeZ=${r2(compositeZ)} " +
                "(z = sum(z*w)/sum(w))",
        )

        // Final logistic score + band, read from recovery(...) verbatim.
        if (score != null) {
            lines.add(
                "charge score=${r2(score)} band=${RecoveryScorer.band(score)} " +
                    "(logistic k=${r2(RecoveryScorer.logisticK)} z0=${r2(RecoveryScorer.logisticZ0)})",
            )
        } else {
            lines.add("charge nilScore reason=noValidTerms (no driver produced a usable term)")
        }

        // ── Parasympathetic-saturation guard: DETECTED, NOT APPLIED ────────────────────────────────
        //
        // Emitted ONLY when the signature fires. The score above is the UNGUARDED number; this line
        // reports the counterfactual the guard WOULD have produced, so real low-HRV + low-RHR nights can
        // be counted and checked against ground truth before the easing is ever allowed to move Charge.
        // See the header in RecoveryScorer.kt for the validation gap and the contested benign-saturation
        // / non-functional-overreaching ambiguity that keep it switched off.
        //
        // wouldRaiseCharge recomputes the composite with the eased HRV z swapped in (the HRV term is
        // terms[0]) and runs it through RecoveryScorer.logisticScore -- the SAME curve recovery() uses --
        // so the delta is exact, not estimated. Mirrors the Swift trace line exactly.
        if (sat.active && score != null && totalWeight > 0.0) {
            val easedZ = terms.withIndex()
                .sumOf { (i, t) -> (if (i == 0) sat.easedHrvZ else t.first) * t.second } / totalWeight
            val wouldBe = RecoveryScorer.logisticScore(easedZ)
            lines.add(
                "charge saturation active hrvZraw=${r2(hrvZRaw)} rhrZ=${r2(rhrZForGuard ?: 0.0)} " +
                    "damp=${r2(sat.dampFraction)} wouldEaseHrvZTo=${r2(sat.easedHrvZ)} " +
                    "wouldRaiseCharge=${r2(wouldBe - score)} wouldBand=${RecoveryScorer.band(wouldBe)} " +
                    "(low HRV + low resting HR: candidate parasympathetic saturation. " +
                    "Easing DETECTED ONLY, not applied: the score above is unchanged)",
            )
        }

        return score to lines
    }
}
