package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1992: the reject hex dump spends ONE budget for the connection, not a fresh per-chunk allowance.
 *
 * The dump is the only channel that carries an unmapped layout's raw bytes to someone who can map it.
 * Bounded per chunk with no session cap, it defeated itself on exactly the straps it exists for: ~25
 * rejects per chunk, many chunks, many sessions per connection, 8 long hex lines each time, flooding a
 * 2000-line rolling log and evicting its own earlier dumps.
 *
 * Swift twin: `BackfillerHexDumpBudgetTests`. It carries one case more: that `begin()` does not refill
 * the budget, which is what makes it a per-CONNECTION cap rather than a per-session one. That cannot be
 * asserted here, because constructing a Backfiller in a plain JVM test needs a repository over a
 * 152-method DAO with no fake in the tree. The invariant holds on both sides; only Swift can pin it.
 */
class RejectHexDumpBudgetTest {

    private val cap = 8

    @Test fun aChunkNeverDumpsMoreThanThePerChunkCap() {
        assertEquals(cap, Backfiller.hexDumpAllowance(rejectedCount = 50, budgetRemaining = 24))
    }

    @Test fun aChunkNeverDumpsMoreThanItRejected() {
        assertEquals(3, Backfiller.hexDumpAllowance(rejectedCount = 3, budgetRemaining = 24))
    }

    /** The point of the change: successive chunks drain one budget rather than each getting a fresh 8. */
    @Test fun successiveChunksDrainTheOneBudget() {
        var budget = Backfiller.REJECT_HEX_DUMP_BUDGET
        var dumped = 0
        repeat(10) {
            val n = Backfiller.hexDumpAllowance(rejectedCount = 25, budgetRemaining = budget)
            dumped += n
            budget -= n
        }
        assertEquals("ten chunks must not exceed the one budget",
            Backfiller.REJECT_HEX_DUMP_BUDGET, dumped)
        assertEquals(0, budget)
    }

    /** Once spent, later chunks dump nothing, which is what stops the flood. */
    @Test fun anExhaustedBudgetDumpsNothing() {
        assertEquals(0, Backfiller.hexDumpAllowance(rejectedCount = 25, budgetRemaining = 0))
    }

    /** Never negative, however the counters are driven. */
    @Test fun theAllowanceIsNeverNegative() {
        assertEquals(0, Backfiller.hexDumpAllowance(rejectedCount = 0, budgetRemaining = 24))
        assertEquals(0, Backfiller.hexDumpAllowance(rejectedCount = 25, budgetRemaining = -5))
    }

    /** The budget must clear more than one chunk, or the sample cannot span an offload. */
    @Test fun theBudgetIsWorthMoreThanOneChunk() {
        assertEquals(true, Backfiller.REJECT_HEX_DUMP_BUDGET > cap)
    }

    // --- #891: the unmapped-type dump line ---

    /**
     * The byte count is DERIVED from the hex rather than passed alongside it, so the number and the bytes
     * beside it cannot disagree. A dump whose stated length contradicts its payload is worse than none:
     * it sends whoever is mapping the layout looking for a field that was never there.
     */
    @Test
    fun unmappedTypeDumpLineDerivesItsLengthFromTheBytes() {
        val line = Backfiller.unmappedTypeDumpLine("type53", "aabbccdd")
        assertEquals("Backfill: unmapped type type53 first frame 4B: aabbccdd", line)
    }

    /** The full frame rides the line - no prefix cap, for the reason the reject dump has none. */
    @Test
    fun unmappedTypeDumpLineDoesNotTruncate() {
        val hex = "ab".repeat(600)
        val line = Backfiller.unmappedTypeDumpLine("HISTORICAL_IMU_DATA_STREAM", hex)
        assertTrue(line, line.endsWith(hex))
        assertTrue(line, line.contains("600B"))
    }
}
