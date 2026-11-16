package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class ThemePresetTest {

    @Test
    fun freshInstallDefaults_useDarkWhoopInspiredPalette() {
        assertEquals(AppearanceMode.DARK, AppearancePrefs.mode)
        assertEquals(ChartStyle.CLASSIC, ChartStylePrefs.style)
        assertEquals(AccentColor.WHOOP_BLUE, AccentPrefs.color)
        assertEquals(
            ThemePreset.CLASSIC,
            ThemePreset.matching(
                accent = AccentColor.WHOOP_BLUE,
                chart = ChartStyle.CLASSIC,
                backdrop = false,
                cardOpacity = 100,
            ),
        )
    }
}
