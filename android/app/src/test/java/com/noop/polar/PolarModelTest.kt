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
}
