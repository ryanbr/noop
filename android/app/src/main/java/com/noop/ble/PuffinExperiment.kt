package com.noop.ble

import android.content.Context
import android.content.SharedPreferences

/**
 * Opt-in switch for the EXPERIMENTAL WHOOP 5.0/MG ("puffin") protocol probes.
 *
 * Direct port of the macOS `PuffinExperiment` (Strand/BLE/PuffinExperiment.swift). Live HR on a
 * 5/MG strap already works over the standard profile after CLIENT_HELLO. These probes go further —
 * sending puffin-framed commands (e.g. asking the strap to start its realtime stream) to learn what
 * a real 5/MG strap responds to. They are guesses, so they are OFF by default and only ever written
 * to the puffin command characteristic (fd4b0002). A 5/MG owner can flip this on under Settings →
 * Experimental to help map the protocol; everyone else is unaffected. It never touches WHOOP 4.0.
 *
 * The macOS app stored this in `UserDefaults` under the key `noopPuffinExperiments`; the Android
 * equivalent is [SharedPreferences]. The same key name is reused for parity.
 */
class PuffinExperiment(private val prefs: SharedPreferences) {

    /** True if the user opted in to the WHOOP 5/MG protocol probes (default false). */
    var isEnabled: Boolean
        get() = prefs.getBoolean(KEY, false)
        set(v) = prefs.edit().putBoolean(KEY, v).apply()

    /** True if the user opted in to recording raw 5/MG backfill frames to a shareable JSONL file
     *  (default false). SEPARATE from [isEnabled]: probes SEND commands at the strap; capture only
     *  RECORDS what arrives — different risk profiles, so different switches. (#78 fork) */
    var isCaptureEnabled: Boolean
        get() = prefs.getBoolean(KEY_CAPTURE, false)
        set(v) = prefs.edit().putBoolean(KEY_CAPTURE, v).apply()

    /** True if the user opted in to the WHOOP 5/MG "R22" deep-data unlock — the one probe that WRITES
     *  a persistent feature flag to the strap (the `enable_r22_*` SET_CONFIG sequence). Kept distinct
     *  from [isEnabled] because it changes strap state; reversible, default false. Mirrors the macOS
     *  `PuffinExperiment.deepDataKey`. Driven only from `WhoopBleClient.enableWhoop5DeepData()`. (#174) */
    var isDeepDataEnabled: Boolean
        get() = prefs.getBoolean(KEY_DEEP_DATA, false)
        set(v) = prefs.edit().putBoolean(KEY_DEEP_DATA, v).apply()

    /** True if the user opted in to "Broadcast heart rate": NOOP writes the device-config flag
     *  whoop_live_hr_in_adv_ind_pkt="1" so the strap advertises the standard Heart Rate Service
     *  (0x180D) + its live HR, pairable by a Garmin/Zwift/gym HR client. Reversible. Default false.
     *  Mirrors the macOS `PuffinExperiment.broadcastHrKey`. (#181) */
    var broadcastHr: Boolean
        get() = prefs.getBoolean(KEY_BROADCAST_HR, false)
        set(v) = prefs.edit().putBoolean(KEY_BROADCAST_HR, v).apply()

    /** True if the user opted in to the "ECG raw-data gate" (#891): NOOP writes the device-config key
     *  `enable_raw_data_w_ecg` — the key the strap's own 115/116 enumeration listed, which reads '0' on a
     *  subscription-free WHOOP MG whose three TOGGLE_LABRADOR commands all ack SUCCESS and emit nothing.
     *
     *  Its own key rather than a shared "ECG" one, because this repo gives every PERSISTENT STRAP WRITE its
     *  own deliberate opt-in ([deepData] #174, [broadcastHr] #181) — reusing one switch for "listen for ECG
     *  packets" and "change a stored value on the strap" would let the second ride in on consent for the
     *  first. Reversible in one tap, default false, and additionally gated on `Whoop5Variant.isMG` at the
     *  call site — a plain 5.0 has no electrodes. Driven only by `WhoopBleClient.setEcgRawDataGate`, which
     *  always follows the write with a GET_DEVICE_CONFIG_VALUE(121) read-back. Mirrors the macOS
     *  `PuffinExperiment.ecgRawDataKey`. */
    var ecgRawData: Boolean
        get() = prefs.getBoolean(KEY_ECG_RAW_DATA, false)
        set(v) = prefs.edit().putBoolean(KEY_ECG_RAW_DATA, v).apply()

