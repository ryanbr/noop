package com.noop.ui

import android.content.Context
import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Hexagon
import androidx.compose.material.icons.filled.LocalDrink
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.ui.graphics.vector.ImageVector
import org.json.JSONArray
import com.noop.R

// MARK: - "Your cards" customisable dashboard (WHOOP "My Dashboard") — Kotlin twin of DashboardCards.swift
//
// The Today screen's "Your cards" section is a user-customisable dashboard faithful to WHOOP's "My
// Dashboard": the user chooses WHICH metric cards show and in WHAT order from a registry of the values
// Today already loads. Persistence is DISPLAY-ONLY — no metric is computed or stored differently; this just
// decides which already-loaded values render as WHOOP metric rows and in what sequence.
//
// Stored as a JSON-encoded array of card ids in SharedPreferences ("today.dashboardCards") — the SAME
// JSON-array form the iOS @AppStorage uses, so a backup/restore reads the same dashboard on either OS.
// Unknown ids are dropped on read; a known id missing from the saved list is offered (disabled) in the
// editor so a future card can't be lost. Mirrors the existing [KeyMetricPrefs] mechanism but as its own
// list so the two sections stay independent (Key Metrics grid vs. the Your-cards dashboard).

/**
 * One available card in the "Your cards" dashboard. The [raw] is the stable persisted identifier — keep it
 * BYTE-IDENTICAL to the iOS `DashboardCard` rawValue so a backup/restore reads the same dashboard on either
 * OS. [title] / [subtitle] / [unit] mirror the Swift registry verbatim; [icon] is the Material twin of the
 * SF Symbol (closest match in the bundled icon set).
 */
enum class DashboardCard(
    val raw: String,
    @StringRes val titleRes: Int,
    @StringRes val subtitleRes: Int,
    val unit: String,
    val icon: ImageVector,
) {
    HRV("hrv", R.string.today_card_hrv, R.string.today_card_hrv_subtitle, "ms", Icons.Filled.MonitorHeart),
    RESTING_HR("restingHr", R.string.today_card_resting_hr, R.string.today_card_resting_hr_subtitle, "bpm", Icons.Filled.Favorite),
    RESPIRATORY("respiratory", R.string.today_card_respiratory, R.string.today_card_respiratory_subtitle, "rpm", Icons.Filled.Air),
    STEPS("steps", R.string.today_card_steps, R.string.today_card_steps_subtitle, "", Icons.AutoMirrored.Filled.DirectionsWalk),
    STRESS("stress", R.string.today_card_stress, R.string.today_card_stress_subtitle, "", Icons.Filled.Bolt),
    FITNESS_AGE("fitnessAge", R.string.today_card_fitness_age, R.string.today_card_fitness_age_subtitle, "yrs", Icons.AutoMirrored.Filled.DirectionsRun),
    VO2MAX("vo2max", R.string.today_card_vo2max, R.string.today_card_vo2max_subtitle, "", Icons.Filled.Air),
    VITALITY("vitality", R.string.today_card_vitality, R.string.today_card_vitality_subtitle, "", Icons.Filled.AutoAwesome),
    BLOOD_OXYGEN("bloodOxygen", R.string.today_card_blood_oxygen, R.string.today_card_blood_oxygen_subtitle, "", Icons.Filled.WaterDrop),
    SKIN_TEMP("skinTemp", R.string.today_card_skin_temp, R.string.today_card_skin_temp_subtitle, "", Icons.Filled.Thermostat),
    SLEEP("sleep", R.string.today_card_sleep, R.string.today_card_sleep_subtitle, "", Icons.Filled.Bedtime),
    CALORIES("calories", R.string.today_card_calories, R.string.today_card_calories_subtitle, "kcal", Icons.Filled.LocalFireDepartment),
    HYDRATION("hydration", R.string.today_card_hydration, R.string.today_card_hydration_subtitle, "", Icons.Filled.LocalDrink),

    // Optional, default-OFF (task #43): a tap-through to the Coupled view (the WHOOP-style day read). Unlike
    // every other card it carries NO metric value of its own, it is a navigation row that opens the full
    // CoupledScreen. It is NOT in [defaultSelection], so a fresh install never shows it until the user adds
    // it via CUSTOMISE. Mirrors iOS DashboardCard.coupled (raw "coupled", byte-identical across OS).
    COUPLED("coupled", R.string.today_card_coupled, R.string.today_card_coupled_subtitle, "", Icons.Filled.Hexagon),

    // Optional, default-OFF (#1862): opens the Coach launcher BOTTOM SHEET rather than a screen — the one
    // card that does. Coach is otherwise buried in More, and entering it means leaving Today. Like COUPLED
    // it carries no metric value and is absent from [defaultSelection], so someone who does not use a
    // provider never gains a fixed dashboard row for one. Opening the sheet makes NO provider request.
    // Reuses the existing nav + Coach-screen strings, so the card adds nothing to translate.
    // Mirrors iOS DashboardCard.coach (raw "coach", byte-identical across OS).
    COACH("coach", R.string.nav_coach, R.string.l10n_coach_screen_ask_anything_about_your_recent_recovery_e6c287ca, "", Icons.AutoMirrored.Filled.Chat);

    companion object {
        fun fromRaw(raw: String?): DashboardCard? = entries.firstOrNull { it.raw == raw }

        /**
         * The default set when the user hasn't customised the dashboard: the original Stress / Fitness age /
         * Vitality trio plus HRV + Resting HR (per the task's "sensible default"). Cards with no value yet
         * simply render a dash, so the default set is safe on a fresh install. Mirrors iOS defaultSelection.
         */
        val defaultSelection: List<DashboardCard> = listOf(
            STRESS, FITNESS_AGE, VITALITY, HRV, RESTING_HR,
        )

        /** Canonical order used to list the disabled remainder in the editor (matches iOS allCases order). */
        val canonicalOrder: List<DashboardCard> = entries.toList()
    }
}

