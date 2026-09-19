package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2332: the band that decides whether a link RSSI reading reaches the epitaph.
 *
 * The value this guards against is 127, the BLE spec's "RSSI is not available". Recording it would put an
 * extremely strong reading on a link that died, which argues the radio was fine and sends the next reader
 * of that log looking anywhere but at range. Pinned here because the gate is one comparison and a wrong
 * bound would be invisible in a strap log: the fabricated reading looks exactly like a good one.
 */
class RssiReadingBandTest {

    @Test fun realReadingsAreKept() {
        // The field report behind #2332: median -92, min -96, best -48.
        for (rssi in listOf(-96, -93, -92, -87, -76, -63, -48)) {
            assertTrue("$rssi dBm is a real reading", WhoopBleClient.rssiReadingIsUsable(rssi))
        }
    }

    @Test fun theSpecsUnavailableSentinelIsRejected() {
        assertFalse("127 is the spec's 'not available'", WhoopBleClient.rssiReadingIsUsable(127))
    }

    @Test fun otherShapesOfTheSameFaultAreRejected() {
        // A band, not `!= 127`: a stack reporting "unavailable" as some other positive number is the same
        // fault, and every one of these would read as a stronger link than any real reading in the report.
        assertFalse(WhoopBleClient.rssiReadingIsUsable(21))
        assertFalse(WhoopBleClient.rssiReadingIsUsable(100))
        assertFalse(WhoopBleClient.rssiReadingIsUsable(Int.MAX_VALUE))
        // ...and one absurdly weak, which no radio reports and which would skew any later slope.
        assertFalse(WhoopBleClient.rssiReadingIsUsable(-128))
        assertFalse(WhoopBleClient.rssiReadingIsUsable(Int.MIN_VALUE))
    }

    @Test fun theBoundsThemselvesAreInclusive() {
        // Pinned so a later "tighten the band" cannot quietly move an edge: both ends are kept.
        assertTrue(WhoopBleClient.rssiReadingIsUsable(-127))
        assertTrue(WhoopBleClient.rssiReadingIsUsable(20))
        assertFalse(WhoopBleClient.rssiReadingIsUsable(-127 - 1))
        assertFalse(WhoopBleClient.rssiReadingIsUsable(20 + 1))
    }

    @Test fun zeroIsKeptBecauseTheSpecPermitsIt() {
        // 0 dBm is not reachable on a real link, so it is a plausible "unavailable" sentinel for a stack
        // to invent. It is KEPT anyway: the spec permits it, so rejecting it would discard a spec-valid
        // reading on a guess. Pinned so the trade-off stays a decision rather than drifting into one.
        assertTrue("0 is inside the spec's range, so it is kept", WhoopBleClient.rssiReadingIsUsable(0))
    }
}
