package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure multi-device fusion contract — the Kotlin half of the Swift↔Kotlin parity gate. IDENTICAL
 * fixtures + expected output to the Swift FusionResolverTests in Packages/StrandAnalytics. Covers the
 * spec test plan (docs/superpowers/specs/2026-06-19-v5-local-multi-device-fusion-design.md §Test
 * plan): trust ordering, cross-validation boundaries, conflict-never-merges, single-source
 * degradation, and provenance integrity. No Room/Android — the engine is pure.
 */
class FusionResolverTest {

    // 1. Trust ordering ("best signal wins") -------------------------------------------------------

    @Test
    fun stepsBandBeatsStrapEstimate() {
        // A wrist band COUNTS steps (tier 0); the strap only ESTIMATES (tier 3) — the band must win.
        val point = FusionResolver.resolve(
            "steps",
            listOf(
                FusionInput(FusionSource.WHOOP_IMPORT, 6000.0), // strap estimate
                FusionInput(FusionSource.XIAOMI_BAND, 8420.0),  // counts directly
            ),
        )
        assertEquals(FusionSource.XIAOMI_BAND, point?.winningSource)
        assertEquals(8420.0, point?.value)
        assertEquals("counts directly", point?.contributors?.first()?.reason)
    }

    @Test
    fun sleepWhoopBeatsPhoneBuckets() {
        // Imported WHOOP stages (tier 0) beat phone sleep buckets (tier 2).
        val point = FusionResolver.resolve(
            "sleep_total_min",
            listOf(
                FusionInput(FusionSource.APPLE_HEALTH, 400.0),
                FusionInput(FusionSource.WHOOP_IMPORT, 432.0),
            ),
        )
        assertEquals(FusionSource.WHOOP_IMPORT, point?.winningSource)
        assertEquals(432.0, point?.value)
        assertEquals("best stager", point?.contributors?.first()?.reason)
    }

    @Test
    fun restingHrStrapBeatsPhone() {
        // The strap measures HR directly (tier 0); the phone aggregates it (tier 2).
        val point = FusionResolver.resolve(
            "rhr",
            listOf(
                FusionInput(FusionSource.APPLE_HEALTH, 55.0),
                FusionInput(FusionSource.WHOOP_IMPORT, 52.0),
            ),
        )
        assertEquals(FusionSource.WHOOP_IMPORT, point?.winningSource)
        assertEquals(52.0, point?.value)
    }

    @Test
    fun tieBrokenStablyBySourcePriority() {
        // Two tier-0 step counters (band + phone). Stable tiebreak = sourcePriority: APPLE_HEALTH (2)
        // < XIAOMI_BAND (4), so the phone wins the tie even though the band is listed first.
        val point = FusionResolver.resolve(
            "steps",
            listOf(
                FusionInput(FusionSource.XIAOMI_BAND, 8000.0),
                FusionInput(FusionSource.APPLE_HEALTH, 8100.0),
            ),
        )
        assertEquals(FusionSource.APPLE_HEALTH, point?.winningSource)
        assertEquals(8100.0, point?.value)
    }

    // 2. Cross-validation classification at boundaries ---------------------------------------------

    @Test
    fun restingHrAgreeWithinTolerance() {
        // RHR tolerance: agree <= 3 bpm. Winner 52, other 54 → delta 2 → agree.
        val point = FusionResolver.resolve(
            "rhr",
            listOf(
                FusionInput(FusionSource.WHOOP_IMPORT, 52.0),
                FusionInput(FusionSource.APPLE_HEALTH, 54.0),
            ),
        )
        assertEquals(AgreementState.AGREE, point?.agreement)
    }

    @Test
    fun restingHrMinorDeltaJustOverAgreeEdge() {
        // Delta 4 (> 3 agree edge, <= 8 minor edge) → minorDelta.
        val point = FusionResolver.resolve(
            "rhr",
            listOf(
                FusionInput(FusionSource.WHOOP_IMPORT, 52.0),
                FusionInput(FusionSource.APPLE_HEALTH, 56.0),
            ),
        )
        assertEquals(AgreementState.MINOR_DELTA, point?.agreement)
    }

    @Test
    fun restingHrConflictBeyondMinorEdge() {
        // Delta 10 (> 8 minor edge) → conflict.
        val point = FusionResolver.resolve(
            "rhr",
            listOf(
                FusionInput(FusionSource.WHOOP_IMPORT, 52.0),
                FusionInput(FusionSource.APPLE_HEALTH, 62.0),
            ),
        )
        assertEquals(AgreementState.CONFLICT, point?.agreement)
    }

    @Test
    fun sleepConflictTwoHoursVsSeven() {
        // 432 min vs 120 min — a gross divergence → conflict (spec's headline example).
        val point = FusionResolver.resolve(
            "sleep_total_min",
            listOf(
                FusionInput(FusionSource.WHOOP_IMPORT, 432.0),
                FusionInput(FusionSource.APPLE_HEALTH, 120.0),
            ),
        )
        assertEquals(AgreementState.CONFLICT, point?.agreement)
    }

