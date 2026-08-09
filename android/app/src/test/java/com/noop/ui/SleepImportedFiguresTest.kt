package com.noop.ui

import com.noop.analytics.RestScorer
import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

/**
 * Pins the Sleep screen's prefer-imported logic: where the WHOOP export carried a figure
 * verbatim (sleep_performance / sleep_consistency / sleep_need_min / sleep_debt_min in
 * metricSeries), the headline tiles must pass it through unscaled; days the export does
 * not cover fall back to the on-device RECOMPUTATION so sparklines stay continuous across
 * the import horizon.
 */
class SleepImportedFiguresTest {

    private fun day(d: String, asleep: Double?) = DailyMetric(
        deviceId = "my-whoop", day = d, totalSleepMin = asleep,
        deepMin = 80.0, remMin = 90.0, lightMin = 200.0, efficiency = 90.0,
    )

    @Test
    fun importedPerformanceWinsPerDay() {
        val days = listOf(day("2026-06-01", 420.0), day("2026-06-02", 410.0))
        val imported = ImportedSleepSeries(performance = mapOf("2026-06-02" to 85.0))
        val m = buildSleepModel(days, session = null, imported = imported)!!
        assertEquals(85.0, m.performance.latest!!, 1e-9)
    }

    @Test
    fun importedDebtPassesThroughInMinutes() {
        val days = listOf(day("2026-06-01", 420.0), day("2026-06-02", 410.0))
        val imported = ImportedSleepSeries(debtMin = mapOf("2026-06-02" to 60.0))
        val m = buildSleepModel(days, session = null, imported = imported)!!
        assertEquals(60.0, m.sleepDebt.latest!!, 1e-9)
    }

    @Test
    fun hoursVsNeededUsesImportedNeedPerDay() {
        val days = listOf(day("2026-06-01", 400.0))
        val imported = ImportedSleepSeries(needMin = mapOf("2026-06-01" to 480.0))
        val m = buildSleepModel(days, session = null, imported = imported)!!
        assertEquals(400.0 / 480.0 * 100.0, m.hoursVsNeeded.latest!!, 1e-9)
    }

    @Test
    fun uncoveredDaysUseTheRestComposite() {
        // Imported covers only day 1; day 2 (the latest) must use the REAL Rest composite
        // (RestScorer.restFromDaily) — the SAME single source of truth the Today Rest score,
        // the metric-detail overlay and iOS SleepView read — NOT the old hours-vs-need proxy
        // that ceilinged live 5.0 nights at ~100% while every other surface showed ~85% (#298).
        val days = listOf(day("2026-06-01", 420.0), day("2026-06-02", 410.0))
        val imported = ImportedSleepSeries(performance = mapOf("2026-06-01" to 85.0))
        val m = buildSleepModel(days, session = null, imported = imported)!!
        assertEquals(RestScorer.restFromDaily(days[1])!!, m.performance.latest!!, 1e-9)
        // …and it is NOT the retired asleep/need approximation.
        assertNotEquals(410.0 / 450.0 * 100.0, m.performance.latest, 1e-6)
        // …and the imported day still carries the verbatim figure inside the series.
        assertEquals(85.0, m.performance.series.first(), 1e-9)
    }

    /** #298 regression: a live night long enough to CEILING the old asleep/need proxy at 100%
     *  must instead show the Rest composite (< 100 once efficiency / restorative pull it down),
     *  matching the tap-through metric-detail overlay and the Today Rest score. */
    @Test
    fun longLiveNightShowsCompositeNotCeilingedProxy() {
        // 8 h asleep, 82% efficiency, modest deep+REM → asleep ≥ personal need, so the OLD proxy
        // would read min(100, 480/450·100) = 100%. The composite scores the quality, landing < 100.
        val night = DailyMetric(
            deviceId = "my-whoop", day = "2026-06-02", totalSleepMin = 480.0,
            deepMin = 70.0, remMin = 80.0, lightMin = 330.0, efficiency = 0.82,
        )
        val days = listOf(
            DailyMetric(deviceId = "my-whoop", day = "2026-06-01", totalSleepMin = 420.0,
                deepMin = 70.0, remMin = 80.0, lightMin = 270.0, efficiency = 0.85),
            night,
        )
        val m = buildSleepModel(days, session = null)!!
        val composite = RestScorer.restFromDaily(night)!!
        assertEquals(composite, m.performance.latest!!, 1e-9)
        assertTrue("composite should be below the 100% proxy ceiling", composite < 100.0)
        assertNotEquals(100.0, m.performance.latest, 1e-6)
    }

