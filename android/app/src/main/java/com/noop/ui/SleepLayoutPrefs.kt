package com.noop.ui

import android.content.Context

// MARK: - Reorderable Sleep sections (#sleep-layout)
//
// The Sleep tab's analytical cards — Sleep marks, the Stages hypnogram, Naps, Night detail, the Sleep-debt
// ledger, Stages-vs-typical, and the Asleep-duration trend — render in one fixed order below the pinned
// Sleep-performance hero + date navigator. This lets the user REORDER or HIDE those cards, mirroring the
// Today tab's Arrange sheet (see TodayLayoutPrefs), with the default being the original order so nothing
// changes for anyone who never customizes Sleep. Display-only — no metric is computed or stored
// differently; this only decides which already-built cards render and in what sequence.
//
// Stored as a single comma-joined string of section keys in SharedPreferences ("sleep.sectionOrder"), the
// same mechanism TodayLayoutPrefs/KeyMetricPrefs use. Mirrors the macOS SleepLayoutPrefs.swift +
// @AppStorage("sleep.sectionOrder"). Every known section stays in the order registry: unknown tokens are
// dropped, and missing known sections are inserted at their default positions. Explicit reversible
// visibility lives separately in "sleep.hiddenSections", byte-identical to the Apple-platform key.

/**
 * One reorderable Sleep card. The [raw] is the stable persisted identifier — keep it byte-identical to the
 * macOS `SleepSection` enum so a backup/restore reads the same layout on either OS.
 */
enum class SleepSection(val raw: String, val title: String) {
    SLEEP_MARKS("sleepMarks", "Sleep marks"),
    STAGES("stages", "Stages"),
    NIGHT_DETAIL("nightDetail", "Night detail"),
    SLEEP_DEBT("sleepDebt", "Sleep-debt ledger"),
    STAGES_VS_TYPICAL("stagesVsTypical", "Stages vs typical"),
    ASLEEP_DURATION("asleepDuration", "Asleep duration"),

    /** #sleep-layout: two ANDROID-ONLY detail cards (Hours-vs-Needed + Consistency, richer than the
     *  Night-detail grid tiles) — previously pinned below the arrange region, now first-class arrangeable
     *  Sleep sections. iOS deliberately renders these metrics only as Night-detail grid tiles (tap-through),
     *  so these two rawValues are Android-only — the macOS `SleepSection` stops at `asleepDuration`. Safe to
     *  diverge here: `sleep.sectionOrder` is not in the .noopbak whitelist, so a cross-OS restore never
     *  reads them. (Consistency's underlying score also differs across platforms — a separate parity item.) */
    HOURS_VS_NEEDED("hoursVsNeeded", "Hours vs needed"),
    CONSISTENCY("consistency", "Consistency");

    companion object {
        fun fromRaw(raw: String?): SleepSection? = entries.firstOrNull { it.raw == raw }

        /** The original, hard-coded card order — the default when the layout isn't customised. Matches the
         *  pre-customisation render order in SleepScreen below the pinned Sleep-performance hero. (Naps
         *  rides with Stages for now — drawn inside the stages hero; making it an independently arrangeable
         *  card is a follow-up that requires hoisting the hero's edit/delete callbacks.) */
        val defaultOrder: List<SleepSection> = listOf(
            SLEEP_MARKS, STAGES, NIGHT_DETAIL, SLEEP_DEBT, STAGES_VS_TYPICAL, ASLEEP_DURATION,
            HOURS_VS_NEEDED, CONSISTENCY,
        )
    }
}

/**
 * Display-only persistence for the Sleep card order and explicit hidden set. Every known card remains in
 * the order registry, while visibility is stored separately so hiding stays reversible. SharedPreferences
 * isn't reactive, so Sleep reads this into remembered state and refreshes it after save. Mirrors the
 * Apple-platform SleepLayoutPrefs, a direct twin of TodayLayoutPrefs with a `sleep.` key namespace.
 */
object SleepLayoutPrefs {
    private const val KEY_ORDER = "sleep.sectionOrder"
    private const val KEY_HIDDEN = "sleep.hiddenSections"

    /** Every known card in display order (saved order first, then any newly-added card at its default position). */
    fun order(context: Context): List<SleepSection> =
        decodeOrder(NoopPrefs.of(context).getString(KEY_ORDER, null))

    /** Persist the card order. */
    fun setOrder(context: Context, sections: List<SleepSection>) {
        NoopPrefs.of(context).edit().putString(KEY_ORDER, encode(sections)).apply()
    }

    /** The explicitly hidden cards in their editor order. Empty/unset means every card is visible. */
    fun hidden(context: Context): List<SleepSection> =
        decodeHidden(NoopPrefs.of(context).getString(KEY_HIDDEN, null))

    /** Persist the explicit reversible hidden list. */
    fun setHidden(context: Context, sections: List<SleepSection>) {
        NoopPrefs.of(context).edit().putString(KEY_HIDDEN, encodeHidden(sections)).apply()
    }

    /** Encode an ordered list of cards into the stored comma-joined string. */
    fun encode(sections: List<SleepSection>): String = sections.joinToString(",") { it.raw }

    fun encodeHidden(sections: List<SleepSection>): String = sections.joinToString(",") { it.raw }

    /**
     * Decode the stored string into the FULL ordered card list. An empty/unset string yields the default
     * order. Unknown tokens are ignored, duplicates collapsed, and any known card missing from the saved
     * order is INSERTED at its default-order position relative to the saved cards (before the first saved
     * card that follows it in the default order; appended when none does) — so every card always renders,
     * and one added in a later app version surfaces where users expect it instead of teleporting to the
     * bottom of an existing saved order.
     */
    fun decodeOrder(raw: String?): List<SleepSection> {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return SleepSection.defaultOrder
        val saved = ArrayList<SleepSection>()
        trimmed.split(",").forEach { token ->
            SleepSection.fromRaw(token.trim())?.let { if (it !in saved) saved.add(it) }
        }
        if (saved.isEmpty()) return SleepSection.defaultOrder
        // Iterate entries (not defaultOrder) so a future enum case accidentally left out of defaultOrder
        // can never be silently hidden; a card without a default index sorts after everything. Twin of the
        // Swift decodeOrder's degraded path; defaultOrder covering every entry is pinned by the tests.
        fun defIdx(s: SleepSection): Int =
            SleepSection.defaultOrder.indexOf(s).let { if (it == -1) SleepSection.defaultOrder.size else it }
        for (missing in SleepSection.entries) {
            if (missing in saved) continue
            val insertAt = saved.indexOfFirst { defIdx(it) > defIdx(missing) }
            if (insertAt == -1) saved.add(missing) else saved.add(insertAt, missing)
        }
        return saved
    }

    /**
     * Decode only explicitly hidden cards. Unknown tokens are ignored and duplicates collapsed. Missing
     * entries stay visible, so a card added by a future release automatically surfaces.
     */
    fun decodeHidden(raw: String?): List<SleepSection> {
        val hidden = LinkedHashSet<SleepSection>()
        raw?.split(",")?.forEach { token -> SleepSection.fromRaw(token.trim())?.let(hidden::add) }
        return hidden.toList()
    }

    /** The full saved order filtered by the explicit hidden set. */
    fun visibleOrder(orderRaw: String?, hiddenRaw: String?): List<SleepSection> {
        val hidden = decodeHidden(hiddenRaw).toSet()
        return decodeOrder(orderRaw).filterNot { it in hidden }
    }
}
