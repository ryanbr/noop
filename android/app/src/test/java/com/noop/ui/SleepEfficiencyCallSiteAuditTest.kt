package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * Compare and Explore each carry a private column map, and each mapped Sleep Efficiency ("%") straight to
 * `DailyMetric.efficiency` (a 0–1 fraction). Both now go through
 * [com.noop.data.WhoopRepository.dailyColumn], whose scale [com.noop.data.SleepEfficiencyUnitTest] pins.
 * The maps are private and build UI strings, so this audits the SOURCE: neither file may read the raw
 * column, which is what a third picker added by copy would do.
 */
class SleepEfficiencyCallSiteAuditTest {

    /** Tolerant of the test host's working dir, as in [ResolvedSeriesCallSiteAuditTest]. */
    private fun uiSourceDir(): File? {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(userDir, "src/main/java/com/noop/ui"),
            File(userDir, "app/src/main/java/com/noop/ui"),
            File(userDir, "android/app/src/main/java/com/noop/ui"),
        ).firstOrNull { it.isDirectory }
    }

    @Test
    fun compareAndExplore_readEfficiencyThroughTheSharedColumnMap() {
        val dir = uiSourceDir()
        assumeTrue("ui source not locatable from ${System.getProperty("user.dir")}", dir != null)
        for (name in listOf("CompareScreen.kt", "TrendsExploreScreen.kt")) {
            val code = File(dir!!, name).readLines().map { it.substringBefore("//") }
            assertEquals(
                "$name must not read DailyMetric.efficiency directly",
                emptyList<String>(),
                code.filter { Regex("\\.efficiency\\b").containsMatchIn(it) },
            )
            assertEquals(
                "$name must resolve sleep efficiency through WhoopRepository.dailyColumn exactly once",
                1,
                code.count { it.contains("WhoopRepository.dailyColumn(\"sleep_efficiency\"") },
            )
        }
    }
}
