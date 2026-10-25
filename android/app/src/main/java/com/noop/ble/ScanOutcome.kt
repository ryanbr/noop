package com.noop.ble

/** Terminal scan readouts, including scans requested while a healthy link is already connected. */
internal object ScanOutcome {
    fun timeout(state: LiveState): LiveState = state.copy(
        scanning = false,
        statusNote = if (state.connected) "Search finished. Keeping the current strap connection."
        else "No strap found. Check it's charged and on your wrist, and that the " +
            "official WHOOP app isn't connected to it (a strap will only pair with one app " +
            "at a time). Then tap Connect again.",
    )

    fun failed(state: LiveState, failure: String): LiveState = state.copy(
        scanning = false,
        statusNote = "Scan failed: $failure. Try Connect again.",
    )
}
