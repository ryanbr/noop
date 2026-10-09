package com.noop.push

import androidx.room.Room
import com.noop.data.DailyMetric
import com.noop.data.MetricSeriesRow
import com.noop.data.SleepSession
import com.noop.data.WhoopDatabase
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.time.LocalDateTime
import java.time.ZoneId

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class PushDaoSleepPerformanceTest {
    @Test
    fun v11ProjectsOnlyTheMatchingMetricSeriesScoreAndV10StaysUnchanged() = runBlocking {
        val database = Room.inMemoryDatabaseBuilder(
            RuntimeEnvironment.getApplication(),
            WhoopDatabase::class.java,
        ).allowMainThreadQueries().build()
        try {
            val day = "2026-08-18"
            database.whoopDao().upsertDailyMetrics(
                listOf(
                    DailyMetric(deviceId = "strap-noop", day = day, totalSleepMin = 430.0),
                    DailyMetric(deviceId = "other-noop", day = day, totalSleepMin = 420.0),
                ),
            )
            database.whoopDao().upsertMetricSeries(
                listOf(
                    MetricSeriesRow("strap-noop", day, "sleep_performance", 91.5),
                    MetricSeriesRow("other-noop", day, "sleep_performance", 12.0),
                    MetricSeriesRow("strap-noop", day, "recovery", 70.0),
                    MetricSeriesRow("strap-noop", day, "sleep_consistency", 77.0),
                    MetricSeriesRow("other-noop", day, "sleep_consistency", 11.0),
                ),
            )
            val window = PushWindow(day, day, 1L, 2L)
            val source = database.pushDao()

            val legacy = source.mutableRows(
                PushMutableTable.DAILY_METRIC, "strap-noop", window, 10, PushProtocol.VERSION,
            ).single()
            val current = source.mutableRows(
                PushMutableTable.DAILY_METRIC, "strap-noop", window, 10, PushProtocol.LATEST_VERSION,
            ).single()

            assertFalse(legacy.data.containsKey("sleepPerformance"))
            assertFalse(legacy.data.containsKey("sleepConsistency"))
            assertTrue(current.data.containsKey("sleepPerformance"))
            assertEquals(91.5, current.data["sleepPerformance"] as Double, 0.0)
            assertEquals(77.0, current.data["sleepConsistency"] as Double, 0.0)
            assertNull(current.data["recovery"])
        } finally {
            database.close()
        }
    }

    @Test
    fun v11EmitsNullWhenTheSourceHasNoScoreOrConsistencyHistory() = runBlocking {
        val database = Room.inMemoryDatabaseBuilder(
            RuntimeEnvironment.getApplication(),
            WhoopDatabase::class.java,
        ).allowMainThreadQueries().build()
        try {
            val day = "2026-08-18"
            database.whoopDao().upsertDailyMetrics(
                listOf(DailyMetric(deviceId = "strap-noop", day = day, totalSleepMin = 430.0)),
            )
            val current = database.pushDao().mutableRows(
                PushMutableTable.DAILY_METRIC,
                "strap-noop",
                PushWindow(day, day, 1L, 2L),
                10,
                PushProtocol.LATEST_VERSION,
            ).single()

            assertNull(current.data["sleepPerformance"])
            assertNull(current.data["sleepConsistency"])
        } finally {
            database.close()
        }
    }

    @Test
    fun v11DoesNotMixImportedConsistencyWithTheComputedSeries() = runBlocking {
        val database = Room.inMemoryDatabaseBuilder(
            RuntimeEnvironment.getApplication(),
            WhoopDatabase::class.java,
        ).allowMainThreadQueries().build()
        try {
            val firstDay = "2026-08-17"
            val latestDay = "2026-08-18"
            val zone = ZoneId.systemDefault()
            fun ts(date: String, hour: Int) =
                LocalDateTime.parse("${date}T%02d:00".format(hour)).atZone(zone).toEpochSecond()
            database.whoopDao().upsertDailyMetrics(
                listOf(
                    DailyMetric(deviceId = "strap-noop", day = firstDay, totalSleepMin = 430.0),
                    DailyMetric(deviceId = "strap-noop", day = latestDay, totalSleepMin = 430.0),
                ),
            )
            database.whoopDao().upsertMetricSeries(
                listOf(MetricSeriesRow("strap-noop", latestDay, "sleep_consistency", 77.0)),
            )
            database.whoopDao().upsertSleepSessions(
                listOf(
                    SleepSession("strap-noop", ts("2026-08-14", 22), ts("2026-08-15", 6)),
                    SleepSession("strap-noop", ts("2026-08-15", 22), ts("2026-08-16", 6)),
                    SleepSession("strap-noop", ts("2026-08-16", 22), ts("2026-08-17", 6)),
                    SleepSession("strap-noop", ts("2026-08-17", 22), ts("2026-08-18", 6)),
                ),
            )

            val rows = database.pushDao().mutableRows(
                PushMutableTable.DAILY_METRIC,
                "strap-noop",
                PushWindow(firstDay, latestDay, ts(firstDay, 0), ts("2026-08-19", 0)),
                10,
                PushProtocol.LATEST_VERSION,
            ).associateBy { it.key["day"] }

            // The local calculation could produce a point for firstDay, but the Sleep screen selects
            // the imported series for the entire range when its latest day has an imported point.
            assertNull(rows[firstDay]?.data?.get("sleepConsistency"))
            assertEquals(77.0, rows[latestDay]?.data?.get("sleepConsistency") as Double, 0.0)
        } finally {
            database.close()
        }
    }

    @Test
    fun v11ComputesTheExistingBedtimeConsistencyForMatchingWakeDays() = runBlocking {
        val database = Room.inMemoryDatabaseBuilder(
            RuntimeEnvironment.getApplication(),
            WhoopDatabase::class.java,
        ).allowMainThreadQueries().build()
        try {
            val day = "2026-08-18"
            val zone = ZoneId.systemDefault()
            fun ts(date: String, hour: Int, minute: Int = 0) =
                LocalDateTime.parse("${date}T%02d:%02d".format(hour, minute)).atZone(zone).toEpochSecond()
            database.whoopDao().upsertDailyMetrics(
                listOf(DailyMetric(deviceId = "strap-noop", day = day, totalSleepMin = 430.0)),
            )
            database.whoopDao().upsertSleepSessions(
                listOf(
                    SleepSession("strap-noop", ts("2026-08-15", 22), ts("2026-08-16", 6)),
                    SleepSession("strap-noop", ts("2026-08-16", 23), ts("2026-08-17", 6)),
                    // The corrected onset is the value used by the Sleep screen's consistency formula.
                    SleepSession(
                        "strap-noop", ts("2026-08-17", 23), ts("2026-08-18", 7),
                        startTsAdjusted = ts("2026-08-18", 0),
                    ),
                    // A second source must not influence the rating for strap-noop.
                    SleepSession("other-noop", ts("2026-08-15", 18), ts("2026-08-16", 6)),
                    SleepSession("other-noop", ts("2026-08-16", 20), ts("2026-08-17", 6)),
                    SleepSession("other-noop", ts("2026-08-17", 22), ts("2026-08-18", 7)),
                ),
            )

            val current = database.pushDao().mutableRows(
                PushMutableTable.DAILY_METRIC,
                "strap-noop",
                PushWindow(day, day, ts(day, 0), ts("2026-08-19", 0)),
                10,
                PushProtocol.LATEST_VERSION,
            ).single()

            // 22:00, 23:00, and corrected 00:00 have a population SD of sqrt(2400) minutes:
            // exactly the existing SleepModel formula 100 * (1 - SD / 120).
            assertEquals(
                100.0 * (1.0 - kotlin.math.sqrt(2400.0) / 120.0),
                current.data["sleepConsistency"] as Double,
                1e-9,
            )
        } finally {
            database.close()
        }
    }
}