    @Test
    fun stepsPercentBandAgree() {
        // Steps tolerance is ±10% agree / ±30% minor. Winner 8000, other 8500 → 6.25% → agree.
        val point = FusionResolver.resolve(
            "steps",
            listOf(
                FusionInput(FusionSource.XIAOMI_BAND, 8000.0),
                FusionInput(FusionSource.WHOOP_IMPORT, 8500.0),
            ),
        )
        assertEquals(FusionSource.XIAOMI_BAND, point?.winningSource)
        assertEquals(AgreementState.AGREE, point?.agreement)
    }

    @Test
    fun stepsPercentBandConflict() {
        // Winner 8000, other 14000 → 75% over → conflict.
        val point = FusionResolver.resolve(
            "steps",
            listOf(
                FusionInput(FusionSource.XIAOMI_BAND, 8000.0),
                FusionInput(FusionSource.WHOOP_IMPORT, 14000.0),
            ),
        )
        assertEquals(AgreementState.CONFLICT, point?.agreement)
    }

    // 3. Conflict never silently merges ------------------------------------------------------------

    @Test
    fun conflictKeepsBothContributorsWinnerHigherTrust() {
        val point = FusionResolver.resolve(
            "sleep_total_min",
            listOf(
                FusionInput(FusionSource.APPLE_HEALTH, 120.0),
                FusionInput(FusionSource.WHOOP_IMPORT, 432.0),
            ),
        )
        // Winner is the higher-trust source, value is verbatim (NOT an average of 120 & 432 = 276).
        assertEquals(FusionSource.WHOOP_IMPORT, point?.winningSource)
        assertEquals(432.0, point?.value)
        assertEquals(AgreementState.CONFLICT, point?.agreement)
        assertEquals(2, point?.contributors?.size)
        assertTrue(point?.contributors?.any { it.source == FusionSource.APPLE_HEALTH } == true)
        assertTrue(point?.contributors?.any { it.source == FusionSource.WHOOP_IMPORT } == true)
    }

    // 4. Single-source degradation -----------------------------------------------------------------

    @Test
    fun singleSourcePassesThroughNoAgreement() {
        val point = FusionResolver.resolve(
            "hrv",
            listOf(FusionInput(FusionSource.WHOOP_IMPORT, 68.0)),
        )
        assertEquals(68.0, point?.value)
        assertEquals(FusionSource.WHOOP_IMPORT, point?.winningSource)
        assertEquals(AgreementState.SINGLE, point?.agreement)
        assertEquals(1, point?.contributors?.size)
    }

    @Test
    fun emptyInputsYieldNull() {
        assertNull(FusionResolver.resolve("hrv", emptyList()))
    }

    // 5. Provenance integrity ----------------------------------------------------------------------

    @Test
    fun winningSourceMatchesSuppliedValue() {
        // Three sources; the winner's value must be exactly the value that source supplied.
        val inputs = listOf(
            FusionInput(FusionSource.APPLE_HEALTH, 55.0),
            FusionInput(FusionSource.NOOP_COMPUTED, 53.0),
            FusionInput(FusionSource.WHOOP_IMPORT, 52.0),
        )
        val point = FusionResolver.resolve("rhr", inputs)
        val winner = point!!.winningSource
        val suppliedByWinner = inputs.first { it.source == winner }.value
        assertEquals(point.value, suppliedByWinner, 1e-9) // delta form: avoid JUnit's deprecated assertEquals(double,double)
        assertEquals(FusionSource.WHOOP_IMPORT, winner) // tier 0 vs computed tier 1 vs phone tier 2
    }

    // Policy table sanity --------------------------------------------------------------------------

    @Test
    fun stepsTierTable() {
        assertEquals(
            0,
            MetricArbitrationPolicy.tier(
                MetricArbitrationPolicy.MetricKind.STEPS, FusionSource.XIAOMI_BAND,
            ),
        )
        assertEquals(
            3,
            MetricArbitrationPolicy.tier(
                MetricArbitrationPolicy.MetricKind.STEPS, FusionSource.WHOOP_IMPORT,
            ),
        )
    }

    @Test
    fun sleepTierTable() {
        assertEquals(
            0,
            MetricArbitrationPolicy.tier(
                MetricArbitrationPolicy.MetricKind.SLEEP, FusionSource.WHOOP_IMPORT,
            ),
        )
        assertEquals(
            2,
            MetricArbitrationPolicy.tier(
                MetricArbitrationPolicy.MetricKind.SLEEP, FusionSource.APPLE_HEALTH,
            ),
        )
    }

    @Test
    fun keyMapping() {
        assertEquals(MetricArbitrationPolicy.MetricKind.RESTING_HR, MetricArbitrationPolicy.kind("rhr"))
        assertEquals(
            MetricArbitrationPolicy.MetricKind.SLEEP, MetricArbitrationPolicy.kind("asleep_min"),
        )
        assertEquals(
            MetricArbitrationPolicy.MetricKind.SLEEP, MetricArbitrationPolicy.kind("sleep_deep_min"),
        )
        assertEquals(MetricArbitrationPolicy.MetricKind.STEPS, MetricArbitrationPolicy.kind("steps"))
        assertEquals(
            MetricArbitrationPolicy.MetricKind.OTHER, MetricArbitrationPolicy.kind("made_up_key"),
        )
    }
}
