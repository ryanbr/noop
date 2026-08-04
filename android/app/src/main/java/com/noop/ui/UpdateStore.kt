package com.noop.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

// MARK: - UpdateItem
//
// Kotlin mirror of Strand/Data/UpdateStore.swift's `UpdateItem`. One entry in the "Updates inbox" —
// the bell in the Today header collects these. An item is either purely informational (a What's New
// note, a "new data" reading) or actionable (a deep link to a screen, or a dismissed Today card the
// user can restore). Everything stays on-device; nothing here is medical, identifying, or a verdict
// — just a calm log of what's new in the app and the data.

/** The flavour of update — drives the row's tinted icon and behaviour. Storage strings match the
 *  Swift `UpdateItem.Kind` raw values exactly, so a future export/import round-trips. */
enum class UpdateKind(val storageValue: String) {
    /** a Today info-card the user swiped into the inbox (restorable) */
    DISMISSED_CARD("dismissedCard"),

    /** a release note (seeded from AppChangelog on first run after an update) */
    WHATS_NEW("whatsNew"),

    /** new data arrived (e.g. "N days backfilled") — links to Trends */
    READING("reading"),

    /** a strap-side heads-up (low battery, sync) — informational */
    STRAP_ALERT("strapAlert");

    companion object {
        fun fromStorage(raw: String?): UpdateKind =
            entries.firstOrNull { it.storageValue == raw } ?: WHATS_NEW
    }
}

/**
 * One inbox entry. Mirrors the Swift `UpdateItem` struct field-for-field.
 *
 * @property deepLink Optional route key the inbox navigates to when tapped (null = purely
 *   informational). Matches a nav route string (e.g. "trends"); an unknown key just closes the sheet.
 * @property restorePayload For [UpdateKind.DISMISSED_CARD] only: the Today card id to restore (the
 *   stable suffix of the dismissed-flag pref key). "Restore to Today" flips that flag back.
 */
data class UpdateItem(
    val id: String = UUID.randomUUID().toString(),
    val kind: UpdateKind,
    val title: String,
    val message: String,
    /** Epoch millis the item was posted — drives newest-first ordering and the relative time. */
    val date: Long = System.currentTimeMillis(),
    val read: Boolean = false,
    val deepLink: String? = null,
    val restorePayload: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("kind", kind.storageValue)
        put("title", title)
        put("message", message)
        put("date", date)
        put("read", read)
        if (deepLink != null) put("deepLink", deepLink)
        if (restorePayload != null) put("restorePayload", restorePayload)
    }

    companion object {
        fun fromJson(o: JSONObject): UpdateItem = UpdateItem(
            id = o.optString("id", UUID.randomUUID().toString()),
            kind = UpdateKind.fromStorage(if (o.has("kind")) o.optString("kind") else null),
            title = o.optString("title", ""),
            message = o.optString("message", ""),
            date = o.optLong("date", System.currentTimeMillis()),
            read = o.optBoolean("read", false),
            deepLink = if (o.has("deepLink")) o.optString("deepLink") else null,
            restorePayload = if (o.has("restorePayload")) o.optString("restorePayload") else null,
        )
    }
}

// MARK: - Today card dismissal keys (shared)
//
// The Today info-cards persist their dismissed state under a stable per-card key. The inbox restores
// a card by clearing that same key, so the key shape lives in ONE place both sides use. Mirrors the
// Swift `TodayCardDismissal` enum. Stable card ids ("scoresBuilding", "newHere") match macOS/iOS.
object TodayCardDismissal {
    const val FILE = "noop_today_cards"

    /** The dismissed-flag pref key for a Today info-card, by stable card id. */
    fun flagKey(cardId: String): String = "noop.todayCard.$cardId.dismissed"

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** Whether [cardId] has been dismissed into the inbox (default false = the card is shown). */
    fun isDismissed(ctx: Context, cardId: String): Boolean =
        prefs(ctx).getBoolean(flagKey(cardId), false)

    /** Set/clear the dismissed flag for [cardId]. Restore from the inbox passes false. */
    fun setDismissed(ctx: Context, cardId: String, dismissed: Boolean) {
        prefs(ctx).edit().putBoolean(flagKey(cardId), dismissed).apply()
    }
}

// MARK: - New-data watermark (shared, #521)
//
// The persisted NEWEST day-key (max yyyy-MM-dd in the merged history) the Today inbox has already
// announced as "New data added". TodayScreen compares the live newest key against this watermark and
// only posts when it moves STRICTLY forward — so a background recompute's delete-then-reinsert churn
// (which dips/recovers the row COUNT but not the newest key) never re-announces, and a relaunch over
// the same history stays silent. Persisted (not Compose `remember`) so it survives process death,
// mirroring the Swift `@AppStorage("today.lastAnnouncedDayKey")`.
object NewDataWatermark {
    private const val FILE = "noop_today_newdata"
    private const val KEY_NEWEST = "today.lastAnnouncedDayKey"

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** The last newest day-key announced, or "" when no baseline exists yet (first ever load). */
    fun lastAnnouncedKey(ctx: Context): String =
        prefs(ctx).getString(KEY_NEWEST, "").orEmpty()

