package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2384: the `HR notify:` line Android was missing.
 *
 * A reporter's WHOOP 5/MG banked `live hr=0 rr=0` on ten consecutive links while the historical offload
 * ran perfectly. Their Android log could not say which of two opposite things was happening: the strap
 * never notifying on the standard 0x2A37 profile, or notifying with a reading `parseStandardHr` drops on
 * its 30..220 plausibility check in silence. iOS has always printed this line; Android had no twin.
 *
 * The expected strings below are the Swift twin's own output, verbatim, so the two platforms cannot drift
 * apart in wording. Mirrors `StandardHrNotifyLineTests`.
 */
class StandardHrNotifyLineTest {

    @Test fun aUsableReadingSaysSoPlainly() {
        assertEquals("HR notify: 62 bpm, rr=2",
            WhoopBleClient.standardHrNotifyLine(62, 2))
    }

    @Test fun anUnusableReadingIsMarkedIgnored() {
        assertEquals("HR notify: 0 bpm ignored, rr=0",
            WhoopBleClient.standardHrNotifyLine(0, 0))
    }

    /** The marker must track the value gate exactly, or the line lies about what reached the store. */
    @Test fun theIgnoredMarkerUsesTheSameRangeAsTheValueGate() {
        for (hr in listOf(30, 31, 219, 220)) {
            assertFalse("hr=$hr is inside the gate",
                WhoopBleClient.standardHrNotifyLine(hr, 0).contains("ignored"))
        }
        for (hr in listOf(0, 29, 221, 300)) {
            assertTrue("hr=$hr is outside the gate",
                WhoopBleClient.standardHrNotifyLine(hr, 0).contains(" ignored"))
        }
    }

    /** R-R rides the same line, because "HR arrived but carried no intervals" is its own diagnosis. */
    @Test fun theIntervalCountRidesTheSameLine() {
        assertEquals("HR notify: 58 bpm, rr=0",
            WhoopBleClient.standardHrNotifyLine(58, 0))
    }

    /** The first reading of a link is the one most worth having, so a never-emitted stamp must emit. */
    @Test fun theFirstReadingAlwaysEmits() {
        assertTrue(WhoopBleClient.shouldLogStandardHrNotify(lastEmitMs = 0L, nowMs = 1_000L))
    }

    @Test fun theProfileCadenceIsRateLimitedToOneLinePerGap() {
        assertFalse(WhoopBleClient.shouldLogStandardHrNotify(lastEmitMs = 1_000L, nowMs = 30_999L))
        assertTrue(WhoopBleClient.shouldLogStandardHrNotify(lastEmitMs = 1_000L, nowMs = 31_000L))
    }

    /**
     * A backwards wall clock must not strand the stamp in the future and silence the line indefinitely.
     * Same policy as `shouldEmitLiveInsertFailure`, and a deliberate divergence from the Swift twin,
     * which compares `Date`s inline and does silence on that step. The WORDING is pinned across the two;
     * this cadence policy is not.
     */
    @Test fun aBackwardsClockEmitsRatherThanLatchingSilent() {
        assertTrue(WhoopBleClient.shouldLogStandardHrNotify(lastEmitMs = 9_000_000L, nowMs = 1_000L))
    }
}
