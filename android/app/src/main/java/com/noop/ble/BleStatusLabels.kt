package com.noop.ble

/*
 * BleStatusLabels.kt - names for the BLE integers the strap log used to print bare.
 *
 * The strap log is the only evidence a remote report carries, and a bare number in it is evidence
 * nobody can read. `gattStatusLabel` already established the discipline for GATT operation statuses:
 * name the codes that answer a question, leave everything else as a bare number rather than guessing,
 * because a confidently wrong name in a failure line is worse than no name at all. These extend the
 * same treatment to the two other integer spaces the log emits.
 *
 * Deliberately three separate functions rather than one: a scan error, a GATT operation status and a
 * disconnect reason are DIFFERENT number spaces that happen to share the Int type. Forcing them
 * through one table is exactly how a code acquires a name from the wrong space.
 *
 * Pure formatters: no IO, no state, no PII (these are protocol integers), unit-tested without a radio.
 * Android-only. CoreBluetooth reports scan and disconnect problems as central-manager state changes and
 * NSErrors, not as status integers; the Apple side tokenises those via `BLEManager.bleErrorToken`.
 */

/**
 * A `ScanCallback.SCAN_FAILED_*` code, named.
 *
 * Worth naming even though a scan failure is rare, because one of these codes is both common and
 * entirely self-inflicted: Android permits an app 5 scan starts per 30 seconds and answers the sixth
 * with [SCAN_FAILED_SCANNING_TOO_FREQUENTLY], after which scanning simply stops working for the rest of
 * the window. That is the leading cause of "it will not find my strap", it is fixable once seen, and
 * the log reported it as the character "6".
 */
internal fun scanFailureLabel(code: Int): String = when (code) {
    1 -> "ALREADY_STARTED(1)"
    2 -> "APPLICATION_REGISTRATION_FAILED(2) - the BLE stack rejected our scanner; a Bluetooth restart usually clears it"
    3 -> "INTERNAL_ERROR(3)"
    4 -> "FEATURE_UNSUPPORTED(4) - this device's radio cannot do the scan we asked for"
    5 -> "OUT_OF_HARDWARE_RESOURCES(5) - too many scanners open across all apps"
    SCAN_FAILED_SCANNING_TOO_FREQUENTLY ->
        "SCANNING_TOO_FREQUENTLY(6) - Android throttles an app to 5 scan starts per 30s and this one was refused; scanning stays dead until the window rolls"
    else -> "$code"
}

/** The throttle code, named because callers reason about it and not just log it. */
internal const val SCAN_FAILED_SCANNING_TOO_FREQUENTLY = 6

/**
 * A DISCONNECT status, named.
 *
 * A different space from [gattStatusLabel]'s: these arrive as HCI disconnect reasons surfaced through
 * the same `status` Int, so 8 here means "link supervision timeout" and not the GATT code 8. That
 * overlap is the whole reason this is separate rather than another branch of one shared table.
 *
 * Only the reasons that are unambiguous and long-established are named. 133 stays described as the
 * catch-all it is rather than being given a specific cause it does not have.
 */
internal fun disconnectStatusLabel(status: Int): String = when (status) {
    0 -> "status=0 (clean)"
    8 -> "status=8 (link supervision timeout - the strap went out of range or stopped responding)"
    19 -> "status=19 (the STRAP terminated the connection)"
    22 -> "status=22 (this phone terminated the connection)"
    62 -> "status=62 (connection failed to establish)"
    133 -> "status=133 (GATT_ERROR, Android's catch-all - no specific cause reported)"
    else -> "status=$status"
}
