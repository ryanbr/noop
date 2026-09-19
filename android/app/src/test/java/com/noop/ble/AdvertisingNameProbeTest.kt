package com.noop.ble

import com.noop.protocol.CommandNames
import com.noop.protocol.CommandNumber
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2338: the read-only GET_ADVERTISING_NAME(141) probe.
 *
 * Nothing has ever sent 140 or 141 to a strap, so these pin the two things that can be checked without
 * one: that the decode reads the 5/MG envelope rather than the 4.0 one, and that the WRITE side is not
 * expressible at all.
 */
class AdvertisingNameProbeTest {

    /** SOF, len(LE u16), crc8, then the 5/MG inner block; payload starts at 13. */
    private fun whoop5Response(payload: ByteArray): ByteArray {
        val head = ByteArray(13)
        val length = 13 + payload.size
        head[0] = 0xAA.toByte()
        head[1] = (length and 0xFF).toByte()
        head[2] = ((length shr 8) and 0xFF).toByte()
        return head + payload
    }

    @Test fun decodesAPrintableNameFromTheFiveMgEnvelope() {
        val frame = whoop5Response("Whoop von Beispiel".toByteArray(Charsets.UTF_8))
        assertEquals("Whoop von Beispiel", advertisingNameFromWhoop5Response(frame))
    }

    @Test fun stripsNonPrintableBytesAndTrims() {
        // A NUL-terminated, space-padded name is the 4.0 payload shape; if the 5/MG echoes anything
        // similar the decode must not carry the padding into a device name.
        val frame = whoop5Response(byteArrayOf(0, 0) + "  WHOOP 4.0  ".toByteArray() + byteArrayOf(0))
        assertEquals("WHOOP 4.0", advertisingNameFromWhoop5Response(frame))
    }

    @Test fun aPayloadWithNoPrintableBytesIsNotAName() {
        // The answer to "the strap replied with something that is not a name". An empty string here
        // would read as "the strap says its name is blank", which this cannot support.
        assertNull(advertisingNameFromWhoop5Response(whoop5Response(byteArrayOf(0, 1, 2, 3))))
    }

    @Test fun aTooShortFrameIsNull() {
        assertNull(advertisingNameFromWhoop5Response(byteArrayOf()))
        assertNull(advertisingNameFromWhoop5Response(byteArrayOf(0xAA.toByte(), 2)))
        // Length pointing at or before the payload start carries nothing.
        assertNull(advertisingNameFromWhoop5Response(byteArrayOf(0xAA.toByte(), 13, 0) + ByteArray(20)))
    }

    /**
     * The decode must read the 5/MG envelope, NOT the 4.0 one. Reading a 5/MG frame with the 4.0 helper
     * does not fail, it returns four bytes of envelope dressed as payload, which is exactly the mistake
     * bhelm/noop#4 was. A frame whose envelope bytes are printable would decode differently under each.
     */
    @Test fun readsTheFiveMgOffsetNotTheFourPointZeroOne() {
        val frame = whoop5Response("NAME".toByteArray())
        // Bytes 9..12 are envelope on a 5/MG and would be payload under the 4.0 helper. Make them
        // printable so the two offsets cannot agree by accident.
        frame[9] = 'X'.code.toByte(); frame[10] = 'X'.code.toByte()
        frame[11] = 'X'.code.toByte(); frame[12] = 'X'.code.toByte()
        assertEquals("NAME", advertisingNameFromWhoop5Response(frame))
        assertEquals("XXXXNAME", String(whoop4CommandResponsePayload(frame)!!, Charsets.UTF_8))
    }

    @Test fun theReadOpcodeIsKnownAndLabelled() {
        assertEquals(141, CommandNumber.GET_ADVERTISING_NAME.rawValue)
        assertEquals("GET_ADVERTISING_NAME(141)", CommandNames.label(141))
    }

    /**
     * The WRITE side is deliberately not expressible. 140 has no [CommandNumber] entry, so no code path
     * can form it whatever any allow-list says. This is the guard that keeps an unproven opcode off a
     * stranger's firmware, and it is worth a test because adding the entry would be a one-line mistake.
     */
    @Test fun theWriteSideIsNotExpressible() {
        assertFalse(
            "SET_ADVERTISING_NAME(140) must not be constructible until a strap has answered 141 (#2338)",
            CommandNumber.entries.any { it.rawValue == 140 },
        )
        // 77 is the HARVARD set, WHOOP 4.0 only, and keeps its own name in the log.
        assertTrue(CommandNumber.entries.any { it.rawValue == 77 })
        assertEquals("SET_ADVERTISING_NAME_HARVARD(77)", CommandNames.label(77))
    }
}
