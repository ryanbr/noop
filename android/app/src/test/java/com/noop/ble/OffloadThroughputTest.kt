package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #1007 — the throughput summary emitted at the end of an offload burst.
 *
 * This exists so #477's connection-priority escalation and #533's LE 2M preference can be validated
 * instead of argued about. Both ship OFF, gated on a real-strap comparison that never happened because
 * nothing measured the thing they change: #1007's own figures had to be counted by hand out of a raw
 * capture. These pin the format a before/after comparison is read from.
 */
class OffloadThroughputTest {

    /** The reported case, at #1007's own measurement: 3193 frames in 90 s is ~35.5 frame/s on a 5/MG. */
    @Test fun reportsCountElapsedAndRate() {
        assertEquals(
            "3193 frame(s) in 90.0s (35.5 frame/s)",
            WhoopBleClient.offloadThroughputLine(3193, 90_000L),
        )
    }

    /** A WHOOP 4.0's ~10 frame/s, the slower half of the same issue. */
    @Test fun reportsTheSlowerFourPointZeroRate() {
        assertEquals(
            "600 frame(s) in 60.0s (10.0 frame/s)",
            WhoopBleClient.offloadThroughputLine(600, 60_000L),
        )
    }

    /** A burst the strap never answered still reports honestly — the count is the #78 retry signal. */
    @Test fun aStrapThatSentNothingStillReportsTheElapsed() {
        assertEquals("0 frame(s) in 12.0s (0.0 frame/s)", WhoopBleClient.offloadThroughputLine(0, 12_000L))
    }

    /** An unknown start yields the count WITHOUT a rate, never a fabricated one. */
    @Test fun anUnknownElapsedOmitsTheRate() {
        assertEquals("42 frame(s)", WhoopBleClient.offloadThroughputLine(42, -1L))
        assertEquals("42 frame(s)", WhoopBleClient.offloadThroughputLine(42, 0L))
    }

    /** Sub-second bursts round to a tenth rather than reading as zero elapsed. */
    @Test fun subSecondBurstsRoundToATenth() {
        assertEquals("5 frame(s) in 0.4s (12.5 frame/s)", WhoopBleClient.offloadThroughputLine(5, 400L))
    }
}
