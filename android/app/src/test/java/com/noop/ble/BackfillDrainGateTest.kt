package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Pure JVM coverage for the historical-frame drain ownership handoff. */
class BackfillDrainGateTest {

    @Test
    fun producerBeforeEmptyHandoffLeavesWorkForCurrentOwner() {
        val gate = BackfillDrainGate<Int>()
        val lease = gate.enqueue(1)!!

        assertEquals(1, gate.pollOrRelease(lease))
        assertNull(gate.enqueue(2))
        assertEquals(2, gate.pollOrRelease(lease))
        assertNull(gate.pollOrRelease(lease))
    }

    @Test
    fun producerAfterEmptyHandoffStartsReplacementDrain() {
        val gate = BackfillDrainGate<Int>()
        val firstLease = gate.enqueue(1)!!

        assertEquals(1, gate.pollOrRelease(firstLease))
        assertNull(gate.pollOrRelease(firstLease))

        val replacementLease = gate.enqueue(2)
        assertNotNull(replacementLease)
        assertEquals(2, gate.pollOrRelease(replacementLease!!))
        assertNull(gate.pollOrRelease(replacementLease))
    }

    @Test
    fun resetMakesLateOldDrainHarmlessToNewConnection() {
        val gate = BackfillDrainGate<Int>()
        val oldLease = gate.enqueue(1)!!
        assertNull(gate.enqueue(99))

        gate.reset()
        val newLease = gate.enqueue(2)!!

        // Simulate the old coroutine resuming and then running its finally block after reconnect.
        // It must neither see queued old-session frames nor release the new connection's owner.
        assertNull(gate.pollOrRelease(oldLease))
        gate.release(oldLease)

        assertEquals(2, gate.pollOrRelease(newLease))
        assertNull(gate.pollOrRelease(newLease))
    }

    @Test
    fun exceptionalReleaseLetsNextProducerOwnDrain() {
        val gate = BackfillDrainGate<Int>()
        val failedLease = gate.enqueue(1)!!
        assertEquals(1, gate.pollOrRelease(failedLease))

        gate.release(failedLease)

        val replacementLease = gate.enqueue(2)!!
        assertEquals(2, gate.pollOrRelease(replacementLease))
        assertNull(gate.pollOrRelease(replacementLease))
    }
}
