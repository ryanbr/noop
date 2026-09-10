package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The cmd-151 pack probe must not publish the pack's identity.
 *
 * Its report reaches TWO sinks: the shareable strap log, and a Devices dialog with a
 * copy-to-clipboard button. [redactStrapLogPii] guards only the first, and it would not have caught
 * either identifier anyway — the serial rule keys on a literal "WHOOP " prefix, so a bare
 * `serial  = BB5AP…` matches nothing, and the MAC rule keys on COLONS, which `btAddr`'s colon-less
 * `joinToString("")` never produces. So both are masked at the SOURCE instead. The pack-log line in
 * `handleCommandResponse` already carried that lesson; these tests keep a probe from undoing it.
 */
class BatteryPackProbeRedactionTest {

    /** A well-formed 151 SUCCESS frame at cmdOff=10 carrying a known address, serial and SoC word. */
    private fun frameWith(mac: ByteArray, serial: String, soc: Int): ByteArray {
        val f = ByteArray(45)
        f[10] = 151.toByte()
        f[12] = 1          // result = SUCCESS
        f[14] = 1          // present = true
        mac.copyInto(f, 15)
        serial.toByteArray(Charsets.US_ASCII).copyInto(f, 21)
        f[37] = (soc and 0xFF).toByte()
        f[38] = ((soc shr 8) and 0xFF).toByte()
        return f
    }

    private val mac = byteArrayOf(0xC4.toByte(), 0x9D.toByte(), 0xED.toByte(), 0x11, 0x22, 0x33)
    private val serial = "WHOOP5A1B2C3D4E"

    @Test fun reportNeverCarriesTheFullSerialOrAddress() {
        val report = WhoopBleClient.formatBatteryPackProbe(frameWith(mac, serial, 812), 10)
        assertFalse("the full pack serial must never reach the report", report.contains(serial))
        assertFalse("the full pack address must never reach the report", report.contains("c49ded112233"))
    }

    /** Masked, not merely absent: a diagnostic still has to tell two packs and two addresses apart. */
    @Test fun reportKeepsEnoughToDistinguishTwoPacks() {
        val report = WhoopBleClient.formatBatteryPackProbe(frameWith(mac, serial, 812), 10)
        assertTrue("a serial prefix is what distinguishes two packs", report.contains("serial  = WHO"))
        assertTrue("first and last octet distinguish two addresses", report.contains("c4:••:••:••:••:33"))
        // The finding itself must survive redaction — this is what the probe exists to collect.
        assertTrue(report.contains("SoC raw word = 812"))
    }

    /**
     * The dialog sink is scrubbed too. The `raw:` frame dump carries the serial as ASCII inside the
     * hex, which the source-level masking above cannot touch and only the scrubber removes.
     */
    @Test fun scrubbingTheReportRemovesTheSerialFromTheRawHexDump() {
        val report = WhoopBleClient.formatBatteryPackProbe(frameWith(mac, serial, 812), 10)
        val hexSerial = serial.toByteArray(Charsets.US_ASCII).joinToString("") { "%02x".format(it) }
        assertTrue("precondition: the raw dump does embed the serial", report.contains(hexSerial))
        assertFalse("the value shown in the dialog must not", redactStrapLogPii(report).contains(hexSerial))
    }

    /** A frame that did not decode keeps every byte: there, the offsets are the open question. */
    @Test fun anUndecodableFrameKeepsItsBytesForEvidence() {
        val f = ByteArray(45)
        f[10] = 151.toByte(); f[12] = 9   // result != SUCCESS -> decode() returns null
        mac.copyInto(f, 15)
        val report = WhoopBleClient.formatBatteryPackProbe(f, 10)
        assertTrue(report.contains("DID NOT DECODE"))
        assertTrue("the dump must stay whole when the layout is unconfirmed",
            report.contains("c49ded112233"))
    }

    @Test fun maskedAddressHandlesMissingAndMalformedInput() {
        assertEquals("<none>", WhoopBleClient.maskPackBtAddr(null))
        assertEquals("<none>", WhoopBleClient.maskPackBtAddr(""))
        assertEquals("<malformed>", WhoopBleClient.maskPackBtAddr("c49ded"))
        assertEquals("c4:••:••:••:••:33", WhoopBleClient.maskPackBtAddr("c49ded112233"))
    }

    /** An absent pack reports absence and no identity at all. */
    @Test fun absentPackReportsNoIdentifiers() {
        val f = ByteArray(45)
        f[10] = 151.toByte(); f[12] = 1; f[14] = 0
        val report = WhoopBleClient.formatBatteryPackProbe(f, 10)
        assertTrue(report.contains("present = FALSE"))
        assertFalse(report.contains("serial  ="))
        assertFalse(report.contains("bt addr ="))
    }
}
