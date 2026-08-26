package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors WhoopProtocolTests/Whoop5VariantTests.swift — same fixtures, same expected outputs, so the
 * twin resolvers cannot drift.
 */
class Whoop5VariantTest {

    @Test fun serialPrefixIdentifiesMg() {
        assertEquals(Whoop5Variant.MG, Whoop5Variant.from("5AM12345678"))
        assertTrue(Whoop5Variant.from("5AM12345678").isMG)
    }

    @Test fun serialPrefixIdentifiesFiveZero() {
        assertEquals(Whoop5Variant.FIVE_ZERO, Whoop5Variant.from("5AG12345678"))
        assertFalse(Whoop5Variant.from("5AG12345678").isMG)
    }

    @Test fun hardwareRevisionIsDeviceAttestedFiveZero() {
        // The observed 5.0 hardware id, with no serial available at all.
        assertEquals(Whoop5Variant.FIVE_ZERO, Whoop5Variant.from(null, "WG50_r52"))
    }

    @Test fun advertisedNamePrefixTolerated() {
        // Callers may pass the advertised name instead of the DIS serial.
        assertEquals(Whoop5Variant.MG, Whoop5Variant.from("WHOOP 5AM12345678"))
        assertEquals(Whoop5Variant.FIVE_ZERO, Whoop5Variant.from("  whoop 5ag12345678  "))
    }

    @Test fun contradictionYieldsUnknownRatherThanAGuess() {
        // Only the 5.0 hardware string is attested today; a contradiction means our model is
        // incomplete, so refuse to pick a winner (#716: a mis-stamped model is worse than none).
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("5AM12345678", "WG50_r52"))
    }

    @Test fun agreeingSignalsResolve() {
        assertEquals(Whoop5Variant.FIVE_ZERO, Whoop5Variant.from("5AG12345678", "WG50_r52"))
    }

    @Test fun unattestedInputsAreUnknownNeverInferred() {
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from(null))
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from(""))
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("WHOOP"))
        // A stray digit in the name must NOT imply a generation (#772 — the bug that read a
        // serial's "5" as Gen5 on a Gen3 ring; same failure mode, different product).
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("WHOOP 4.0"))
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("5XX99999999"))
        // An MG hardware-revision string is not yet attested, so it must not resolve by itself.
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from(null, "WGMG_r01"))
    }

    @Test fun labels() {
        assertEquals("MG", Whoop5Variant.MG.label)
        assertEquals("5.0", Whoop5Variant.FIVE_ZERO.label)
        assertEquals("—", Whoop5Variant.UNKNOWN.label)
    }

    /**
     * The field capture that exposed the gap: serial prefix "MGB", hardware revision "WS50_r03" — neither
     * matches MG_SERIAL_PREFIX ("5AM") nor FIVE_ZERO_HARDWARE_ID_TOKEN ("WG50"), so every heuristic
     * returned UNKNOWN for a strap whose own model number said MG.
     */
    @Test
    fun `a real MG resolves from its model number when the prefixes do not`() {
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("MGB0779473", "WS50_r03"))
        assertEquals(Whoop5Variant.MG, Whoop5Variant.from("MGB0779473", "WS50_r03", "MG"))
    }

    @Test
    fun `the model number is trimmed and case-insensitive`() {
        assertEquals(Whoop5Variant.MG, Whoop5Variant.from(null, null, "  mg  "))
    }

    /** Only MG is claimed - no 5.0 has been observed reporting a model number, so an unrecognised one
     *  falls through to the existing heuristics rather than inventing a verdict. */
    @Test
    fun `an unknown model number does not override the heuristics`() {
        assertEquals(Whoop5Variant.FIVE_ZERO, Whoop5Variant.from("5AG12345678", null, "WHOOP5"))
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from(null, null, "WHOOP5"))
    }

    /** Two heuristics disagreeing is a reason not to guess; it is not a reason to ignore the strap
     *  stating its own model. */
    @Test
    fun `the model number beats the contradiction guard`() {
        assertEquals(Whoop5Variant.MG, Whoop5Variant.from("5AM12345678", "WG50_r52", "MG"))
    }
}
