package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Whole HR-only sessions (#1801), and the physiology they report (#1884).
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
     * #1884 reversed the null contract this used to pin, so the reasoning is worth keeping beside it.
     *
     * #1801 withheld restingHR and avgHRV here on the grounds that a baseline is the one thing a false
     * positive cannot be unwound from. What the field logs showed is that the withholding was the more
     * damaging error: the values are MEASURED, not inferred. The bounds are what heart rate infers —
     * which is why the session still marks itself `hrOnly` — but each RMSSD is computed over its own
     * 5-minute window, so fuzzy bounds change WHICH windows are included, not whether any one of them
     * is valid. Resting HR is HR-derived, and an HR-only night is precisely the night with plenty of HR.
     *
     * The marker travels with the session, so a consumer that wants to weigh these down still can.
     */
    @Test
    fun `an HR-only session reports measured resting HR and HRV and still marks itself`() {
        val (hr, rr) = window()
        val s = SleepStager.hrOnlySessions(hr, rr, emptyList()).first()
        assertTrue("must still be flagged hrOnly", s.hrOnly)
        assertNotNull("restingHR is HR-derived and must be reported", s.restingHR)
        assertNotNull("avgHRV must be reported when R-R is present", s.avgHRV)
    }

    /**
     * The honest boundary of the change: reporting is driven by whether the INPUT exists, not by the
     * `hrOnly` flag. With no R-R there is nothing to compute an RMSSD from, so HRV is still absent —
     * and resting HR, which needs only HR, is still reported. A regression that re-blanked HRV wholesale
     * would pass the test above if it also happened to blank on missing R-R; this separates them.
     */
    @Test
    fun `an HR-only session without R-R still reports resting HR`() {
        val (hr, _) = window()
        val s = SleepStager.hrOnlySessions(hr, emptyList(), emptyList()).first()
        assertTrue("must still be flagged hrOnly", s.hrOnly)
        assertNotNull("restingHR needs only HR", s.restingHR)
        assertNull("no R-R means no RMSSD to report", s.avgHRV)
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
        // Scoped to the `providedSleep` expression rather than a fixed window of characters before the
        // call. The first version measured PROXIMITY — 1200 chars back — and broke the moment a couple
        // of diagnostic lines were inserted between the gate and the call, even though the gate still
        // held. Containment is the actual invariant; distance never was.
        val from = src.indexOf("val providedSleep: List<DetectedSleep> =")
        assertTrue("IntelligenceEngine must build providedSleep", from > 0)
        val to = src.indexOf("val tScore0", from)
        assertTrue("expected the scoring call to follow providedSleep", to > from)
        val expr = src.substring(from, to)
        assertTrue("the fallback must sit inside the absent-gravity gate", expr.contains("grav.size < 2"))
        assertTrue("IntelligenceEngine must call the HR-only fallback",
            expr.contains("SleepStager.hrOnlySessions("))
        assertTrue("and must only run when the device supplied no hypnogram of its own",
            expr.contains("stored.isNotEmpty()"))
        // The bug this replaced: the fallback inherited #804's `owner != importedDeviceId` exclusion,
        // written to keep WHOOP straps OUT of a ring's hypnogram path — and so it never fired on the
        // WHOOP strap it exists for. `resolveDayOwner` returns importedDeviceId whenever the owner
        // source is absent, which on a live 5/MG install is every day. Pinned by asserting the owner
        // check does not stand between the gravity gate and the call: it may still scope the STORED
        // branch, but not the heart-rate one.
        val hrOnlyBranch = expr.substring(expr.indexOf("else ->"))
        assertTrue("the HR-only branch must not be gated on the day's owner",
            !hrOnlyBranch.contains("importedDeviceId"))
        assertTrue("but the stored-hypnogram branch keeps #804's exclusion",
            expr.substring(0, expr.indexOf("else ->")).contains("owner != importedDeviceId"))
    }

    /** No HR at all cannot produce a night, and must not throw. */
    @Test
    fun `no hr yields nothing`() {
        assertTrue(SleepStager.hrOnlySessions(emptyList(), emptyList(), emptyList()).isEmpty())
    }
}
