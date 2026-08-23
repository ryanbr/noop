package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1545: the two always-on bout diagnostics — HR coverage, and the line naming what an Effort was scored
 * against.
 *
 * Diagnosing #1545 meant reversing the arithmetic out of a displayed score to work out which HRmax had set
 * the zone boundaries. These two make that visible from a strap log alone, and split the three causes a low
 * Effort can have: the 50% floor doing its job, a wrong HRmax, or the sensor not being there.
 *
 * Neither changes a score. That is exactly why they need pinning: a silently-wrong diagnostic is worse than
 * none, because the next report will be argued from it.
 *
 * Byte-parity twin of Swift `BoutCalibrationDiagnosticTests`.
 */
class BoutCalibrationDiagnosticTest {

    // ── coverage ──────────────────────────────────────────────────────────────────────────────────

    /**
     * The reason coverage is bucketed rather than sample-counted.
     *
     * A WHOOP 5/MG sends live HR about every 30 s. Counted against a 1 Hz expectation a perfectly captured
     * hour would report ~3% — a number that reads as "the sensor was off" for the most common healthy case,
     * and would send every 5/MG user chasing a hardware fault that isn't there.
     */
    @Test
    fun aThirtySecondCadenceIsFullCoverageNotThreePercent() {
        val ts = (0L until 3600L step 30L).toList()
        assertEquals(100.0, WorkoutDetector.hrCoveragePct(ts, 0L, 3600L) ?: -1.0, 1e-9)
    }

    /**
     * And a real dropout still reads as the gap it is — the diagnostic has to keep the signal it exists
     * for, not just avoid the false alarm above.
     */
    @Test
    fun aRealDropoutReadsAsTheGap() {
        val ts = (0L until 1800L step 30L).toList()          // first half only
        assertEquals(50.0, WorkoutDetector.hrCoveragePct(ts, 0L, 3600L) ?: -1.0, 1e-9)
    }

    /**
     * Samples outside the bout must not inflate it. The detector back-dates a bout's start over the
     * warm-up, so the surrounding day's samples are genuinely present in memory beside these.
     */
    @Test
    fun samplesOutsideTheWindowAreIgnored() {
        val ts = (0L until 600L).toList() + (7200L until 10800L).toList()
        // 600 s in window = 10 of the hour's 60 buckets. The hour of samples AFTER the bout contributes
        // nothing — if it did, a bout followed by a long walk would report as fully covered.
        assertEquals(10.0 / 60.0 * 100.0, WorkoutDetector.hrCoveragePct(ts, 0L, 3600L) ?: -1.0, 1e-9)
    }

    /**
     * A partial trailing bucket still counts as a whole one — 90 s is two buckets, not 1.5 — so coverage
     * can never exceed 100 and a short bout can't read as over-covered.
     */
    @Test
    fun aPartialTrailingBucketCountsAsAWholeBucket() {
        assertEquals(100.0, WorkoutDetector.hrCoveragePct((0L until 90L).toList(), 0L, 90L) ?: -1.0, 1e-9)
        // One sample in each of two buckets is still full coverage; one bucket empty is half.
        assertEquals(50.0, WorkoutDetector.hrCoveragePct(listOf(0L), 0L, 90L) ?: -1.0, 1e-9)
    }

    /** Degenerate windows report nothing rather than a fabricated 0 or 100. */
    @Test
    fun degenerateWindowsAreNull() {
        assertNull(WorkoutDetector.hrCoveragePct(listOf(1L, 2L), 100L, 100L))
        assertNull(WorkoutDetector.hrCoveragePct(listOf(1L, 2L), 100L, 50L))
        assertNull(WorkoutDetector.hrCoveragePct(listOf(1L, 2L), 0L, 60L, bucketSeconds = 0L))
    }

    // ── the line ──────────────────────────────────────────────────────────────────────────────────

    /**
     * The exact bytes. This string is compared between two users' logs — and between an iOS log and an
     * Android one — so its shape is the contract, not an implementation detail.
     */
    @Test
    fun theLineIsExactlyThis() {
        assertEquals(
            "effort bout day=2026-08-24 durMin=45 hrmax=187 src=caller avgHRR=52 cover=43 effort=8.1",
            WorkoutDetector.boutCalibrationLine(
                day = "2026-08-24", durMin = 45, hrmax = 187.0, hrmaxSource = "caller",
                avgHRRPct = 52.4, hrCoveragePct = 43.2, strain = 8.14,
            ),
        )
    }

    /**
     * Missing values say so. A bout with no HRmax is a different diagnosis from one with a low HRmax, and
     * printing 0 for both would merge the two.
     */
    @Test
    fun missingValuesRenderAsNilNotZero() {
        assertEquals(
            "effort bout day=2026-08-24 durMin=12 hrmax=nil src=estimated avgHRR=nil cover=nil effort=nil",
            WorkoutDetector.boutCalibrationLine(
                day = "2026-08-24", durMin = 12, hrmax = null, hrmaxSource = "estimated",
                avgHRRPct = null, hrCoveragePct = null, strain = null,
            ),
        )
    }

