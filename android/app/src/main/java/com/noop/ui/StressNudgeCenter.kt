package com.noop.ui

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * StressNudgeCenter — the L3 closed-loop JITAI surface (the "passive" layer), Kotlin twin of
 * Strand/Screens/StressCheckInCard.swift's `StressNudgeCenter`. When the shipped, unit-tested
 * [com.noop.analytics.StressOnsetDetector] fires (a fresh, non-metabolic HRV dip while still), the
 * central hook (Wave 3, in WhoopBleClient's offload/evaluateStress path) calls [present]; the Compose
 * StressCheckInCard observes [pending] and surfaces a dismissible card.
 *
 * NEVER an alarm, NEVER a push (unless the user separately opted into notifications), NEVER a diagnosis.
 *
 * A process-wide singleton (a plain object holding a StateFlow) so the BLE-layer hook and the Compose UI
 * share one instance without editing AppViewModel (Wave 3 only needs to call [present]).
 *
 * See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L3).
 */
object StressNudgeCenter {

    /** A live nudge awaiting the user, or null. Carries the engine's honest numbers for the card copy. */
    data class Nudge(
        /** The fast short-window RMSSD at the moment of the dip (ms), for the honest sub-line. */
        val fastRMSSD: Double?,
        /** The slow baseline RMSSD (ms) it dipped below. */
        val baselineRMSSD: Double?,
        /** Epoch-millis it fired. */
        val firedAtMs: Long,
    )

    private val _pending = MutableStateFlow<Nudge?>(null)
    val pending: StateFlow<Nudge?> = _pending.asStateFlow()

    /** Post a nudge (the central L3 hook calls this on a fire). A newer fire replaces an un-acted one. */
    fun present(fastRMSSD: Double?, baselineRMSSD: Double?, firedAtMs: Long = System.currentTimeMillis()) {
        _pending.value = Nudge(fastRMSSD, baselineRMSSD, firedAtMs)
    }

    fun dismiss() {
        _pending.value = null
    }
}
