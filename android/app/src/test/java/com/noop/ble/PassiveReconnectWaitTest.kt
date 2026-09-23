package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2406: a passive reconnect that answers says how long it waited.
 *
 * When the direct attempts are spent, the client hands the strap to Android with `autoConnect = true`
 * and then does nothing at all: no scan, no timer, no line. A field log on 23 Sep 2026 has 26 minutes
 * of silence between "reconnecting passively in 12s (attempt 3)" and the next "Connected", and nothing
 * in the file distinguishes that from the app having given up. Both look like nothing.
 */
class PassiveReconnectWaitTest {

    @Test fun theLineNamesTheWaitAndHowHardTheLinkHadBeenTrying() {
        assertEquals(
            "Reconnect: a passive reconnect was outstanding for 1572s before the link came up" +
                " (attempt 3, autoConnect: no scan, no timer, nothing logged while it waits)",
            passiveReconnectAnsweredLine(waitedSeconds = 1_572, attempts = 3),
        )
    }

    /** The field case, in the units a reader meets it in: 26 minutes. */
    @Test fun theFieldCaseReadsAsMinutesWorthOfSeconds() {
        val line = passiveReconnectAnsweredLine(waitedSeconds = 26 * 60, attempts = 3)
        assertTrue(line, line.contains("outstanding for 1560s"))
    }

    /** A wait that answers at once still reports, because "it came straight back" is also an answer. */
    @Test fun animmediateAnswerIsStillReported() {
        assertTrue(passiveReconnectAnsweredLine(waitedSeconds = 0, attempts = 1).contains("outstanding for 0s"))
    }
}
