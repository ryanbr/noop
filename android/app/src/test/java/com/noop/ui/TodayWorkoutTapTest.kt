package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * #1694: the Today "Latest Workouts" tiles open the SAME read-only detail the Workouts list opens.
 *
 * Compose wiring has no logic function to assert against, so this reads the sources — the idiom
 * [ResolvedSeriesCallSiteAuditTest] already uses. What it pins is not cosmetic:
 *
 * The Today sections are LazyColumn items. Hosting the sheet inside [TodayWorkoutsSection] compiles and
 * looks correct, but a disposed item takes an open sheet down with it, so the sheet MUST stay at screen
 * level — which is also where every other Today dialog lives. That mistake is invisible to a compiler
 * and to every other test in this suite.
 */
class TodayWorkoutTapTest {

    private fun repoRoot(): File {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val candidates = listOf(userDir, File(userDir, ".."), File(userDir, "../.."))
        return candidates.firstOrNull { File(it, "Strand/Screens/TodayView.swift").isFile }
            ?: error("could not locate the repo root from ${userDir.absolutePath}")
    }

    private fun todayScreenKt() = File(repoRoot(), "android/app/src/main/java/com/noop/ui/TodayScreen.kt").readText()

    /**
     * The section body, from its declaration to the start of the next top-level composable, with `//`
     * comments removed. Stripping matters: this file's comments NAME the very symbols asserted on, so a
     * raw substring search matches the prose describing the code rather than the code.
     */
    private fun workoutsSectionBody(source: String): String {
        val start = source.indexOf("private fun TodayWorkoutsSection(")
        assertTrue("TodayWorkoutsSection not found", start > 0)
        val next = source.indexOf("\n@Composable", start)
        val body = source.substring(start, if (next > start) next else source.length)
        return body.lines().joinToString("\n") { it.substringBefore("//") }
    }

    @Test
    fun tilesAreClickableAndReportTheTappedRow() {
        val body = workoutsSectionBody(todayScreenKt())
        assertTrue("the feed tiles must be clickable", body.contains(".clickable("))
        assertTrue("a tap must report the row it was on", body.contains("onSelect(workout)"))
        assertTrue(
            "the tap needs an accessibility action label, like the Sources row beside it",
            body.contains("R.string.today_action_show_workout"),
        )
    }

    @Test
    fun theSheetIsHostedAtScreenLevelNotInsideTheLazySection() {
        val source = todayScreenKt()
        assertTrue(
            "Today must open the Workouts list's own read-only sheet",
            source.contains("WorkoutDetailSheet(vm = viewModel, row = row"),
        )
        assertFalse(
            "hosting the sheet inside the section loses it when the LazyColumn disposes that item",
            workoutsSectionBody(source).contains("WorkoutDetailSheet("),
        )
    }

    /** Parity: iOS reaches the same read-only detail from the same feed, and presents it at screen level. */
    @Test
    fun iosTodayOpensTheSameDetailComponent() {
        val swift = File(repoRoot(), "Strand/Screens/TodayView.swift").readText()
        assertTrue("iOS tiles must open a detail", swift.contains("workoutDetail = WorkoutDetailTarget(row: w)"))
        assertTrue(
            "iOS must present the SAME read-only view the Workouts list uses",
            swift.contains("WorkoutDetailView(row: target.row)"),
        )
        assertTrue(
            "the press treatment must match Android's liquidPress, not fall back to .plain",
            swift.contains("LiquidPressStyle()"),
        )
    }
}
