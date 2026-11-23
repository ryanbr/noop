package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * `sleep_efficiency` is a percentage everywhere it is read: a metricSeries point is WHOOP's 0–100 figure
 * and the catalogs label the key "%". [DailyMetric.efficiency] is the 0–1 fraction, and it was passed
 * through unscaled, so Compare and Explore drew ~0.9 where they meant ~90. Twin of the Swift
 * `SleepEfficiencyUnitTests`; the screens' own half is [com.noop.ui.SleepEfficiencyCallSiteAuditTest].
 */
class SleepEfficiencyUnitTest {

    private val strap = "my-whoop"
    private val key = "sleep_efficiency"

    private fun daily(day: String, efficiency: Double?, source: String = strap) =
        DailyMetric(deviceId = source, day = day, totalSleepMin = 420.0, efficiency = efficiency)

    /** A repository over fixture rows. Any dao call the resolver should not need throws. */
    private fun repo(series: List<MetricSeriesRow>, days: List<DailyMetric>): WhoopRepository {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "metricSeries" -> series.filter {
                    it.deviceId == args!![0] && it.key == args[1] &&
                        it.day >= args[2] as String && it.day <= args[3] as String
                }.sortedBy { it.day }
                "dailyMetricsRange" -> days.filter {
                    it.deviceId == args!![0] && it.day >= args[1] as String && it.day <= args[2] as String
                }.sortedBy { it.day }
                else -> throw UnsupportedOperationException("resolver must not call ${method.name}")
            }
        } as WhoopDao
        return WhoopRepository(dao)
    }

    /** Expected values are stdout of the Swift twin compiled standalone, pasted verbatim. Zero tolerance on
     *  purpose: the two platforms must produce the same bits, FP dust included. */
    @Test
    fun dailyColumn_returnsPercent() {
        val swiftOracle = listOf(
            0.0 to 0.0,
            0.005 to 0.5,
            0.29 to 28.999999999999996,
            0.57 to 56.99999999999999,
            0.58 to 57.99999999999999,
            0.7 to 70.0,
            0.785 to 78.5,
            0.875 to 87.5,
            0.923 to 92.30000000000001,
            0.95 to 95.0,
            0.9876543210987654 to 98.76543210987654,
            1.0 to 100.0,
            1.0000000000000002 to 100.00000000000003, // FP noise above a whole night is still a fraction
            1.5 to 150.0, // the split itself, matching the v18 -> v19 heal's `> 1.5`
            1.5000000000000002 to 1.5000000000000002,
            62.0 to 62.0, // Fitbit / Oura-export / Mi Band rows are percentages
            88.5 to 88.5,
            92.3 to 92.3,
            100.0 to 100.0,
        )
        for ((stored, percent) in swiftOracle) {
            assertEquals(
                "stored $stored",
                percent,
                WhoopRepository.dailyColumn(key, daily("2026-06-12", stored))!!,
                0.0,
            )
        }
        assertNull(WhoopRepository.dailyColumn(key, daily("2026-06-12", null)))
    }

    /** The reported shape: an import covering the older days, strap-only nights after it. */
    @Test
    fun mixedImportedAndStrapOnlyDays_shareOneScale() = runBlocking {
        val repo = repo(
            // The 8th carries the fraction in its row AND the percentage in its series point; the series
            // point must still win, and must not be scaled a second time.
            series = listOf(MetricSeriesRow(deviceId = strap, day = "2026-06-08", key = key, value = 92.3)),
            days = listOf(
                daily("2026-06-08", 0.5),
                daily("2026-06-09", 0.75),
                daily("2026-06-10", 0.875, source = "$strap-noop"),
            ),
        )

        val resolved = repo.resolvedSeries(key, strap, "0000-00-00", "9999-99-99", strapDeviceId = strap)

        assertEquals(
            listOf("2026-06-08" to 92.3, "2026-06-09" to 75.0, "2026-06-10" to 87.5),
            resolved.values,
        )
    }

    /** A row whose column already holds a percentage (the demo seeder writes one under the strap id) sits
     *  beside fraction rows without being scaled twice. */
    @Test
    fun percentScaleRow_isNotScaledTwice() = runBlocking {
        val repo = repo(
            series = emptyList(),
            days = listOf(daily("2026-06-08", 88.5), daily("2026-06-09", 0.875)),
        )

        val resolved = repo.resolvedSeries(key, strap, "0000-00-00", "9999-99-99", strapDeviceId = strap)

        assertEquals(listOf("2026-06-08" to 88.5, "2026-06-09" to 87.5), resolved.values)
    }
}
