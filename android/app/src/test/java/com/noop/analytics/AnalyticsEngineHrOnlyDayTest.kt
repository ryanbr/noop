package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset

/**
 * A whole day whose only sleep is HR-only, driven through `analyzeDay` (#1884).
 *
 * The unit tests around this one check the pieces: `SleepStagerHrOnlySessionsTest` that a session reports
 * what it measured, `HrOnlyPhysiologyIsolationTest` that the day's physiology set is chosen the way the
 * design says. Neither runs the whole function, and the gap between them is where #1884's own regression
 * hid: `sleepHrOnly` was derived from `physiologySessions.isEmpty()`, which is equivalent to "every
 * session was HR-only" ONLY while the set was an exclusion. Making it a preference means it can never be
 * empty when `matched` is not, so the flag would have been pinned to false forever — and the note that
 * explains a blank Recovery Vitals card would have silently stopped appearing for everyone.
 *
 * Nothing pinned that derivation: every other `sleepHrOnly` test supplies the flag as an INPUT (the carry,
 * the coalesce, the migration, the note gate). This drives it as an OUTPUT.
 */
class AnalyticsEngineHrOnlyDayTest {

    private val profile = UserProfile(weightKg = 75.0, heightCm = 178.0, age = 30.0, sex = "male")
    private val day = "2026-07-27"
    private val dayStart = LocalDate.parse(day).atStartOfDay(ZoneOffset.UTC).toEpochSecond()

    /**
     * The same field-shaped generator the session tests use — 16 h awake around 74 +/- 11 bpm, then 8 h
     * asleep around 64 +/- 5 — anchored so the night runs 00:00-08:00 on `day`. NO gravity, which is what
     * makes the night HR-only: an unbonded strap streams standard HR and R-R and banks no motion.
     */
    private fun streams(): Pair<List<HrSample>, List<RrInterval>> {
        val t0 = dayStart - 16 * 3600
        val hr = ArrayList<HrSample>()
        val rr = ArrayList<RrInterval>()
        var i = 0
        while (i < 16 * 3600) {
            val bpm = 74 + (Math.sin(i / 500.0) * 11).toInt()
            hr.add(HrSample("t", t0 + i, bpm)); rr.add(RrInterval("t", t0 + i, 60000 / bpm)); i++
        }
        var j = 0
        while (j < 8 * 3600) {
            val bpm = 64 + (Math.sin(j / 900.0) * 5).toInt()
            val t = dayStart + j
            hr.add(HrSample("t", t, bpm)); rr.add(RrInterval("t", t, 60000 / bpm)); j++
        }
        return hr to rr
    }

    @Test
    fun `an all HR-only day reports its measured vitals and still marks itself HR-only`() {
        val (hr, rr) = streams()
        // The production wiring: IntelligenceEngine stages the HR-only night and hands it to analyzeDay
        // as `providedSleep`. Driving it the same way is the point — the enrichment call site that used to
        // short-circuit on `hrOnly` only exists on this path.
        val provided = SleepStager.hrOnlySessions(hr, rr, emptyList())
        assertTrue("the HR-only spine must stage a night here", provided.isNotEmpty())
        val res = AnalyticsEngine.analyzeDay(day = day, hr = hr, rr = rr, profile = profile,
            providedSleep = provided)

        assertTrue("the staged night must reach the day's sessions", res.sleepSessions.isNotEmpty())
        assertTrue("every session must be HR-only — this day has no gravity at all",
            res.sleepSessions.all { it.hrOnly })

        // #1884: measured, not discarded. Before the change both of these were null by construction, which
        // is what left Charge with `nilScore reason=missingInput`.
        assertNotNull("resting HR is HR-derived and must survive to the day row", res.daily.restingHr)
        assertNotNull("the HRV measured over this night's windows must survive to the day row",
            res.daily.avgHrv)

        // The regression guard. `sleepHrOnly` says "every session was staged from heart rate alone", and
        // that remains TRUE of this day — the change made the vitals available, not the staging better.
        assertEquals("the day must still be marked HR-only", true, res.daily.sleepHrOnly)
    }
}
