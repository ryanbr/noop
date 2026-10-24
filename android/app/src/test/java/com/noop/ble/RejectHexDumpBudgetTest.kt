package com.noop.ble

import com.noop.protocol.Framing
import com.noop.protocol.Whoop5Ecg

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    /**
     * An R16 ECG record gains a decoded summary beside its hex (#891).
     *
     * The dump exists to carry an unmapped layout to someone who can map it. R16 IS mapped now, so the
     * line answers the question a reporter actually has: did the banked reading record a waveform. The
     * hex still rides along, and the summary carries counts and flags only, never samples.
     */
    @Test
    fun anR16RecordGainsADecodedSummaryBesideItsHex() {
        val inner = IntArray(Whoop5Ecg.R16_INNER_LENGTH)
        inner[0] = Whoop5Ecg.STORED_RECORD_TYPE
        inner[1] = Whoop5Ecg.R16_REVISION
        inner[17] = 100                                       // progress: terminal
        inner[24] = 0xf4; inner[25] = 0x01                    // declared count 500
        inner[Whoop5Ecg.R16_LEADS_OFF_COUNT_OFFSET] = 10
        val frame = Framing.puffinCommandFrame(
            cmd = inner[2], seq = inner[1],
            payload = ByteArray(inner.size - 3) { inner[it + 3].toByte() },
            type = inner[0],
        )
        val hex = frame.joinToString("") { "%02x".format(it) }
        val line = Backfiller.unmappedTypeDumpLine("HISTORICAL_DATA", hex)
        assertTrue(line, line.contains(hex))                  // the bytes are still there
        assertTrue(line, line.contains("| R16 "))
        assertTrue(line, line.contains("samples=500"))
        assertTrue(line, line.contains("terminal"))
        assertTrue(line, line.contains("grouping=51/50x8/49"))
        // Never the samples themselves.
        assertFalse(line, line.contains("sample["))
    }

    /** A frame that is not an R16 gains nothing, so the ordinary dump is unchanged. */
    @Test
    fun aNonR16FrameGainsNoSummary() {
        val line = Backfiller.unmappedTypeDumpLine("type53", "aabbccdd")
        assertFalse(line, line.contains("| R16"))
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
