import Foundation

/// Opt-in switch for the EXPERIMENTAL WHOOP 5.0/MG ("puffin") protocol probes.
///
/// Live HR on a 5/MG strap already works over the standard profile after CLIENT_HELLO. These probes
/// go further — sending puffin-framed commands (e.g. asking the strap to start its realtime stream)
/// to learn what a real 5/MG strap responds to. They are guesses, so they are OFF by default and only
/// ever written to the puffin command characteristic (fd4b0002). A 5/MG owner can flip this on under
/// Settings → Experimental to help map the protocol; everyone else is unaffected.
enum PuffinExperiment {
    /// Shared with the Settings toggle via `@AppStorage(PuffinExperiment.defaultsKey)`.
    static let defaultsKey = "noopPuffinExperiments"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// Separate, more-deliberate opt-in for the WHOOP 5/MG "R22" deep-data unlock — the one probe
    /// that WRITES a persistent feature flag to the strap (the `enable_r22_*` SET_CONFIG sequence the
    /// official app sends; documented by judes.club + Asherlc/dofek). Kept distinct from the read-only
    /// probes above because it changes strap state, so it must be turned on explicitly.
    ///
    /// Reversible, and now actually reversed by code rather than only in the comment: this key gates BOTH
    /// `BLEManager.enableWhoop5DeepData()` and `BLEManager.disableWhoop5DeepData()`, and the send allowlist
    /// consults `FeatureFlagWriteGate` so only the sixteen R22 keys — carrying either their enable value or
    /// the off value — can travel through opcode 120. Note the pref itself writes NOTHING in either
    /// direction; it only decides whether a send is permitted. (#174)
    static let deepDataKey = "noopWhoop5DeepData"

    static var deepDataEnabled: Bool { UserDefaults.standard.bool(forKey: deepDataKey) }

    /// Opt-in "Broadcast heart rate": writes the device-config flag `whoop_live_hr_in_adv_ind_pkt="1"`
    /// so the strap advertises the standard Heart Rate Service (0x180D) + its live HR, pairable by a
    /// Garmin/Zwift/gym HR client. Reversible, default off; applied on each 5/MG connection and driven by
    /// `BLEManager.setBroadcastHr(_:)`. Mirrors the Android `PuffinExperiment.KEY_BROADCAST_HR`. (#181)
    static let broadcastHrKey = "noopBroadcastHr"

    static var broadcastHrEnabled: Bool { UserDefaults.standard.bool(forKey: broadcastHrKey) }

    /// Opt-in "ECG raw-data gate" (#891): writes the device-config key `enable_raw_data_w_ecg` — the key
    /// the strap's own 115/116 enumeration listed, and which reads `'0'` on a subscription-free WHOOP MG
    /// whose three TOGGLE_LABRADOR commands all ack SUCCESS and emit nothing.
    ///
    /// Its own key rather than a shared "ECG" one: this repo gives every PERSISTENT STRAP WRITE its own
    /// deliberate opt-in (`deepDataKey` #174, `broadcastHrKey` #181), so reusing one switch for "listen for
    /// ECG packets" (`ecgKey`) and "change a stored value on the strap" would let the second ride in on
    /// consent given for the first.
    ///
    /// Reversible in one tap, default OFF, and additionally gated on `Whoop5Variant.isMG` at the call site
    /// — a plain 5.0 has no electrodes. Driven only by `BLEManager.setEcgRawDataGate(_:)`, which always
    /// follows the write with a `GET_DEVICE_CONFIG_VALUE(121)` read-back. Mirrors the Android
    /// `PuffinExperiment.KEY_ECG_RAW_DATA`.
    static let ecgRawDataKey = "noopEcgRawDataGate"

    static var ecgRawDataEnabled: Bool { UserDefaults.standard.bool(forKey: ecgRawDataKey) }

