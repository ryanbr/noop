package com.noop.analytics

import com.noop.analytics.SleepStager.RespEvidence
import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RespSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Respiration evidence in the V1 stager: a MISSING RRV is [RespEvidence.UNMEASURED], never
 * [RespEvidence.REGULAR]. Android twin of SleepStagerRespEvidenceTests.swift.
 *
 * The classifier used to hold `rrvRegular = (!rrv.isFinite()) || rrv <= rrvLo`, converting the absence of a
 * respiration reading into a positive assertion that breathing was regular — which is pro-deep. On a WHOOP
 * 5/MG that is the permanent state, not an edge case: the v18 layout emits no `resp_rate_raw`, so
 * `respSample` has zero rows and every epoch's RRV is NaN.
 *
 * These pin three things: the corrected representation, that the correction changed no label, and the SIZE
 * of the bias that remains (so the next person to touch the deep gate has the number, not an adjective).
 */
class SleepStagerRespEvidenceTest {

    private val dev = "test"
    private val refMidnight = 1_749_513_600L

    private fun feature(
        moveFrac: Double, hr: Double, hrVar: Double, rmssd: Double, rrv: Double,
    ): SleepStager.EpochFeatures = SleepStager.EpochFeatures(
        index = 0, midTs = 0.0, count = 0.0, moveFrac = moveFrac, ckSleep = true,
        hr = hr, hrVar = hrVar, rmssd = rmssd, sdnn = 0.0, respRate = 14.0, rrv = rrv, clock = 0.5,
    )

    private fun classify(f: SleepStager.EpochFeatures): String =
        SleepStager.classifyOne(f, hrLo = 55.0, hrHi = 90.0, rmssdHi = 50.0, hrvarHi = 10.0,
            rrvHi = 1.0, rrvLo = 0.5)

    // ── The corrected representation ─────────────────────────────────────────────────────────────────

    /** The fix, stated directly: no measurement is UNMEASURED, and UNMEASURED is not REGULAR. */
    @Test
    fun missingRrvIsUnmeasuredNotRegular() {
        assertEquals(RespEvidence.UNMEASURED, RespEvidence.of(Double.NaN, lowBar = 0.5, highBar = 1.0))
        assertNotEquals(RespEvidence.REGULAR, RespEvidence.of(Double.NaN, lowBar = 0.5, highBar = 1.0))
        // A whole session with no respiration channel leaves BOTH percentile bars null (nothing finite to
        // take a percentile of). That is the 5/MG case, and it is still UNMEASURED, not REGULAR.
        assertEquals(RespEvidence.UNMEASURED, RespEvidence.of(Double.NaN, lowBar = null, highBar = null))
        assertNotEquals(RespEvidence.REGULAR, RespEvidence.of(Double.NaN, lowBar = null, highBar = null))
        assertEquals(RespEvidence.UNMEASURED, RespEvidence.of(Double.POSITIVE_INFINITY, lowBar = 0.5, highBar = 1.0))
    }

    @Test
    fun measuredValuesMapToTheirBands() {
        assertEquals(RespEvidence.REGULAR, RespEvidence.of(0.2, 0.5, 1.0))            // below the low bar
        assertEquals(RespEvidence.REGULAR, RespEvidence.of(0.5, 0.5, 1.0))            // inclusive
        assertEquals(RespEvidence.IRREGULAR, RespEvidence.of(1.0, 0.5, 1.0))          // inclusive
        assertEquals(RespEvidence.IRREGULAR, RespEvidence.of(2.0, 0.5, 1.0))
        assertEquals(RespEvidence.MEASURED_MID_BAND, RespEvidence.of(0.75, 0.5, 1.0))
        // Both bars on the same value: the reading clears each of them.
        assertEquals(RespEvidence.BARS_DEGENERATE, RespEvidence.of(0.75, 0.75, 0.75))
        // …and only ON that value. Either side of it the pair still separates normally.
        assertEquals(RespEvidence.REGULAR, RespEvidence.of(0.74, 0.75, 0.75))
        assertEquals(RespEvidence.IRREGULAR, RespEvidence.of(0.76, 0.75, 0.75))
    }

