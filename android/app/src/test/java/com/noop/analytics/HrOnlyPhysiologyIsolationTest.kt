package com.noop.analytics

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The display-only guarantee for an HR-only night (#1801), guarded at the level it actually fails.
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
    fun `the physiology set excludes HR-only nights`() {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        val src = run {
            repeat(4) {
                val f = java.io.File(root, "android/app/src/main/java/com/noop/analytics/AnalyticsEngine.kt")
                if (f.isFile) return@run f.readText()
                root = root.parentFile ?: root
            }
            error("AnalyticsEngine.kt not found — this test must not pass by default")
        }
        assertTrue("physiologySessions must filter out hrOnly",
            src.contains("val physiologySessions = matched.filter { !it.hrOnly }"))
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
