package com.noop.widget

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Pins the second gate: a push [PushGate] admitted still costs nothing when none of the widgets have
 * anything different to show.
 *
 * This is the Android half of what `WidgetPublish.saveAndReloadIfChanged` has done on the Apple side
 * since #1957, minus the trace-only case that Glance cannot take (no OS-scheduled rebuild to carry a
 * withheld point to the screen). Everything asserted below is a case where a full widget update —
 * including a half-megabyte bitmap over a Binder transaction — would have drawn what was already
 * there.
 */
class RenderedGateTest {

    @Before
    fun setUp() = RenderedGate.resetForTest()

    private fun snap(
        hr: Int? = 62,
        stale: Boolean = false,
        recovery: Int? = 70,
        battery: Int? = 80,
        connected: Boolean = true,
        series: List<HrPoint> = listOf(HrPoint(ts = 1000, bpm = 62)),
    ) = WidgetSnapshot(
        recoveryPct = recovery,
        restPct = 80,
        effortPct = 40,
        heartRate = hr,
        heartRateStale = stale,
        batteryPct = battery,
        connected = connected,
        hrSeries = series,
        updatedAtMs = 1_700_000_000_000L,
    )

    /** The widgets may be showing what an earlier process left them, so the first push always sends. */
    @Test
    fun theFirstPushAfterAProcessStartAlwaysSends() {
        assertTrue(RenderedGate.changed(snap(), dark = false))
    }

    /**
     * The case this exists for: PushGate's 60-second timer fires whether or not anything moved, so a
     * quiet strap used to cost a full widget update a minute to redraw an identical screen.
     */
    @Test
    fun anIdenticalSnapshotIsNotSentTwice() {
        assertTrue(RenderedGate.changed(snap(), dark = false))
        assertFalse(RenderedGate.changed(snap(), dark = false))
        assertFalse(RenderedGate.changed(snap(), dark = false))
    }

    /**
     * The heart-rate VALUE has to count, because PushGate deliberately does not know it — it keys on
     * whether a reading exists, so that a stream of samples cannot admit a push each. If this gate
     * ignored the value too, a changing heart rate would never reach the screen.
     */
    @Test
    fun aChangedHeartRateSends() {
        RenderedGate.changed(snap(hr = 62), dark = false)
        assertTrue(RenderedGate.changed(snap(hr = 63), dark = false))
    }

    /** Crossing LIVE_MS dims the reading, which is a visible change with no value change behind it. */
    @Test
    fun aStalenessFlipSends() {
        RenderedGate.changed(snap(stale = false), dark = false)
        assertTrue(RenderedGate.changed(snap(stale = true), dark = false))
    }

    /** A new trace point IS sent on Android, unlike the Apple rule: nothing else would carry it. */
    @Test
    fun anAdvancedTraceSends() {
        val series = listOf(HrPoint(ts = 1000, bpm = 62))
        RenderedGate.changed(snap(series = series), dark = false)
        assertTrue(RenderedGate.changed(snap(series = series + HrPoint(ts = 1060, bpm = 63)), dark = false))
    }

    /** A point ageing out of the window redraws the chart just as surely as one arriving. */
    @Test
    fun aPrunedTraceSends() {
        RenderedGate.changed(snap(series = listOf(HrPoint(1000, 62), HrPoint(1060, 63))), dark = false)
        assertTrue(RenderedGate.changed(snap(series = listOf(HrPoint(1060, 63))), dark = false))
    }

    /** Every scalar the 2x2 and compact widgets render has to count, not just the HR ones. */
    @Test
    fun theOtherWidgetsFieldsSendToo() {
        RenderedGate.changed(snap(), dark = false)
        assertTrue("recovery", RenderedGate.changed(snap(recovery = 71), dark = false))
        assertTrue("battery", RenderedGate.changed(snap(recovery = 71, battery = 79), dark = false))
        assertTrue("connected", RenderedGate.changed(snap(recovery = 71, battery = 79, connected = false), dark = false))
    }

    /**
     * The end state after a disconnect: the trace prunes empty and the reading is dropped, and from
     * then on every push is identical. That is where this gate pays for itself, so it must not keep
     * sending once there is nothing left to say.
     */
    @Test
    fun aDrainedSnapshotSettlesAndStopsSending() {
        assertTrue(RenderedGate.changed(snap(hr = null, series = emptyList()), dark = false))
        repeat(10) { assertFalse(RenderedGate.changed(snap(hr = null, series = emptyList()), dark = false)) }
    }

    /**
     * The timestamp is the field this gate could most easily have got wrong, so it is asserted from
     * both sides.
     *
     * All three widgets RENDER it — the HR card as a permanent "Updated <time>" line, the 2x2 and
     * compact as their disconnected "last seen". Including it in the key would change the key on every
     * push and the gate could never fire. Excluding it and letting the stamp advance anyway would tell
     * the reader 14:47 while showing them 14:32's reading, and freeze a visible clock at whatever a
     * later unrelated recomposition happened to read.
     *
     * So the key excludes it deliberately, and [WidgetSnapshotStore.push] puts the previous value back
     * when it declines. This pins the first half; the second is push()'s.
     */
    @Test
    fun theStampAloneDoesNotSend() {
        RenderedGate.changed(snap(), dark = false)
        val later = WidgetSnapshot(
            recoveryPct = 70, restPct = 80, effortPct = 40,
            heartRate = 62, heartRateStale = false, batteryPct = 80, connected = true,
            hrSeries = listOf(HrPoint(ts = 1000, bpm = 62)),
            updatedAtMs = 1_700_000_900_000L,          // fifteen minutes later, same everything else
        )
        assertFalse("a newer stamp with identical content is not worth an update",
            RenderedGate.changed(later, dark = false))
    }

    /**
     * The appearance is an input the widgets read at composition, not one the snapshot carries, and
     * nothing refreshes them when it changes — a theme flip reaches the screen only because a push
     * updated them. Leaving it out of the key would have left a widget in the wrong colours until
     * something unrelated moved, which is a regression this gate would have INTRODUCED.
     */
    @Test
    fun aThemeFlipSends() {
        RenderedGate.changed(snap(), dark = false)
        assertTrue(RenderedGate.changed(snap(), dark = true))
        assertFalse("and settles again once sent", RenderedGate.changed(snap(), dark = true))
    }
}
