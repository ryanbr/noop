package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Registry model-label → [DeviceFamily] resolution (#171). Mirrors the macOS `RegistryModelFamilyTests`.
 *
 * The device registry holds several historical spellings for the same hardware — the Add-Device
 * wizard's bare "4.0" / "5.0 MG", the full picker labels ("WHOOP 4.0" / "WHOOP 5.0 / MG"), and the
 * legacy seeded "my-whoop" row's bare "WHOOP". Call sites that compared ONE spelling silently missed
 * the others (issue #171: wizard-paired 4.0 straps decoded on the 5/MG /100 scale, ~8 °C skin temps
 * in the Deep Timeline). These tests pin the full label contract so a new spelling — or a regression
 * back to a single-spelling comparison — fails loudly.
 */
class RegistryModelFamilyTest {

    // ── WHOOP 4.0 — every stored spelling must positively identify (the #171 fix) ──

    @Test
    fun wizardBare40LabelResolvesToWhoop4() {
        assertEquals(DeviceFamily.WHOOP4, DeviceFamily.forRegistryModel("4.0"))
    }

    @Test
    fun fullPicker40LabelResolvesToWhoop4() {
        assertEquals(DeviceFamily.WHOOP4, DeviceFamily.forRegistryModel("WHOOP 4.0"))
    }

    // ── WHOOP 5/MG — both spellings keep the /100 path ──────────────────────

    @Test
    fun wizard5MgLabelResolvesToWhoop5() {
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel("5.0 MG"))
        // "WHOOP 5.0 MG" is a spelling no writer produces today (the picker writes
        // "WHOOP 5.0 / MG"); it lands on the safe WHOOP5 default, which happens to be correct.
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel("WHOOP 5.0 MG"))
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel("WHOOP 5.0 / MG"))
    }

    // ── Legacy + unknowns — the prior WHOOP5 fallback, unchanged ────────────

    @Test
    fun legacySeededWhoopLabelKeepsWhoop5Fallback() {
        // The seeded "my-whoop" row predates the wizard and was written identically for 4.0 and
        // 5/MG installs, so "WHOOP" carries no family information; it keeps the prior fallback.
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel("WHOOP"))
    }

    @Test
    fun nullEmptyAndGarbageFallBackToWhoop5() {
        // Model-ONLY resolution is brand-blind: an Oura/Garmin model string has no WHOOP spelling, so it
        // lands on the WHOOP5 default. This is why a non-WHOOP device needs forRegistryDevice (#1086) —
        // the brand is the evidence the model string lacks.
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel(null))
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel(""))
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel("Oura Ring Gen3"))
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryModel("garmin-hrm"))
    }

    // ── Brand-aware resolution (#1086) — a non-WHOOP brand must NOT resolve to a WHOOP family ──

    /**
     * The core of #1086: an Oura ring carries brand "Oura", so it resolves to null (not a WHOOP). The
     * brand is tested BEFORE the model switch, so every generation resolves to null — no model-string
     * enumeration to keep in sync with new rings (Oura Ring 3/4/5 and the cloud fallback are one path).
     */
    @Test
    fun nonWhoopBrandResolvesToNull() {
        for (model in listOf("Oura Ring 3", "Oura Ring 4", "Oura Ring 5", "Oura (cloud)")) {
            assertEquals("Oura model $model must not resolve to a WHOOP family",
                null, DeviceFamily.forRegistryDevice(model, "Oura"))
        }
        assertEquals(null, DeviceFamily.forRegistryDevice(null, "Garmin"))
        assertEquals(null, DeviceFamily.forRegistryDevice("Watch", "Apple"))
    }

    /** A WHOOP brand still resolves by model spelling, exactly as forRegistryModel does. */
    @Test
    fun whoopBrandResolvesByModel() {
        assertEquals(DeviceFamily.WHOOP4, DeviceFamily.forRegistryDevice("4.0", "WHOOP"))
        assertEquals(DeviceFamily.WHOOP4, DeviceFamily.forRegistryDevice("WHOOP 4.0", "WHOOP"))
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryDevice("5.0 MG", "WHOOP"))
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryDevice("WHOOP 5.0 / MG", "WHOOP"))
    }

    /** A null/empty brand carries no non-WHOOP signal (legacy rows, WHOOP straps), so it defers to model. */
    @Test
    fun missingBrandDefersToModel() {
        assertEquals(DeviceFamily.WHOOP4, DeviceFamily.forRegistryDevice("4.0", null))
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryDevice("5.0 MG", ""))
        assertEquals(DeviceFamily.WHOOP5, DeviceFamily.forRegistryDevice(null, null))
    }

    /**
     * "No scoring change" half of #1086: every consumer coalesces a non-WHOOP null to WHOOP5 (the
     * non-4.0 skin-temp scale), so the family a non-WHOOP row is *treated as* is identical to before the
     * brand-aware resolver existed. Guards the skin-temp/day-owner call sites against a scale regression.
     */
    @Test
    fun nonWhoopCoalescesToPriorLabel() {
        for (model in listOf("Oura Ring 3", "Oura Ring 4", "Oura Ring 5")) {
            assertEquals(
                "$model treated-as family must be unchanged",
                DeviceFamily.forRegistryModel(model),
                DeviceFamily.forRegistryDevice(model, "Oura") ?: DeviceFamily.WHOOP5,
            )
        }
    }
}
