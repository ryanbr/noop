package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    // #1193 wording is for a genuine split — NOT for a second strap's night

    /**
     * The over-assertion this branch exists for. A wearer with two straps has nights owned by the other
     * one; DayOwnerResolver hands each day to whichever device holds its data. Samples under that id are
     * expected, and calling it a read failure sends the reader hunting a bug that is not there.
     */
    @Test
    fun `a second registered strap's night is expected, not a read failure`() {
        val line = AndroidDiagnostics.orphanedSamplesLine(
            activeId = "whoop-FD:4A",
            othersWithSamples = listOf("my-whoop" to 59_304),
            otherLiveStrapIds = setOf("my-whoop"),
        )
        assertTrue(line.contains("another registered strap"))
        assertTrue(line.contains("'my-whoop' (59304 rows)"))
        assertTrue("must point at the line that settles it", line.contains("dayOwner"))
        assertFalse("must not claim a bug", line.contains("are not being read"))
        assertFalse(line.contains("#1193"))
    }

    /** An id that is NOT a live registered strap is still the #1193 split — that wording must survive. */
    @Test
    fun `an unregistered id holding the samples is still reported as a split`() {
        val line = AndroidDiagnostics.orphanedSamplesLine(
            activeId = "whoop-FD:4A",
            othersWithSamples = listOf("my-whoop" to 59_304),
            otherLiveStrapIds = setOf("whoop-OTHER"),   // my-whoop is not a live device row
        )
        assertTrue(line.contains("#1193"))
        assertTrue(line.contains("are not being read"))
    }

    /** No registry supplied (the default) keeps every existing caller byte-identical. */
    @Test
    fun `without a registry the wording is unchanged`() {
        val withDefault = AndroidDiagnostics.orphanedSamplesLine(
            "whoop-FD:4A", listOf("my-whoop" to 59_304),
        )
        val explicitEmpty = AndroidDiagnostics.orphanedSamplesLine(
            "whoop-FD:4A", listOf("my-whoop" to 59_304), emptySet(),
        )
        assertEquals(withDefault, explicitEmpty)
        assertTrue(withDefault.contains("#1193"))
    }

    /** Mixed: one id is a live strap, one is not — the live strap explains it, so no bug is claimed. */
    @Test
    fun `a live strap among the ids wins over the split wording`() {
        val line = AndroidDiagnostics.orphanedSamplesLine(
            activeId = "whoop-FD:4A",
            othersWithSamples = listOf("orphan-id" to 10, "my-whoop" to 59_304),
            otherLiveStrapIds = setOf("my-whoop"),
        )
        assertTrue(line.contains("another registered strap"))
        assertTrue(line.contains("'my-whoop' (59304 rows)"))
        assertFalse("the orphan id is not the story when a real strap owns the night",
                    line.contains("'orphan-id'"))
    }
}
