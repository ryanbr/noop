package com.noop.analytics

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * How an HR-only night reaches the day's physiology, guarded at the level it actually fails.
 *
 * #1801 made this an EXCLUSION: an HR-only night was kept out of every physiological aggregate. #1884
 * made it a PREFERENCE, because the exclusion was discarding a computed HRV and leaving Charge with no
 * input at all. The night is still marked `hrOnly` for anything that wants to weigh it down; what it no
 * longer gets is a silent delete.
 *
 * A null `restingHR`/`avgHRV` only protects an aggregate that READS those fields. Two of the day's
 * physiological aggregates do not: the deep-window HRV pool and the SDNN index both re-derive from `rr`
 * over each session's own stages, so an HR-only night — which has stages — would have been folded into
 * both, and from there into Charge and the HRV baseline. `deepHrvWindow` is a user setting, so that path
 * is reachable, not theoretical.
 *
 * Read from the source because `physiologySessions` is a local inside `analyzeDay` and cannot be
 * observed directly, and because the failure this guards is a FUTURE aggregate reaching for `matched`
 * out of habit. A behavioural test on one path would not catch that; this does.
 */
class HrOnlyPhysiologyIsolationTest {

    private fun analyzeDayBody(): String {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        val src = run {
            repeat(4) {
                val f = java.io.File(root, "android/app/src/main/java/com/noop/analytics/AnalyticsEngine.kt")
                if (f.isFile) return@run f.readText()
                root = root.parentFile ?: root
            }
            error("AnalyticsEngine.kt not found — this test must not pass by default")
        }
        val decl = src.indexOf("val physiologySessions")
        assertTrue("analyzeDay must name the physiology-session set", decl > 0)
        // Start AFTER the declaration: that line reads `matched` legitimately, since defining the
        // filtered set is the one place the unfiltered one belongs.
        val from = src.indexOf("\n", decl) + 1
        val to = src.indexOf("val avgSDNNDaily", from)
        assertTrue("expected the SDNN index to follow the physiology set", to > from)
        // Through the end of the SDNN call, which is the last of the four aggregates.
        return src.substring(from, src.indexOf(")", src.indexOf("segmentSec = 300", to)) + 1)
    }

    @Test
    fun `the physiology set prefers motion-backed nights and falls back rather than emptying`() {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        val src = run {
            repeat(4) {
                val f = java.io.File(root, "android/app/src/main/java/com/noop/analytics/AnalyticsEngine.kt")
                if (f.isFile) return@run f.readText()
                root = root.parentFile ?: root
            }
            error("AnalyticsEngine.kt not found — this test must not pass by default")
        }
        // #1884 changed this from an exclusion to a PREFERENCE, and the old assertion could not tell the
        // difference: it was a `contains` on a prefix, so appending `.ifEmpty { matched }` reversed the
        // guarantee while the guard stayed green. Pin the whole expression, so the next change to it has
        // to be deliberate rather than accidental.
        assertTrue(
            "physiologySessions must PREFER motion-backed sessions and fall back rather than emptying",
            src.contains("val physiologySessions = matched.filter { !it.hrOnly }.ifEmpty { matched }"),
        )
        // The preference still has to exist: an aggregate that simply read `matched` would fold an
        // HR-only night in even when a motion-backed one was available on the same day.
        assertTrue("the hrOnly filter must survive the fallback",
            src.contains("matched.filter { !it.hrOnly }"))
    }

    /**
     * The four aggregates built from a night's physiology must read the filtered set. `matched` still
     * has legitimate uses in `analyzeDay` — duration, stage totals, Rest, the onset — which is exactly
     * why this checks the physiology region rather than banning the name outright.
     */
    @Test
    fun `no physiological aggregate reads the unfiltered sessions`() {
        val body = analyzeDayBody()
        val offenders = Regex("matched\\.[a-zA-Z]").findAll(body).map { it.value }.toList()
        assertTrue(
            "physiological aggregates must use physiologySessions, found: $offenders",
            offenders.isEmpty(),
        )
        for (needle in listOf("restingHRDaily", "val deep", "val pairs", "avgSDNNDaily")) {
            assertTrue("$needle must sit inside the guarded region", body.contains(needle))
        }
    }
}
