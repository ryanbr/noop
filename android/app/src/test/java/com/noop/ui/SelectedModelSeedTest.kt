package com.noop.ui

import com.noop.ble.WhoopModel
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The strap family the picker starts on.
 *
 * `_selectedModel` used to be a hardcoded `WhoopModel.WHOOP4` that nothing ever corrected from
 * storage, while `autoReconnectOnLaunch` re-seeded it from the family half of the saved last-device
 * pair. That pair only records whatever the picker held when a strap last bonded, so a wrong value
 * survived every restart and re-stored itself, and an install whose only strap is a 5/MG could sit on
 * WHOOP 4.0 indefinitely.
 *
 * That is not cosmetic: the value feeds `ble.connect(...)`, which starts a SERVICE-FILTERED scan, so a
 * wrong family points every scan-based reconnect at the wrong service and burns the fallback delay
 * before rotating, with the strap in range the whole time.
 *
 * These pin the precedence that fixes it, and the fallback that keeps older installs working.
 */
class SelectedModelSeedTest {
    @Test
    fun recordedFamilyWinsOverTheRememberedPair() {
        // What discovery saw on the link beats what the picker happened to hold at last bond — this is
        // the loop that stranded a 5/MG-only install on WHOOP 4.0.
        assertEquals(
            WhoopModel.WHOOP5_MG,
            resolveSelectedModel(recorded = WhoopModel.WHOOP5_MG, remembered = WhoopModel.WHOOP4),
        )
    }

    @Test
    fun recordedFamilyWinsInTheOtherDirectionToo() {
        // Symmetry matters: the rule must not be "prefer 5/MG", or a user moving back to a 4.0 gets
        // the same wrong-service scan the other way round.
        assertEquals(
            WhoopModel.WHOOP4,
            resolveSelectedModel(recorded = WhoopModel.WHOOP4, remembered = WhoopModel.WHOOP5_MG),
        )
    }

    @Test
    fun rememberedPairStillCarriesInstallsThatPredateTheRecordedFamily() {
        // An install that bonded before the family was ever recorded has nothing better. It must keep
        // its remembered family rather than being silently reset to WHOOP4.
        assertEquals(
            WhoopModel.WHOOP5_MG,
            resolveSelectedModel(recorded = null, remembered = WhoopModel.WHOOP5_MG),
        )
    }

    @Test
    fun freshInstallFallsBackToWhoop4() {
        // Nothing known at all: unchanged from the old hardcoded default.
        assertEquals(WhoopModel.WHOOP4, resolveSelectedModel(recorded = null, remembered = null))
    }
}
