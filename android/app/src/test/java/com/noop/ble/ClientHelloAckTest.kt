package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The bond gate for [completionIsClientHelloAck], written from the #1635 field capture. Swift twin:
 * `ClientHelloOutcomeTests`.
 */
class ClientHelloAckTest {
    @Test
    fun `the field case - a queued command completing on the hello characteristic is not a bond`() {
        // 15:24:13 in the capture: DISABLE_ALARM was in flight, so the CLIENT_HELLO write was rejected by
        // the stack and nothing was owed. DISABLE_ALARM's completion then arrived on fd4b0002 - the SAME
        // characteristic the hello uses - and the link was declared bonded. isHelloChar is TRUE here, which
        // is exactly why a uuid check alone would not have caught it.
        assertFalse(
            completionIsClientHelloAck(
                isHelloChar = true, helloOutstanding = false, alreadyBonded = false, isWhoop5 = true,
            )
        )
    }

    @Test
    fun `a foreign characteristic completing inside the window is not a bond`() {
        assertFalse(
            completionIsClientHelloAck(
                isHelloChar = false, helloOutstanding = true, alreadyBonded = false, isWhoop5 = true,
            )
        )
    }

    @Test
    fun `a genuine ack still bonds`() {
        // The regression that matters most: the gate must not cost a real bond.
        assertTrue(
            completionIsClientHelloAck(
                isHelloChar = true, helloOutstanding = true, alreadyBonded = false, isWhoop5 = true,
            )
        )
    }

    @Test
    fun `an already-bonded link does not re-bond, and a WHOOP4 link never takes this path`() {
        assertFalse(
            completionIsClientHelloAck(
                isHelloChar = true, helloOutstanding = true, alreadyBonded = true, isWhoop5 = true,
            )
        )
        assertFalse(
            completionIsClientHelloAck(
                isHelloChar = true, helloOutstanding = true, alreadyBonded = false, isWhoop5 = false,
            )
        )
    }
}
