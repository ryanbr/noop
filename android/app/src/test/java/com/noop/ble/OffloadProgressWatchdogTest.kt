package com.noop.ble

import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which offload frames may re-arm the backfill idle watchdog ([WhoopBleClient.offloadFrameShowsProgress]).
 *
 * A WHOOP 4.0 that answered SEND_HISTORICAL_DATA with PENDING and then sent only its periodic EVENT
 * frames kept the session open indefinitely, because every event re-armed the 60 s watchdog. These pin
 * that events no longer count as progress on a 4.0 while every genuine offload type still does, and
 * that 5/MG keeps its existing behaviour. Twin of the Swift `OffloadProgressWatchdogTests`.
 */
class OffloadProgressWatchdogTest {

    private fun frame(type: Int, at: Int): ByteArray = ByteArray(16).also { it[at] = type.toByte() }

    @Test
    fun whoop4EventFrameIsNotProgress() {
        assertTrue("an EVENT is still an offload frame and is still routed to the drain",
            WhoopBleClient.isOffloadFrame(frame(48, 4), DeviceFamily.WHOOP4))
        assertFalse(WhoopBleClient.offloadFrameShowsProgress(frame(48, 4), DeviceFamily.WHOOP4))
    }

    @Test
    fun whoop4HistoryTypesAreProgress() {
        for (t in intArrayOf(47, 49, 50, 56)) {
            assertTrue("type $t must re-arm the watchdog",
                WhoopBleClient.offloadFrameShowsProgress(frame(t, 4), DeviceFamily.WHOOP4))
        }
    }

    @Test
    fun liveFramesAreNeverProgress() {
        for (t in intArrayOf(40, 43)) {
            assertFalse(WhoopBleClient.offloadFrameShowsProgress(frame(t, 4), DeviceFamily.WHOOP4))
            assertFalse(WhoopBleClient.offloadFrameShowsProgress(frame(t, 8), DeviceFamily.WHOOP5))
        }
    }

    @Test
    fun whoop5EventFrameIsUnchanged() {
        assertTrue(WhoopBleClient.offloadFrameShowsProgress(frame(48, 8), DeviceFamily.WHOOP5))
    }

    @Test
    fun shortFrameIsNotProgress() {
        assertFalse(WhoopBleClient.offloadFrameShowsProgress(byteArrayOf(0xAA.toByte(), 1, 0), DeviceFamily.WHOOP4))
    }
}