    /**
     * The five cases are the CROSS-PRODUCT of the two predicates this replaced, so every combination
     * including "both true" has a home and none is decided by which bar `of` tests first.
     */
    @Test
    fun everyCaseIsOneCellOfThePreFixBooleanPair() {
        // (rrvIrregular, rrvRegular) → case
        assertEquals(RespEvidence.UNMEASURED, RespEvidence.of(Double.NaN, 0.5, 1.0))       // (false, true)
        assertEquals(RespEvidence.REGULAR, RespEvidence.of(0.2, 0.5, 1.0))                 // (false, true)
        assertEquals(RespEvidence.IRREGULAR, RespEvidence.of(2.0, 0.5, 1.0))               // (true,  false)
        assertEquals(RespEvidence.MEASURED_MID_BAND, RespEvidence.of(0.75, 0.5, 1.0))      // (false, false)
        assertEquals(RespEvidence.BARS_DEGENERATE, RespEvidence.of(0.75, 0.75, 0.75))      // (true,  true)
        // The two readouts the classifier consumes, for the cell a four-state enum could not hold.
        assertFalse("pre-fix `rrvRegular` was true here", RespEvidence.BARS_DEGENERATE.contradictsDepth)
        assertTrue("pre-fix `rrvIrregular` was true here", RespEvidence.BARS_DEGENERATE.meetsIrregularBar)
    }

    /**
     * Coincident bars are REACHABLE, not a theoretical corner — which is why the case is preserved rather
     * than waved away.
     *
     * Two independent routes. (1) RRV is the population std of breath intervals measured in WHOLE SECONDS
     * (`respRateAndRRV`, `dtS` = 1), so it is quantised onto a small discrete lattice and exact ties
     * between epochs are ordinary; `percentile` interpolates between order statistics, so p50 and p65
     * coincide whenever a tie run spans them. (2) With exactly ONE finite RRV in the sleep period —
     * `respRateAndRRV` returns NaN freely, on short, flat or low-peak windows — `percentile` returns that
     * single value for EVERY percentile, so the bars coincide by construction and the epoch that set them
     * necessarily sits on both.
     *
     * Both labels below are the pre-fix answers. Testing the high bar before the low bar would have
     * classified the first as IRREGULAR and flipped it deep → light.
     */
    @Test
    fun coincidentBarsAreReachableAndPreserveThePreFixLabels() {
        // Route (2), through the same `percentile` the stager uses.
        val sessionRrvs = listOf(Double.NaN, Double.NaN, 0.75, Double.NaN, Double.NaN)
        val lo = SleepStager.percentile(sessionRrvs, SleepStager.stageRRVLowPct)
        val hi = SleepStager.percentile(sessionRrvs, SleepStager.stageRRVHighPct)
        assertEquals(0.75, lo!!, 1e-12)
        assertEquals("one finite RRV in the session puts both bars on the same value", 0.75, hi!!, 1e-12)
        assertEquals(RespEvidence.BARS_DEGENERATE, RespEvidence.of(0.75, lo, hi))

        // Route (1): a tie run spanning p50…p65 does it too, with several finite values present.
        val tied = listOf(0.0, 0.25, 0.5, 0.5, 0.5, 0.5, 0.5, 1.0, 1.5, 2.0)
        assertEquals(
            SleepStager.percentile(tied, SleepStager.stageRRVLowPct)!!,
            SleepStager.percentile(tied, SleepStager.stageRRVHighPct)!!,
            1e-12,
        )

        // Depth-shaped, no cardiac activation → pre-fix "deep" (the deep rule is stated first).
        assertEquals(
            "deep",
            SleepStager.classifyOne(
                feature(0.0, hr = 50.0, hrVar = 0.0, rmssd = 60.0, rrv = 0.75),
                hrLo = 55.0, hrHi = 90.0, rmssdHi = 50.0, hrvarHi = 10.0, rrvHi = 0.75, rrvLo = 0.75,
            ),
        )
        // Cardiac-activated, not depth-shaped → the REM rule still sees the irregular bar cleared.
        assertEquals(
            "rem",
            SleepStager.classifyOne(
                feature(0.0, hr = 95.0, hrVar = 20.0, rmssd = 10.0, rrv = 0.75),
                hrLo = 55.0, hrHi = 90.0, rmssdHi = 50.0, hrvarHi = 10.0, rrvHi = 0.75, rrvLo = 0.75,
            ),
        )

        // End to end, letting `classifyEpochs` compute the bars itself from the session above.
        val feats = sessionRrvs.mapIndexed { i, rrv ->
            SleepStager.EpochFeatures(
                index = i, midTs = i * 30.0, count = 0.0, moveFrac = 0.0, ckSleep = true,
                hr = 50.0, hrVar = Double.NaN, rmssd = 60.0, sdnn = 0.0, respRate = 14.0,
                rrv = rrv, clock = 0.5,
            )
        }
        assertEquals(List(5) { "deep" }, SleepStager.classifyEpochs(feats))
    }

