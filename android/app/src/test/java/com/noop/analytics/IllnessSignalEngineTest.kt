package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirror of the Swift IllnessSignalEngineTests — identical inputs and expected outputs (parity guard). */
class IllnessSignalEngineTest {

    private val labels = mapOf(
        "restingHR" to "RHR +6",
        "skinTemp" to "skin temp +0.7 °C",
        "hrv" to "HRV −22%",
        "respiration" to "respiration up",
    )

    private fun reading(z: Double) = IllnessSignalEngine.SignalReading(z)

    @Test fun classicThreeSignalPatternRaises() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val r = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(), labels)
        assertEquals(IllnessSignalEngine.Level.RAISED, r.level)
        assertTrue(r.score >= IllnessSignalEngine.raiseThreshold)
        assertEquals(3, r.signalCount)
        assertEquals(listOf("RHR +6", "skin temp +0.7 °C", "HRV −22%"), r.firedSignals)
        assertTrue(r.suppressedBy.isEmpty())
        assertTrue(r.copy.contains("not a diagnosis"))
    }

    @Test fun alcoholTagSuppresses() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val raised = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(), labels)
        val suppressed = IllnessSignalEngine.evaluate(
            inputs, IllnessSignalEngine.Context(alcohol = true), labels)
        assertEquals(IllnessSignalEngine.Level.SUPPRESSED, suppressed.level)
        assertEquals(listOf("alcohol"), suppressed.suppressedBy)
        assertTrue(suppressed.score < raised.score)
        assertEquals(raised.score * IllnessSignalEngine.confounderDampen, suppressed.score, 1e-9)
        assertTrue(suppressed.copy.contains("alcohol"))
        assertTrue(suppressed.copy.contains("not illness"))
        assertTrue(suppressed.copy.contains("not a diagnosis"))
    }

    @Test fun stressSaunaTravelEachDowngradeWithReason() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val stress = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(stress = true), labels)
        assertEquals(IllnessSignalEngine.Level.SUPPRESSED, stress.level)
        assertEquals(listOf("stress"), stress.suppressedBy)

        val sauna = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(sauna = true), labels)
        assertEquals(listOf("sauna"), sauna.suppressedBy)

        val travel = IllnessSignalEngine.evaluate(
            inputs, IllnessSignalEngine.Context(travelPhaseJump = true), labels)
        assertEquals(listOf("travel"), travel.suppressedBy)
        assertTrue(travel.copy.contains("travel"))
    }

    @Test fun multipleConfoundersJoinNaturally() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val r = IllnessSignalEngine.evaluate(
            inputs, IllnessSignalEngine.Context(alcohol = true, stress = true), labels)
        assertEquals(listOf("alcohol", "stress"), r.suppressedBy)
        assertTrue(r.copy.contains("alcohol and stress"))
    }

    @Test fun alreadyUnwellSwitchesCopy() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val r = IllnessSignalEngine.evaluate(
            inputs, IllnessSignalEngine.Context(alreadyUnwell = true), labels)
        assertEquals(IllnessSignalEngine.Level.ALREADY_UNWELL, r.level)
        assertTrue(r.copy.contains("Rest up"))
        assertTrue(r.copy.contains("numbers agree"))
        assertFalse(r.copy.contains("Heads-up"))
    }

    @Test fun singleSignalDoesNotRaise() {
        val inputs = IllnessSignalEngine.Inputs(restingHR = reading(4.0))
        val r = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(), labels)
        assertEquals(IllnessSignalEngine.Level.QUIET, r.level)
        assertEquals(1, r.signalCount)
    }

    @Test fun untrustedBaselineStaysSilent() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val r = IllnessSignalEngine.evaluate(
            inputs, IllnessSignalEngine.Context(baselineTrusted = false), labels)
        assertEquals(IllnessSignalEngine.Level.QUIET, r.level)
        assertFalse(r.copy.contains("Heads-up"))
    }

    @Test fun belowThresholdSignalsAreMildNotRaised() {
        val inputs = IllnessSignalEngine.Inputs(restingHR = reading(2.6), skinTemp = reading(2.6))
        val r = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(), labels)
        assertEquals(2, r.signalCount)
        assertEquals(IllnessSignalEngine.Level.MILD, r.level)
        assertTrue(r.score < IllnessSignalEngine.raiseThreshold)
        assertTrue(r.score >= IllnessSignalEngine.mildThreshold)
    }

    @Test fun absentSignalsDoNotCount() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2),
            skinTemp = IllnessSignalEngine.SignalReading(9.0, present = false),
            hrv = reading(3.5))
        val r = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(), labels)
        assertEquals(2, r.signalCount)
        assertFalse(r.firedSignals.contains("skin temp +0.7 °C"))
    }

    @Test fun copyNeverNamesACondition() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val banned = listOf("covid", "flu", "fever", "infection", "sick with", "illness with", "disease")
        val ctxs = listOf(
            IllnessSignalEngine.Context(),
            IllnessSignalEngine.Context(alcohol = true),
            IllnessSignalEngine.Context(alreadyUnwell = true))
        for (ctx in ctxs) {
            val copy = IllnessSignalEngine.evaluate(inputs, ctx, labels).copy.lowercase()
            for (b in banned) assertFalse("copy contained $b: $copy", copy.contains(b))
        }
    }

    @Test fun scorePerSignalCapping() {
        val inputs = IllnessSignalEngine.Inputs(restingHR = reading(100.0), skinTemp = reading(2.5))
        val r = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(), labels)
        val expectedSkin = IllnessSignalEngine.kZToScore * (2.5 - IllnessSignalEngine.signalZThreshold)
        assertEquals(IllnessSignalEngine.perSignalCap + expectedSkin, r.score, 1e-9)
    }
}
