package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the #747 / #750 bond-refusal give-up: a strap that keeps REFUSING the encrypted bond
 * (INSUFFICIENT_AUTHENTICATION/_ENCRYPTION, no genuine bond between) eventually trips a give-up that
 * (a) pauses auto-reconnect so NOOP stops hammering it (#747) and (b) writes a one-line epitaph carrying
 * only an opaque, HASHED id (no MAC, no serial; #750). Pure value type, no BLE seam. Mirrors the Swift
 * BondRefusalGiveUpTests.
 */
class BondRefusalGiveUpTest {

    // The default threshold is 5: the pairing hint already shows from streak 2, so we give the user several
    // reconnect cycles to act before pausing. The trip is reported exactly once.
    @Test fun givesUpAfterThresholdRefusals() {
        val g = BondRefusalGiveUp()   // default giveUpThreshold = 5
        for (i in 1..4) {
            assertFalse("refusal $i is below the give-up threshold", g.recordRefusal())
            assertFalse(g.gaveUp)
        }
        assertTrue("the 5th refusal freshly trips the give-up", g.recordRefusal())
        assertTrue(g.gaveUp)
        assertEquals(5, g.refusals)
        // Already gave up → no second "freshly tripped" signal (caller pauses + writes the epitaph once).
        assertFalse(g.recordRefusal())
        assertTrue(g.gaveUp)
    }

    // reset() re-arms: a genuine bond or an explicit user reconnect clears the streak so auto-reconnect works.
    @Test fun resetReArms() {
        val g = BondRefusalGiveUp()
        repeat(5) { g.recordRefusal() }
        assertTrue(g.gaveUp)
        g.reset()
        assertFalse(g.gaveUp)
        assertEquals(0, g.refusals)
        for (i in 1..4) assertFalse(g.recordRefusal())
        assertTrue(g.recordRefusal())
    }

    // A custom (lower) threshold trips sooner.
    @Test fun customThreshold() {
        val g = BondRefusalGiveUp(giveUpThreshold = 2)
        assertFalse(g.recordRefusal())
        assertTrue(g.recordRefusal())
        assertTrue(g.gaveUp)
    }

    // #750: the epitaph records the streak + opaque id and carries NO PII (no MAC, no em-dash).
    @Test fun epitaphLineHasNoPii() {
        val line = BondRefusalGiveUp.epitaphLine(5, "a1b2c3d4")
        assertTrue(line.contains("refused the encrypted bond 5x"))
        assertTrue(line.contains("a1b2c3d4"))
        // No raw MAC (colon-separated hex octets) and no em-dash.
        assertFalse(Regex("[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:").containsMatchIn(line))
        assertFalse(line.contains("\u2014"))
    }

    // #750: the opaque id is an irreversible HASH of the MAC (never the MAC itself), deterministic + short.
    @Test fun opaqueIdHashesTheMacDeterministically() {
        val mac = "A1:B2:C3:D4:E5:F6"
        val id = BondRefusalGiveUp.opaqueId(mac)
        // 8 hex chars, lower-case, and it does NOT contain the raw MAC bytes.
        assertEquals(8, id.length)
        assertTrue(Regex("^[0-9a-f]{8}$").matches(id))
        assertFalse(id.contains("a1b2"))
        // Deterministic: the same MAC always hashes to the same token.
        assertEquals(id, BondRefusalGiveUp.opaqueId(mac))
        // Distinct MACs give distinct tokens (so a log can tell two straps apart).
        assertFalse(id == BondRefusalGiveUp.opaqueId("11:22:33:44:55:66"))
    }

    // #747: the paused hint explains the stop + the fix, with no em-dash.
    @Test fun pausedHintWording() {
        val hint = BondRefusalGiveUp.pausedHint()
        assertTrue(hint.contains("stopped retrying"))
        assertTrue(hint.contains("Forget This Device"))
        assertFalse(hint.contains("\u2014"))
    }

    @Test
    fun `a lower threshold latches sooner, and the latch still reports once`() {
        var g = BondRefusalGiveUp()          // pause threshold 5
        assertFalse(g.recordRefusal(threshold = 3))
        assertFalse(g.recordRefusal(threshold = 3))
        assertTrue(g.recordRefusal(threshold = 3))   // crossed at 3, not 5
        assertTrue(g.gaveUp)
        // Still exactly one crossing: the epitaph and the latch write are once-per-give-up.
        assertFalse(g.recordRefusal(threshold = 3))
        assertEquals(4, g.refusals)
    }

    @Test
    fun `omitting the threshold keeps the constructed one`() {
        val g = BondRefusalGiveUp()
        assertEquals(5, g.giveUpThreshold)
        repeat(4) { assertFalse(g.recordRefusal()) }
        assertTrue(g.recordRefusal())
    }
}