    /**
     * MEASURED_MID_BAND and UNMEASURED both fail both bars but mean opposite things, and the classifier
     * treats them differently — collapsing them into one "unknown" would silently change the hypnogram.
     */
    @Test
    fun midBandAndUnmeasuredAreDistinctAndBehaveDifferently() {
        assertNotEquals(RespEvidence.MEASURED_MID_BAND, RespEvidence.UNMEASURED)
        assertTrue(RespEvidence.MEASURED_MID_BAND.contradictsDepth)
        assertFalse(RespEvidence.UNMEASURED.contradictsDepth)
        assertFalse(RespEvidence.REGULAR.contradictsDepth)
        assertTrue(RespEvidence.IRREGULAR.contradictsDepth)
        // A finite RRV with no bars is still a measurement, so it must not fall into the unmeasured branch.
        assertEquals(RespEvidence.MEASURED_MID_BAND, RespEvidence.of(0.7, null, null))
    }

    /**
     * The waiver is now explicit and NAMED rather than emergent from a `!isFinite()` short-circuit — but
     * it is still a waiver, and this pins that it is. Removing it would decode 0 m of deep on every 5/MG
     * night (the #127/#129 regression, for the parallel missing-RMSSD case).
     */
    @Test
    fun unmeasuredRespirationIsWaivedForDeepAndTheWaiverIsExplicit() {
        assertEquals("deep", classify(feature(0.0, hr = 50.0, hrVar = 0.0, rmssd = 60.0, rrv = Double.NaN)))
        assertFalse(RespEvidence.UNMEASURED.contradictsDepth)
    }

    // ── The correction changed no label ──────────────────────────────────────────────────────────────