    @Test
    fun importedConsistencyUsedOnlyWhenItCoversTheLatestNight() {
        val days = listOf(day("2026-06-01", 420.0), day("2026-06-02", 410.0))
        // Covers the latest night → verbatim series wins.
        val covered = buildSleepModel(days, null,
            ImportedSleepSeries(consistency = mapOf("2026-06-01" to 70.0, "2026-06-02" to 74.0)))!!
        assertEquals(74.0, covered.consistency.latest!!, 1e-9)
        // Ends before the latest night → the APPROXIMATE duration-spread proxy, never a
        // months-old import-era value presented as "latest".
        val stale = buildSleepModel(days, null,
            ImportedSleepSeries(consistency = mapOf("2026-06-01" to 70.0)))!!
        assertNotEquals(70.0, stale.consistency.latest)
    }

    @Test
    fun emptyImportedReproducesTheApproximateBaseline() {
        val days = listOf(day("2026-06-01", 420.0), day("2026-06-02", 410.0))
        val a = buildSleepModel(days, session = null)!!
        val b = buildSleepModel(days, session = null, imported = ImportedSleepSeries())!!
        assertEquals(a, b)
    }

    // --- Cross-platform parity: ASLEEP, not in-bed; window is full history, not the browsed
    //     night. Mirrors iOS SleepView, which reads totalSleepMin over repo.days for every tile,
    //     the debt ledger, and the personal need. (#1/#5/#7)

    /** A session whose IN-BED window (600 min) dwarfs the night's ASLEEP total (410 min) must NOT
     *  bleed time-in-bed into the per-tile passes. The old metricsWindow substituted the session's
     *  (wake − onset) for totalSleepMin, inflating hours-vs-needed / debt; dropped for parity. */
    @Test
    fun sessionInBedWindowDoesNotSubstituteForAsleep() {
        val days = listOf(day("2026-06-01", 420.0), day("2026-06-02", 410.0))
        // endTs = 2026-06-02 08:00 UTC; onset 600 min earlier → 600 min IN BED, but asleep = 410.
        val session = SleepSession(
            deviceId = "my-whoop", startTs = 1780351200L, endTs = 1780387200L, efficiency = 90.0,
        )
        val m = buildSleepModel(days, session = session)!!
        // need = max(450, mean asleep[420,410]=415) = 450. hours-vs-needed reads ASLEEP 410, not 600.
        assertEquals(410.0 / 450.0 * 100.0, m.hoursVsNeeded.latest!!, 1e-9)
        // Debt tile reads ASLEEP too: max(0, 450 − 410) = 40, never max(0, 450 − 600) = 0.
        assertEquals(40.0, m.sleepDebt.latest!!, 1e-9)
        // The debt TILE and the LEDGER agree (both asleep over the full history) — the #5 symptom.
        assertEquals(m.sleepDebt.latest, -m.sleepDebtLedger.nights.last().deltaMin, 1e-9)
    }

    /** A passed session must give the SAME tiles/ledger as no session — there is no display-time
     *  in-bed swap left. (Stage cards still update from the reclipped stagesJSON; tiles do not.) */
    @Test
    fun passingASessionDoesNotChangeTheTiles() {
        val days = listOf(day("2026-06-01", 420.0), day("2026-06-02", 410.0))
        val session = SleepSession(
            deviceId = "my-whoop", startTs = 1780351200L, endTs = 1780387200L, efficiency = 90.0,
        )
        val withSession = buildSleepModel(days, session = session)!!
        val noSession = buildSleepModel(days, session = null)!!
        assertEquals(noSession.performance, withSession.performance)
        assertEquals(noSession.hoursVsNeeded, withSession.hoursVsNeeded)
        assertEquals(noSession.sleepDebt, withSession.sleepDebt)
        assertEquals(noSession.sleepDebtLedger, withSession.sleepDebtLedger)
        assertEquals(noSession.typicalTotalMin, withSession.typicalTotalMin)
    }

