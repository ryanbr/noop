package com.noop.ui

import android.content.SharedPreferences
import androidx.annotation.StringRes
import com.noop.R
import kotlin.math.roundToInt

// MARK: - Waist stepper (optional VO₂max input)

/** A typical adult waist (cm) used as the first value when stepping up from "unset" (0), so the field
 *  jumps to a sensible starting point rather than 1 cm. ~34" — the rough population midpoint. */
private const val WAIST_SEED_CM = 86.0

/** Step the waist by one centimetre, seeding [WAIST_SEED_CM] when starting from unset (0). Stepping
 *  down from the seed cannot go below the seed (it never silently re-enters the "unset" sentinel). */
internal fun waistCmStep(current: Double, up: Boolean): Double {
    if (current <= 0.0) return if (up) WAIST_SEED_CM else 0.0
    return (current + if (up) 1.0 else -1.0).coerceAtLeast(WAIST_SEED_CM - 30.0)
}

/** Step the waist by one inch (entry unit in imperial; stored as cm), seeding [WAIST_SEED_CM] from
 *  unset. Snaps to whole inches so the up/down sequence is symmetric, mirroring the Height field. */
internal fun waistInchesStep(current: Double, up: Boolean): Double {
    if (current <= 0.0) return if (up) WAIST_SEED_CM else 0.0
    val inches = UnitFormatter.cmToInches(current).roundToInt()
    val nextInches = (inches + if (up) 1 else -1)
    val nextCm = nextInches * UnitFormatter.CENTIMETERS_PER_INCH
    return nextCm.coerceAtLeast(WAIST_SEED_CM - 30.0)
}

// MARK: - Strap status helpers (mirror SettingsView's computed properties)

/**
 * The Strap pill on Settings.
 *
 * [encryptedBond], not [bonded], is what "Bonded" means. `bonded` is also set by the 5/MG live-HR
 * shortcut (#69), where HR streams over the open profile with no encrypted pairing at all — so keying the
 * green "Bonded" state off it told a strap with no pairing that it had one. The Live screen has drawn this
 * distinction since #69; Settings and Data Sources were missed, and #1635 hello suppression turns that
 * state from a brief moment on the way to bonding into where a 5/MG now permanently sits.
 *
 * It is not cosmetic. The encrypted bond gates buzz, alarms, double-tap and history sync, and Settings
 * already says so a few rows further down ("Needs the full encrypted bond…"). A green "Bonded · streaming"
 * above that contradicts it on the same screen.
 *
 * Returns a string resource rather than text so the branch stays testable in a plain JVM test, where
 * [uiString] has no Application to resolve through.
 */
@StringRes
internal fun strapStatusTitleRes(encryptedBond: Boolean, bonded: Boolean, connected: Boolean): Int = when {
    encryptedBond && connected -> R.string.onboarding_state_bonded_streaming
    encryptedBond -> R.string.l10n_settings_logic_bonded_idle_1930284f
    bonded && connected -> R.string.l10n_settings_logic_live_hr_not_fully_paired_6fd6ddb1
    connected -> R.string.recording_chip_title_connected
    // No `bonded`-only idle arm: without an encrypted bond there was never a pairing to be idle from,
    // and labelling that "Paired" would be the same overclaim this change exists to remove. The 5/MG
    // shortcut's `bonded` is cleared on disconnect anyway, so the honest answer here is Disconnected.
    else -> R.string.l10n_settings_logic_disconnected_771e05f2
}

/** Positive ONLY for a real encrypted bond on a live link — see [strapStatusTitleRes]. A live-HR-only link
 *  is a warning, not a success: it works, but the pairing-gated features do not. */
internal fun strapTone(encryptedBond: Boolean, bonded: Boolean, connected: Boolean): StrandTone = when {
    encryptedBond && connected -> StrandTone.Positive
    connected || bonded -> StrandTone.Warning
    else -> StrandTone.Critical
}

// `internal` (not private) so the unit test in the same package can assert the scanning branch. A string
// resource for the same reason as [strapStatusTitleRes].
@StringRes
internal fun strapStatusDetailRes(
    encryptedBond: Boolean,
    bonded: Boolean,
    connected: Boolean,
    scanning: Boolean,
): Int = when {
    scanning -> R.string.l10n_settings_logic_searching_for_your_whoop_make_sure_7be37c50
    encryptedBond && connected -> R.string.l10n_settings_logic_your_strap_is_paired_and_sending_ef06dfd4
    bonded && connected -> R.string.l10n_settings_logic_live_heart_rate_is_streaming_but_934807fc
    connected -> R.string.l10n_settings_logic_connected_finishing_the_secure_pairing_handshake_1e56d362
    bonded -> R.string.l10n_settings_logic_previously_paired_but_not_currently_connected_0a84a072
    else -> R.string.l10n_settings_logic_no_strap_connected_put_your_whoop_61a155c1
}

internal fun batteryTone(pct: Double): StrandTone = when {
    pct <= 15 -> StrandTone.Critical
    pct <= 30 -> StrandTone.Warning
    else -> StrandTone.Positive
}

// MARK: - Sex options

internal data class SexOption(val tag: String, @StringRes val labelRes: Int)

internal val SEX_OPTIONS = listOf(
    SexOption("male", R.string.onboarding_male),
    SexOption("female", R.string.onboarding_female),
    SexOption("nonbinary", R.string.l10n_settings_logic_non_binary_dc82a40c),
)

// MARK: - Advanced disclosure persistence (S3)

/**
 * The persisted open/closed state of the Settings "Advanced" disclosure. Keyed identically to the iOS
 * `@AppStorage("settingsAdvancedOpen")` (here under the `noop.` SharedPreferences namespace), and it
 * DEFAULTS to false so a first-run user lands collapsed. Pulled out so the default is a single testable
 * fact: a regression that ships it defaulting open would dump the full wall of cards on first run again.
 */
internal object SettingsDisclosurePrefs {
    const val KEY = "noop.settingsAdvancedOpen"
    const val DEFAULT_OPEN = false

    fun read(prefs: SharedPreferences): Boolean = prefs.getBoolean(KEY, DEFAULT_OPEN)
    fun write(prefs: SharedPreferences, open: Boolean) { prefs.edit().putBoolean(KEY, open).apply() }
}
