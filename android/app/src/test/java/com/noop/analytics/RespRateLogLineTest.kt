package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the resp diagnostic's nil-reason (#1331). Swift twin: `RespRateLogLineTests`.
 *
 * The line exists because "rpm=nil" alone cost a cross-subsystem investigation to explain: on a WHOOP
 * 4.0 the RSA beat-accuracy gate empties the card on nearly every night, and nothing said so.
 */
class RespRateLogLineTest {

    @Test
    fun `a real rate is unchanged and carries no reason`() {
        assertEquals(
            "resp day=2026-08-11 rpm=16.0",
            IntelligenceEngine.respRateLogLine("2026-08-11", 16.0, 0.52, "crossSecondOverCount"),
        )
    }

    @Test
    fun `nil below the gate names the gate that refused it`() {
        assertEquals(
            "resp day=2026-08-26 rpm=nil beatAccurate=0.45<0.50 rrIntegrity=crossSecondOverCount" +
                " — RSA gate refused the R-R",
            IntelligenceEngine.respRateLogLine("2026-08-26", null, 0.45, "crossSecondOverCount"),
        )
    }

    @Test
    fun `nil above the gate says the cause is elsewhere rather than guessing`() {
        // The estimator has four other NaN exits (beats, span, grid, window). Naming the gate here would
        // be wrong, so the line says only what it knows.
        assertEquals(
            "resp day=2026-08-26 rpm=nil beatAccurate=0.83>=0.50 rrIntegrity=plausible" +
                " — gate passed, cause is elsewhere",
            IntelligenceEngine.respRateLogLine("2026-08-26", null, 0.83, "plausible"),
        )
    }

    @Test
    fun `a night with no HRV block reads exactly as it always did`() {
        assertEquals("resp day=2026-08-26 rpm=nil", IntelligenceEngine.respRateLogLine("2026-08-26", null))
    }

    @Test
    fun `the boundary itself passes`() {
        // 0.50 is >= the gate, so it must NOT read as refused — an off-by-one here would blame the gate
        // for a night it actually admitted.
        val line = IntelligenceEngine.respRateLogLine("2026-08-26", null, 0.50, "plausible")
        assertEquals(
            "resp day=2026-08-26 rpm=nil beatAccurate=0.50>=0.50 rrIntegrity=plausible" +
                " — gate passed, cause is elsewhere",
            line,
        )
    }

    @Test
    fun `an unknown integrity is labelled rather than blank`() {
        assertEquals(
            "resp day=2026-08-26 rpm=nil beatAccurate=0.45<0.50 rrIntegrity=unknown" +
                " — RSA gate refused the R-R",
            IntelligenceEngine.respRateLogLine("2026-08-26", null, 0.45, null),
        )
    }

    @Test
    fun `a NaN fraction reads as passed, mirroring the gate's own NaN convention`() {
        // beatValuesAreTrustworthy is written as !(f < MIN) precisely so NaN lands on TRUE — "not
        // measured" must not be silently refused. This line uses the same `<` for the same reason.
        // Rewriting it as `f >= MIN` would read identically for every real number and flip NaN to
        // "refused", diverging from the gate it reports on.
        assertEquals(
            "resp day=2026-08-26 rpm=nil beatAccurate=NaN>=0.50 rrIntegrity=plausible" +
                " — gate passed, cause is elsewhere",
            IntelligenceEngine.respRateLogLine("2026-08-26", null, Double.NaN, "plausible"),
        )
    }
}