    /** A detected nap repays debt on every local fallback surface without changing the canonical
     *  main-night total used by Hours vs Needed. Mirrors StrandTests/SleepNapDebtTests.swift. */
    @Test
    fun napSleepRepaysDebtWithoutChangingMainNightMetrics() {
        val zone = ZoneId.systemDefault()
        val nightStart = LocalDate.of(2026, 6, 2).atStartOfDay(zone).toEpochSecond()
        val napStart = LocalDate.of(2026, 6, 2).atTime(14, 0).atZone(zone).toEpochSecond()
        val night = SleepSession(
            deviceId = "my-whoop", startTs = nightStart, endTs = nightStart + 416 * 60,
            stagesJSON = """{"awake":24,"light":214,"deep":82,"rem":96}""", // 392 asleep
        )
        val nap = SleepSession(
            deviceId = "my-whoop", startTs = napStart, endTs = napStart + 50 * 60,
            stagesJSON = """{"awake":2,"light":30,"deep":10,"rem":8}""", // 48 asleep
        )
        val napCredit = napSleepMinutesByDay(listOf(night, nap))
        assertEquals(48.0, napCredit["2026-06-02"]!!, 1e-9)

        // Mean main-night sleep is exactly 480 min, so personal need is 480. The latest day is
        // 392 main + 48 nap = 440 credited: 40 min debt rather than the old 88 min.
        val m = buildSleepModel(
            days = listOf(day("2026-06-01", 568.0), day("2026-06-02", 392.0)),
            session = night,
            napSleepMinByDay = napCredit,
        )!!
        assertEquals(40.0, m.sleepDebt.latest!!, 1e-9)
        assertEquals(40.0 / 60.0, m.trendDebtHours.last(), 1e-9)
        assertEquals(440.0, m.sleepDebtLedger.nights.last().sleptMin, 1e-9)
        assertEquals(-40.0, m.sleepDebtLedger.nights.last().deltaMin, 1e-9)
        assertEquals(392.0 / 480.0 * 100.0, m.hoursVsNeeded.latest!!, 1e-9)
    }

    @Test
    fun bridgedMainNightFragmentsAreNotDoubleCreditedAsNaps() {
        val zone = ZoneId.systemDefault()
        val midnight = LocalDate.of(2026, 6, 2).atStartOfDay(zone).toEpochSecond()
        val first = SleepSession(
            deviceId = "my-whoop", startTs = midnight - 60 * 60, endTs = midnight + 60 * 60,
            stagesJSON = """{"awake":10,"light":70,"deep":25,"rem":15}""",
        )
        val second = SleepSession(
            deviceId = "my-whoop", startTs = midnight + 90 * 60, endTs = midnight + 300 * 60,
            stagesJSON = """{"awake":15,"light":120,"deep":40,"rem":35}""",
        )
        val napStart = midnight + 14 * 60 * 60
        val nap = SleepSession(
            deviceId = "my-whoop", startTs = napStart, endTs = napStart + 50 * 60,
            stagesJSON = """{"awake":2,"light":30,"deep":10,"rem":8}""",
        )

        val credit = napSleepMinutesByDay(listOf(first, second, nap))
        assertEquals(48.0, credit["2026-06-02"]!!, 1e-9)
    }

    /** Browsing a PAST night (selectedDay = an earlier day) leaves the at-a-glance tiles and the
     *  "Last 14 nights" ledger LATEST-anchored (full history) — only the hero re-points. The window
     *  is one cross-platform definition: full history, exactly as iOS keeps repo.days. (#5) */
    @Test
    fun browsingAPastNightKeepsTilesLatestAnchored() {
        val days = listOf(day("2026-06-01", 420.0), day("2026-06-02", 410.0), day("2026-06-03", 400.0))
        val latestView = buildSleepModel(days, session = null)!!                       // newest night
        val browsedView = buildSleepModel(days, session = null, selectedDay = "2026-06-01")!!
        // Tiles, need, typical and the ledger are identical regardless of which night is browsed.
        assertEquals(latestView.performance, browsedView.performance)
        assertEquals(latestView.sleepDebt, browsedView.sleepDebt)
        assertEquals(latestView.sleepDebtLedger, browsedView.sleepDebtLedger)
        assertEquals(latestView.typicalTotalMin, browsedView.typicalTotalMin)
        // The HERO does follow the browsed night — its stages come from the selected day's row.
        assertNotEquals(latestView.stages, browsedView.stages)
    }
}