    /// Opt-in "SpO₂ strap estimate" display (#103): surfaces the WHOOP 5/MG `spo2_candidate_82` nightly
    /// mean in the Blood Oxygen tile/card, labelled "strap estimate (unverified)". The @82 byte is a
    /// strap-computed SpO₂ % (70–100 range) that an 8-night independent validation tracked at corr +0.99
    /// against the WHOOP app, but two nights on the original #103 device moved OPPOSITE — device/firmware
    /// variance unresolved. Per the derived-biosignal rule (CLAUDE.md), an unvalidated signal ships behind
    /// a default-off toggle, never as the default `spo2Pct` and never feeding a downstream gate.
    ///
    /// Display-only: writes nothing to the strap. The engine computes `nightlySpo2CandidateMean` and
    /// writes it to metricSeries as "spo2_candidate" under the "-noop" computed device ID; the UI reads
    /// it only while this toggle is ON. Mirrors the Android `NoopPrefs.KEY_SPO2_CANDIDATE_DISPLAY`.
    static let spo2CandidateDisplayKey = "noopSpo2CandidateDisplay"

    static var spo2CandidateDisplayEnabled: Bool { UserDefaults.standard.bool(forKey: spo2CandidateDisplayKey) }

    /// Opt-in "Continuous HRV capture": hold the dense realtime HR stream armed even with no Live screen
    /// open, so the strap banks beat-to-beat R-R intervals 24/7 for far better overnight HRV/recovery/
    /// sleep (vs the sparse history offload). Uses more battery (continuous HR streaming). Default OFF;
    /// applied on launch + each (re)bond and driven by `BLEManager.setKeepRealtimeForData(_:)`. Mirrors
    /// the Android `NoopPrefs.KEY_CONTINUOUS_HRV`. Works on WHOOP 4 and 5/MG (both emit 0x2A37 R-R).
    static let keepRealtimeForDataKey = "noopContinuousHrv"

    static var keepRealtimeForDataEnabled: Bool { UserDefaults.standard.bool(forKey: keepRealtimeForDataKey) }

    /// Opt-in "Overnight only" refinement of Continuous HRV capture (#927): arm the dense realtime stream
    /// only inside the nightly window (the reused quiet-hours window convention: minutes since local
    /// midnight, wrap-aware, 22:00 to 07:00 by default) instead of 24/7, roughly halving the battery
    /// cost. Composed with the base toggle so existing users need no migration: base on + this off reads
    /// ALWAYS (the pre-#927 behaviour). Defaults ON for fresh installs, OFF once Continuous HRV has been
    /// used (#1008) — see below. Read by BLEManager at EVERY arm site (re-derived at
    /// arm time, never precomputed; see ContinuousHrvSchedule). Mirrors the Android
    /// `NoopPrefs.KEY_CONTINUOUS_HRV_OVERNIGHT`.
    static let continuousHrvOvernightOnlyKey = "noopContinuousHrvOvernightOnly"

    /// Defaults to ON for anyone who has never touched Continuous HRV, and to OFF for anyone who has
    /// (#1008). WHOOP publishes no daytime HRV figure at all — its reading is an overnight one — so a
    /// 24/7 stream has no official-app analogue, and overnight-only roughly halves the battery cost.
    /// Making the cheaper, WHOOP-comparable behaviour the default is the point; the expensive one stays
    /// a deliberate choice.
    ///
    /// `UserDefaults.bool(forKey:)` cannot express this on its own: it returns `false` for a missing key,
    /// which is indistinguishable from an explicit off. The unset case is therefore resolved from whether
    /// `keepRealtimeForDataKey` exists, rather than by writing a migration — the only thing that must not
    /// happen is silently narrowing capture for someone already relying on it. Twin of the Android
    /// `NoopPrefs.continuousHrvOvernight`.
    static var continuousHrvOvernightOnlyEnabled: Bool {
        UserDefaults.standard.object(forKey: continuousHrvOvernightOnlyKey) as? Bool ?? true
    }

