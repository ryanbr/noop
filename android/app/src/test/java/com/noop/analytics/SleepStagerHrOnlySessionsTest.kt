package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Whole HR-only sessions (#1801), and the display-only guarantee that rides on them.
 *
 * The night is synthetic: a slow HR drift well under the window median, so the spine puts it in the
 * sleep band. That is enough to exercise assembly and the null contract; it is NOT a claim that the
 * staging is accurate on a real night, which no test here can establish.
 */
class SleepStagerHrOnlySessionsTest {

    /**
     * A field-shaped window: `aH` hours awake around 74 +/- 11 bpm, then `nH` hours asleep around
     * 64 +/- 5 — the shape the #1801 report shows. The same generator the anchor tests use, so the two
     * files cannot drift into disagreeing about what a detectable night looks like.
     */
    private fun window(aH: Int = 16, nH: Int = 8): Pair<List<HrSample>, List<RrInterval>> {
        val t0 = 1_788_300_000L
        val hr = ArrayList<HrSample>()
        val rr = ArrayList<RrInterval>()
        var i = 0
        while (i < aH * 3600) {
            val bpm = 74 + (Math.sin(i / 500.0) * 11).toInt()
            hr.add(HrSample("d", t0 + i, bpm)); rr.add(RrInterval("d", t0 + i, 60000 / bpm)); i++
        }
        var j = 0
        while (j < nH * 3600) {
            val bpm = 64 + (Math.sin(j / 900.0) * 5).toInt()
            val t = t0 + aH * 3600L + j
            hr.add(HrSample("d", t, bpm)); rr.add(RrInterval("d", t, 60000 / bpm)); j++
        }
        return hr to rr
    }

    @Test
    fun `a low-HR night becomes at least one staged session`() {
        val (hr, rr) = window()
        val out = SleepStager.hrOnlySessions(hr, rr, emptyList())
        assertTrue("expected at least one night, got ${out.size}", out.isNotEmpty())
        assertTrue("every session must carry stages", out.all { it.stages.isNotEmpty() })
        assertTrue("every session must span at least minSleepMin",
            out.all { (it.end - it.start) >= SleepStager.minSleepMin * 60L })
        // Conservative by design: it may under-read a night, but must never invent more sleep than the
        // window holds.
        assertTrue("total must not exceed the 8 h actually asleep",
            out.sumOf { it.end - it.start } <= 8 * 3600L)
    }

    /**
     * The display-only guarantee at its source. restingHR and avgHRV are the two values Charge and the
     * baselines fold in, and a baseline is the one thing a false positive cannot be unwound from.
     */
    @Test
    fun `an HR-only session withholds resting HR and HRV and marks itself`() {
        val (hr, rr) = window()
        val s = SleepStager.hrOnlySessions(hr, rr, emptyList()).first()
        assertTrue("must be flagged hrOnly", s.hrOnly)
        assertNull("restingHR must stay null", s.restingHR)
        assertNull("avgHRV must stay null", s.avgHRV)
    }

    /** A stretch below the minimum-duration gate is not a night. */
    @Test
    fun `a short low-HR stretch is not a night`() {
        val (hr, rr) = window(aH = 16, nH = 8)
        val cut = 1_788_300_000L + 16 * 3600L + 1500L   // ~25 min of night, well under minSleepMin
        assertTrue(
            SleepStager.hrOnlySessions(hr.filter { it.ts < cut }, rr.filter { it.ts < cut }, emptyList())
                .isEmpty()
        )
    }

    /**
     * A strap that DOES bank motion must never reach this path. A WHOOP 4.0 streams a gravity vector and
     * stages its nights from the motion spine — it is reported working — so the HR-only fallback exists
     * only for the case where that spine has nothing. Read from the source because the gate lives at the
     * call site in IntelligenceEngine, and a fallback that quietly widened to every strap would replace a
     * working detector with a weaker one.
     */
    @Test
    fun `the fallback is reachable only when gravity is absent`() {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        val src = run {
            repeat(4) {
                val f = java.io.File(root, "android/app/src/main/java/com/noop/analytics/IntelligenceEngine.kt")
                if (f.isFile) return@run f.readText()
                root = root.parentFile ?: root
            }
            error("IntelligenceEngine.kt not found — this test must not pass by default")
        }
        val idx = src.indexOf("SleepStager.hrOnlySessions(")
        assertTrue("IntelligenceEngine must call the HR-only fallback", idx > 0)
        val guard = src.substring(maxOf(0, idx - 1200), idx)
        assertTrue("the fallback must sit behind the absent-gravity gate", guard.contains("grav.size < 2"))
        assertTrue("and must only run when the device supplied no hypnogram of its own",
            guard.contains("stored.isNotEmpty()"))
    }

    /** No HR at all cannot produce a night, and must not throw. */
    @Test
    fun `no hr yields nothing`() {
        assertTrue(SleepStager.hrOnlySessions(emptyList(), emptyList(), emptyList()).isEmpty())
    }
}
