package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Kotlin twin of `LowRefreshCadenceTests.swift`. "Low refresh" (Settings -> Power saving sub-option)
 * moves the BASE periodic-offload cadence from 15 min to 60 min. The invariant that matters is
 * COMPOSITION: every other lever stretches FROM that base with `max`, so no lever can hand back a faster
 * cadence than the user asked for, and a lever that would have stretched a 15-min base becomes a no-op
 * once the base is already longer.
 *
 * Cadence only, by design: low refresh does NOT touch the keep-alive (that tick re-arms realtime and
 * evaluates the stall fuse) and does NOT release continuous HRV capture (that is the separate
 * `setPauseCaptureOnPowerSave` lever). Those are the two places a quieter radio would cost real data
 * rather than merely delaying it.
 */
class LowRefreshCadenceTest {

    @Test
    fun baseIsFifteenMinutesWhenOff() {
        assertEquals(900_000L, WhoopBleClient.baseBackfillIntervalMs(lowRefresh = false))
    }

    @Test
    fun baseIsHourlyWhenOn() {
        assertEquals(
            WhoopBleClient.LOW_REFRESH_BACKFILL_INTERVAL_MS,
            WhoopBleClient.baseBackfillIntervalMs(lowRefresh = true),
        )
        assertEquals(3_600_000L, WhoopBleClient.LOW_REFRESH_BACKFILL_INTERVAL_MS)
    }

    /** The low-battery lever (45 min) is SHORTER than low refresh (60 min): composed with `max` it must
     *  leave the hourly cadence alone rather than speeding it back up. */
    @Test
    fun lowBatteryLeverNeverShortensLowRefresh() {
        val base = WhoopBleClient.baseBackfillIntervalMs(lowRefresh = true)
        val composed = WhoopBleClient.offloadIntervalMsFor(
            baseMs = base,
            lowBatteryMs = maxOf(base, 2_700_000L),
            batteryPct = 10,
            charging = false,
            thresholdPct = 20,   // lever fully engaged
        )
        assertEquals(WhoopBleClient.LOW_REFRESH_BACKFILL_INTERVAL_MS, composed)
    }

    /** With low refresh off the same engaged lever still stretches 15 -> 45 min: inert for everyone who
     *  does not turn it on. */
    @Test
    fun defaultBehaviourIsUnchangedWhenOff() {
        val base = WhoopBleClient.baseBackfillIntervalMs(lowRefresh = false)
        assertEquals(
            2_700_000L,
            WhoopBleClient.offloadIntervalMsFor(
                baseMs = base, lowBatteryMs = maxOf(base, 2_700_000L),
                batteryPct = 10, charging = false, thresholdPct = 20,
            ),
        )
        // …and an idle/charged strap keeps the plain 15-min cadence.
        assertEquals(
            900_000L,
            WhoopBleClient.offloadIntervalMsFor(
                baseMs = base, lowBatteryMs = maxOf(base, 2_700_000L),
                batteryPct = 90, charging = false, thresholdPct = 20,
            ),
        )
    }

    /** The 5/MG empty-history stretch (45 min) composes the same way. */
    @Test
    fun whoop5EmptyHistoryStretchNeverShortensLowRefresh() {
        val base = WhoopBleClient.baseBackfillIntervalMs(lowRefresh = true)
        assertEquals(
            WhoopBleClient.LOW_REFRESH_BACKFILL_INTERVAL_MS,
            WhoopBleClient.whoop5EmptyHistoryBackfillIntervalMs(
                baseMs = base,
                lowBatteryMs = maxOf(base, 2_700_000L),
                historyEmpty = true,
            ),
        )
    }
}
