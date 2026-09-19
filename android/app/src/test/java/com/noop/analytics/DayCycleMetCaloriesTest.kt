package com.noop.analytics

import android.content.Context
import androidx.room.Room
import com.noop.data.DailyMetric
import com.noop.data.HrSample
import com.noop.data.OuraMetSampleEntity
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * #2242: the day-cycle fold makes `analyzeDay`'s MET-vs-HR energy decision over its own window.
 *
 * 2026-09-17, first hardware day of the MET-calories toggle (iOS): `analyzeDay` logged the ring's MET
 * number (1220 kcal) and the export held 743 — Keytel over the wake-to-wake HR window, which this fold
 * recomputed unconditionally and the integration wrote over the day's `activeKcalEst`. Same shape on
 * Android. Twin of Swift `DayCycleRecoveryTests` (#2242 section): a covered MET cycle carries the MET
 * total, a thin one is WITHHELD (no HR substitute), and the toggle off is the byte-identical Keytel path.
 * Real Room in memory under Robolectric so the fold's own reads are the ones under test.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class DayCycleMetCaloriesTest {

    private val owner = "oura-ring"
    private val onset = 1_755_208_800L - 2 * 3_600L          // 2026-08-14 22:00 UTC
    private val wake = onset + 8 * 3_600L
    private val now = wake + 12 * 3_600L
    private val day = AnalyticsEngine.dayString(wake, 0L)

    private val db = Room.inMemoryDatabaseBuilder(
        RuntimeEnvironment.getApplication() as Context, WhoopDatabase::class.java,
    ).allowMainThreadQueries().build()
    private val repo = WhoopRepository(db.whoopDao())

    @After fun close() = db.close()

    /** One 8-h main sleep, `now` 12 h after wake, 0.2 Hz HR across the cycle so Keytel has something to say. */
    private fun seedCycle(): DayResult = runBlocking {
        repo.insertHr((onset until now step 5L).map { HrSample(owner, it, if (it < wake) 52 else 74) })
        val sleep = DetectedSleep(
            start = onset, end = wake, efficiency = 0.9,
            stages = listOf(StageSegment(onset, wake, "light")), restingHR = 50, avgHRV = null,
        )
        DayResult(
            daily = DailyMetric(deviceId = "$owner-noop", day = day, totalSleepMin = 460.0, restingHr = 50),
            sleepSessions = listOf(sleep), workouts = emptyList(), recovery = null, strain = null,
        )
    }

    private fun compute(night: DayResult, ouraMetCalories: Boolean): PhysiologicalStepCycleEngine.Result = runBlocking {
        PhysiologicalStepCycleEngine.compute(
            scoredNights = listOf(night), editedRows = emptyList(),
            resolvedScoreOwnerByDay = mapOf(day to owner),
            candidatePriorities = listOf(owner to 0), stepWitnessByDay = emptyMap(), repo = repo,
            tzOffsetSeconds = 0L, habitualMidsleepSec = null, windowStart = onset - 86_400L,
            nowSeconds = now, stepTicksPerStep = 1.0, stepsTraceSink = null,
            dayCycleMode = DayCycleMode.SLEEP_ONSET, profile = UserProfile(), maxHROverride = null,
            effortMethod = StrainScorer.Method.EDWARDS, ouraMetCalories = ouraMetCalories,
        )
    }

    @Test
    fun coveredMetCycleCarriesTheMetTotalNotKeytel() {
        val night = seedCycle()
        // Every minute of the cycle at 1.1 MET, one 30-min 4.0 bout after wake.
        val met = (onset until now step 60L).map {
            OuraMetSampleEntity(owner, it, if (it >= wake + 3_600 && it < wake + 5_400) 4.0 else 1.1, 0, 60)
        }
        runBlocking { assertEquals(met.size, repo.insertOuraMetSamples(met)) }

        val result = compute(night, ouraMetCalories = true)

        val expected = Calories.estimateDayEnergyFromMet(
            met.map { Calories.MetSample(it.ts, it.met, it.epochS) }, UserProfile(), onset, now,
        )
        assertEquals(1.0, expected.coverageFraction, 1e-9)
        assertEquals(expected.totalKcal, result.cycleCaloriesByWakeDay[day]!!, 1e-9)
        // And the fold carries it onto the row (the write that used to bring Keytel back).
        val applied = DayCycleIntelligenceIntegration.apply(night.daily, result, "$owner-noop", mutableListOf())
        assertEquals(expected.totalKcal, applied.activeKcalEst!!, 1e-9)
    }

    @Test
    fun thinMetCoverageWithholdsTheCycleAndDoesNotSubstituteKeytel() {
        val night = seedCycle()
        // 10 % of the cycle covered — below the floor — with plenty of HR alongside.
        val met = (onset until onset + 2 * 3_600L step 60L).map { OuraMetSampleEntity(owner, it, 3.0, 0, 60) }
        runBlocking { repo.insertOuraMetSamples(met) }

        val result = compute(night, ouraMetCalories = true)

        assertNull("withheld: no entry, no HR figure in its place", result.cycleCaloriesByWakeDay[day])
        val applied = DayCycleIntelligenceIntegration.apply(night.daily, result, "$owner-noop", mutableListOf())
        assertNull(applied.activeKcalEst)
        assertNotNull("the rest of the fold is untouched by the decision", result.cycleStrainByWakeDay[day])
    }

    @Test
    fun toggleOffIsTheKeytelPath() {
        val night = seedCycle()
        val met = (onset until now step 60L).map { OuraMetSampleEntity(owner, it, 4.0, 0, 60) }
        runBlocking { repo.insertOuraMetSamples(met) }

        val off = compute(night, ouraMetCalories = false)
        val keytel = off.cycleCaloriesByWakeDay[day]
        assertNotNull(keytel)
        assertTrue(keytel!! > 0)
        // An empty MET table with the toggle ON is the same as off: the HR path, byte for byte.
        runBlocking { db.whoopDao().deleteOuraMetFor(owner) }
        assertEquals(keytel, compute(night, ouraMetCalories = true).cycleCaloriesByWakeDay[day]!!, 0.0)
    }
}