    /** Record [key] as the newest day-key seen, so only a strictly-greater key fires a future announce. */
    fun setLastAnnouncedKey(ctx: Context, key: String) {
        prefs(ctx).edit().putString(KEY_NEWEST, key).apply()
    }
}

// MARK: - UpdateStore
//
// The bell's backing store: a single-user, on-device inbox of [UpdateItem]s persisted as a JSON array
// in SharedPreferences. Kotlin mirror of the Swift `UpdateStore` singleton — the same lightweight
// persist-the-whole-list-on-every-mutation approach, just over `org.json` instead of Codable. A
// process singleton ([from]) so any surface (the Today cards, the import path) posts to the SAME
// inbox the UI observes.
//
// The item list is a Compose `mutableStateListOf`, so reads in a composable recompose automatically
// on every mutation — the same snapshot-state idiom `AppearancePrefs`/`ChartStylePrefs` use for a
// scalar, here over a list.
//
// First-run seeding: posts the current What's New (AppChangelog.releases.first) once, tracking
// `lastSeededWhatsNewVersion` so the same version is never double-posted across launches.
class UpdateStore private constructor(private val prefs: SharedPreferences) {

    /** The inbox, in insertion order. Snapshot state — every `Palette`-style read recomposes on
     *  mutation. Newest-first ordering is derived at read time ([sortedItems]). */
    val items: androidx.compose.runtime.snapshots.SnapshotStateList<UpdateItem> = mutableStateListOf()

    /** A restore signal TodayScreen observes: set to a card id when "Restore to Today" is tapped, so
     *  the Today screen (which holds the dismissed flags in local state) can flip the matching flag
     *  back. Cleared by the observer once handled. Mirrors the Swift `restoreRequest`. */
    var restoreRequest: String? by mutableStateOf(null)

    init {
        load()
    }

    // MARK: Derived

    /** Items newest-first (the inbox list order). */
    val sortedItems: List<UpdateItem> get() = items.sortedByDescending { it.date }

    /** How many unread — drives the bell badge. */
    val unreadCount: Int get() = items.count { !it.read }

    // MARK: Mutations

    /** Add a new item (unread). Informational rows ([UpdateKind.READING]/[UpdateKind.WHATS_NEW]) are
     *  deduped and capped (#521): an identical informational post (same kind + deepLink) within
     *  [DEDUP_WINDOW_MS] of an existing one just refreshes that row's date (and re-arms its unread badge)
     *  instead of appending a duplicate, and the informational backlog is trimmed to [MAX_ITEMS] newest.
     *  Actionable rows ([UpdateKind.DISMISSED_CARD]/[UpdateKind.STRAP_ALERT]) always append and are never
     *  auto-evicted. Mirrors the Swift `UpdateStore.post`. */
    fun post(item: UpdateItem) {
        val dup = if (isInformational(item.kind)) {
            items.indexOfFirst {
                it.kind == item.kind && it.deepLink == item.deepLink &&
                    (item.date - it.date) in 0 until DEDUP_WINDOW_MS
            }
        } else -1
        if (dup >= 0) {
            // Collapse into the existing row: bump its date + message, re-mark unread so the badge shows.
            items[dup] = items[dup].copy(
                title = item.title, message = item.message, date = item.date, read = false,
            )
        } else {
            items.add(item)
        }
        evictOverflow()
        persist()
    }

    private fun isInformational(kind: UpdateKind): Boolean =
        kind == UpdateKind.READING || kind == UpdateKind.WHATS_NEW

    /** Trim the informational backlog to the newest [MAX_ITEMS]. Actionable rows
     *  ([UpdateKind.DISMISSED_CARD]/[UpdateKind.STRAP_ALERT]) are exempt — only READING/WHATS_NEW are
     *  auto-evicted, oldest first. Mirrors the Swift `evictOverflow`. */
    private fun evictOverflow() {
        val informationalCount = items.count { isInformational(it.kind) }
        if (informationalCount <= MAX_ITEMS) return
        var toRemove = informationalCount - MAX_ITEMS
        val removeIds = mutableSetOf<String>()
        for (it in items.sortedBy { it.date }) {           // oldest first
            if (toRemove <= 0) break
            if (isInformational(it.kind)) {
                removeIds.add(it.id)
                toRemove--
            }
        }
        if (removeIds.isNotEmpty()) items.removeAll { it.id in removeIds }
    }

