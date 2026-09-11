package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Which config field dropped the day cache.
 *
 * #2073 made a wholesale drop visible (`configDropped`), and a field log on build 487 showed it firing
 * for real: `reused=0/21 missBy=absent:21,configDropped:1`, against a healthy pass that reuses 20 of 21
 * and misses only today. The expensive passes cost up to 35 s of prep and 22 s of scoring, so which field
 * moved is the difference between a config the user actually changed and a value that drifts on its own.
 *
 * The signature is a plain "|"-joined value list built inside `analyzeRecentOnCpu`, which sits on a JaCoCo
 * bytecode ratchet, so the field NAMES live beside the reader instead. That split is the risk this pins:
 * a reader that guessed an index would name the wrong field and send someone hunting a bug that is not
 * there, which is worse than saying nothing.
 */
class DayCacheConfigFieldTest {

    private fun sig(vararg values: String) = values.joinToString("|")

    /** A signature with one field per name, so a changed index has a name to resolve to. */
    private fun fullSig(mutate: (MutableList<String>) -> Unit = {}): String {
        val v = MutableList(IntelligenceEngine.DAY_CACHE_CONFIG_FIELDS.size) { "v$it" }
        mutate(v)
        return v.joinToString("|")
    }

    @Test
    fun `the moved field is named`() {
        val before = fullSig()
        val after = fullSig { it[0] = "moved" }
        assertEquals("hrvBaseline", IntelligenceEngine.changedConfigField(before, after))
    }

    /** The field log's leading suspicion was a rolling baseline, which is index 0 and 1. Naming them
     *  apart is the whole point: one is HRV drifting, the other resting heart rate. */
    @Test
    fun `the two baselines are told apart`() {
        assertEquals("rhrBaseline",
            IntelligenceEngine.changedConfigField(fullSig(), fullSig { it[1] = "moved" }))
        assertEquals("dayCycleMode",
            IntelligenceEngine.changedConfigField(fullSig(), fullSig { it[15] = "moved" }))
    }

    /** Several at once happens on a settings change that touches more than one knob. */
    @Test
    fun `several movers are all named`() {
        val after = fullSig { it[0] = "a"; it[14] = "b" }
        assertEquals("hrvBaseline+effortMethod",
            IntelligenceEngine.changedConfigField(fullSig(), after))
    }

    /** The signature starts EMPTY rather than null, so the first drop of a process has nothing to diff
     *  against. Reporting that as "unknown" would describe a shape mismatch that never happened. */
    @Test
    fun `the first drop of a process says first`() {
        assertEquals("first", IntelligenceEngine.changedConfigField("", fullSig()))
    }

    /**
     * The names and the construction site can fall out of step, because they live apart. When they do,
     * this refuses to name anything rather than resolve an index against a list that no longer describes
     * it. A wrong field name is worse than none: it is a diagnostic asserting what it cannot attribute.
     */
    @Test
    fun `a shape mismatch is refused rather than guessed`() {
        assertEquals("unknown", IntelligenceEngine.changedConfigField(sig("a", "b"), sig("a", "c")))
        assertEquals("unknown", IntelligenceEngine.changedConfigField(fullSig(), sig("a")))
    }

    /** The two platforms must describe the same fields in the same order, or the same drop is reported
     *  as two different causes depending on which phone the reporter happens to hold. Pinned on BOTH
     *  sides, because a list pinned on one is free to drift on the other. */
    @Test
    fun `the field list matches the Swift twin`() {
        assertEquals(
            listOf(
                "hrvBaseline", "rhrBaseline", "age", "sex", "stepTicksPerStep", "maxHROverride",
                "tzOffset", "sleepNeedHours", "sleepConsistency", "habitualMidsleep",
                "experimentalSleepV2", "motionAwareWake", "deepHrvWindow", "spo2CandidateDisplay",
                "effortMethod", "dayCycleMode",
            ),
            IntelligenceEngine.DAY_CACHE_CONFIG_FIELDS,
        )
    }

    /** Equal signatures never reach the caller, but the helper still answers honestly if they do. */
    @Test
    fun `an unchanged signature names nothing`() {
        assertEquals("none", IntelligenceEngine.changedConfigField(fullSig(), fullSig()))
    }
}
