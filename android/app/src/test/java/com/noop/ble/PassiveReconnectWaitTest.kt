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

    /**
     * The stamp must be set AFTER the reconnect is scheduled, because `scheduleReconnect` opens with
     * `cancelPendingReconnect()`, which clears it. The first version of #2406 stamped first, so the
     * field was wiped microseconds later and the line above could never print: a 23 Sep 2026 field log
     * has two passive reconnects and not one of these lines. The builder is pure and was always green,
     * which is exactly why the ordering needs its own pin, against the source.
     */
    @Test fun theStampSurvivesTheSchedulingItIsSetAround() {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        val src = run {
            repeat(4) {
                val f = java.io.File(root, "android/app/src/main/java/com/noop/ble/WhoopBleClient.kt")
                if (f.isFile) return@run f.readText()
                root = root.parentFile ?: root
            }
            error("WhoopBleClient.kt not found — this test must not pass by default")
        }
        val scheduled = src.indexOf("scheduleReconnect(directDelay) { connectToDevice(dev, autoConnect = passiveReconnect) }")
        val stamped = src.indexOf("if (passiveReconnect) passiveReconnectSinceMs = System.currentTimeMillis()")
        assertTrue("the passive reconnect scheduling call moved; fix this test", scheduled > 0)
        assertTrue("the passive wait stamp moved; fix this test", stamped > 0)
        assertTrue(
            "the stamp must follow scheduleReconnect, which clears it via cancelPendingReconnect()",
            stamped > scheduled,
        )
    }
}