    /** True if the user opted in to "Experimental sleep staging (V2)": detected nights are re-staged with
     *  [com.noop.analytics.SleepStagerV2] (the transparent cardiorespiratory recipe, reimplemented from
     *  contributor PR #600) instead of the older V1 [com.noop.analytics.SleepStager]. Pure analysis switch
     *  — it changes ONLY which staging engine runs over an already-detected sleep window; detection, scoring
     *  and the V1 code path itself are untouched. Model-agnostic (works on WHOOP 4 and 5). **Default true —
     *  V2, not V1, is what stages a normal user's nights**:
     *  V2 was promoted to the default staging engine after a 44-subject cross-subject benchmark (AAUWSS +
     *  Walch sleep-accel, leave-one-subject-out) showed V2 strictly dominates V1 (kappa 0.35 vs 0.03, deep
     *  recall 55% vs 1%) — the multi-subject validation this recipe originally lacked. V1 remains available.
     *  Mirrors the macOS `PuffinExperiment.experimentalSleepV2Key`. */
    var experimentalSleepV2: Boolean
        get() = prefs.getBoolean(KEY_EXPERIMENTAL_SLEEP_V2, true)
        set(v) = prefs.edit().putBoolean(KEY_EXPERIMENTAL_SLEEP_V2, v).apply()

    /** True if the user opted in to "HR-from-PPG sub-lag interpolation" (default false): the v26 optical-PPG
     *  gap-fill HR estimator ([com.noop.protocol.PpgHr]) refines its integer autocorrelation lag with a
     *  parabolic (Variant A) interpolation of the ACF peak, removing the ~+-8 bpm lag-quantization near a
     *  high HR. Pure OPT-IN research variant: default OFF is byte-identical to the integer-lag estimate, and
     *  it only ever fills seconds the strap never reported an HR for (it NEVER overrides a WHOOP-stored HR).
     *  The pure [com.noop.protocol.PpgHr] package cannot read prefs, so this flag is read at the app-layer
     *  call site (the Backfiller / archive replay / capture import) and threaded into the estimator. Mirrors
     *  the macOS `PuffinExperiment.ppgHrSubLagInterpKey`. */
    var ppgHrSubLagInterp: Boolean
        get() = prefs.getBoolean(KEY_PPG_HR_SUBLAG_INTERP, false)
        set(v) = prefs.edit().putBoolean(KEY_PPG_HR_SUBLAG_INTERP, v).apply()

    /** True if the user opted in to the experimental "HRV readiness (Plews/Altini)" tier readout (default
     *  false): a read-only Test Centre readout of the SWC log-HRV tier ([com.noop.analytics.HRVReadiness]).
     *  It changes NOTHING downstream — the Charge ring stays byte-identical whether on or off; it only
     *  surfaces the tier + baseline band in the Experimental algorithms card. Rough / early (n=1, not yet
     *  validated against varying real data). Mirrors the macOS `PuffinExperiment.hrvReadinessKey`. */
    var hrvReadiness: Boolean
        get() = prefs.getBoolean(KEY_HRV_READINESS, false)
        set(v) = prefs.edit().putBoolean(KEY_HRV_READINESS, v).apply()

    /** True if the user opted in to "Motion-aware wake refinement" (default false, #364 "Proposal 2"
     *  follow-up): a post-pass ([com.noop.analytics.WakeMotionRefinement]) over the already-staged
     *  hypnogram that reclassifies a scored WAKE segment to `light` when its per-minute step-tick cadence
     *  shows no locomotion AND its per-minute gravity posture stays stable outside a minority of isolated
     *  "turn-over" burst minutes (which are kept as wake). Targets the HR-led wake call misreading a
     *  hot-but-still/atonic stretch as an awakening. Self-gates on the OBSERVED gravity + step-sample
     *  density (never on strap family/model, per #345): a WHOOP 4.0 night (sparse gravity, no step stream
     *  at all) fails the gate and is left untouched every time; a WHOOP 5.0/MG night, which streams both
     *  densely, is the expected beneficiary. Pure analysis switch — it only ever SHRINKS an already-scored
     *  wake segment, never invents wake time; detection and the V1/V2 staging engines are untouched either
     *  way. Mirrors the macOS `PuffinExperiment.motionAwareWakeKey`. */
    var motionAwareWake: Boolean
        get() = prefs.getBoolean(KEY_MOTION_AWARE_WAKE, false)
        set(v) = prefs.edit().putBoolean(KEY_MOTION_AWARE_WAKE, v).apply()

