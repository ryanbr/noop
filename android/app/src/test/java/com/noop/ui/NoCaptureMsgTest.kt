package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The no-capture toast must not name a remedy the strap cannot reach (#1635).
 *
 * A live-HR-only 5/MG has no puffin channel and so no history sync, and the old copy told those users to
 * "let a 5/MG history sync run" — waiting for something that never arrives. Same failure mode as every
 * other confidently-wrong line this issue produced, just in a Toast.
 */
class NoCaptureMsgTest {
    @Test
    fun `a live-HR-only strap is told the sync is unreachable, not pending`() {
        val msg = LogExport.noCaptureMsgText(
            whoop5Connected = true, captureEnabled = true, encryptedBond = false, sharingLog = false,
        )
        assertTrue(msg.contains("live HR only"))
        assertTrue(msg.contains("encrypted pairing"))
        assertFalse(msg.contains("Let a 5/MG history sync run"))
    }

    @Test
    fun `a properly bonded strap is still told to let a sync run`() {
        val msg = LogExport.noCaptureMsgText(
            whoop5Connected = true, captureEnabled = true, encryptedBond = true, sharingLog = false,
        )
        assertTrue(msg.contains("Let a 5/MG history sync run"))
    }

    @Test
    fun `turning the toggle on comes first, even when unbonded`() {
        // Ordering matters: with capture off, "turn it on" is the actionable step regardless of bond.
        val msg = LogExport.noCaptureMsgText(
            whoop5Connected = true, captureEnabled = false, encryptedBond = false, sharingLog = false,
        )
        assertTrue(msg.contains("Turn on"))
    }

    @Test
    fun `a WHOOP 4 is never told about pairing at all`() {
        val msg = LogExport.noCaptureMsgText(
            whoop5Connected = false, captureEnabled = true, encryptedBond = false, sharingLog = true,
        )
        assertTrue(msg.contains("doesn't apply to WHOOP 4.0"))
        assertTrue(msg.contains("Sharing the strap log."))
    }
}
