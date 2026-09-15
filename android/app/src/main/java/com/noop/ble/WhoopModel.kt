package com.noop.ble

import com.noop.protocol.DeviceFamily
import java.util.UUID

/**
 * Which strap the user is pairing. They pick this before scanning so we look for
 * exactly one device family instead of guessing — a WHOOP 4.0 scan no longer
 * waits forever on a WHOOP 5/MG wrist, and vice versa.
 *
 * This is the user-facing choice; it is deliberately separate from the
 * protocol-layer DeviceFamily (which carries CRC/characteristic detail).
 */
enum class WhoopModel(val displayName: String, val service: UUID) {
    WHOOP4("WHOOP 4.0", WhoopBleClient.WHOOP4_SERVICE),
    WHOOP5_MG("WHOOP 5.0 / MG", WhoopBleClient.WHOOP5_SERVICE);

    /**
     * The OTHER WHOOP family to try when a service-filtered scan for this model finds nothing. A
     * stale/missing persisted preference (after an update or restore) can point the scan at the wrong
     * service so it runs forever with the strap right there; rotating to the other family — and
     * persisting whichever one actually advertises — recovers reconnect automatically. Mirrors macOS
     * `WhoopModel.fallbackScanModel`. (PR#195)
     */
    val fallbackScanModel: WhoopModel
        get() = when (this) {
            WHOOP4 -> WHOOP5_MG
            WHOOP5_MG -> WHOOP4
        }
}

/**
 * The picker model backed by service-discovery evidence from this connection.
 *
 * [family] is deliberately ignored until [familyEstablished] is true. The BLE client keeps its last
 * discovered family across a disconnect (and starts with WHOOP4), so reading the family alone would
 * turn either a default or the previous link into a claim about the current strap. (#2068)
 */
internal fun establishedWhoopModel(
    familyEstablished: Boolean,
    family: DeviceFamily,
): WhoopModel? {
    if (!familyEstablished) return null
    return when (family) {
        DeviceFamily.WHOOP4 -> WhoopModel.WHOOP4
        DeviceFamily.WHOOP5 -> WhoopModel.WHOOP5_MG
    }
}
