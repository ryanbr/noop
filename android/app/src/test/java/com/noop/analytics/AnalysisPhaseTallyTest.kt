package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The post-loop phase line. Twin of the Swift `AnalysisPhaseTallyTests` against the SAME literals: the
 * two platforms name their own phases (the passes genuinely differ after the day loop), but the
 * rendering — order, rounding, the total, the empty case — is one contract.
 */
class AnalysisPhaseTallyTest {

    @Test
    fun phasesRenderInOrderWithATotal() {
        assertEquals(
            "analyzeRecent postLoop total=30042ms baselines=12ms score2=1100ms steps=28930ms",
            AnalysisPhaseTally.logLine("postLoop", listOf("baselines" to 0.012, "score2" to 1.1, "steps" to 28.93)),
        )
    }

    /**
     * The phases are printed in the order GIVEN, never sorted by cost. Execution order is the point: the
     * line is read front to back as the pass runs, and a sort would hide where in the pass the time sits.
     */
    @Test
    fun orderIsExecutionOrderNotCost() {
        assertEquals(
            "analyzeRecent postLoop total=28942ms steps=28930ms baselines=12ms",
            AnalysisPhaseTally.logLine("postLoop", listOf("steps" to 28.93, "baselines" to 0.012)),
        )
    }

    /**
     * A backwards clock step yields a negative interval. It floors at zero rather than printing a
     * negative duration — and, more to the point, that is the one input where Swift's
     * round-half-away-from-zero and Kotlin's round-half-up would disagree.
     */
    @Test
    fun negativeAndNonFinitePhasesFloorAtZero() {
        assertEquals("analyzeRecent postLoop total=0ms skew=0ms",
            AnalysisPhaseTally.logLine("postLoop", listOf("skew" to -0.0005)))
        assertEquals("analyzeRecent postLoop total=0ms nan=0ms",
            AnalysisPhaseTally.logLine("postLoop", listOf("nan" to Double.NaN)))
    }

    /**
     * The total is the sum of what was MEASURED, not of the pass. A phase nobody bracketed shows up as
     * the gap between this number and `re-score: done`, which is how the next blind spot gets found.
     */
    @Test
    fun totalIsTheSumOfMeasuredPhasesOnly() {
        assertEquals("analyzeRecent postLoop total=750ms a=500ms b=250ms",
            AnalysisPhaseTally.logLine("postLoop", listOf("a" to 0.5, "b" to 0.25)))
    }

    /**
     * The scope is the caller's, not a constant. Android brackets only `persistFitnessVitalityAndSteps`
     * (the JaCoCo method-size ratchet on `analyzeRecentOnCpu` leaves no room), so its line must not claim
     * a `postLoop` total it never measured. Same phases, different scope, different line.
     */
    @Test
    fun scopeNamesWhatWasActuallyBracketed() {
        val phases = listOf("weekly" to 0.07, "steps" to 28.93)
        assertEquals("analyzeRecent persistSteps total=29000ms weekly=70ms steps=28930ms",
            AnalysisPhaseTally.logLine("persistSteps", phases))
        assertEquals("analyzeRecent postLoop total=29000ms weekly=70ms steps=28930ms",
            AnalysisPhaseTally.logLine("postLoop", phases))
    }

    @Test
    fun noPhasesSaysSoRatherThanPrintingNothing() {
        assertEquals("analyzeRecent postLoop total=0ms (no phases)", AnalysisPhaseTally.logLine("postLoop", emptyList()))
    }
}
