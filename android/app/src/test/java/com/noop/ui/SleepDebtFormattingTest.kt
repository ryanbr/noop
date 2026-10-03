package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class SleepDebtFormattingTest {

    /** [debtCaption] resolves through app resources; read the English value the JVM can reach. */
    private fun caption(debt: Double?): String = EnglishResources.text(debtCaptionRes(debt))


    @Test
    fun nightDetailUsesTenMinuteDebtBoundary() {
        assertEquals("On target", caption(9.9))
        assertEquals(Palette.statusPositive, debtColor(9.9))

        assertEquals("Below need", caption(10.0))
        assertEquals(Palette.statusWarning, debtColor(10.0))
    }

    @Test
    fun importedDebtAboveBoundaryRemainsDebt() {
        assertEquals("Below need", caption(12.5))
        assertEquals(Palette.statusWarning, debtColor(12.5))
    }
}
