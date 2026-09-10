package com.noop.ble

import com.noop.data.PairedDeviceRow

/**
 * Which registry device a live BLE link's samples belong to (#1881).
 *
 * Split out of [WhoopBleClient] because it is the whole of the decision and none of the Bluetooth: BLE
 * behaviour cannot be tested in CI, but *this* can, and it is the part that silently files rows under the
 * wrong device when it is wrong. Swift twin: `WhoopStore.SourceIdentity`.
 *
 * The bug it exists to prevent: the client held one `deviceId` meaning "the active device" and reused it as
 * "the device these bytes came from". Those were the same thing only while every registered device was a
 * WHOOP. Once a ring could be active, a WHOOP connection filed its samples — including `stepSample` and
 * `gravitySample`, which only a strap can produce — under the ring's id.
 */
object SourceIdentity {

    /**
     * The device id this connection's samples should be stored under, or null to leave the current id alone.
     *
     * Conservative by construction. It returns an id ONLY when a registry row is both matched by address and
     * a WHOOP, so every uncertain case keeps today's behaviour rather than guessing:
     *  - [address] null/blank, or no row carries it -> null. This is the legacy single-WHOOP row before it
     *    has adopted a `peripheralId`; the coordinator adopts one on this same connect, so the next resolves.
     *  - the matched row is not a WHOOP -> null. Nothing else should arrive on the WHOOP callback, and if it
     *    does, re-pointing the strap's id at it would be the very bug this prevents.
     *  - the matched row is already the current id -> null, so there is no write on the common path.
     *
     * Matching is case-insensitive because the two platforms disagree about case (an Apple UUID string vs an
     * Android MAC), and neither is guaranteed by the OS.
     */
    fun resolve(address: String?, rows: List<PairedDeviceRow>, currentId: String): String? {
        if (address.isNullOrBlank()) return null
        val row = rows.firstOrNull { it.peripheralId?.equals(address, ignoreCase = true) == true }
            ?: return null
        if (!isWhoop(row) || row.id == currentId) return null
        return row.id
    }

    /**
     * A device is a WHOOP when it is the seeded legacy row or its brand says so. Kept here beside the
     * resolver rather than reaching into [SourceCoordinator], so this file has no dependency to test
     * around. Byte-identical to `SourceCoordinator.isWhoop` on both platforms.
     */
    fun isWhoop(device: PairedDeviceRow): Boolean =
        device.id == WhoopBleClient.DEFAULT_DEVICE_ID || device.brand.equals("WHOOP", ignoreCase = true)
}
