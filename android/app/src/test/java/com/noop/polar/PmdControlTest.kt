package com.noop.polar

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Kotlin parity for PolarProtocol/Tests/.../PmdControlTests.swift — the PMD control-point command
 *  builder + response parse. Pure byte work, no android.bluetooth. */
class PmdControlTest {

    @Test fun getSettingsBytes() {
        assertArrayEquals(byteArrayOf(0x01, 0x03), PolarPmdControl.getSettings(PolarPmdMeasurement.PPI))
        assertArrayEquals(byteArrayOf(0x01, 0x00), PolarPmdControl.getSettings(PolarPmdMeasurement.ECG))
    }

    @Test fun startOnlineNoSettings() {
        assertArrayEquals(byteArrayOf(0x02, 0x03), PolarPmdControl.start(PolarPmdMeasurement.PPI))
        assertArrayEquals(byteArrayOf(0x02, 0x00), PolarPmdControl.start(PolarPmdMeasurement.ECG))
    }

    @Test fun startWithSettingsSerialisesU16LEBlocks() {
        val bytes = PolarPmdControl.start(
            PolarPmdMeasurement.ACC,
            settings = listOf(
                PolarPmdControl.Setting(PolarPmdControl.SETTING_SAMPLE_RATE, listOf(52)),
                PolarPmdControl.Setting(PolarPmdControl.SETTING_RANGE, listOf(8)),
            ),
        )
        assertArrayEquals(byteArrayOf(0x02, 0x02, 0x00, 0x01, 52, 0x00, 0x02, 0x01, 8, 0x00), bytes)
    }

    @Test fun startRecordingSetsBit7() {
        assertArrayEquals(byteArrayOf(0x02, 0x80.toByte()), PolarPmdControl.start(PolarPmdMeasurement.ECG, recording = true))
        assertArrayEquals(byteArrayOf(0x02, 0x83.toByte()), PolarPmdControl.start(PolarPmdMeasurement.PPI, recording = true))
    }

    @Test fun stopBytes() {
        assertArrayEquals(byteArrayOf(0x03, 0x03), PolarPmdControl.stop(PolarPmdMeasurement.PPI))
    }

    @Test fun parseResponseSuccessAndFailure() {
        val ok = PolarPmdControl.parseResponse(byteArrayOf(0xF0.toByte(), 0x02, 0x03, 0x00, 0x00))!!
        assertEquals(0x02, ok.requestOpcode)
        assertEquals(PolarPmdMeasurement.PPI, ok.measurement)
        assertEquals(0x00, ok.status)
        assertTrue(ok.isSuccess)

        val fail = PolarPmdControl.parseResponse(byteArrayOf(0xF0.toByte(), 0x02, 0x03, 0x05))!!
        assertFalse(fail.isSuccess)
        assertEquals(0x05, fail.status)
    }

    @Test fun parseResponseRejectsNonResponseFrames() {
        assertNull(PolarPmdControl.parseResponse(byteArrayOf(0x00, 0x02, 0x03, 0x00)))
        assertNull(PolarPmdControl.parseResponse(byteArrayOf(0xF0.toByte(), 0x02, 0x03)))
        assertNull(PolarPmdControl.parseResponse(byteArrayOf()))
    }
}
