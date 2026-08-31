package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The line that says which scores can exist at all for the strap actually being worn.
 *
 * A 5/MG that never completes its handshake streams live HR and R-R over the standard characteristic and
 * nothing else — motion and steps ride the proprietary offload. Without motion the sleep stager has no
 * HR-only fallback and the workout detector returns before it looks at heart rate, so Rest reads
 * "No data" and no bout is ever found. A report showed all of those absences with nothing tying them to
 * their single cause, leaving a reader to infer the pipeline. This states it.
 */
class StrapProvidesLineTest {

    @Test
    fun `an unbonded 5MG streams heart data and nothing else`() {
        assertEquals(
            "Provides:    HR yes · R-R yes · motion NO · steps NO (last 48h)",
            AndroidDiagnostics.strapProvidesLine(hr = true, rr = true, motion = false, steps = false),
        )
    }

    @Test
    fun `a fully synced strap provides all four`() {
        assertEquals(
            "Provides:    HR yes · R-R yes · motion yes · steps yes (last 48h)",
            AndroidDiagnostics.strapProvidesLine(hr = true, rr = true, motion = true, steps = true),
        )
    }

    /**
     * NO is capitalised and yes is not, deliberately: the absences are what the line exists to surface,
     * and a reader scanning a report should catch them without reading the labels.
     */
    @Test
    fun `absence is the half that stands out`() {
        val line = AndroidDiagnostics.strapProvidesLine(hr = true, rr = false, motion = false, steps = true)
        assertEquals(2, Regex("NO").findAll(line).count())
        assertEquals("Provides:    HR yes · R-R NO · motion NO · steps yes (last 48h)", line)
    }
}
