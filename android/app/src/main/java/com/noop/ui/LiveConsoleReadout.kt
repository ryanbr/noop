package com.noop.ui

import com.noop.ble.SourceIdentity
import com.noop.data.PairedDeviceRow

/**
 * What the Live Console should read out, given WHICH device is active.
 *
 * [com.noop.ble.LiveState] is one object that every live source writes into, so "is this field
 * populated" is not the same question as "does this field describe the device on screen". A bonded
 * WHOOP sitting beside a streaming Oura ring leaves every WHOOP-only field truthful-looking while the
 * console is naming the ring, which is #2075: the ring's own charge was decoded and held, and the
 * strap's stale one was what got drawn under the ring's name.
 *
 * Pure twin of Swift `LiveConsoleReadout`, so the two consoles cannot answer it differently.
 */
object LiveConsoleReadout {

    /**
     * Whether the ACTIVE registry device is a WHOOP.
     *
     * Defaults to true when the registry has not opened or the active row is not resolvable, which is
     * the WHOOP-first tone the console's device name already takes. Delegates to [SourceIdentity], the
     * one place that answers this, rather than adding a second spelling of it: that file's own note is
     * that two spellings which could disagree is how a strap's samples end up filed under a ring.
     *
     * That default is load-bearing rather than cosmetic. A WHOOP adopting its serial identity re-keys the
     * active row mid-session (#1303) without going through the ViewModel's setActive, so the id being
     * asked about can briefly name a row that no longer exists; answering "WHOOP" there keeps a working
     * strap's console intact, which is right because the device that just re-keyed IS a WHOOP. It also
     * means the verdict is exactly as fresh as the device NAME beside it, since both come from the same
     * registry read: they can go stale together, but they can never disagree, and disagreeing is the bug.
     */
    fun activeIsWhoop(devices: List<PairedDeviceRow>, activeId: String?): Boolean {
        if (activeId == null) return true
        val active = devices.firstOrNull { it.id == activeId } ?: return true
        return SourceIdentity.isWhoop(active)
    }

    /**
     * The charge to show for the ACTIVE device, or null to show nothing.
     *
     * A non-WHOOP active device never falls back to the WHOOP's charge. Showing nothing is the honest
     * answer when a ring has not reported yet; showing the strap's number would be a confident lie, and
     * it is the exact shape of the reported bug.
     */
    fun batteryPercent(activeIsWhoop: Boolean, whoopPct: Double?, ringPct: Int?): Int? =
        // ROUNDS, and deliberately. The surfaces this replaced disagreed: Devices and the widget rounded,
        // the Live Console truncated, so a strap on 72.6% read 73 on one screen and 72 on another. One
        // seam has to pick, and for a percentage rounding is the accurate one. Math.round is half-up and
        // Swift's .rounded() is half-away-from-zero, identical over the 0..100 this sees.
        if (activeIsWhoop) whoopPct?.let { Math.round(it).toInt() } else ringPct
}
