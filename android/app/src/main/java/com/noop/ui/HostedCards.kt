package com.noop.ui

import android.content.Context
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.ui.graphics.vector.ImageVector
import org.json.JSONArray

// MARK: - Hosted cards (#today-hosted-cards)
//
// Cards that natively live in the Trends or Sleep tab, which the user can ALSO surface inside the Today
// tab via the Customise sheet — added, removed and reordered like "Your cards", while still appearing in
// their home tab (mirrored, not moved). Display-only: nothing is computed or stored differently, this
// just decides which foreign cards Today additionally renders and in what order.
//
// The [raw] ids are ORIGIN-NAMESPACED ("sleep.*" / "trends.*") so a hosted id is self-describing and
// routes to the right provider, and can never collide with a Today DashboardCard id. Keep them
// byte-identical to the iOS HostedCard enum so a backup/restore reads the same Today composition on
// either OS — the selection rides .noopbak under the "today.hostedCards" key.

/**
 * One card that can be hosted in Today from another tab. The [raw] is the stable persisted identifier
 * (origin-namespaced); keep it byte-identical to the iOS `HostedCard`. [origin] names the source tab,
 * shown as the editor subtitle.
 */
enum class HostedCard(
    val raw: String,
    val title: String,
    val origin: String,
    val icon: ImageVector,
) {
    /** Sleep tab · "Sleep marks" — the tap-to-log going-to-sleep / awake card. Self-contained (logging
     *  only, no model), the first card wired end-to-end. */
    SLEEP_MARKS("sleep.sleepMarks", "Sleep marks", "Sleep", Icons.Filled.Bedtime);

    companion object {
        fun fromRaw(raw: String?): HostedCard? = entries.firstOrNull { it.raw == raw }

        /** The default selection: EMPTY. Nothing is hosted until the user opts in. Mirrors iOS. */
        val defaultSelection: List<HostedCard> = emptyList()

        /** Canonical order used to list the not-yet-hosted remainder in the editor (matches iOS allCases). */
        val canonicalOrder: List<HostedCard> = entries.toList()
    }
}

/**
 * Display-only persistence for the Today-hosted card selection. Holds an ORDERED list of the enabled
 * hosted cards as a JSON-encoded array of ids; a card not in the list is not hosted. Stored in
 * SharedPreferences under "today.hostedCards" and whitelisted into .noopbak. Mirrors [DashboardCardPrefs]
 * byte-for-byte EXCEPT the default is EMPTY — hosting is purely additive/opt-in, so a fresh install (and
 * every existing user) hosts nothing until they add a card in Customise. Mirrors iOS HostedCardPrefs.
 */
object HostedCardPrefs {
    /** The SharedPreferences / canonical backup key. Public so the `.noopbak` bridge can reference it
     *  instead of a magic string. Byte-identical to the iOS `HostedCardPrefs.selectionKey`. */
    const val KEY_SELECTION = "today.hostedCards"

    /** The hosted cards in display order. An empty/unset value yields the EMPTY default (nothing hosted). */
    fun enabled(context: Context): List<HostedCard> =
        decodeEnabled(NoopPrefs.of(context).getString(KEY_SELECTION, null))

    /** Persist the hosted cards in order. Cards not hosted are simply omitted from the stored string. */
    fun setEnabled(context: Context, cards: List<HostedCard>) {
        NoopPrefs.of(context).edit().putString(KEY_SELECTION, encode(cards)).apply()
    }

    /** Encode an ordered list of hosted cards into the stored JSON-array string (matches the iOS form). */
    fun encode(cards: List<HostedCard>): String {
        val arr = JSONArray()
        cards.forEach { arr.put(it.raw) }
        return arr.toString()
    }

    /**
     * Decode the stored string into an ordered list of hosted cards. An empty/unset string yields the
     * EMPTY default (nothing hosted). Accepts both the JSON-array form (canonical) and a legacy
     * comma-joined form. Unknown ids are dropped; duplicates de-duped; returns ONLY the hosted cards in
     * their saved order. Unlike [DashboardCardPrefs], an all-unknown decode stays EMPTY (never back-fills
     * a default), because there is no sensible non-empty default for an opt-in surface. Mirrors iOS.
     */
    fun decodeEnabled(raw: String?): List<HostedCard> {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return HostedCard.defaultSelection

        val ids: List<String> = parseJsonArray(trimmed)
            ?: trimmed.split(",").map { it.trim() }

        val seen = LinkedHashSet<HostedCard>()
        ids.forEach { token -> HostedCard.fromRaw(token)?.let { seen.add(it) } }
        return seen.toList()
    }

    private fun parseJsonArray(s: String): List<String>? = runCatching {
        val arr = JSONArray(s)
        (0 until arr.length()).map { arr.getString(it) }
    }.getOrNull()
}
