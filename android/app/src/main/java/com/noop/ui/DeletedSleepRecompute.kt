package com.noop.ui

import kotlinx.coroutines.CancellationException

/**
 * Reopen a deleted sleep window before requesting the normal recent scan (Refs #515).
 *
 * Success means only that marker removal completed: the scan may not cover an old night,
 * may lack raw samples, or may fail. Cancellation must stop the action at either stage.
 */
internal suspend fun reopenDeletedSleepWindow(
    clearMarker: suspend () -> Unit,
    scanRecent: suspend () -> Unit,
): Boolean {
    val cleared = runCatching { clearMarker() }
        .onFailure { if (it is CancellationException) throw it }
        .isSuccess
    if (!cleared) return false
    runCatching { scanRecent() }
        .onFailure { if (it is CancellationException) throw it }
    return true
}
