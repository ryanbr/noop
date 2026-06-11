package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

/**
 * WHOOP 5.0/MG type-47 "v18" historical decode (Android), against the SAME real captured frames the
 * macOS `Whoop5HistoricalTests` uses — so both platforms are verified to decode byte-for-byte identical
 * data. Offsets are WHOOP5-absolute (record @8), NOT the WHOOP4 V24 layout. Each per-second biometric
 * field is gated to a physical range; this test pins the real decoded values.
 */
class Whoop5HistoricalDecodeTest {

    private fun bytes(s: String): ByteArray =
        s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    // Real worn WHOOP 5 v18 frame: hr=102, rr=[602,613] ms, |gravity|≈1, skin temp 30.57 °C.
    private val wornV18 =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    // Real off-wrist v18 frame (hr=0): same thermistor reads ambient (~22.5 °C), not skin.
    private val offWristV18 =
        "aa01740001003fb12f12803a3d84018889266a3d0a00000000000000000000000000000000000000000064c33b52b47d3fe1ba1dbda470ecbd000064000000000000000000e500e200c708000c010c020c0000000000000000000000000000000000000000000000010000008080000000000000000000009ffafe6c"

    @Test
    fun decodesWhoop5V18CoreAndBiometrics() {
        val p = decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)
        assertNotNull(p)
        p!!
        assertEquals(18, p["hist_version"])
        assertEquals(1780916150, p["unix"])
        assertEquals(102, p["heart_rate"])
        assertEquals(2, p["rr_count"])
        assertEquals(listOf(602, 613), p["rr_intervals"])

        val gx = p["gravity_x"] as Double
        val gy = p["gravity_y"] as Double
        val gz = p["gravity_z"] as Double
        assertEquals(1.0, sqrt(gx * gx + gy * gy + gz * gz), 0.05)

        // Per-second biometric fields (verified vs the real frame).
        assertEquals(3057, p["skin_temp_raw"]) // 30.57 °C
        assertEquals(50, p["step_motion_counter"])
        assertEquals(0, p["motion_wear_quality"])
        assertTrue((p["dynamic_acceleration"] as Double) in 0.0..8.0)
    }

    @Test
    fun skinTempTracksWristContact() {
        val worn = decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP5)!!
        val off = decodeHistorical(bytes(offWristV18), DeviceFamily.WHOOP5)!!
        assertEquals(3057, worn["skin_temp_raw"]) // ~30.6 °C on the wrist
        assertEquals(2247, off["skin_temp_raw"]) // ~22.5 °C off the wrist (ambient), still within guard
    }

    @Test
    fun whoop4FamilyDoesNotMisreadAWhoop5Frame() {
        // Decoding a WHOOP5 frame as WHOOP4 must yield null (different envelope; type@4 != 47 / CRC differs)
        assertNull(decodeHistorical(bytes(wornV18), DeviceFamily.WHOOP4))
    }

    // Real Android WHOOP 5.0 v18 frame from an ACK-enabled hardware offload (a clock-synced strap
    // releasing genuine body frames) — independent ground truth for the same offsets. (#78 fork)
    private val androidAckCaptureV18 =
        "aa01740001003fb12f1280aaae6f01bea0286ae11a004200000000000000000000b0000084414b38dc80b96c3c717d243dd7638f3ee182773ff6007e00000000000000000026013601a60c5004010c020c00000000000000000000000000000000000000000000010100a27c2521000000bff73ec00000002ce4150a"

    @Test
    fun decodesAndroidAckCaptureV18() {
        val p = decodeHistorical(bytes(androidAckCaptureV18), DeviceFamily.WHOOP5)
        assertNotNull(p)
        p!!
        assertEquals(18, p["hist_version"])
        assertEquals(1781047486, p["unix"])
        assertEquals(66, p["heart_rate"])
        assertEquals(3238, p["skin_temp_raw"]) // 32.38 °C on the wrist
        val gx = p["gravity_x"] as Double
        val gy = p["gravity_y"] as Double
        val gz = p["gravity_z"] as Double
        assertEquals(1.0, sqrt(gx * gx + gy * gy + gz * gz), 0.05)
    }

    // A SECOND device (Galaxy S24 Ultra capture, 2026-06-11). Each HR was cross-checked against the
    // SAME device's own live REALTIME_DATA at the identical unix second (57 & 63 bpm matched exactly,
    // 53/53 over the overlap) — ground truth, not self-referential. Pins that v18 GENERALISES.
    private val secondDeviceHR57 =
        "aa01740001003fb12f128093c47c006dbc296a00600039000000000000000000006137020b610000e1e04c063d8fce36bf7b08233f8fea993e38a50000000000000000000019012101920b5002010c020c0100000000000000000000000000000000000000000005010085808080000000a5538ec000000016d0680d"
    private val secondDeviceHR63 =
        "aa01740001003fb12f128034d67c000ece296a0a77003f01fc0300000000000000203a0302e30000ff00f8093c1f8534bcc3a5473f4819243f85a6000000000000000000001b012601e80b5003010c020c00000000000000000000000000000000000000000000050100ced7241c0000006ead8cc00000008775b70c"

    @Test
    fun decodesV18FromASecondDevice() {
        for ((hex, expectHR, expectUnix) in listOf(
            Triple(secondDeviceHR57, 57, 1781120109),
            Triple(secondDeviceHR63, 63, 1781124622),
        )) {
            val p = decodeHistorical(bytes(hex), DeviceFamily.WHOOP5)
            assertNotNull(p); p!!
            assertEquals(18, p["hist_version"])
            assertEquals(expectUnix, p["unix"])
            assertEquals(expectHR, p["heart_rate"]) // == the device's own live HR at this second
            val gx = p["gravity_x"] as Double
            val gy = p["gravity_y"] as Double
            val gz = p["gravity_z"] as Double
            assertEquals(1.0, sqrt(gx * gx + gy * gy + gz * gz), 0.2)
        }
    }
}
