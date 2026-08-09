package com.noop.analytics

// GuidedCaptureProgress.kt - Kotlin twin of GuidedCaptureProgress.swift. Pure state machine for
// the guided "wear it N nights/days" capture. A no-data night is a recorded gap, never a stall.
// No em-dashes.

sealed class GuidedCaptureProgress {
    data class Capturing(val done: Int, val target: Int) : GuidedCaptureProgress()
    object Complete : GuidedCaptureProgress()

    companion object {
        @Suppress("UNUSED_PARAMETER") // nightsElapsed mirrors the Swift GuidedCaptureProgress.evaluate signature (parity)
        fun evaluate(target: Int, nightsWithData: Int, nightsElapsed: Int): GuidedCaptureProgress =
            if (nightsWithData >= target) Complete else Capturing(nightsWithData, target)

        fun label(state: GuidedCaptureProgress): String = when (state) {
            is Complete -> "Capture complete. Tap Report to export."
            is Capturing -> "Captured ${state.done} of ${state.target} nights. Wear it again tonight."
        }

        fun gapNudge(): String = "No data last night. Wear the strap tonight to continue."
    }
}