    /**
     * Exhaustive grid: the new RespEvidence classifier must agree with the OLD boolean predicates on every
     * combination. The old formulas are reproduced verbatim so the equivalence is checkable rather than
     * asserted — this is what makes the change a representation fix and not a scoring change.
     *
     * The BAR PAIR is an axis, not a constant. Holding it at a well-separated (0.5, 1.0) hides the one
     * combination where the two pre-fix booleans were BOTH true — `rrvHi <= rrv <= rrvLo`, which the
     * coincident-bar pairs below reach — and hides the null bars entirely. Those cells are where a
     * four-state enum would have silently changed a label.
     */
    @Test
    fun classificationIsIdenticalToThePreFixPredicates() {
        fun legacy(
            f: SleepStager.EpochFeatures, hrLo: Double?, hrHi: Double?, rmssdHi: Double?,
            hrvarHi: Double?, rrvHi: Double?, rrvLo: Double?, cardiacSparse: Boolean,
        ): String {
            val hasHR = f.hr.isFinite()
            val hrLow = hasHR && hrLo != null && f.hr <= hrLo
            val hrHigh = hasHR && hrHi != null && f.hr >= hrHi
            val parasympOK = (!f.rmssd.isFinite()) || (rmssdHi != null && f.rmssd >= rmssdHi)
            val hrvarHigh = f.hrVar.isFinite() && hrvarHi != null && f.hrVar >= hrvarHi
            val cardiacActivated = hrHigh || hrvarHigh
            val cardiacActivatedForWake = if (cardiacSparse) hrHigh else cardiacActivated
            // The two predicates this change replaced, exactly as they were.
            val rrvIrregular = f.rrv.isFinite() && rrvHi != null && f.rrv >= rrvHi
            val rrvRegular = (!f.rrv.isFinite()) || (rrvLo != null && f.rrv <= rrvLo)
            val still = f.moveFrac <= SleepStager.stageStillMoveFrac
            val moving = f.moveFrac >= SleepStager.stageWakeMoveFrac
            if (moving && (cardiacActivatedForWake || !hasHR)) return "wake"
            if (still && parasympOK && hrLow && rrvRegular) return "deep"
            if (still && cardiacActivated && rrvIrregular) return "rem"
            if (still && hrHigh && hrvarHigh && !f.rrv.isFinite()) return "rem"
            return "light"
        }

        // (low, high). Separated; coincident on a value the RRV axis hits; coincident elsewhere;
        // inverted (defensive — `of` reads the pair, it does not assume low <= high); and each way of
        // having no bar at all, up to the 5/MG session where neither exists.
        val barPairs: List<Pair<Double?, Double?>> = listOf(
            0.5 to 1.0, 0.75 to 0.75, 0.5 to 0.5, 1.0 to 0.5, null to 1.0, 0.5 to null, null to null,
        )

        var checked = 0
        var sawBothPreFixBooleansTrue = false
        for ((barLo, barHi) in barPairs) {
            for (moveFrac in listOf(0.0, 0.05, 0.12, 0.2)) {
                for (hr in listOf(Double.NaN, 45.0, 60.0, 95.0)) {
                    for (hrVar in listOf(Double.NaN, 1.0, 20.0)) {
                        for (rmssd in listOf(Double.NaN, 10.0, 80.0)) {
                            // NaN (never measured), below/at/between/at/above the bars.
                            for (rrv in listOf(Double.NaN, 0.2, 0.5, 0.75, 1.0, 2.0)) {
                                for (sparse in listOf(false, true)) {
                                    val f = feature(moveFrac, hr, hrVar, rmssd, rrv)
                                    val new = SleepStager.classifyOne(
                                        f, hrLo = 55.0, hrHi = 90.0, rmssdHi = 50.0, hrvarHi = 10.0,
                                        rrvHi = barHi, rrvLo = barLo, cardiacSparse = sparse,
                                    )
                                    val old = legacy(f, 55.0, 90.0, 50.0, 10.0, barHi, barLo, sparse)
                                    assertEquals(
                                        "label changed for move=$moveFrac hr=$hr hrVar=$hrVar " +
                                            "rmssd=$rmssd rrv=$rrv sparse=$sparse " +
                                            "bars=($barLo, $barHi)",
                                        old, new,
                                    )
                                    if (rrv.isFinite() && barLo != null && barHi != null &&
                                        rrv >= barHi && rrv <= barLo
                                    ) {
                                        sawBothPreFixBooleansTrue = true
                                    }
                                    checked++
                                }
                            }
                        }
                    }
                }
            }
        }
        assertEquals(7 * 4 * 4 * 3 * 3 * 6 * 2, checked)
        // The grid is only worth more than the old one if it actually visits the cell that motivated it.
        assertTrue(
            "the grid must reach `rrvIrregular && rrvRegular` — otherwise the coincident-bar case is " +
                "still untested and a bar-pair axis was added for nothing",
            sawBothPreFixBooleansTrue,
        )
    }