    /** Mark one item read (no-op if already read / not found). */
    fun markRead(id: String) {
        val i = items.indexOfFirst { it.id == id }
        if (i < 0 || items[i].read) return
        items[i] = items[i].copy(read = true)
        persist()
    }

    /** Mark every item read. */
    fun markAllRead() {
        if (items.none { !it.read }) return
        for (i in items.indices) {
            if (!items[i].read) items[i] = items[i].copy(read = true)
        }
        persist()
    }

    /** Remove one item (e.g. after restoring a dismissed card). */
    fun remove(id: String) {
        val removed = items.removeAll { it.id == id }
        if (removed) persist()
    }

    /** Empty the inbox. */
    fun clearAll() {
        if (items.isEmpty()) return
        items.clear()
        persist()
    }

    // MARK: Seeding

    /**
     * Post the current What's New as a [UpdateKind.WHATS_NEW] item ONCE per version. Idempotent:
     * tracks the last version it seeded in prefs, so a relaunch on the same version never
     * double-posts. Call on app start, after the changelog version is known. Mirrors the Swift
     * `seedWhatsNewIfNeeded`.
     */
    fun seedWhatsNewIfNeeded(
        version: String = AppChangelog.CURRENT_VERSION,
        title: String = AppChangelog.releases.firstOrNull()?.title ?: "",
    ) {
        if (version.isEmpty()) return
        if (prefs.getString(KEY_LAST_SEEDED, null) == version) return
        // Mark seeded FIRST so a re-entrant call (or a crash mid-post) can't double-post this version.
        prefs.edit().putString(KEY_LAST_SEEDED, version).apply()

        post(
            UpdateItem(
                kind = UpdateKind.WHATS_NEW,
                title = if (title.isEmpty()) "What's new in NOOP $version" else title,
                message = "NOOP $version is here — tap to read what's new.",
                // #984: this row promised "tap to read what's new" while carrying NO deep link, so the
                // tap resolved to nothing and only marked it read. Every release since the inbox shipped
                // has posted an entry that could not be opened.
                deepLink = WHATS_NEW_DEEP_LINK,
            ),
        )
    }

    // MARK: Persistence

    private fun load() {
        items.clear()
        val raw = prefs.getString(KEY_ITEMS, null) ?: return
        val arr = runCatching { JSONArray(raw) }.getOrNull() ?: return
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            items.add(UpdateItem.fromJson(o))
        }
    }

    private fun persist() {
        val arr = JSONArray()
        items.forEach { arr.put(it.toJson()) }
        prefs.edit().putString(KEY_ITEMS, arr.toString()).apply()
    }

    companion object {
        private const val FILE = "noop_updates"
        private const val KEY_ITEMS = "updates.items"
        private const val KEY_LAST_SEEDED = "updates.lastSeededWhatsNewVersion"

        /** Deep-link key a What's New row routes to (#984). `AppRoot`'s `onDeepLink` maps it to the
         *  changelog sheet; any key it does not know is ignored, so this must stay in step with it. */
        const val WHATS_NEW_DEEP_LINK = "whatsNew"

        /**
         * What a tap on [item] should open, or null when the row is purely informational (#984).
         *
         * Pure and separate from the Compose row so the rule is unit-testable — the store's own I/O is
         * SharedPreferences + org.json and therefore not reachable from a plain JVM test (same
         * constraint `NapStoreTest` documents), so this is the part of the fix that CAN be pinned.
         *
         * The kind fallback exists for rows posted BEFORE the fix: a What's New item already sitting in
         * someone's inbox carries no `deepLink`, and without this it would stay inert until the next
         * release replaced it. New rows carry the key themselves.
         */
        fun deepLinkTarget(item: UpdateItem): String? =
            item.deepLink ?: WHATS_NEW_DEEP_LINK.takeIf { item.kind == UpdateKind.WHATS_NEW }

        /** Inbox guard-rails (#521). Cap the informational ([UpdateKind.READING]/[WHATS_NEW]) backlog and
         *  collapse an identical informational post landing within this window into the existing row, so
         *  background recompute ticks can't grow the inbox unbounded or re-post the same row on a loop. */
        private const val MAX_ITEMS = 50
        private const val DEDUP_WINDOW_MS = 30L * 60L * 1000L   // 30 minutes

        @Volatile
        private var instance: UpdateStore? = null

        /** The app-wide instance, so non-UI code (an import-complete path) posts to the SAME inbox
         *  the UI observes. Matches the `ProfileStore.from` / `SmartAlarmStore.from` accessor shape. */
        fun from(context: Context): UpdateStore =
            instance ?: synchronized(this) {
                instance ?: UpdateStore(
                    context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE),
                ).also { instance = it }
            }
    }
}
