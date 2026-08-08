package com.noop.ble

import android.bluetooth.BluetoothGatt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [WhoopBleClient.connectionPriorityFor] — the pure GATT connection-priority decision (#477),
 * unit-testable without a BLE stack (the [ScanPowerBackoffTest] idiom).
 *
 * SAFE half: HIGH during an offload burst OR a live-HR session — a SHORTER interval than BALANCED, so
 * it can't cause a supervision-timeout drop and it shortens the radio-on window. RISKY half
 * ([idleThrottleEnabled], default off): LOW_POWER when idle. Off → BALANCED, today's default.
 */
class ConnectionPriorityTest {

    @Test fun activeWorkIsAlwaysHigh() {
        // offload OR live-HR → HIGH, and the idle throttle can't override active work
        assertEquals(
            BluetoothGatt.CONNECTION_PRIORITY_HIGH,
            WhoopBleClient.connectionPriorityFor(offloadActive = true, liveHrActive = false, idleThrottleEnabled = false),
        )
        assertEquals(
            BluetoothGatt.CONNECTION_PRIORITY_HIGH,
            WhoopBleClient.connectionPriorityFor(offloadActive = false, liveHrActive = true, idleThrottleEnabled = false),
        )
        assertEquals(
            BluetoothGatt.CONNECTION_PRIORITY_HIGH,
            WhoopBleClient.connectionPriorityFor(offloadActive = true, liveHrActive = false, idleThrottleEnabled = true),
        )
    }

    @Test fun idleWithThrottleOffStaysBalanced() {
        // The whole point of the safe half shipping default-on: idle == today's behaviour when the
        // risky throttle is off.
        assertEquals(
            BluetoothGatt.CONNECTION_PRIORITY_BALANCED,
            WhoopBleClient.connectionPriorityFor(offloadActive = false, liveHrActive = false, idleThrottleEnabled = false),
        )
    }

    @Test fun idleWithThrottleOnDropsToLowPower() {
        assertEquals(
            BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER,
            WhoopBleClient.connectionPriorityFor(offloadActive = false, liveHrActive = false, idleThrottleEnabled = true),
        )
    }

    // --- #533: which ACTIVE work escalates, once the safe half is switched on ---

    /**
     * The production wiring passes `liveHrActive = realtimeArmed && escalateForLiveHr`, and
     * `escalateForLiveHr` is DEFAULT OFF. That matters because `realtimeArmed` is true for the whole
     * OVERNIGHT continuous-HRV window, not just while a Live screen is open: escalating it would hold an
     * ~11.25 ms interval for hours to carry a 1 Hz stream BALANCED already serves. Pin that an armed live
     * stream alone stays BALANCED, while the bounded offload burst still escalates through it.
     */
    @Test fun liveHrAloneDoesNotEscalateByDefault() {
        val realtimeArmed = true
        val escalateForLiveHr = false      // the shipped default
        val liveHrActive = realtimeArmed && escalateForLiveHr

        // Overnight capture armed, no offload → stays BALANCED (no all-night HIGH).
        assertEquals(
            BluetoothGatt.CONNECTION_PRIORITY_BALANCED,
            WhoopBleClient.connectionPriorityFor(
                offloadActive = false, liveHrActive = liveHrActive, idleThrottleEnabled = false,
            ),
        )
        // ...but an offload burst during that same window DOES escalate — the point of #533.
        assertEquals(
            BluetoothGatt.CONNECTION_PRIORITY_HIGH,
            WhoopBleClient.connectionPriorityFor(
                offloadActive = true, liveHrActive = liveHrActive, idleThrottleEnabled = false,
            ),
        )
    }

    /** Opting the knob ON restores the #477 behaviour (the R22 deep-buffer capture is the one high-rate
     *  live case that could legitimately want it), so the resolver branch stays live, not dead. */
    @Test fun liveHrEscalatesWhenTheKnobIsOptedIn() {
        val liveHrActive = true && true     // realtimeArmed && escalateForLiveHr
        assertEquals(
            BluetoothGatt.CONNECTION_PRIORITY_HIGH,
            WhoopBleClient.connectionPriorityFor(
                offloadActive = false, liveHrActive = liveHrActive, idleThrottleEnabled = false,
            ),
        )
    }

    // --- #533: turning the experiment OFF must UNDO a live escalation ---

    /**
     * `refreshConnectionPriority` early-returns once management is disabled, so disabling can only stop
     * FUTURE escalations — a link already pinned at HIGH would stay there until the next reconnect unless
     * the on→off edge explicitly releases it. That would break the toggle's own promise ("turn it back off"
     * if it costs battery) for anyone on a background connection.
     */
    @Test fun disablingReleasesTheLinkBackToDefault() {
        assertTrue(WhoopBleClient.releasesOnDisable(wasEnabled = true, nowEnabled = false))
    }

    /** Every other transition must issue NO request — notably the default launch path, which re-applies
     *  `enabled = false` while already off and must stay byte-for-byte today's zero-BLE-op behaviour. */
    @Test fun onlyTheOnToOffEdgeReleases() {
        assertFalse(WhoopBleClient.releasesOnDisable(wasEnabled = false, nowEnabled = false))
        assertFalse(WhoopBleClient.releasesOnDisable(wasEnabled = false, nowEnabled = true))
        assertFalse(WhoopBleClient.releasesOnDisable(wasEnabled = true, nowEnabled = true))
    }

    // --- battery-adaptive gate, keyed on STRAP battery only (#477) ---

    @Test fun idleThrottleEngagesOnlyWhenDischargingAtOrBelowThreshold() {
        // strap at/below threshold, discharging → engage
        assertTrue(WhoopBleClient.idleThrottleActive(batteryPct = 20, charging = false, thresholdPct = 20))
        assertTrue(WhoopBleClient.idleThrottleActive(batteryPct = 12, charging = false, thresholdPct = 20))
        // above threshold → do not engage
        assertFalse(WhoopBleClient.idleThrottleActive(batteryPct = 21, charging = false, thresholdPct = 20))
        // well above → do not engage (the phone's own Battery Saver is NOT a trigger)
        assertFalse(WhoopBleClient.idleThrottleActive(batteryPct = 80, charging = false, thresholdPct = 20))
    }

    @Test fun idleThrottleNeverEngagesWhenChargingOrDisabled() {
        // strap charging → never (its battery isn't the concern)
        assertFalse(WhoopBleClient.idleThrottleActive(batteryPct = 5, charging = true, thresholdPct = 30))
        // threshold 0 → disabled
        assertFalse(WhoopBleClient.idleThrottleActive(batteryPct = 1, charging = false, thresholdPct = 0))
    }

    // --- battery-adaptive offload cadence (#477) ---

    private val base = 900_000L      // 15 min
    private val low = 2_700_000L     // 45 min

    @Test fun offloadStretchesOnlyWhenDischargingAtOrBelowThreshold() {
        // strap discharging, at/below → stretched
        assertEquals(low, WhoopBleClient.offloadIntervalMsFor(base, low, batteryPct = 18, charging = false, thresholdPct = 20))
        // above threshold → normal cadence (no phone-Battery-Saver override)
        assertEquals(base, WhoopBleClient.offloadIntervalMsFor(base, low, batteryPct = 40, charging = false, thresholdPct = 20))
        assertEquals(base, WhoopBleClient.offloadIntervalMsFor(base, low, batteryPct = 70, charging = false, thresholdPct = 20))
    }

    @Test fun offloadNeverStretchesWhenChargingOrDisabled() {
        // strap charging → normal even at low battery
        assertEquals(base, WhoopBleClient.offloadIntervalMsFor(base, low, batteryPct = 8, charging = true, thresholdPct = 30))
        // threshold 0 → normal cadence always
        assertEquals(base, WhoopBleClient.offloadIntervalMsFor(base, low, batteryPct = 3, charging = false, thresholdPct = 0))
    }

    // #battery: a 5/MG whose history offload is known-empty (experimental on 5.0) stretches to the 45-min
    // floor regardless of battery % — it banks nothing per pass, so a 15-min kick just holds the link ~60 s
    // for zero data. Twin of iOS BLEManager.whoop5EmptyHistoryBackfillInterval.
    @Test fun whoop5EmptyHistoryStretchesToLowFloor() {
        assertEquals(low, WhoopBleClient.whoop5EmptyHistoryBackfillIntervalMs(base, low, historyEmpty = true))
    }

    @Test fun whoop5NonEmptyStaysAtBase() {
        assertEquals(base, WhoopBleClient.whoop5EmptyHistoryBackfillIntervalMs(base, low, historyEmpty = false))
    }

    // Defensive: a misconfigured low floor below the base never SHORTENS the cadence (max, not min).
    @Test fun whoop5EmptyHistoryNeverShortensBelowBase() {
        assertEquals(base, WhoopBleClient.whoop5EmptyHistoryBackfillIntervalMs(base, lowBatteryMs = 300_000L, historyEmpty = true))
    }
}