    /**
     * Turn OFF every 5/MG-only experimental probe: protocol probes ([isEnabled]), raw capture
     * ([isCaptureEnabled]), the R22 deep-data strap write ([isDeepDataEnabled]) and broadcast-HR
     * ([broadcastHr]). Called on a strap FAMILY switch (WHOOP 4.0 ↔ 5/MG) so a 5/MG-only option can
     * never linger enabled and get applied to a strap it doesn't belong to. One atomic edit.
     *
     * The line is "does it SEND something to the strap": these four arm probes, raw-capture writes, the
     * R22 deep-data write and the broadcast-HR write, all of which target hardware that may not support
     * them. Pure analysis flags are deliberately left alone even when they only do anything on one
     * family — [ppgHrSubLagInterp] only affects v26 optical records, which a 4.0 never sends, so it is
     * inert rather than misapplied. [experimentalSleepV2], [hrvReadiness] and [motionAwareWake] are
     * model-agnostic (the last self-gates on observed sample density, never on family, per #345).
     */
    fun resetFiveMGGatedProbes() {
        val editor = prefs.edit()
        FIVE_MG_GATED_KEYS.forEach { editor.putBoolean(it, false) }
        editor.apply()
    }

    companion object {
        /** Persisted preferences file. Internal so a UI screen can observe external writes to it. */
        internal const val PREFS = "noop_experiments"

        /** Shared key name with the macOS build (`PuffinExperiment.defaultsKey`). */
        const val KEY = "noopPuffinExperiments"

        /** 5/MG raw backfill capture (research aid for the puffin biometric decode). */
        const val KEY_CAPTURE = "noopWhoop5Capture"

        /** 5/MG R22 deep-data unlock opt-in (mirrors macOS `PuffinExperiment.deepDataKey`). */
        const val KEY_DEEP_DATA = "noopWhoop5DeepData"

        /** "Broadcast heart rate" opt-in (mirrors macOS `PuffinExperiment.broadcastHrKey`). */
        const val KEY_BROADCAST_HR = "noopBroadcastHr"

        /** "ECG raw-data gate" opt-in — the `enable_raw_data_w_ecg` strap write (mirrors macOS
         *  `PuffinExperiment.ecgRawDataKey`). (#891) */
        const val KEY_ECG_RAW_DATA = "noopEcgRawDataGate"

        /** The 5/MG-only probe keys, in ONE place: [resetFiveMGGatedProbes] clears exactly these, and
         *  SettingsScreen watches exactly these for external writes. Two lists would drift. */
        internal val FIVE_MG_GATED_KEYS =
            listOf(KEY, KEY_CAPTURE, KEY_DEEP_DATA, KEY_BROADCAST_HR, KEY_ECG_RAW_DATA)

        /** "Experimental sleep staging (V2)" opt-in (mirrors macOS `PuffinExperiment.experimentalSleepV2Key`). */
        const val KEY_EXPERIMENTAL_SLEEP_V2 = "noopExperimentalSleepV2"

        /** "HR-from-PPG sub-lag interpolation" opt-in (mirrors macOS `PuffinExperiment.ppgHrSubLagInterpKey`). */
        const val KEY_PPG_HR_SUBLAG_INTERP = "noopPpgHrSubLagInterp"

        /** "HRV readiness (Plews/Altini)" readout opt-in (mirrors macOS `PuffinExperiment.hrvReadinessKey`). */
        const val KEY_HRV_READINESS = "noopHrvReadiness"

        /** "Motion-aware wake refinement" opt-in (mirrors macOS `PuffinExperiment.motionAwareWakeKey`). */
        const val KEY_MOTION_AWARE_WAKE = "noopMotionAwareWake"

        fun from(context: Context): PuffinExperiment =
            PuffinExperiment(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}