    /**
     * The rounding tie this formatter exists to remove. C `printf` rounds .5 to even and Java rounds it up,
     * so `%.0f` on 52.5 would print 52 on iOS and 53 on Android — the two logs the line is meant to be
     * compared across. Both platforms must produce the Java answer here.
     */
    @Test
    fun aHalfRoundsUpOnBothPlatforms() {
        assertEquals("53", WorkoutDetector.round0(52.5))
        assertEquals("54", WorkoutDetector.round0(53.5))   // printf: 52 then 54 — it ties to even
        assertEquals("1", WorkoutDetector.round0(0.5))
        assertEquals("8.3", WorkoutDetector.round1(8.25))
        assertEquals("0.0", WorkoutDetector.round1(0.0))
        assertEquals("21.0", WorkoutDetector.round1(21.0))
    }

    /**
     * The NEGATIVE tie, which breaks the other way: Swift's `.rounded()` is half-away-from-zero and Java's
     * `Math.round` is half-up, so they disagree on -4.5 (-5 vs -4). Rounding the magnitude and re-applying
     * the sign makes them agree — and these values are non-negative in production precisely so that nobody
     * notices when they stop agreeing, which is why it is pinned rather than assumed.
     */
    @Test
    fun negativesRoundSymmetricallyAndKeepTheirSign() {
        assertEquals("-0.5", WorkoutDetector.round1(-0.45))
        assertEquals("-8.3", WorkoutDetector.round1(-8.25))
        assertEquals("-53", WorkoutDetector.round0(-52.5))
    }

    /**
     * The minus sign must survive. Integer `/` and `%` truncate toward zero, so a naive
     * `"${t / 10}.${abs(t % 10)}"` renders -0.4 as `0.4` — a diagnostic silently reporting the opposite of
     * the truth, which is worse than reporting nothing.
     */
    @Test
    fun aSmallNegativeDoesNotLoseItsSign() {
        assertEquals("-0.4", WorkoutDetector.round1(-0.4))
        assertNotEquals("0.4", WorkoutDetector.round1(-0.4))
    }

    /** A non-finite value must not print `inf`/`nan` into a log people read as evidence. */
    @Test
    fun nonFiniteValuesAreNil() {
        assertEquals("nil", WorkoutDetector.round0(Double.NaN))
        assertEquals("nil", WorkoutDetector.round1(Double.POSITIVE_INFINITY))
        assertEquals("nil", WorkoutDetector.round1(Double.NEGATIVE_INFINITY))
    }

    /**
     * And an absurd FINITE value must not take the process with it. `Int(1e300)` traps in Swift while
     * Kotlin's `Math.round` saturates to `Long.MAX_VALUE` — a crash on one platform and a nonsense number
     * on the other, from a line whose only job is explaining a bug. Both print `nil` instead.
     *
     * Not reachable through today's detector (it gates `maxHR > restingHR` before computing %HRR), but
     * these formatters are public API and a near-zero HR reserve is the obvious way in.
     */
    @Test
    fun anAbsurdFiniteValueIsNilRatherThanACrash() {
        assertEquals("nil", WorkoutDetector.round0(1e300))
        assertEquals("nil", WorkoutDetector.round1(-1e300))
        assertEquals("nil", WorkoutDetector.round0(Long.MAX_VALUE.toDouble()))
        // The bound is well clear of anything physiological — real values still print.
        assertEquals("220", WorkoutDetector.round0(220.0))
    }

    // ── end to end ────────────────────────────────────────────────────────────────────────────────

    /**
     * The field has to actually arrive on a detected bout — a diagnostic that is always null in production
     * would pass every unit test above and tell a reporter nothing.
     */
    @Test
    fun detectedBoutsCarryCoverage() {
        val hr = (0 until 3600).map {
            HrSample("t", it.toLong(), if (it < 600 || it > 3000) 60 else 150)
        }
        val grav = (0 until 3600).map {
            GravitySample("t", it.toLong(), x = if (it % 2 == 0) 0.9 else 0.5, y = 0.1, z = 0.1)
        }
        val bouts = WorkoutDetector.detect(hr = hr, gravity = grav, restingHR = 60.0, maxHR = 190.0, age = 30.0)

        assertTrue("fixture must produce a bout for this test to mean anything", bouts.isNotEmpty())
        for (b in bouts) {
            assertNotNull("a detected bout must report its coverage", b.hrCoveragePct)
            // 1 Hz HR runs across the whole fixture, so every bucket of any detected window is populated
            // — the assertion holds wherever the detector back-dates the start to.
            assertEquals(100.0, b.hrCoveragePct ?: -1.0, 1e-9)
        }
    }
}
