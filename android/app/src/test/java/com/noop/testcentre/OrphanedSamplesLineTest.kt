package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1617 follow-up: the funnel's zero-sample line must distinguish "the samples are not there" from
 * "the samples are under a different device id" (#1193/#740). The old line asserted the first
 * unconditionally, which is the wrong answer to give an investigation exactly when it matters.
 *
 * Swift twin: `orphanedSamplesLine` in `Strand/System/DebugDataDiagnostics.swift` — the two must emit
 * the same strings, so these expectations are written out in full rather than pattern-matched.
 */
class OrphanedSamplesLineTest {

    @Test
    fun `no samples anywhere keeps the fresh-re-add wording`() {
        assertEquals(
            "(no raw biometric samples under 'my-whoop' for this night — expected on a freshly " +
                "re-added strap; reconnect + let a history sync run, then re-export)",
            AndroidDiagnostics.orphanedSamplesLine("my-whoop", emptyList()),
        )
    }

    @Test
    fun `samples under another id report the split instead`() {
        val line = AndroidDiagnostics.orphanedSamplesLine("my-whoop", listOf("whoop-F1:D4:F7:24:53:DE" to 4213))
        assertEquals(
            "(no raw biometric samples under the ACTIVE id 'my-whoop' for this night — they are under " +
                "'whoop-F1:D4:F7:24:53:DE' (4213 rows) instead. The history spine and the raw stream are " +
                "on different device ids (#1193); this is NOT a fresh re-add, the samples exist and are " +
                "not being read.)",
            line,
        )
        // The benign explanation must not survive anywhere in the split wording — a reader scanning the
        // log for "freshly re-added" would otherwise still stop here.
        assertTrue(!line.contains("freshly re-added"))
    }

    @Test
    fun `several holders are listed heaviest first`() {
        val line = AndroidDiagnostics.orphanedSamplesLine(
            "my-whoop",
            listOf("whoop-aa" to 12, "whoop-bb" to 900, "whoop-cc" to 300),
        )
        assertTrue(line.contains("'whoop-bb' (900 rows), 'whoop-cc' (300 rows), 'whoop-aa' (12 rows)"))
    }

    @Test
    fun `equal counts break the tie on id so both platforms agree`() {
        // Swift's `sorted` is not a stable sort; without an explicit tie-break the twin lines could list
        // the same two ids in different orders.
        val line = AndroidDiagnostics.orphanedSamplesLine(
            "my-whoop",
            listOf("whoop-zz" to 50, "whoop-aa" to 50),
        )
        assertTrue(line.contains("'whoop-aa' (50 rows), 'whoop-zz' (50 rows)"))
    }
}
