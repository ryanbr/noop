package com.noop.widget

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins [HrDisplay]: the widget keeps showing the last heart rate through a brief quiet patch (the 5/MG
 * HR-profile lull at rest, or a reconnect that clears biometrics) instead of blanking to "-", dims it once
 * it's a carry-over rather than a fresh live sample, and drops it once it's too old to stand for the wearer.
 */
class WidgetHrDisplayTest {

    private val now = 1_000_000_000L

    @Test fun liveSample_shown_and_not_stale() {
        assertEquals(72 to false, HrDisplay.resolve(lastHr = 72, lastHrAtMs = now, live = true, nowMs = now))
    }

    @Test fun carryOver_withinCap_shown_but_dimmed() {
        // 2 min since the last live sample (a 5/MG rest lull) — keep showing it, dimmed.
        assertEquals(72 to true, HrDisplay.resolve(lastHr = 72, lastHrAtMs = now - 2 * 60_000L, live = false, nowMs = now))
    }

    @Test fun carryOver_pastCap_dropped() {
        // 16 min stale — beyond the 15-min cap, too old to represent HR; blank it.
        assertEquals(null to false, HrDisplay.resolve(lastHr = 72, lastHrAtMs = now - 16 * 60_000L, live = false, nowMs = now))
    }

    @Test fun noReading_isBlank() {
        assertEquals(null to false, HrDisplay.resolve(lastHr = null, lastHrAtMs = 0, live = false, nowMs = now))
        assertEquals(null to false, HrDisplay.resolve(lastHr = 0, lastHrAtMs = now, live = true, nowMs = now))
    }

    @Test fun staleLiveFlag_pastLiveWindow_isDimmed() {
        // App killed mid-stream: `live` is still true but the sample is 5 min old — show it, but DIMMED,
        // never as a fresh live reading.
        assertEquals(72 to true, HrDisplay.resolve(lastHr = 72, lastHrAtMs = now - 5 * 60_000L, live = true, nowMs = now))
    }

    @Test fun staleLiveFlag_pastCap_isDropped() {
        // A lingering `live = true` must NOT bypass the cap — an hour-old reading is dropped, not shown live.
        assertEquals(null to false, HrDisplay.resolve(lastHr = 72, lastHrAtMs = now - 60 * 60_000L, live = true, nowMs = now))
    }
}
