package com.noop.ble

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A drain interrupted by a drop or a stop banks its progress before the anchor goes (#2443).
 *
 * The resume cursor is committed only when a drain ENDS, so an interrupted drain used to throw its
 * progress away: the next connect refetched from the old cursor, the ring re-served what had already
 * been stored, and those copies resolved under the NEXT session's SyncTime anchor. Landing a second or
 * two off, they missed `rrInterval`'s (deviceId, ts, rrMs, seq) key instead of colliding with it, so the
 * beats were stored twice and the night's HRV was refused. One reported night had 1,753 of 4,346
 * records served twice.
 *
 * A BLE source has no unit-testable surface, so the wiring is pinned against the source the way
 * `StressPersonalBaselineSurfaceTest` pins its own. What actually needs pinning is the ORDER: the commit
 * has to run after the hypnogram flush, so a burst still assembling banks against the cursor it belongs
 * to, and before the driver is torn down, because the commit asks the driver to resolve the candidate
 * ring time and a stopped driver has no anchor left.
 */
class OuraInterruptedDrainCursorTest {

    /** Offsets of real CALL sites, excluding the declaration and any mention in a doc comment. */
    private fun callSites(src: String): List<Int> =
        Regex("\\bcommitInterruptedDrainCursor\\(\\)").findAll(src).map { it.range.first }
            .filter { at ->
                val lineStart = src.lastIndexOf('\n', at).let { if (it < 0) 0 else it + 1 }
                val line = src.substring(lineStart, at).trim()
                !line.startsWith("private fun") && !line.startsWith("private func") &&
                    !line.startsWith("*") && !line.startsWith("//") && !line.startsWith("///")
            }.toList()

    private fun repoRoot(): File {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val candidates = listOf(userDir, File(userDir, ".."), File(userDir, "../.."))
        return candidates.firstOrNull { File(it, "Strand/BLE/OuraLiveSource.swift").isFile }
            ?: error("could not locate the repo root from ${userDir.absolutePath}")
    }

    private fun source(path: String): String = File(repoRoot(), path).readText()

    private val kotlinSource by lazy { source("android/app/src/main/java/com/noop/ble/OuraLiveSource.kt") }
    private val swiftSource by lazy { source("Strand/BLE/OuraLiveSource.swift") }

    @Test
    fun `both platforms commit an interrupted drain's cursor at every teardown`() {
        // Two teardowns each: the deliberate stop() and the involuntary disconnect. The report named
        // only the disconnect; a stop() mid-drain loses the cursor by exactly the same route.
        assertEquals2(
            "Kotlin must bank an interrupted drain at BOTH teardowns",
            2,
            callSites(kotlinSource).size,
        )
        assertEquals2(
            "Swift must bank an interrupted drain at BOTH teardowns",
            2,
            callSites(swiftSource).size,
        )
    }

    @Test
    fun `the commit runs after the hypnogram flush, never before it`() {
        for ((label, src) in listOf("Kotlin" to kotlinSource, "Swift" to swiftSource)) {
            val drops = Regex("dropUnanchoredHypnogramBursts\\(\\)").findAll(src)
                .map { it.range.first }.toList()
            val commits = callSites(src)
            for (commit in commits) {
                val precedingDrop = drops.lastOrNull { it < commit }
                assertTrue(
                    "$label: a commit at $commit has no hypnogram flush before it; a burst still " +
                        "assembling would bank against the wrong cursor",
                    precedingDrop != null && commit - precedingDrop < 400,
                )
            }
        }
    }

    @Test
    fun `the commit runs before the driver is torn down`() {
        // Swift tears the driver down at both teardowns; Kotlin only in stop(). Where the teardown
        // exists, the commit must precede it, or there is no anchor left to resolve the candidate.
        val swiftStops = Regex("driver\\?\\.stop\\(\\)").findAll(swiftSource).map { it.range.first }.toList()
        val swiftCommits = callSites(swiftSource)
        assertTrue("Swift: expected two wired commits, found ${swiftCommits.size}", swiftCommits.size == 2)
        for (commit in swiftCommits) {
            val nextStop = swiftStops.firstOrNull { it > commit }
            assertTrue(
                "Swift: the commit at $commit is not immediately before a driver teardown",
                nextStop != null && nextStop - commit < 200,
            )
        }
    }

    @Test
    fun `the helper only commits mid-drain, and only with banked progress`() {
        // Committing on every teardown would write a "stopped early" line for a link that dropped while
        // merely streaming, and would ask the cursor rules to judge a drain that banked nothing.
        val kotlinHelper = kotlinSource.substringAfter("private fun commitInterruptedDrainCursor()")
            .substringBefore("private fun commitResumeCursor")
        assertTrue(
            "Kotlin: the helper must gate on the drain phase",
            kotlinHelper.contains("OuraDriverPhase.FetchingHistory"),
        )
        assertTrue(
            "Kotlin: the helper must gate on banked progress",
            kotlinHelper.contains("drain.maxStoredRingTime"),
        )
        assertTrue(
            "Kotlin: the helper must reuse the existing stopped-early rules, not new cursor logic",
            kotlinHelper.contains("commitResumeCursor(drainCompleted = false)"),
        )
        // An interrupted drain must NOT make the #2097 reboot judgement. That judgement wipes the cursor
        // to 0 and re-pulls the ring's whole history, and it declines when this session never adopted an
        // anchor, which is the ordinary state of a drain cut short early. Answering "no evidence" with a
        // full re-pull would double-store everything re-served, which is the defect being fixed.
        assertTrue(
            "Kotlin: an interrupted drain must defer the reboot judgement",
            kotlinHelper.contains("drain.sawPreResumeData"),
        )

        val swiftHelper = swiftSource.substringAfter("private func commitInterruptedDrainCursor()")
            .substringBefore("private func commitResumeCursor")
        assertTrue(
            "Swift: the helper must gate on the drain phase",
            swiftHelper.contains("driver.phase == .fetchingHistory"),
        )
        assertTrue(
            "Swift: the helper must gate on banked progress",
            swiftHelper.contains("drain.maxStoredRingTime"),
        )
        assertTrue(
            "Swift: the helper must reuse the existing stopped-early rules, not new cursor logic",
            swiftHelper.contains("commitResumeCursor(drainCompleted: false)"),
        )
        assertTrue(
            "Swift: an interrupted drain must defer the reboot judgement",
            swiftHelper.contains("!drain.sawPreResumeData"),
        )
    }

    private fun assertEquals2(message: String, expected: Int, actual: Int) {
        assertTrue("$message (expected $expected, found $actual)", expected == actual)
    }
}
