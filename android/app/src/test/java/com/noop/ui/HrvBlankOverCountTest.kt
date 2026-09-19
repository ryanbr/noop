package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2335: the HRV tile is blank and NOOP knows exactly why, so it has to say so.
 *
 * The #1118 caveat cannot: it decorates a value that IS shown, and the over-count verdict is the very
 * thing that makes `SleepStager.sessionAvgHRV` return null. The reported log carries that exact pair
 * (`rrIntegrity=crossSecondOverCount` with `avgHrv=nil`), which is the case pinned first.
 */
class HrvBlankOverCountTest {

    private val today = "2026-09-19"

    private fun blanked(map: Map<String, Double>, todayKey: String = today) =
        hrvBlankedByOverCount(map, todayKey)

    @Test fun theReportedShapeIsExplained() {
        assertTrue(blanked(mapOf("2026-09-19" to 1.0)))
    }

    @Test fun noNightYetIsNotAnOverCount() {
        // A fresh install, or a wearer who has not slept in the strap. The blank is real but it is NOT
        // this cause, and claiming it would send them chasing a fault that is not there (see #2302,
        // which reports the same blank from having no staged night at all).
        assertFalse(blanked(emptyMap()))
    }

    @Test fun aCleanLatestNightIsNotExplainedAway() {
        assertFalse(blanked(mapOf("2026-09-17" to 1.0, "2026-09-18" to 1.0, "2026-09-19" to 0.0)))
    }

    @Test fun onlyTheNewestNightDecides() {
        assertTrue(blanked(mapOf("2026-09-17" to 0.0, "2026-09-18" to 0.0, "2026-09-19" to 1.0)))
    }

    @Test fun insertionOrderDoesNotDecide() {
        // The map arrives built by a scan loop, so "newest" must be a property of the KEY, not of
        // iteration order. No Swift twin: its Dictionary has no insertion order to get wrong.
        assertTrue(blanked(linkedMapOf("2026-09-19" to 1.0, "2026-09-18" to 0.0)))
        assertFalse(blanked(linkedMapOf("2026-09-19" to 0.0, "2026-09-18" to 1.0)))
    }

    @Test fun dayKeysCompareChronologicallyAcrossMonthAndYearEnds() {
        assertTrue(blanked(mapOf("2026-09-30" to 0.0, "2026-10-01" to 1.0), todayKey = "2026-10-01"))
        assertTrue(blanked(mapOf("2026-12-31" to 0.0, "2027-01-01" to 1.0), todayKey = "2027-01-01"))
        assertFalse(blanked(mapOf("2026-09-30" to 1.0, "2026-10-01" to 0.0), todayKey = "2026-10-01"))
    }

    @Test fun theFlagIsADoubleSoTheGateIsAThreshold() {
        // It round-trips through metricSeries as a Double, so the gate is `>= 0.5`, not `== 1.0`.
        assertTrue(blanked(mapOf("2026-09-19" to 0.5)))
        assertFalse(blanked(mapOf("2026-09-19" to 0.49)))
    }

    @Test fun aStaleOverCountedNightIsNotTheReasonTheTileIsBlank() {
        // Past Baselines.vitalCarryDays (7) the tile blanks because the reading went STALE, not because
        // it was refused. Blaming the over-count there points at the wrong thing, and it is also where
        // the two platforms would drift: Apple loads 14 days of this series, Android loads
        // RECENT_DAYS_CAP, so a helper keyed on "whatever was loaded" would answer differently.
        assertTrue("inside the carry window", blanked(mapOf("2026-09-12" to 1.0)))
        assertFalse("older than the carry window", blanked(mapOf("2026-09-11" to 1.0)))
        assertFalse("far older", blanked(mapOf("2026-08-01" to 1.0)))
    }
}
