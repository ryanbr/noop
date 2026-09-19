package com.noop.ui

import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `stagingSparse` is a DAY-level verdict stamped onto EVERY stored block, so the caveat has to ask all of
 * them rather than the main one alone. iOS says exactly that on its own gate ("each carries the day's
 * value") and reads `night.sourceBlocks.contains { $0.stagingSparse == true }`; Android read only the main
 * block, so a night whose main block was imported (nil flag) while a computed fragment carried true warned
 * on iPhone and Mac and stayed silent here.
 *
 * Both halves of that decision are pure helpers precisely so this can be tested: which blocks get read
 * ([sleepDayBlocks]) and what counts as sparse across them ([anyBlockStagingSparse]).
 */
class SleepSparseBlocksTest {

    private fun block(sparse: Boolean?, start: Long = 0L) =
        SleepSession(deviceId = "test", startTs = start, endTs = start + 3600, stagingSparse = sparse)

    // ── which blocks get read ─────────────────────────────────────────────────────────────────────

    @Test fun `the bridged group is what gets read when there is one`() {
        val main = block(null)
        val group = listOf(block(null, 1), block(true, 2))
        assertEquals(group, sleepDayBlocks(main, group))
    }

    @Test fun `the main block is the fallback when the group is empty`() {
        val main = block(true)
        assertEquals(listOf(main), sleepDayBlocks(main, emptyList()))
    }

    @Test fun `no session and no group reads nothing rather than throwing`() {
        assertEquals(emptyList<SleepSession>(), sleepDayBlocks(null, emptyList()))
    }

    // ── what counts as sparse across them ─────────────────────────────────────────────────────────

    /** The reported shape: main block imported (nil), a computed fragment sparse. Must be seen. */
    @Test fun `a sparse fragment counts even when the main block carries no flag`() {
        assertTrue(anyBlockStagingSparse(listOf(block(null, 1), block(true, 2))))
    }

    /** Reading only the FIRST block is what produced the divergence: it misses the fragment. */
    @Test fun `reading only the first block would miss it - the bug this closes`() {
        val blocks = listOf(block(null, 1), block(true, 2))
        assertFalse("the old main-block-only reading", blocks.firstOrNull()?.stagingSparse == true)
        assertTrue("the any-block reading", anyBlockStagingSparse(blocks))
    }

    @Test fun `a night of nil flags is never flagged`() {
        assertFalse(anyBlockStagingSparse(listOf(block(null, 1), block(null, 2))))
    }

    @Test fun `explicit false blocks are not flagged`() {
        assertFalse(anyBlockStagingSparse(listOf(block(false, 1), block(false, 2), block(null, 3))))
    }

    @Test fun `an empty day is not flagged`() {
        assertFalse(anyBlockStagingSparse(emptyList()))
    }

    // ── and the duration gate still governs (#2324) ───────────────────────────────────────────────

    @Test fun `any-block sparse still defers to the duration gate`() {
        val blocks = listOf(block(null, 1), block(true, 2))
        assertTrue(stageSparseNoteApplies(anyBlockStagingSparse(blocks), asleepMin = 60.0))
        assertFalse(stageSparseNoteApplies(anyBlockStagingSparse(blocks), asleepMin = 12 * 60.0))
    }
}