    /// One-time migration for the #1008 default flip. Called once at launch, BEFORE anything reads the
    /// setting, and before the user can reach the toggle.
    ///
    /// The default moved from OFF to ON, so an install that predates the change has to be pinned to OFF
    /// explicitly or it would be silently narrowed to overnight-only capture — removing daytime data the
    /// user opted in for. "Predates the change" is read as "has ever toggled Continuous HRV", i.e. the
    /// base key exists.
    ///
    /// Deciding this at READ time instead does not work, and the way it fails is worth recording: the
    /// discriminator would be the base key, which the user's own opt-in creates — so a fresh install
    /// would default to ON and then flip to OFF the moment they enabled Continuous HRV, the exact
    /// opposite of the intent.
    ///
    /// A `@AppStorage` `onChange` hook cannot substitute for this either: `@AppStorage` writes the value
    /// BEFORE the handler runs, so by then a first-ever toggle is indistinguishable from any other.
    ///
    /// Idempotent: writes only when the overnight key is absent and the base key is present.
    /// Twin of the Android `NoopPrefs.migrateContinuousHrvOvernightDefault`.
    static func migrateContinuousHrvOvernightDefault() {
        let defaults = UserDefaults.standard
        guard shouldPinLegacyOvernightDefault(
            hasOvernightChoice: defaults.object(forKey: continuousHrvOvernightOnlyKey) != nil,
            hasUsedContinuousHrv: defaults.object(forKey: keepRealtimeForDataKey) != nil) else { return }
        defaults.set(false, forKey: continuousHrvOvernightOnlyKey)
    }

    /// The migration's decision, lifted out so it is testable without touching `UserDefaults`. Twin of
    /// the Android `NoopPrefs.shouldPinLegacyOvernightDefault`.
    ///
    /// Pin the OLD default only for an install that has used Continuous HRV and never chose an overnight
    /// setting. Everything else is left alone.
    ///
    /// Note what this is NOT keyed on: the READ. An earlier attempt resolved the default at read time
    /// from `hasUsedContinuousHrv`, which the user's own opt-in creates — so a fresh install read ON and
    /// then flipped to OFF the moment Continuous HRV was enabled. Running the decision once at launch is
    /// what makes the answer stable.
    static func shouldPinLegacyOvernightDefault(hasOvernightChoice: Bool,
                                                hasUsedContinuousHrv: Bool) -> Bool {
        !hasOvernightChoice && hasUsedContinuousHrv
    }

    // MARK: - Power saving (#477), parity with Android NoopPrefs

    /// "Power saving" master: battery-adaptive strap-sync cadence. Default off. */
    static let powerSavingKey = "noopPowerSaving"
    static var powerSavingEnabled: Bool { UserDefaults.standard.bool(forKey: powerSavingKey) }

    /// Battery-% threshold for power saving (10–30). Default 20 (0 in the store means "unset" → 20).
    static let powerSavingBatteryPctKey = "noopPowerSavingBatteryPct"
    static var powerSavingBatteryPct: Int {
        let v = UserDefaults.standard.integer(forKey: powerSavingBatteryPctKey)
        return v == 0 ? 20 : v
    }

    /// "Pause HRV capture under Low Power Mode" — a sub-option of power saving, default ON when the master
    /// is on. Stored inverted (`…Disabled`) so the default-true reads correctly from a zero-value store.
    static let pauseHrvDisabledKey = "noopPowerSavingPauseHrvDisabled"
    static var pauseHrvOnPowerSaveEnabled: Bool { !UserDefaults.standard.bool(forKey: pauseHrvDisabledKey) }

    /// "Experimental sleep staging (V2)": re-stage each detected night with `SleepStagerV2` — a transparent
    /// cardiorespiratory recipe (reimplemented from contributor PR #600) — instead of the older V1 stager.
    /// Pure analysis switch: it changes ONLY which staging engine runs over an already-detected sleep window;
    /// sleep DETECTION, scoring and the V1 path are all untouched. Model-agnostic (WHOOP 4 and 5). **Default
    /// ON**: V2 was promoted to the default staging engine after a 44-subject cross-subject benchmark (AAUWSS
    /// + Walch sleep-accel, leave-one-subject-out) showed V2 strictly dominates V1 (kappa 0.35 vs 0.03, deep
    /// recall 55 % vs 1 %) — the multi-subject validation this recipe originally lacked. V1 remains available.
    /// Read at the staging call site (Repository). Mirrors the Android `PuffinExperiment.KEY_EXPERIMENTAL_SLEEP_V2`.
    static let experimentalSleepV2Key = "noopExperimentalSleepV2"

