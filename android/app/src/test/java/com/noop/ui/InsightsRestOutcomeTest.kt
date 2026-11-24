package com.noop.ui

import com.noop.analytics.RestScorer
import com.noop.data.DailyMetric
import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.lang.reflect.Proxy

/**
 * The Insights "Rest" outcome is the Rest score, the `sleep_performance` series Apple's Insights ranks.
 * Both Android screens picked `DailyMetric.efficiency`: another metric, normally on a 0–1 scale.
 */
class InsightsRestOutcomeTest {

    private fun day(n: Int, efficiency: Double?) = DailyMetric(
        deviceId = "my-whoop", day = "2026-06-%02d".format(n), totalSleepMin = 420.0,
        efficiency = efficiency, recovery = 60.0, avgHrv = 70.0, restingHr = 52,
    )

    /** Rest comes from the series whichever scale the efficiency column happens to hold. */
    @Test
    fun restOutcome_isTheRestScore_notEfficiency() {
        val outcomes = InsightsHubViewModel.outcomeDays(
            days = listOf(day(8, efficiency = 0.95), day(9, efficiency = 88.5)),
            restByDay = mapOf("2026-06-08" to 71.0, "2026-06-09" to 64.0),
        )
        assertEquals(
            mapOf("2026-06-08" to 71.0, "2026-06-09" to 64.0),
            outcomes[InsightsOutcome.Sleep.key],
        )
        assertEquals("71%", InsightsOutcome.Sleep.format(71.0))
    }

    /** A night with an efficiency but no Rest score has no Rest outcome; the two must not mix in a mean. */
    @Test
    fun restOutcome_isAbsentWithoutARestScore() {
        val outcomes = InsightsHubViewModel.outcomeDays(
            days = listOf(day(8, efficiency = 0.95), day(9, efficiency = 0.9)),
            restByDay = mapOf("2026-06-08" to 71.0),
        )
        assertEquals(mapOf("2026-06-08" to 71.0), outcomes[InsightsOutcome.Sleep.key])
    }

    /** The other three outcomes still read their columns. */
    @Test
    fun otherOutcomes_readTheirDailyColumns() {
        val outcomes = InsightsHubViewModel.outcomeDays(listOf(day(8, efficiency = 0.95)), emptyMap())
        assertEquals(mapOf("2026-06-08" to 60.0), outcomes["recovery"])
        assertEquals(mapOf("2026-06-08" to 70.0), outcomes["hrv"])
        assertEquals(mapOf("2026-06-08" to 52.0), outcomes["rhr"])
        assertEquals(emptyMap<String, Double>(), outcomes["sleep_performance"])
    }

    /** End to end through the ranker: the two group means a mover card prints are Rest points. On the
     *  efficiency column every night below is 0.9, so there was no difference to rank at all. */
    @Test
    fun rankedRestEffect_comparesRestPoints() {
        val days = (1..20).map { day(it, efficiency = 0.9) }
        // Irregular yes days, so lag 0 is the best lag on its own; Rest sits 20 points lower on them (+/- 1
        // so the two groups have variance).
        val yesDays = setOf(1, 4, 5, 8, 11, 12, 13, 17, 18, 20)
        val yes = days.filterIndexed { i, _ -> (i + 1) in yesDays }.map { it.day }
        val no = days.filterIndexed { i, _ -> (i + 1) !in yesDays }.map { it.day }
        val rest = yes.mapIndexed { i, d -> d to 60.0 + (if (i % 2 == 0) 1 else -1) }.toMap() +
            no.mapIndexed { i, d -> d to 80.0 + (if (i % 2 == 0) 1 else -1) }.toMap()

        val snapshot = InsightsHubViewModel.Snapshot(
            loaded = true,
            behaviours = mapOf("Alcohol" to yes.toSet()),
            controls = mapOf("Alcohol" to no.toSet()),
            outcomeByKey = InsightsHubViewModel.outcomeDays(days, rest),
        )
        val ranked = InsightsHubViewModel().rankFor(snapshot, InsightsOutcome.Sleep)

        val effect = ranked.single().effect
        assertEquals(60.0, effect.meanWith, 1e-9)
        assertEquals(80.0, effect.meanWithout, 1e-9)
        assertEquals("60%", InsightsOutcome.Sleep.format(effect.meanWith))
    }

    /** The read: the import wins its day, a strap-only night resolves under the ACTIVE strap's computed
     *  sibling, and a night with no series point derives the same composite Today shows for it. */
    @Test
    fun restByDay_resolvesImportedComputedAndDerivedNights() = runBlocking {
        val strap = "whoop-ABC123"
        val derived = DailyMetric(
            deviceId = "$strap-noop", day = "2026-06-10", totalSleepMin = 450.0, efficiency = 0.92,
            deepMin = 90.0, remMin = 110.0, lightMin = 250.0,
        )
        val series = listOf(
            MetricSeriesRow("my-whoop", "2026-06-08", "sleep_performance", 83.0),
            MetricSeriesRow("$strap-noop", "2026-06-08", "sleep_performance", 70.0),
            MetricSeriesRow("$strap-noop", "2026-06-09", "sleep_performance", 77.0),
        )
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "metricSeries" -> series.filter { it.deviceId == args!![0] && it.key == args[1] }
                "dailyMetricsRange" -> listOf(derived).filter { it.deviceId == args!![0] }
                else -> throw UnsupportedOperationException("resolver must not call ${method.name}")
            }
        } as WhoopDao

        val expected = RestScorer.restFromDaily(derived)
        assertNotNull(expected)
        assertTrue("derived Rest must be on the 0–100 scale, got $expected", expected!! > 1.5)
        assertEquals(
            mapOf("2026-06-08" to 83.0, "2026-06-09" to 77.0, "2026-06-10" to expected),
            insightsRestByDay(WhoopRepository(dao), strap),
        )
    }

    /** InsightsScreen's outcome enum is private and builds UI strings, so its half is audited as source:
     *  neither screen may read the efficiency column, and each must load the shared Rest read. */
    @Test
    fun bothInsightsScreens_loadRestThroughTheSharedRead() {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val dir = listOf(
            File(userDir, "src/main/java/com/noop/ui"),
            File(userDir, "app/src/main/java/com/noop/ui"),
            File(userDir, "android/app/src/main/java/com/noop/ui"),
        ).firstOrNull { it.isDirectory }
        assumeTrue("ui source not locatable from $userDir", dir != null)
        for (name in listOf("InsightsScreen.kt", "InsightsHubScreen.kt")) {
            val code = File(dir!!, name).readLines().map { it.substringBefore("//") }
            assertEquals(
                "$name must not read DailyMetric.efficiency",
                emptyList<String>(),
                code.filter { Regex("\\.efficiency\\b").containsMatchIn(it) },
            )
            assertEquals(
                "$name must load Rest through insightsRestByDay",
                1,
                code.count { it.contains("insightsRestByDay(vm.repo, vm.activeStrapId)") },
            )
        }
    }
}
