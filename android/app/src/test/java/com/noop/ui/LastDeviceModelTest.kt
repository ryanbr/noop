package com.noop.ui

import com.noop.ble.WhoopModel
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Which model gets remembered for a strap, and why it cannot be the picker's value.
 *
 * `autoReconnectOnLaunch` reads the stored pair straight back into the picker, so persisting the
 * picker makes a wrong model self-perpetuating: restore stale, connect, store stale again. A field log
 * showed it, "Auto-reconnecting to your saved WHOOP 4.0" on an install whose active device is a 5.0 MG.
 * The pair also feeds family selection, so this is not only a label.
 */
class LastDeviceModelTest {

    @Test fun detectionOverridesAStalePicker() {
        // The reported shape: the picker still says 4.0 from an older strap, the link is a 5/MG.
        assertEquals(
            WhoopModel.WHOOP5_MG,
            lastDeviceModelFor(detectedWhoop5 = true, selected = WhoopModel.WHOOP4),
        )
    }

    @Test fun detectionAgreeingWithThePickerChangesNothing() {
        assertEquals(
            WhoopModel.WHOOP5_MG,
            lastDeviceModelFor(detectedWhoop5 = true, selected = WhoopModel.WHOOP5_MG),
        )
    }

    @Test fun noDetectionKeepsTodaysBehaviourExactly() {
        // Absence is not evidence: a 5 whose service was not found looks like a 4.0 from here, so a
        // miss must not relabel a genuine 4.0 in the other direction.
        for (picked in WhoopModel.entries) {
            assertEquals(
                picked,
                lastDeviceModelFor(detectedWhoop5 = false, selected = picked),
            )
        }
    }
}
