package com.noop.ui

import android.content.Context
import java.util.Calendar
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Message
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.ui.graphics.vector.ImageVector

/** Haptic shapes exposed to the notification UI. */
internal enum class BuzzPattern(val label: String, val loops: Int) {
    Single("Single", 1),
    Double("Double", 2),
    Triple("Triple", 3),
    Long("Long", 5),
}

internal enum class NotifCategory(
    val title: String,
    val icon: ImageVector,
    val defaultPattern: BuzzPattern,
) {
    Calls("Calls", Icons.Filled.Message, BuzzPattern.Triple),
    Messaging("Messages", Icons.AutoMirrored.Filled.Chat, BuzzPattern.Single),
    Email("Email", Icons.Filled.Email, BuzzPattern.Double),
    Meetings("Meetings", Icons.Filled.Videocam, BuzzPattern.Triple),
    Calendar("Calendar", Icons.Filled.CalendarMonth, BuzzPattern.Double),
}

internal data class NotifApp(
    val id: String,
    val name: String,
    val category: NotifCategory,
    val glyph: ImageVector,
)

internal val notifCatalog: List<NotifApp> = listOf(
    NotifApp("com.whatsapp", "WhatsApp", NotifCategory.Messaging, Icons.AutoMirrored.Filled.Chat),
    NotifApp("org.telegram.messenger", "Telegram", NotifCategory.Messaging, Icons.AutoMirrored.Filled.Chat),
    NotifApp("com.google.android.apps.messaging", "Messages", NotifCategory.Messaging, Icons.Filled.Message),
    NotifApp("com.Slack", "Slack", NotifCategory.Messaging, Icons.AutoMirrored.Filled.Chat),
    NotifApp("com.microsoft.teams", "Microsoft Teams", NotifCategory.Messaging, Icons.AutoMirrored.Filled.Chat),
    NotifApp("com.google.android.gm", "Gmail", NotifCategory.Email, Icons.Filled.Email),
    NotifApp("com.microsoft.office.outlook", "Outlook", NotifCategory.Email, Icons.Filled.Email),
    NotifApp("us.zoom.videomeetings", "Zoom", NotifCategory.Meetings, Icons.Filled.Videocam),
    NotifApp("com.google.android.calendar", "Calendar", NotifCategory.Calendar, Icons.Filled.CalendarMonth),
)

internal object NotifPrefs {
    private const val FILE = "noop_notif_prefs"
    const val MASTER = "notif.masterEnabled"
    const val ALL_OTHER = "notif.allOtherApps"
    const val WORN = "notif.onlyWhenWorn"
    const val QUIET = "notif.quietHoursEnabled"
    const val QUIET_START = "notif.quietStartMinutes"
    const val QUIET_END = "notif.quietEndMinutes"
    const val CALLS_MASTER = "notif.calls.masterEnabled"
    const val CALLS_PHONE = "notif.calls.phoneEnabled"
    const val CALLS_VOIP = "notif.calls.voipEnabled"
    const val CALLS_PATTERN = "notif.calls.pattern"
    const val ALARM_TIMER = "notif.alarmTimer"

    private fun prefs(ctx: Context) = ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun getBool(ctx: Context, key: String, default: Boolean) = prefs(ctx).getBoolean(key, default)
    fun setBool(ctx: Context, key: String, value: Boolean) = prefs(ctx).edit().putBoolean(key, value).apply()
    fun getInt(ctx: Context, key: String, default: Int) = prefs(ctx).getInt(key, default)
    fun setInt(ctx: Context, key: String, value: Int) = prefs(ctx).edit().putInt(key, value).apply()

    fun appEnabled(ctx: Context, id: String) = prefs(ctx).getBoolean("app.$id.enabled", false)
    fun setAppEnabled(ctx: Context, id: String, value: Boolean) = prefs(ctx).edit().putBoolean("app.$id.enabled", value).apply()

    fun appPattern(ctx: Context, app: NotifApp): BuzzPattern {
        val saved = prefs(ctx).getString("app.${app.id}.pattern", null)
        return BuzzPattern.entries.firstOrNull { it.name == saved } ?: app.category.defaultPattern
    }

    fun setAppPattern(ctx: Context, id: String, pattern: BuzzPattern) =
        prefs(ctx).edit().putString("app.$id.pattern", pattern.name).apply()

    fun appLoops(ctx: Context, pkg: String): Int {
        val saved = prefs(ctx).getString("app.$pkg.pattern", null)
        return BuzzPattern.entries.firstOrNull { it.name == saved }?.loops ?: BuzzPattern.Double.loops
    }

    fun callPattern(ctx: Context): BuzzPattern {
        val saved = prefs(ctx).getString(CALLS_PATTERN, null)
        return BuzzPattern.entries.firstOrNull { it.name == saved } ?: BuzzPattern.Triple
    }

    fun setCallPattern(ctx: Context, pattern: BuzzPattern) =
        prefs(ctx).edit().putString(CALLS_PATTERN, pattern.name).apply()

    fun callLoops(ctx: Context) = callPattern(ctx).loops

    fun inQuietHours(ctx: Context): Boolean {
        if (!getBool(ctx, QUIET, false)) return false
        val start = getInt(ctx, QUIET_START, 22 * 60)
        val end = getInt(ctx, QUIET_END, 7 * 60)
        val nowCal = Calendar.getInstance()
        val now = nowCal.get(Calendar.HOUR_OF_DAY) * 60 + nowCal.get(Calendar.MINUTE)
        return if (start <= end) now in start until end else now >= start || now < end
    }
}
