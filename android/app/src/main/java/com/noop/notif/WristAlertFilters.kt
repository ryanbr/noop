package com.noop.notif

import android.app.Notification

/**
 * Noise filters for wrist-alert buzz specificity: progress notifications and persistent
 * non-dismissable rows are app state readouts (download bars, uploads, timer countdowns, always-on
 * launcher/service rows), not user-facing alerts — the listener must never buzz the strap for them.
 * Mirrors [VoipCallClassifier]: [of] extracts framework state from the posted [Notification] and the
 * policy is a pure function of that snapshot, so the rule is testable without a device.
 */
internal object WristAlertFilters {

    // Notification.setProgress() stores its state in the notification extras under these framework
    // keys (there is no public SDK constant for them — they are the documented extras keys).
    const val EXTRA_PROGRESS = "android.progress"
    const val EXTRA_PROGRESS_MAX = "android.progressMax"
    const val EXTRA_PROGRESS_INDETERMINATE = "android.progressIndeterminate"

    // A ProgressStyle notification declares this template in extras: the row inflates a ProgressBar.
    const val PROGRESS_TEMPLATE = "android.widget.ProgressBar"

    // KEY PRESENCE IS NOT THE SIGNAL — never gate on extras.containsKey(EXTRA_PROGRESS). The framework
    // seeds android.progress=0, android.progressMax=0 and android.progressIndeterminate=false into the
    // extras of ORDINARY text alerts (real device dumps show all three keys on plain notifications),
    // so a containsKey gate silences every post. Only the VALUES, the ProgressStyle template, or
    // NO_CLEAR distinguish a state readout from an alert. Pinned by WristAlertFiltersTest.

    /** Framework snapshot of one posted notification, decoupled from android.jar for the tests. */
    data class Snapshot(
        val progress: Int,
        val progressMax: Int,
        val indeterminate: Boolean,
        val template: String?,
        val noClear: Boolean,
    )

    fun of(n: Notification): Snapshot {
        val ex = n.extras
        return Snapshot(
            progress = ex?.getInt(EXTRA_PROGRESS, 0) ?: 0,
            progressMax = ex?.getInt(EXTRA_PROGRESS_MAX, 0) ?: 0,
            indeterminate = ex?.getBoolean(EXTRA_PROGRESS_INDETERMINATE, false) == true,
            template = ex?.getString(Notification.EXTRA_TEMPLATE),
            noClear = (n.flags and Notification.FLAG_NO_CLEAR) != 0,
        )
    }

    /** True when the notification shows a progress bar — determinate, indeterminate, or styled. */
    fun isProgressNotification(n: Notification): Boolean = of(n).isProgress()

    /** True when the user cannot swipe the notification away ([Notification.FLAG_NO_CLEAR]). */
    fun isPersistentNotification(n: Notification): Boolean = of(n).noClear
}

// The policy itself, as top-level extensions so tests (and callers) apply it directly to a Snapshot.
// A bar only exists when its VALUES say so: indeterminate spinners set the flag, determinate bars
// carry progress/progressMax above zero; the framework's 0/false defaults on plain alerts do not.
internal fun WristAlertFilters.Snapshot.isProgress(): Boolean =
    indeterminate || progress > 0 || progressMax > 0 || template == WristAlertFilters.PROGRESS_TEMPLATE

internal fun WristAlertFilters.Snapshot.isPersistent(): Boolean = noClear
