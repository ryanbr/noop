package com.noop.ui

import com.noop.R
import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * #1617: the Blood Oxygen empty state must not promise a reading the strap cannot produce.
 *
 * A WHOOP 4.0 never produces an SpO2 candidate — the `@82` decode is gated to `hist_version == 18`,
 * which is a 5/MG layout — and `spo2Pct` is only ever written by an import. "Not enough history yet"
 * is therefore a countdown that never completes, and it sends the user to wear the strap longer, which
 * is the one thing that cannot help.
 */
class Spo2EmptyStateTest {

    private val notEnoughHistory = R.string.l10n_health_screen_not_enough_history_yet_0e2f93b6

    /** The reported case: 4.0, Blood Oxygen, nothing to show and nothing coming. */
    @Test fun whoop4BloodOxygenSaysTheStrapDoesNotReportIt() {
        val s = spo2EmptyState(key = "spo2", family = DeviceFamily.WHOOP4, candidateDisplayOn = false)
        assertEquals(R.string.l10n_health_screen_your_whoop_4_0_does_not_5941a06e, s.titleRes)
        assertEquals(R.string.l10n_health_screen_blood_oxygen_is_not_something_a_c39d2144, s.bodyRes)
        assertNotEquals("a 4.0 must never be told to wait", notEnoughHistory, s.titleRes)
    }

    /** The toggle state must not change that: waiting still cannot help a 4.0. */
    @Test fun whoop4IsUnaffectedByTheCandidateToggle() {
        val off = spo2EmptyState("spo2", family = DeviceFamily.WHOOP4, candidateDisplayOn = false)
        val on = spo2EmptyState("spo2", family = DeviceFamily.WHOOP4, candidateDisplayOn = true)
        assertEquals(off, on)
    }

    /**
     * The bug this nearly shipped with. A null family means a positively non-WHOOP brand (an Oura ring,
     * which DOES produce SpO2 via the 0x6F ceiling transform) or a registry row not yet loaded. Either
     * way, claiming "your WHOOP 4.0 does not report blood oxygen" would be plainly wrong.
     */
    @Test fun aNonWhoopOrUnresolvedDeviceIsNeverToldItIsAWhoop4() {
        for (on in listOf(true, false)) {
            val s = spo2EmptyState("spo2", family = null, candidateDisplayOn = on)
            assertEquals(notEnoughHistory, s.titleRes)
            assertNotEquals(
                "a non-WHOOP device must never see the 4.0 copy",
                R.string.l10n_health_screen_your_whoop_4_0_does_not_5941a06e,
                s.titleRes,
            )
        }
    }

    /** 5/MG with the estimate off: actionable, so name the switch rather than implying more nights. */
    @Test fun whoop5WithTheEstimateOffPointsAtTheToggle() {
        val s = spo2EmptyState("spo2", family = DeviceFamily.WHOOP5, candidateDisplayOn = false)
        assertEquals(R.string.l10n_health_screen_the_blood_oxygen_estimate_is_turned_4c403ab2, s.titleRes)
        assertEquals(R.string.l10n_health_screen_your_strap_reports_a_blood_oxygen_349fe34a, s.bodyRes)
    }

    /** 5/MG with it on genuinely just needs nights, so the default copy is correct there. */
    @Test fun whoop5WithTheEstimateOnKeepsTheDefaultCopy() {
        val s = spo2EmptyState("spo2", family = DeviceFamily.WHOOP5, candidateDisplayOn = true)
        assertEquals(notEnoughHistory, s.titleRes)
    }

    /** Every other vital is untouched on both strap generations — this is a Blood Oxygen carve-out. */
    @Test fun otherVitalsKeepTheDefaultOnEitherStrap() {
        for (key in listOf("hrv", "resting_hr", "skin_temp", "resp_rate", "fitness_age")) {
            for (w5 in listOf(true, false)) {
                for (on in listOf(true, false)) {
                    assertEquals(
                        "$key must keep the default empty state",
                        notEnoughHistory,
                        spo2EmptyState(key, family = if (w5) DeviceFamily.WHOOP5 else DeviceFamily.WHOOP4, candidateDisplayOn = on).titleRes,
                    )
                }
            }
        }
    }
}
