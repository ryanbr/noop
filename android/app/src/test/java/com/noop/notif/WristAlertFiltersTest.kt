package com.noop.notif

import com.noop.notif.WristAlertFilters.Snapshot
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the wrist-alert buzz filters ([WristAlertFilters]) — the buzz-specificity rule:
 * progress notifications (download/upload bars, timer countdowns) and persistent non-dismissable
 * rows must never buzz the strap, while ordinary alert notifications stay buzzable.
 *
 * Mirrors the plain-JUnit policy style of [VoipCallClassifierTest]: the rule is tested on the
 * framework [Snapshot] the listener extracts from each posted notification, so no android.jar
 * classes are constructed on the JVM.
 */
class WristAlertFiltersTest {

    private val alert = Snapshot(
        progress = 0, progressMax = 0, indeterminate = false, template = null, noClear = false,
    )

    @Test
    fun plainAlertNotificationIsNeitherProgressNorPersistent() {
        assertFalse(alert.isProgress())
        assertFalse(alert.isPersistent())
    }

    @Test
    fun frameworkDefaultProgressExtrasOnPlainNotificationsAreNotProgress() {
        // REGRESSION: the framework seeds android.progress=0, android.progressMax=0 and
        // android.progressIndeterminate=false into the extras of ORDINARY text alerts (device
        // dumps show all three keys present), so key PRESENCE must never be the gate — a
        // containsKey-based filter silenced every buzz and broke wrist alerts app-wide.
        val plain = alert.copy(template = "android.app.Notification${'$'}Template")
        assertFalse(plain.isProgress())
    }

    @Test
    fun determinateProgressBarIsFilteredAsProgress() {
        assertTrue(alert.copy(progress = 45, progressMax = 100).isProgress())
        // A bar at zero of a known max is still a visible bar (upload just started).
        assertTrue(alert.copy(progress = 0, progressMax = 100).isProgress())
    }

    @Test
    fun indeterminateSpinnerIsFilteredAsProgress() {
        // setProgress(max, 0, true): the flag alone marks the spinner, values stay zero.
        assertTrue(alert.copy(indeterminate = true).isProgress())
    }

    @Test
    fun progressStyleTemplateIsFilteredAsProgress() {
        assertTrue(alert.copy(template = WristAlertFilters.PROGRESS_TEMPLATE).isProgress())
    }

    @Test
    fun unrelatedTemplateIsNotProgress() {
        val bigText = """android.app.Notification${'$'}BigTextTemplate"""
        assertFalse(alert.copy(template = bigText).isProgress())
    }

    @Test
    fun noClearFlagIsFilteredAsPersistentOnly() {
        val persistent = alert.copy(noClear = true)
        assertTrue(persistent.isPersistent())
        assertFalse(persistent.isProgress())
    }

    @Test
    fun progressAndPersistentCombineOnStateReadouts() {
        // A foreground-service/timer row carries BOTH the countdown bar and NO_CLEAR: both filters
        // claim it, so neither buzz path fires.
        val timer = Snapshot(
            progress = 12,
            progressMax = 300,
            indeterminate = false,
            template = WristAlertFilters.PROGRESS_TEMPLATE,
            noClear = true,
        )
        assertTrue(timer.isProgress())
        assertTrue(timer.isPersistent())
    }
}
