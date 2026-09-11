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
            "Provides:    HR yes · R-R yes · motion NO · steps NO (my-whoop, last 48h)",
            AndroidDiagnostics.strapProvidesLine(
                hr = true, rr = true, motion = false, steps = false, deviceId = "my-whoop",
            ),
        )
    }

    @Test
    fun `a fully synced strap provides all four`() {
        assertEquals(
            "Provides:    HR yes · R-R yes · motion yes · steps yes (my-whoop, last 48h)",
            AndroidDiagnostics.strapProvidesLine(
                hr = true, rr = true, motion = true, steps = true, deviceId = "my-whoop",
            ),
        )
    }

    /**
     * NO is capitalised and yes is not, deliberately: the absences are what the line exists to surface,
     * and a reader scanning a report should catch them without reading the labels.
     */
    @Test
    fun `absence is the half that stands out`() {
        val line = AndroidDiagnostics.strapProvidesLine(
            hr = true, rr = false, motion = false, steps = true, deviceId = "my-whoop",
        )
        assertEquals(2, Regex("NO").findAll(line).count())
        assertEquals("Provides:    HR yes · R-R NO · motion NO · steps yes (my-whoop, last 48h)", line)
    }

    /**
     * #2012: the line asks ONE id, the active one, while every scorer reads the union of the active,
     * canonical and computed ids. On a re-added strap or an archived spine those disagree, and the line
     * then reads as "this install has no heart rate" when it means "the active strap id delivered none".
     * Naming the id is what stops a reader drawing the first conclusion, which cost real triage time.
     */
    @Test
    fun `the line names whose data it is describing`() {
        val line = AndroidDiagnostics.strapProvidesLine(
            hr = false, rr = false, motion = false, steps = false, deviceId = "whoop-5A0FAKE",
        )
        assertEquals("Provides:    HR NO · R-R NO · motion NO · steps NO (whoop-5A0FAKE, last 48h)", line)
    }

    /** The funnel's heading says "latest night"; when it falls back it has to say so. */
    @Test
    fun `the funnel note fires only when an older night was analysed`() {
        assertEquals("", AndroidDiagnostics.funnelFallbackNote("2026-09-09", "2026-09-09"))
        assertEquals(
            " (NOT the latest night: 2026-09-09 carried no skin temperature)",
            AndroidDiagnostics.funnelFallbackNote("2026-09-05", "2026-09-09"),
        )
    }
}
