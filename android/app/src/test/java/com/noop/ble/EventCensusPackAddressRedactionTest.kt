package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Test Centre event census must not publish the pack's BT address.
 *
 * It logs `payload=<event_payload_hex>` for every pushed event, and event 109 — the pack record the
 * readout reads — carries the pack's address at payload offset 5..10. [redactStrapLogPii] lifts an
 * ASCII serial out of a hex run but has no rule that can reach a colon-less address, so the census
 * line shipped it in every shared strap log. Masked at the source, only once the frame has decoded
 * as a present pack; every other event, and an undecodable 109, keeps its bytes — the census exists
 * to expose exactly those. Same shape as `BatteryPackProbeRedactionTest`.
 */
class EventCensusPackAddressRedactionTest {

    /** A 5/MG event frame: event byte at 10, payload from 16; payload is the 32-byte pack record. */
    private fun eventFrame(event: Int, payload: ByteArray): ByteArray {
        val f = ByteArray(16 + payload.size)
        f[10] = event.toByte()
        payload.copyInto(f, 16)
        return f
    }

    /** A pack record with a known address, an ASCII serial and an in-range SoC, present = true. */
    private fun packRecord(present: Boolean): ByteArray {
        val p = ByteArray(32)
        p[4] = if (present) 1 else 0
        byteArrayOf(0xC4.toByte(), 0x9D.toByte(), 0xED.toByte(), 0x11, 0x22, 0x33).copyInto(p, 5)
        "WBB5AP0000001".toByteArray(Charsets.US_ASCII).copyInto(p, 11)
        p[27] = 0x39; p[28] = 0x02   // SoC word 569 -> 56.9 %
        return p
    }

    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    @Test fun packEventPayloadHasItsAddressMaskedAndNothingElse() {
        val rec = packRecord(present = true)
        val out = WhoopBleClient.maskPackAddrInEventPayload(hex(rec), eventFrame(109, rec))
        assertFalse("the pack address must not survive into the census", out.contains("c49ded112233"))
        assertTrue("exactly the six address bytes are blanked", out.contains("••••••••••••"))
        assertEquals("every byte before the address is untouched", hex(rec).substring(0, 10), out.substring(0, 10))
        assertEquals("every byte after the address is untouched", hex(rec).substring(22), out.substring(22))
        // The SoC word — the finding the census produced — must survive.
        assertTrue(out.contains("3902"))
    }

    @Test fun otherEventsKeepTheirPayloadWhole() {
        val rec = packRecord(present = true)
        val out = WhoopBleClient.maskPackAddrInEventPayload(hex(rec), eventFrame(21, rec))
        assertEquals("a non-109 event is never touched, whatever its bytes look like", hex(rec), out)
    }

    @Test fun anAbsentPackKeepsItsBytes() {
        val rec = packRecord(present = false)
        val out = WhoopBleClient.maskPackAddrInEventPayload(hex(rec), eventFrame(109, rec))
        assertEquals("present=false is not a confirmed layout, so nothing is blanked", hex(rec), out)
    }

    @Test fun aShortOrMalformedFrameIsLeftAlone() {
        assertEquals("abcd", WhoopBleClient.maskPackAddrInEventPayload("abcd", ByteArray(4)))
        val rec = packRecord(present = true)
        val short = hex(rec).substring(0, 16)   // payload hex too short to hold the address span
        assertEquals(short, WhoopBleClient.maskPackAddrInEventPayload(short, eventFrame(109, rec)))
    }
}
