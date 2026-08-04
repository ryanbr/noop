package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #690: byte-parity twin of the Swift `BodyLocationProbeTests` — same synthetic fixtures, same expectations
 * — for `WhoopBleClient.formatBodyLocationProbe`. Fixtures are SYNTHETIC (the 4-byte layout is RE'd, not yet
 * hardware-captured); they pin the decode/format contract until a strap answers 0x54.
 */
class BodyLocationProbeFormatTest {

    private fun hexToBytes(h: String): ByteArray =
        ByteArray(h.length / 2) { ((h[it * 2].digitToInt(16) shl 4) or h[it * 2 + 1].digitToInt(16)).toByte() }

    // cmd 0x54 @6, payload [revision=01, location=01 WRIST, confidence=5a=90, status=00], then a 4-byte CRC.
    private val wristFrame = "aa09000024005401015a00deadbeef"

    @Test fun whoop4AcceptedDecodesTheFourFields() {
        val (text, payHex) = WhoopBleClient.formatBodyLocationProbe(hexToBytes(wristFrame), 6, false, null)
        assertTrue(text.contains("WHOOP 4.0"))
        assertTrue(text.contains("opcode 84 ACCEPTED — 4-byte payload"))
        assertTrue(text.contains(wristFrame))
        assertTrue(text.contains("  @00  01 01 5a 00"))
        assertTrue(text.contains("revision:   1"))
        assertTrue(text.contains("location:   1  (WRIST)"))
        assertTrue(text.contains("confidence: 90  (raw)"))
        assertTrue(text.contains("status:     0  (raw)"))
        assertTrue(text.contains("first capture"))
        assertEquals(4 * 2, payHex?.length)
    }

    @Test fun unknownLocationIsPreservedAsRaw() {
        val (text, _) = WhoopBleClient.formatBodyLocationProbe(hexToBytes("aa09000024005401060000deadbeef"), 6, false, null)
        assertTrue(text.contains("location:   6  (raw6)"))
    }

    @Test fun knownEnumValuesMapToTheirLabels() {
        val cases = listOf(2 to "BICEP", 3 to "CALF", 4 to "SIDE_TORSO", 5 to "GLUTE", 7 to "ANKLE",
            128 to "NOT_CONCLUSIVE", 160 to "UNKNOWN_GARMENT")
        for ((raw, label) in cases) {
            val frame = "aa090000240054" + "01" + "%02x".format(raw) + "0000" + "deadbeef"
            val (text, _) = WhoopBleClient.formatBodyLocationProbe(hexToBytes(frame), 6, false, null)
            assertTrue("location $raw should read $label", text.contains("($label)"))
        }
    }

    @Test fun diffFlagsTheChangedLocationByte() {
        val first = hexToBytes(wristFrame)
        val (_, prev) = WhoopBleClient.formatBodyLocationProbe(first, 6, false, null)
        val second = first.copyOf()
        second[8] = 0x03            // location WRIST(01) -> CALF(03)
        val (text, _) = WhoopBleClient.formatBodyLocationProbe(second, 6, false, prev)
        assertTrue(text.contains("Δ vs previous capture:"))
        assertTrue(text.contains("@01:01→03"))
        assertTrue(text.contains("location:   3  (CALF)"))
    }

    @Test fun bareStubIsCalledOut() {
        val (text, payHex) = WhoopBleClient.formatBodyLocationProbe(hexToBytes("aa0700fa24005446758858"), 6, false, null)
        assertTrue(text.contains("bare stub"))
        // Twin of the Swift assertion: a bare stub is one reply, not a firmware capability.
        assertTrue(text.contains("ambiguous"))
        assertFalse(text.contains("no body-location data on this firmware"))
        assertTrue(text.contains("not the same as the firmware having none"))
        assertNull(payHex)
    }

    /** Golden FULL-output lock: the exact byte-for-byte report, identical to the Swift
     *  `BodyLocationProbeTests.testFullOutput_goldenParityLock`, so the two twins can't drift. */
    @Test fun fullOutputGoldenParityLock() {
        val (text, _) = WhoopBleClient.formatBodyLocationProbe(hexToBytes(wristFrame), 6, false, null)
        val golden = listOf(
            "#690 BODY-LOCATION PROBE — WHOOP 4.0",
            "Verdict: opcode 84 ACCEPTED — 4-byte payload",
            "",
            "Raw frame (15 B):",
            "aa09000024005401015a00deadbeef",
            "",
            "Payload (4 B, CRC excluded):",
            "  @00  01 01 5a 00",
            "",
            "Decoded:",
            "  revision:   1",
            "  location:   1  (WRIST)",
            "  confidence: 90  (raw)",
            "  status:     0  (raw)",
            "",
            "Δ vs previous capture: first capture — probe again in another position to diff",
        ).joinToString("\n")
        assertEquals(golden, text)
    }

    @Test fun whoop5SuccessDoesNotMisdecodeTheResultCodeAsAField() {
        val (text, _) = WhoopBleClient.formatBodyLocationProbe(hexToBytes("aa000c000000000000005400010102030405060708090a46758858"), 10, true, null)
        assertTrue(text.contains("Result code @12: SUCCESS(1)"))
        assertTrue("must never present the result code as a location", !text.contains("location:"))
        assertTrue(text.contains("unconfirmed"))
    }

    @Test fun whoop5UnsupportedIsDecisiveVerdict() {
        val (text, _) = WhoopBleClient.formatBodyLocationProbe(hexToBytes("aa000c000000000000005400030046758858"), 10, true, null)
        assertTrue(text.contains("REJECTED by firmware (UNSUPPORTED)"))
        assertTrue(text.contains("Result code @12: UNSUPPORTED(3)"))
    }
}