    /**
     * The same equivalence for a session with NO respiration channel at all (both bars null) — the WHOOP
     * 5/MG shape, and the one the bias actually lives on.
     */
    @Test
    fun noRespChannelSessionIsAlsoUnchanged() {
        for (moveFrac in listOf(0.0, 0.12, 0.2)) {
            for (hr in listOf(Double.NaN, 45.0, 95.0)) {
                for (hrVar in listOf(Double.NaN, 1.0, 20.0)) {
                    for (rmssd in listOf(Double.NaN, 10.0, 80.0)) {
                        val f = feature(moveFrac, hr, hrVar, rmssd, Double.NaN)
                        val new = SleepStager.classifyOne(
                            f, hrLo = 55.0, hrHi = 90.0, rmssdHi = 50.0, hrvarHi = 10.0,
                            rrvHi = null, rrvLo = null,
                        )
                        // Old formulas with null bars: rrvIrregular = false, rrvRegular = true (the bug).
                        val hasHR = f.hr.isFinite()
                        val hrLow = hasHR && f.hr <= 55.0
                        val hrHigh = hasHR && f.hr >= 90.0
                        val parasympOK = (!f.rmssd.isFinite()) || f.rmssd >= 50.0
                        val hrvarHigh = f.hrVar.isFinite() && f.hrVar >= 10.0
                        val still = f.moveFrac <= SleepStager.stageStillMoveFrac
                        val moving = f.moveFrac >= SleepStager.stageWakeMoveFrac
                        val old = when {
                            moving && ((hrHigh || hrvarHigh) || !hasHR) -> "wake"
                            still && parasympOK && hrLow -> "deep"
                            still && hrHigh && hrvarHigh -> "rem"
                            else -> "light"
                        }
                        assertEquals(old, new)
                    }
                }
            }
        }
    }

    /**
     * `remRejectReason` must stay in lockstep with `classifyOne` — they were hand-duplicated predicates
     * and now share one factory, so this guards the seam. The bar pair is an axis here too: the diagnostic
     * reads `meetsIrregularBar`, so the coincident-bar case has to be exercised on both sides of the seam
     * or only one of them is pinned.
     */
    @Test
    fun remRejectReasonAgreesWithTheClassifier() {
        val barPairs: List<Pair<Double?, Double?>> = listOf(0.5 to 1.0, 0.75 to 0.75, null to null)
        for ((barLo, barHi) in barPairs) {
            for (rrv in listOf(Double.NaN, 0.2, 0.75, 2.0)) {
                for (hr in listOf(Double.NaN, 45.0, 95.0)) {
                    for (hrVar in listOf(Double.NaN, 1.0, 20.0)) {
                        for (moveFrac in listOf(0.0, 0.2)) {
                            val f = feature(moveFrac, hr, hrVar, Double.NaN, rrv)
                            val label = SleepStager.classifyOne(
                                f, hrLo = 55.0, hrHi = 90.0, rmssdHi = 50.0, hrvarHi = 10.0,
                                rrvHi = barHi, rrvLo = barLo,
                            )
                            val reason = SleepStager.remRejectReason(
                                f, hrLo = 55.0, hrHi = 90.0, rmssdHi = 50.0, hrvarHi = 10.0,
                                rrvHi = barHi, rrvLo = barLo,
                            )
                            assertEquals(
                                "rem-eligibility disagreed for rrv=$rrv hr=$hr bars=($barLo, $barHi)",
                                label == "rem", reason == SleepStager.REMRejectReason.REM_ELIGIBLE,
                            )
                        }
                    }
                }
            }
        }
    }

    /**
     * A measured-but-mid-band respiration must NOT earn the missing-respiration REM fallback — that
     * fallback exists to compensate for having no reading, not for having an unremarkable one.
     */
    @Test
    fun midBandDoesNotEarnTheMissingRespirationRemFallback() {
        // still + hrHigh + hrvarHigh: the fallback's exact preconditions.
        assertEquals("rem", classify(feature(0.0, hr = 95.0, hrVar = 20.0, rmssd = Double.NaN, rrv = Double.NaN)))
        assertEquals("light", classify(feature(0.0, hr = 95.0, hrVar = 20.0, rmssd = Double.NaN, rrv = 0.75)))
    }

    // ── The size of the remaining bias ───────────────────────────────────────────────────────────────