/**
 * Display-only persistence for the "Your cards" dashboard selection. Holds an ORDERED list of the enabled
 * cards as a JSON-encoded array of ids; a card not in the list is hidden. Stored in SharedPreferences under
 * "today.dashboardCards", the same mechanism every other Android preference uses ([NoopPrefs]).
 * SharedPreferences isn't reactive, so the Today screen reads this once into remembered state (like the
 * other prefs) and re-reads on the recomposition the editor's write triggers. Mirrors the iOS
 * DashboardCardPrefs (@AppStorage "today.dashboardCards", JSON-array form).
 */
object DashboardCardPrefs {
    private const val KEY_SELECTION = "today.dashboardCards"

    /** The enabled cards in display order. An empty/unset value yields the default selection. */
    fun enabled(context: Context): List<DashboardCard> =
        decodeEnabled(NoopPrefs.of(context).getString(KEY_SELECTION, null))

    /** Persist the enabled cards in order. Disabled cards are simply omitted from the stored string. */
    fun setEnabled(context: Context, cards: List<DashboardCard>) {
        NoopPrefs.of(context).edit().putString(KEY_SELECTION, encode(cards)).apply()
    }

    /** Encode an ordered list of enabled cards into the stored JSON-array string (matches the iOS form). */
    fun encode(cards: List<DashboardCard>): String {
        val arr = JSONArray()
        cards.forEach { arr.put(it.raw) }
        return arr.toString()
    }

    /**
     * Decode the stored string into an ordered list of enabled cards. An empty/unset string yields the
     * default selection (so a fresh install shows the sensible default). Accepts both the JSON-array form
     * (the canonical iOS form) and a legacy comma-joined form. Unknown ids are dropped; duplicates are
     * de-duped; this returns ONLY the enabled cards in their saved order — the editor pairs it with the
     * disabled remainder. An all-unknown / empty decode falls back to the default set so the dashboard is
     * never blanked. Mirrors iOS DashboardCardPrefs.decodeEnabled.
     */
    fun decodeEnabled(raw: String?): List<DashboardCard> {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return DashboardCard.defaultSelection

        val ids: List<String> = parseJsonArray(trimmed)
            ?: trimmed.split(",").map { it.trim() }

        val seen = LinkedHashSet<DashboardCard>()
        ids.forEach { token -> DashboardCard.fromRaw(token)?.let { seen.add(it) } }
        return if (seen.isEmpty()) DashboardCard.defaultSelection else seen.toList()
    }

    /** Parse a JSON string array into a list of ids, or null if it isn't valid JSON (caller then falls back
     *  to the legacy comma-joined form). */
    private fun parseJsonArray(s: String): List<String>? = runCatching {
        val arr = JSONArray(s)
        (0 until arr.length()).map { arr.getString(it) }
    }.getOrNull()
}
