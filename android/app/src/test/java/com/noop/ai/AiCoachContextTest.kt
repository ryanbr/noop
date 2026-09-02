package com.noop.ai

import com.noop.data.DailyMetric
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * Pins the #124 fix: the coach grounds itself in the MERGED raw+computed daily view
 * ([WhoopRepository.daysMerged]) — the same per-field-coalesce path every screen reads — so a
 * strap-only user whose scores live under the computed "my-whoop-noop" source gets real numbers
 * in the context instead of the no-data sentinel.
 *
 * Exercises the pure [AiCoach.buildContext] on lists shaped by the real
 * [WhoopRepository.Companion.mergeDaily]. The repository behind the coach is a throwing stub,
 * which doubles as proof the context builder never touches storage.
 */
class AiCoachContextTest {

    /** AiCoach whose repository throws on ANY dao call — buildContext must stay pure. */
    private fun coach(): AiCoach {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ ->
            throw UnsupportedOperationException("buildContext must not touch the repo (${method.name})")
        } as WhoopDao
        return AiCoach(WhoopRepository(dao))
    }

    /** A fully populated on-device computed day — what IntelligenceEngine writes for strap-only users. */
    private fun computedRow(day: String) = DailyMetric(
        deviceId = "my-whoop-noop",
        day = day,
        totalSleepMin = 450.0, // 7.5h
        restingHr = 52,
        avgHrv = 65.0,
        recovery = 67.0,
        strain = 12.3,
    )

    /**
     * The sleep detail the coach could not see. A user asked why it said it had no access to sleep
     * stages, and it was answering honestly: `rest 7.5h` was every word the context carried about a
     * night, while `deepMin`/`remMin`/`lightMin`/`efficiency` sat unread on the SAME row.
     *
     * Absence is asserted too, in the same shape as every other field: a night with no staging must
     * say "-" rather than go quiet, so the model cannot read a missing stage as a zero.
     */
    @Test
    fun sleepStagesAndEfficiencyReachTheCoach() {
        val withStages = computedRow(june(1)).copy(
            deepMin = 84.0,      // 1.4h
            remMin = 114.0,      // 1.9h
            lightMin = 252.0,    // 4.2h
            efficiency = 0.94,
        )
        val ctx = coach().buildContext(listOf(withStages))
        assertTrue("deep", ctx.contains("deep 1.4h"))
        assertTrue("REM", ctx.contains("REM 1.9h"))
        assertTrue("light", ctx.contains("light 4.2h"))
        assertTrue("efficiency", ctx.contains("eff 94%"))
        assertTrue("the prompt must claim what it now sends",
            AiCoach.DEFAULT_SYSTEM_PROMPT.contains("deep/REM/light"))
    }

    /**
     * Efficiency arrives as a PERCENTAGE on some import paths, not a 0-1 fraction — SleepMetricDetail
     * and SleepModel each guard against that inline. Without the same guard here a bare `* 100` sends
     * the coach "eff 9400%", and a model handed a nonsense number reasons about it confidently.
     */
    @Test
    fun anEfficiencyStoredAsAPercentageIsNotMultipliedAgain() {
        val asFraction = coach().buildContext(listOf(computedRow(june(1)).copy(efficiency = 0.94)))
        val asPercent = coach().buildContext(listOf(computedRow(june(1)).copy(efficiency = 94.0)))
        assertTrue("fraction", asFraction.contains("eff 94%"))
        assertTrue("percentage", asPercent.contains("eff 94%"))
        assertFalse("never multiplied twice", asPercent.contains("9400%"))
    }

    /** A night with no staging says so, rather than the field vanishing from the line. */
    @Test
    fun anUnstagedNightReportsDashesNotSilence() {
        val ctx = coach().buildContext(listOf(computedRow(june(1))))
        assertTrue("deep", ctx.contains("deep -"))
        assertTrue("REM", ctx.contains("REM -"))
        assertTrue("light", ctx.contains("light -"))
        assertTrue("efficiency", ctx.contains("eff -"))
    }

    /** Consecutive June days, oldest first (lexicographic = chronological for YYYY-MM-DD). */
    private fun june(dayOfMonth: Int) = "2026-06-%02d".format(dayOfMonth)

    /**
     * The #124 shape: a live-strap user has NO imported rows at all; every score sits under the
     * computed source. The merged list must carry those numbers into the context — never the
     * "no synced days" sentinel the raw read used to produce.
     */
    @Test
    fun computedOnlyMergedDaysGroundTheCoachInRealNumbers() {
        val merged = WhoopRepository.mergeDaily(
            imported = emptyList(),
            computed = (1..14).map { computedRow(june(it)) },
        )
        assertEquals(14, merged.size)

        val ctx = coach().buildContext(merged)

        // Real figures, exactly as buildContext formats them.
        assertTrue("daily recovery", ctx.contains("charge 67%"))
        assertTrue("daily strain", ctx.contains("effort 12.3"))
        assertTrue("daily sleep", ctx.contains("rest 7.5h"))
        assertTrue("daily HRV", ctx.contains("HRV 65ms"))
        assertTrue("daily RHR", ctx.contains("RHR 52bpm"))
        assertTrue(
            "latest snapshot",
            ctx.contains("Most recent day (${june(14)}): charge 67%, effort 12.3."),
        )
        // The #124 symptom: with data present the no-data sentinel must NOT appear.
        assertFalse("no-data sentinel leaked", ctx.contains("No wearable data is available yet"))
    }

    /**
     * Sparse import, no computed source: sleep is recorded but recovery/strain/HRV/RHR never are.
     * Missing values must render as dashes / "n/a" — the context must not invent a score.
     */
    @Test
    fun sparseRawOnlyDaysRenderDashesNotInventedNumbers() {
        val merged = WhoopRepository.mergeDaily(
            imported = (1..14).map {
                DailyMetric(deviceId = "my-whoop", day = june(it), totalSleepMin = 420.0) // 7h
            },
            computed = emptyList(),
        )

        val ctx = coach().buildContext(merged)

        // Sleep is real; everything unrecorded is a dash on every daily line.
        // Repinned for the stage fields (#1817), NOT weakened: still one contiguous line asserting that
        // every unrecorded value is a dash, now including deep/REM/light/eff. Keeping it contiguous is
        // the point — it is what catches a field silently dropping out of the line.
        assertTrue(
            "daily dashes",
            ctx.contains("charge -, effort -, rest 7h, deep -, REM -, light -, eff -, HRV -, RHR -"),
        )
        assertTrue("latest snapshot n/a", ctx.contains("charge n/a, effort n/a"))
        // Never an invented score: no digit ever follows "recovery " or "HRV ".
        assertFalse("invented charge", Regex("charge \\d").containsMatchIn(ctx))
        assertFalse("invented HRV", Regex("HRV \\d").containsMatchIn(ctx))
        // Data exists (sleep), so the no-data sentinel is still wrong here.
        assertFalse("no-data sentinel leaked", ctx.contains("No wearable data is available yet"))
    }
}