    /// Default ON when the key is unset (mirrors the Android `getBoolean(KEY, true)`): a `bool(forKey:)` alone
    /// reads a missing key as false, so an absent preference must resolve to the promoted V2 default explicitly.
    static var experimentalSleepV2Enabled: Bool {
        UserDefaults.standard.object(forKey: experimentalSleepV2Key) == nil
            ? true
            : UserDefaults.standard.bool(forKey: experimentalSleepV2Key)
    }

    /// Opt-in "HR-from-PPG sub-lag interpolation" (default off): the v26 optical-PPG gap-fill HR estimator
    /// (`PpgHr`) refines its integer autocorrelation lag with a parabolic (Variant A) interpolation of the
    /// ACF peak, removing the ~±8 bpm lag-quantization near a high HR. Pure opt-in research variant: default
    /// OFF is byte-identical to the integer-lag estimate, and it only ever fills seconds the strap never
    /// reported an HR for (it NEVER overrides a WHOOP-stored HR). The pure `PpgHr` package cannot read prefs,
    /// so the app-layer call site (the Backfiller / archive replay) reads this flag and threads it into the
    /// estimator. Mirrors the Android `PuffinExperiment.KEY_PPG_HR_SUBLAG_INTERP`.
    static let ppgHrSubLagInterpKey = "noopPpgHrSubLagInterp"

    static var ppgHrSubLagInterpEnabled: Bool { UserDefaults.standard.bool(forKey: ppgHrSubLagInterpKey) }

    /// Opt-in experimental "HRV readiness (Plews/Altini)" tier readout (default off): a read-only Test Centre
    /// readout of the SWC log-HRV tier (`HRVReadiness`). It changes NOTHING downstream — the Charge ring stays
    /// byte-identical whether on or off; it only surfaces the tier + baseline band in the Experimental
    /// algorithms card. Rough / early (n=1, not yet validated against varying real data). Read directly by the
    /// Test Centre view via @AppStorage on this key. Mirrors the Android `PuffinExperiment.KEY_HRV_READINESS`.
    static let hrvReadinessKey = "noopHrvReadiness"

    /// Opt-in "Auto-detect workouts": after a sync / on Today appear, scan the last day or two of HR for a
    /// SUSTAINED-ELEVATED window (resting HR + 30 bpm held ≥ 12 min) that doesn't overlap a saved workout,
    /// and surface ONE dismissible Today card offering to save it as a manual-style workout. Pure read +
    /// suggestion: nothing is ever created without the user tapping Save, and turning this OFF stops all
    /// detection and hides the card. Default OFF. Mirrors the Android `NoopPrefs.KEY_AUTO_DETECT_WORKOUTS`.
    static let autoDetectWorkoutsKey = "noopAutoDetectWorkouts"

    static var autoDetectWorkoutsEnabled: Bool { UserDefaults.standard.bool(forKey: autoDetectWorkoutsKey) }

    /// "Journal reminder" (#627). When ON, Today shows a persistent journal widget (a last-7-days
    /// completion strip that taps through to the journal) and nudges when today isn't logged yet.
    /// Default ON — gates both the widget and (on Android) the morning sleep sheet. Mirrors the Android
    /// `NoopPrefs.KEY_JOURNAL_REMINDER_ENABLED`. Default-true, so a bare `bool(forKey:)` can't be used to
    /// read it (that defaults false); read it through @AppStorage(...) = true or `object(forKey:)`.
    static let journalReminderKey = "noopJournalReminder"

    static var journalReminderEnabled: Bool {
        UserDefaults.standard.object(forKey: journalReminderKey) as? Bool ?? true
    }

