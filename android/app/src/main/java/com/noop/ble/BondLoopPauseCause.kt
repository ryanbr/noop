package com.noop.ble

/**
 * Mirror of the Swift `BondLoopPauseCause` (Strand/BLE/BLEManager.swift), same phrases.
 *
 * Why auto-reconnect is paused, so the paused-disconnect line names what was observed rather than one
 * cause for all of them. The pause trips on a refused bond (#747), on a pairing that never finishes
 * (#971/#982) or on a link that drops within seconds of pairing (#617); only the first is a refusal.
 */
sealed class BondLoopPauseCause {
    object RefusedBond : BondLoopPauseCause()
    object PairingNeverFinished : BondLoopPauseCause()
    data class DroppedAfterPairing(val cycles: Int) : BondLoopPauseCause()

    /** The parenthetical of the paused-disconnect line. */
    val pausedReason: String
        get() = when (this) {
            RefusedBond -> "strap keeps refusing to pair"
            PairingNeverFinished -> "pairing never finished"
            is DroppedAfterPairing -> "the link dropped within seconds of pairing $cycles times in a row"
        }
}
