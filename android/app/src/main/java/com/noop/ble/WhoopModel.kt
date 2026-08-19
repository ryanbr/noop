package com.noop.ble

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

    /**
     * The UUIDs that may appear in a strap's ADVERTISEMENT, which is not the same set as [service].
     *
     * A 128-bit UUID often does not fit the 31-byte advertising payload, so a peripheral may advertise the
     * 16-bit SIG member form instead, which expands to `0000FD4B-0000-1000-8000-00805F9B34FB` and does NOT
     * equal the vendor UUID `fd4b0001-...`. A scan filtered only on the vendor UUID would then never see
     * the strap, reading to the owner as "NOOP cannot find my 5.0" rather than as a discovery bug.
     *
     * Advertisement-only, deliberately: after connecting the strap exposes the real 128-bit service in
     * GATT, so service discovery must keep using [service] alone. Widening that would be wrong.
     *
     * UNCONFIRMED against hardware - a fact re-derived from OpenStrap/edge#255 (Dart; no code taken),
     * which ships the same widening while its own test plan still asks for the capture that would settle
     * it. Straps do pair today, so the vendor UUID demonstrably works at least often; this only removes a
     * way for discovery to fail silently, and the scan log records which form actually matched.
     */
    val advertisedScanUuids: List<UUID>
        get() = when (this) {
            WHOOP4 -> listOf(service)
            WHOOP5_MG -> listOf(service, UUID.fromString("0000FD4B-0000-1000-8000-00805F9B34FB"))
        }
}
