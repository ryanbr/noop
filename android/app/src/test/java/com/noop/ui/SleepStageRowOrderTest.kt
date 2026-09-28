package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2534: every surface that lists the four sleep stages lists them in the SAME order.
 *
 * The order is chart depth, which is also the standard hypnogram convention: awake, REM, light, deep.
 *
 * A source tripwire is the right instrument because the order is a literal sequence of call sites. Each one
 * compiles perfectly in any order, no runtime assertion can see "the rows are in the wrong sequence", and the
 * sequence is written out SIX times across four files. That duplication is exactly how this broke: Android
 * routes every surface through two shared composables, but Apple repeats the rows inline in both
 * `SleepView` (Sleep detail) and `StagesCard` (the hosted card on Liquid Today, which is the default Today).
 * Before this, the two Apple files disagreed with each other AND each disagreed internally between its
 * breakdown rows and its timeline rows.
 *
 * Asserting the extracted sequence rather than a substring is deliberate: a test that only checked "awake
 * comes before deep" would have passed the state the report was filed about.
 *
 * SCOPE, stated so the next reader does not over-trust this. It pins the six stage ROW STACKS, which are
 * what #2534 is about. Two other places name the stages in a sequence and are NOT covered, because aligning
 * them was not part of this change:
 *
 *  - `XiaomiBandView.swift` lists REM / Deep / Light / Awake for a Mi Band night.
 *  - `Charts.hypnogramSummary` builds the hypnogram's screen-reader read-out as deep / REM / light / awake,
 *    so a TalkBack user currently hears a different order from the one they would see.
 *
 * Both are worth a look, and neither is pinned here.
 */
class SleepStageRowOrderTest {

    /** Chart depth, top to bottom. */
    private val expected = listOf("awake", "rem", "light", "deep")

    private fun repoRoot(): File {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val candidates = listOf(userDir, File(userDir, ".."), File(userDir, "../.."))
        return candidates.firstOrNull { File(it, "Strand/Screens/StagesCard.swift").isFile }
            ?: error("could not locate the repo root from ${userDir.absolutePath}")
    }

    private fun source(path: String): String = File(repoRoot(), path).readText()

    /** The stage names in the order [callSite] mentions them, from the call's own argument. */
    private fun order(src: String, callSite: String, marker: String): List<String> {
        val start = src.indexOf(callSite)
        assertTrue("missing call site: $callSite", start >= 0)
        val end = src.indexOf("\n    }", start)
        assertTrue("unterminated: $callSite", end > start)
        return Regex(marker).findAll(src.substring(start, end)).map { it.groupValues[1].lowercase() }.toList()
    }

    @Test
    fun `apple sleep detail lists both its row stacks in chart-depth order`() {
        val src = source("Strand/Screens/SleepView.swift")
        assertEquals("breakdown rows", expected,
                     order(src, "private func stageBreakdownRows", """stageBreakdownRow\(\.(\w+)"""))
        assertEquals("timeline rows", expected,
                     order(src, "private func stageTimeline(", """stageTimelineRow\(\.(\w+)"""))
    }

    /**
     * The hosted card is the half PR #2536 left behind, and it is not a dead surface: `LiquidTodayView`
     * renders it and Liquid Today is the default. Leaving it would have made Today and Sleep detail disagree
     * on exactly the axis the report is about.
     */
    @Test
    fun `apple hosted stages card lists both its row stacks in chart-depth order`() {
        val src = source("Strand/Screens/StagesCard.swift")
        assertEquals("breakdown rows", expected,
                     order(src, "private func stageBreakdownRows", """stageBreakdownRow\(\.(\w+)"""))
        assertEquals("timeline rows", expected,
                     order(src, "private func stageTimeline(", """stageTimelineRow\(\.(\w+)"""))
    }

    /** Android routes every surface through these two, so pinning them covers all of its screens. */
    @Test
    fun `android shared composables list their stages in chart-depth order`() {
        val breakdown = source("android/app/src/main/java/com/noop/ui/SleepStageBreakdownUi.kt")
        assertEquals("StageBreakdownRows", expected,
                     order(breakdown, "internal fun StageBreakdownRows", """StageBreakdownRow\("(\w+)""""))

        val screen = source("android/app/src/main/java/com/noop/ui/SleepScreen.kt")
        val start = screen.indexOf("internal fun StageTimeline(")
        assertTrue("missing StageTimeline", start >= 0)
        val listStart = screen.indexOf("listOf(", start)
        val listEnd = screen.indexOf(").forEach", listStart)
        assertTrue("unterminated stage list", listEnd > listStart)
        val found = Regex("""Triple\("(\w+)"""").findAll(screen.substring(listStart, listEnd))
            .map { it.groupValues[1].lowercase() }.toList()
        assertEquals("StageTimeline", expected, found)
    }

    /**
     * Every ROW STACK agrees, which is the property the report is actually about: two screens showing the
     * same night must not order its stages differently. Not "every surface in the app", see the scope note.
     */
    @Test
    fun `every stage row stack agrees, so no two screens can disagree`() {
        val all = listOf(
            order(source("Strand/Screens/SleepView.swift"), "private func stageBreakdownRows",
                  """stageBreakdownRow\(\.(\w+)"""),
            order(source("Strand/Screens/SleepView.swift"), "private func stageTimeline(",
                  """stageTimelineRow\(\.(\w+)"""),
            order(source("Strand/Screens/StagesCard.swift"), "private func stageBreakdownRows",
                  """stageBreakdownRow\(\.(\w+)"""),
            order(source("Strand/Screens/StagesCard.swift"), "private func stageTimeline(",
                  """stageTimelineRow\(\.(\w+)"""),
            order(source("android/app/src/main/java/com/noop/ui/SleepStageBreakdownUi.kt"),
                  "internal fun StageBreakdownRows", """StageBreakdownRow\("(\w+)""""),
        )
        assertEquals("every row stack must read the same: " + all, 1, all.distinct().size)
        assertEquals(expected, all.first())
    }
}