    /// Opt-in "Motion-aware wake refinement" (default OFF, #364 "Proposal 2" follow-up): a post-pass
    /// (`WakeMotionRefinement`) over the already-staged hypnogram that reclassifies a scored WAKE segment
    /// to `light` when its per-minute step-tick cadence shows no locomotion AND its per-minute gravity
    /// posture stays stable outside a minority of isolated "turn-over" burst minutes (which are kept as
    /// wake). Targets the HR-led wake call misreading a hot-but-still/atonic stretch as an awakening — a
    /// real anonymized night scored 194 min wake from single-minute turn-over bursts with zero walking
    /// cadence between them. Self-gates on the OBSERVED gravity + step-sample density (never on strap
    /// family/model, per #345): a WHOOP 4.0 night (sparse gravity, no step stream at all) fails the gate
    /// and is left untouched every time; a WHOOP 5.0/MG night, which streams both densely, is the expected
    /// beneficiary. Pure analysis switch — it only ever SHRINKS an already-scored wake segment, never
    /// invents wake time; detection and the V1/V2 staging engines are untouched either way. Read at the
    /// staging call sites (`Repository.restageFromRaw`, `IntelligenceEngine`, threaded through
    /// `AnalyticsEngine.analyzeDay`). Mirrors the Android `PuffinExperiment.KEY_MOTION_AWARE_WAKE`.
    static let motionAwareWakeKey = "noopMotionAwareWake"

    static var motionAwareWakeEnabled: Bool { UserDefaults.standard.bool(forKey: motionAwareWakeKey) }

    /// Opt-in "WHOOP MG ECG (experimental)": unlock the gated, user-initiated ECG ("Labrador") probe that
    /// asks an MG strap to start its ECG subsystem. Default OFF, and OFF is not merely the default — with
    /// this key false the four ECG opcodes are dropped by the BLEManager allowlist, so no ECG byte can
    /// reach a strap on a normal install. Additionally gated on a POSITIVELY identified MG
    /// (`Whoop5Variant.mg`): a plain 5.0 has no electrodes and a 4.0 has neither the hardware nor the
    /// transport. Every send is still user-initiated and confirmation-gated at the call site.
    ///
    /// NOT a medical feature. Whatever the strap returns is unvalidated instrumentation, never a
    /// diagnosis — see the probe's report text and DISCLAIMER.md.
    static let ecgKey = "noopWhoop5Ecg"

    static var ecgEnabled: Bool { UserDefaults.standard.bool(forKey: ecgKey) }

    /// Every 5/MG-only probe key, in ONE place — the twin of Kotlin's `FIVE_MG_GATED_KEYS`.
    ///
    /// The capture flag deliberately appears here even though it is declared on `PuffinFrameRecorder`
    /// rather than on this type, and under a DIFFERENT string (`noopPuffinCapture` vs Kotlin's
    /// `noopWhoop5Capture`). That split is exactly why it was missed when this reset first shipped:
    /// grepping this file for a capture key found nothing, and grepping for the Kotlin key name found
    /// nothing either. Add new gated probes here, not inline in the reset.
    static let fiveMGGatedKeys: [String] = [
        defaultsKey,                     // protocol probes
        deepDataKey,                     // R22 deep-data strap write
        broadcastHrKey,                  // broadcast-HR write
        // MG ECG (Labrador) probe — writes ECG control commands. Swift-only for now: the Android client
        // takes the ECG decoder but has no ECG app layer, so Kotlin's FIVE_MG_GATED_KEYS has no twin
        // entry to add. Add one there in the same change that adds an Android probe.
        ecgKey,
        ecgRawDataKey,                   // enable_raw_data_w_ecg strap write (#891)
        PuffinFrameRecorder.enabledKey,  // raw frame capture — declared on PuffinFrameRecorder
    ]

    /// Turn OFF every key in [fiveMGGatedKeys] on a strap FAMILY switch (WHOOP 4.0 ↔ 5/MG), so a
    /// 5/MG-only option cannot linger enabled and get applied to a strap that does not support it.
    /// The line is "does it SEND something to the strap" — model-agnostic analysis toggles (continuous
    /// HRV, experimental sleep V2, auto-detect workouts) are deliberately left alone. Mirrors the
    /// Android `PuffinExperiment.resetFiveMGGatedProbes`.
    static func resetFiveMGGatedProbes() {
        for key in fiveMGGatedKeys { UserDefaults.standard.set(false, forKey: key) }
    }
}
