package com.noop.ui

/**
 * What the Today header's battery ring can honestly show for the ACTIVE device. Pure, so the truth table
 * pins with no strap and no BLE. Twin of iOS `LiquidTodayView.StrapBatteryDisplay.resolve`, minus the
 * charging bit the Android ring never drew.
 */
object HeaderBatteryDisplay {
    sealed class State {
        /** The active device is neither the strap nor a ring that has reported its charge this link, so
         *  the control has nothing to say and is not drawn. Distinct from [Offline], which asserts a strap
         *  that IS active is not connected — collapsing the two told a wearer with a streaming ring that
         *  their strap was not connected (#2208 / #2216). */
        data object NotActiveDevice : State()
        /** The strap is active with no link — say nothing about charge. A stale % is worse than no %. */
        data object Offline : State()
        /** The strap is linked, but no charge reading has landed yet. */
        data object Pending : State()
        /** A reading from the current link. [isRing] says whose: the ring's own charge under an active
         *  ring, the strap's under an active strap — the label names the device the number belongs to. */
        data class Charge(val pct: Double, val isRing: Boolean) : State()
    }

    /**
     * #2208: `activeIsWhoop` decides whose number is shown. `connected` alone was never enough: it is true
     * the moment ANY source streams and the strap's `batteryPct` is never cleared, so under an active
     * ring both halves of the old gate passed and Today drew the strap's charge.
     *
     * A ring reports its OWN charge into [ringPct] (`SourceCoordinator.ouraBatteryPct`), cleared with the
     * source, so under a non-WHOOP active device a non-null [ringPct] is a reading from the ring that is
     * live right now and is drawn as such; null (no ring, or none has reported yet) keeps the control off
     * the header — a generic HR strap or a machine never writes it. Same resolution
     * [LiveConsoleReadout.batteryPercent] applies.
     */
    fun resolve(activeIsWhoop: Boolean, connected: Boolean, strapPct: Double?, ringPct: Int?): State {
        if (!activeIsWhoop) {
            return if (ringPct == null) State.NotActiveDevice else State.Charge(ringPct.toDouble(), isRing = true)
        }
        if (!connected) return State.Offline
        if (strapPct == null) return State.Pending
        return State.Charge(strapPct, isRing = false)
    }
}
