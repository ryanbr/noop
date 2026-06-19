package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Tests/StrandAnalyticsTests/DoseResponseEngineTests.swift.
 * Same fixtures, same numbers — cross-platform parity is the contract.
 */
class DoseResponseEngineTest {

    private fun ymd(y: Int, m: Int, d: Int): String = "%04d-%02d-%02d".format(y, m, d)

    private val alcoholPrior = -5.0

    // n_user = 0 returns the prior exactly

    @Test
    fun noDataReturnsPrior() {
        val doses = mapOf(ymd(2026, 6, 1) to 2, ymd(2026, 6, 2) to 1)
        val r = DoseResponseEngine.estimate(DosedBehavior.ALCOHOL, doses, emptyMap())!!
        assertEquals(0, r.nUser)
        assertEquals(0.0, r.weight, 1e-12)
        assertNull(r.userSlope)
        assertEquals(alcoholPrior, r.perUnit, 1e-12)
        assertTrue(r.priorDominated)
        assertFalse(r.contradictsPrior)
        assertEquals(ScoreConfidence.CALIBRATING, r.confidence)
        assertEquals("Charge", r.outcome)
    }

    // shrinkage weight w = n/(n+k) is exact at the boundary n = k

    @Test
    fun shrinkageWeightAtBoundary() {
        val doses = HashMap<String, Int>()
        val outcome = HashMap<String, Double>()
        val months = listOf(1, 2, 3, 4, 5, 6, 7, 8)
        for ((i, month) in months.withIndex()) {
            val dose = i % 4
            val day = ymd(2026, month, 10)
            doses[day] = dose
            outcome[ymd(2026, month, 11)] = 80.0 - 2.0 * dose
        }
        val r = DoseResponseEngine.estimate(DosedBehavior.ALCOHOL, doses, outcome)!!
        assertEquals(8, r.nUser)
        assertEquals(0.5, r.weight, 1e-12)
        assertEquals(-2.0, r.userSlope!!, 1e-9)
        assertEquals(-3.5, r.perUnit, 1e-9)
        assertEquals(ScoreConfidence.BUILDING, r.confidence)
    }

    // large n_user recovers ≈ the personal slope

    @Test
    fun largeNRecoversPersonalSlope() {
        val doses = HashMap<String, Int>()
        val outcome = HashMap<String, Double>()
        var count = 0
        for (month in listOf(1, 4, 7, 10)) {
            for (k in 0 until 10) {
                val dom = 1 + k * 3
                val dose = count % 4
                val day = ymd(2026, month, dom)
                doses[day] = dose
                outcome[ymd(2026, month, dom + 1)] = 90.0 - 3.0 * dose
                count++
            }
        }
        assertEquals(40, count)
        val r = DoseResponseEngine.estimate(DosedBehavior.ALCOHOL, doses, outcome)!!
        assertEquals(40, r.nUser)
        assertEquals(-3.0, r.userSlope!!, 1e-9)
        val w = 40.0 / 48.0
        assertEquals(w, r.weight, 1e-12)
        assertEquals(w * (-3.0) + (1.0 - w) * (-5.0), r.perUnit, 1e-9)
        assertFalse(r.priorDominated)
        assertFalse(r.contradictsPrior)
        assertEquals(ScoreConfidence.SOLID, r.confidence)
    }

    // a personal slope that contradicts the prior flips the copy state

    @Test
    fun personalSlopeContradictsPriorOverGate() {
        val doses = HashMap<String, Int>()
        val outcome = HashMap<String, Double>()
        for ((i, month) in listOf(1, 2, 3, 4, 5, 6).withIndex()) {
            val dose = i % 4
            val day = ymd(2026, month, 10)
            doses[day] = dose
            outcome[ymd(2026, month, 11)] = 60.0 + 2.0 * dose
        }
        val r = DoseResponseEngine.estimate(DosedBehavior.ALCOHOL, doses, outcome)!!
        assertEquals(6, r.nUser)
        assertTrue(r.userSlope!! > 0)
        assertFalse(r.priorDominated)
        assertTrue(r.contradictsPrior)
    }

    // below the gate stays prior-dominated even with a contrary slope

    @Test
    fun belowGateStaysPriorDominated() {
        val doses = HashMap<String, Int>()
        val outcome = HashMap<String, Double>()
        for ((i, month) in listOf(1, 2, 3).withIndex()) {
            val dose = i
            val day = ymd(2026, month, 10)
            doses[day] = dose
            outcome[ymd(2026, month, 11)] = 60.0 + 5.0 * dose
        }
        val r = DoseResponseEngine.estimate(DosedBehavior.ALCOHOL, doses, outcome)!!
        assertEquals(3, r.nUser)
        assertTrue(r.priorDominated)
        assertFalse(r.contradictsPrior)
        assertEquals(ScoreConfidence.CALIBRATING, r.confidence)
    }

    // clamp keeps a runaway personal slope inside the prior's range

    @Test
    fun perUnitIsClampedToPriorRange() {
        val doses = HashMap<String, Int>()
        val outcome = HashMap<String, Double>()
        for (k in 0 until 40) {
            val dose = k % 4
            val month = 1 + (k / 10) * 3
            val dom = 1 + (k % 10) * 3
            val day = ymd(2026, month, dom)
            doses[day] = dose
            outcome[ymd(2026, month, dom + 1)] = 100.0 - 40.0 * dose
        }
        val r = DoseResponseEngine.estimate(DosedBehavior.ALCOHOL, doses, outcome)!!
        assertEquals(-15.0, r.perUnit, 1e-9)
    }

    // curve points use the shrunk slope from a 0 anchor

    @Test
    fun curvePoints() {
        val r = DoseResponseEngine.estimate(DosedBehavior.ALCOHOL, emptyMap(), emptyMap())!!
        assertEquals(listOf(0, 1, 2, 3), r.curve.map { it.dose })
        assertEquals(listOf(0.0, -5.0, -10.0, -15.0), r.curve.map { it.outcomeDelta })
    }

    // delta() composes incremental units

    @Test
    fun deltaComposesUnits() {
        val r = DoseResponseEngine.estimate(DosedBehavior.ALCOHOL, emptyMap(), emptyMap())!!
        assertEquals(-5.0, r.delta(1, 2), 1e-12)
        assertEquals(-15.0, r.delta(0, 3), 1e-12)
        assertEquals(0.0, r.delta(2, 2), 1e-12)
    }

    // no documented prior → null

    @Test
    fun noPriorOutcomeReturnsNull() {
        assertNull(
            DoseResponseEngine.estimate(DosedBehavior.ALCOHOL, "RHR", emptyMap(), emptyMap()),
        )
    }

    // caffeine default outcome is HRV with its own prior

    @Test
    fun caffeineDefaultsToHRV() {
        val r = DoseResponseEngine.estimate(DosedBehavior.CAFFEINE, emptyMap(), emptyMap())!!
        assertNotNull(r)
        assertEquals("HRV", r.outcome)
        assertEquals(-4.0, r.perUnit, 1e-12)
    }
}
