package com.noop.polar

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Kotlin parity for PolarProtocol/Tests/.../PolarModelTests.swift — Polar model identification + PMD
 *  stream capabilities. */
class PolarModelTest {

    @Test fun identifyFromAdvertisedName() {
        assertEquals(PolarModel.H10, PolarModel.fromAdvertisedName("Polar H10 A1B2C3D4"))
        assertEquals(PolarModel.H9, PolarModel.fromAdvertisedName("Polar H9 11223344"))
        assertEquals(PolarModel.OH1, PolarModel.fromAdvertisedName("Polar OH1 55667788"))
        assertEquals(PolarModel.VERITY_SENSE, PolarModel.fromAdvertisedName("Polar Sense 99AABBCC"))
        assertEquals(PolarModel.H10, PolarModel.fromAdvertisedName("polar h10 lowercase"))
    }

    @Test fun unknownAndNonPolarResolveToUnknown() {
        assertEquals(PolarModel.UNKNOWN, PolarModel.fromAdvertisedName("Wahoo TICKR"))
        assertEquals(PolarModel.UNKNOWN, PolarModel.fromAdvertisedName("Polar Grit X"))
        assertEquals(PolarModel.UNKNOWN, PolarModel.fromAdvertisedName(null))
        assertEquals(PolarModel.UNKNOWN, PolarModel.fromAdvertisedName(""))
    }

    @Test fun pmdStreamsPerModel() {
        assertEquals(setOf(PolarPmdMeasurement.ECG, PolarPmdMeasurement.ACC), PolarModel.H10.pmdStreams)
        assertEquals(emptySet<PolarPmdMeasurement>(), PolarModel.H9.pmdStreams)
        assertEquals(
            setOf(PolarPmdMeasurement.PPG, PolarPmdMeasurement.PPI, PolarPmdMeasurement.ACC),
            PolarModel.OH1.pmdStreams,
        )
        // OH1 has no gyroscope; Verity Sense does — the one place they diverge.
        assertFalse(PolarModel.OH1.pmdStreams.contains(PolarPmdMeasurement.GYRO))
        assertTrue(PolarModel.VERITY_SENSE.pmdStreams.contains(PolarPmdMeasurement.GYRO))
    }

    @Test fun hrvPmdStreamPicksPpiOnlyWhereExposed() {
        assertEquals(PolarPmdMeasurement.PPI, PolarModel.VERITY_SENSE.hrvPmdStream)
        assertEquals(PolarPmdMeasurement.PPI, PolarModel.OH1.hrvPmdStream)
        assertNull(PolarModel.H10.hrvPmdStream)
        assertNull(PolarModel.H9.hrvPmdStream)
        assertNull(PolarModel.UNKNOWN.hrvPmdStream)
    }

    @Test fun serialContainingModelTokenDoesNotMisidentify() {
        // The matcher anchors on the model position, not a whole-name substring: an OH1 whose serial
        // happens to contain "h10" must stay an OH1 (a `contains` matcher wrongly returned H10 here).
        assertEquals(PolarModel.OH1, PolarModel.fromAdvertisedName("Polar OH1 H10ABCDE"))
    }

    // Debug identification (Test Centre / strap-log diagnostics) — parity with the Swift twin.

    @Test fun isPolarSeparatesPolarFromUnrecognisedAndForeign() {
        assertTrue(PolarModel.isPolar("Polar H10 A1B2C3D4"))
        assertTrue(PolarModel.isPolar("Polar Grit X"))       // real Polar, no catalog entry
        assertTrue(PolarModel.isPolar("polar sense 99AA"))   // case-insensitive
        assertFalse(PolarModel.isPolar("Wahoo TICKR"))
        assertFalse(PolarModel.isPolar("Polaris X"))         // prefix must be "polar " + space
        assertFalse(PolarModel.isPolar(null))
        assertFalse(PolarModel.isPolar(""))
    }

    @Test fun pmdDebugSummaryStatesStreamsAndHrvRoute() {
        assertEquals("PMD ecg,acc; HRV via standard R-R", PolarModel.H10.pmdDebugSummary)
        assertEquals("no PMD service; HRV via standard R-R", PolarModel.H9.pmdDebugSummary)
        assertEquals("PMD ppg,acc,ppi; HRV via PMD PPI", PolarModel.OH1.pmdDebugSummary)
        assertEquals("PMD ppg,acc,ppi,gyro; HRV via PMD PPI", PolarModel.VERITY_SENSE.pmdDebugSummary)
        assertEquals("PMD unknown (probe); HRV via standard R-R", PolarModel.UNKNOWN.pmdDebugSummary)
    }

    @Test fun debugIdentificationAutoDetectsFromAnyName() {
        // Same helper works on a live scan name OR a stored PairedDevice model — a paired strap
        // auto-detects without a live connection.
        assertEquals(
            "Polar H10 identified — PMD ecg,acc; HRV via standard R-R",
            PolarModel.debugIdentification("Polar H10 A1B2C3D4"),
        )
        assertEquals(
            "Polar Verity Sense identified — PMD ppg,acc,ppi,gyro; HRV via PMD PPI",
            PolarModel.debugIdentification("Polar Sense 99AABBCC"),
        )
        assertEquals(
            "Polar (unrecognised model) identified — PMD unknown (probe); HRV via standard R-R",
            PolarModel.debugIdentification("Polar Grit X"),
        )
        assertNull(PolarModel.debugIdentification("Wahoo TICKR"))
        assertNull(PolarModel.debugIdentification(null))
    }
}