    /**
     * QUANTIFIED, so the next person to touch the deep gate argues with a number.
     *
     * The "regular" bar is `stageRRVLowPct` = 50 — the MEDIAN. So on a night with real respiration data
     * about half of otherwise-depth-shaped epochs clear it. On a session with no respiration channel the
     * old code cleared it for ALL of them, on no measurement at all. That factor-of-two is the bias.
     *
     * It is bounded, though, and the bound matters as much as the bias: `hrLow` is itself a percentile bar
     * (`stageHRLowPct` = 25), so at most ~25% of sleep epochs can reach the deep gate however the
     * respiration term resolves. The bias inflates deep within that ceiling; it cannot run away.
     */
    @Test
    fun theDeepPassRateDoublesWhenTheRespirationChannelIsAbsent() {
        val rrvs = (0 until 100).map { it / 100.0 }   // 0.00 … 0.99, median 0.5
        val deepWithResp = rrvs.count {
            classify(feature(0.0, hr = 50.0, hrVar = 0.0, rmssd = 60.0, rrv = it)) == "deep"
        }
        assertEquals("the regular bar is the median, so ~half of epochs pass", 51, deepWithResp)

        val deepWithoutResp = rrvs.count {
            SleepStager.classifyOne(
                feature(0.0, hr = 50.0, hrVar = 0.0, rmssd = 60.0, rrv = Double.NaN),
                hrLo = 55.0, hrHi = 90.0, rmssdHi = 50.0, hrvarHi = 10.0, rrvHi = null, rrvLo = null,
            ) == "deep"
        }
        assertEquals(
            "with no respiration channel EVERY depth-shaped epoch passes the deep gate",
            100, deepWithoutResp,
        )
        assertEquals(1.96, 100.0 / deepWithResp, 0.05)
    }

    /**
     * The RRV source itself: with no respiration samples there is nothing to measure, so the NaN is honest
     * at the point it is produced. The bug was never here — it was in spending that NaN as evidence
     * downstream. (No Kotlin test covered `respRateAndRRV` at all before this.)
     */
    @Test
    fun rrvIsNaNWhenThereAreNoRespirationSamples() {
        assertTrue(SleepStager.respRateAndRRV(emptyList()).second.isNaN())
        assertTrue(SleepStager.respRateAndRRV(listOf(1.0, 2.0, 3.0)).second.isNaN())
    }

    // ── V2 (the DEFAULT stager) accepts `resp` and never reads it ────────────────────────────────────

    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }

    private fun sleepHR(start: Long, durationS: Int): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = start + it, bpm = 52 + ((it / 60) % 3)) }

    private fun regularRR(start: Long, durationS: Int): List<RrInterval> =
        (0 until durationS).map { i ->
            RrInterval(deviceId = dev, ts = start + i, rrMs = 1000 + (40.0 * sin(2.0 * PI * i / 4.0)).roundToInt())
        }

    /**
     * A populated `resp` stream must not move a single segment. If this ever fails, V2 started consuming
     * respiration and the "signature-parity only" doc — and V2's cache key, which deliberately omits
     * `resp` — are both wrong. It also matters for the bug above: on the shipped default path the raw
     * respiration ADC is not consulted at all, so the V1 pro-deep bias reaches only users who have turned
     * the V2 experiment off.
     */
    @Test
    fun v2OutputIsIdenticalWithAndWithoutARespirationStream() {
        val start = refMidnight + 3_600L
        val dur = 90 * 60
        val grav = stillGravity(start, dur)
        val hr = sleepHR(start, dur)
        val rr = regularRR(start, dur)
        // A resp stream with real structure, not a constant — a consumer would produce different RRVs.
        val resp = (0 until dur).map { i ->
            RespSample(deviceId = dev, ts = start + i, raw = 1000 + (200.0 * sin(2.0 * PI * i / 4.0)).roundToInt())
        }

        val without = SleepStagerV2.stageSession(start, start + dur, grav, hr, rr, emptyList())
        val with = SleepStagerV2.stageSession(start, start + dur, grav, hr, rr, resp)
        assertEquals(
            "V2 must ignore `resp` — it recovers respiration regularity from R-R (RSA) instead",
            without.map { "${it.start}-${it.end}-${it.stage}" },
            with.map { "${it.start}-${it.end}-${it.stage}" },
        )
        assertFalse("the fixture must actually produce segments", without.isEmpty())
    }
}
