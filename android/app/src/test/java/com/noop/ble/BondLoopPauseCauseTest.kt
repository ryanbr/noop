package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** Twin of Swift `BondLoopPauseParkingTests` wording tests: the same phrases on both platforms. */
class BondLoopPauseCauseTest {

    @Test
    fun eachPauseCauseNamesWhatWasObserved() {
        assertEquals("strap keeps refusing to pair", BondLoopPauseCause.RefusedBond.pausedReason)
        assertEquals("pairing never finished", BondLoopPauseCause.PairingNeverFinished.pausedReason)
        assertEquals("the link dropped within seconds of pairing 2 times in a row",
                     BondLoopPauseCause.DroppedAfterPairing(2).pausedReason)
    }

    @Test
    fun theDropsAfterPairingNeverClaimARefusal() {
        assertFalse(BondLoopPauseCause.DroppedAfterPairing(3).pausedReason.contains("refus"))
    }
}
