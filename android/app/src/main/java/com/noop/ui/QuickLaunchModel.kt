package com.noop.ui

import android.content.SharedPreferences
import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CompareArrows
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.CloudSync
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.HealthAndSafety
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.ui.graphics.vector.ImageVector
import com.noop.R

/** A stable Quick Launch identity. Multiple items may intentionally open the same destination. */
internal data class LaunchItem(
    val id: String,
    @StringRes val titleRes: Int,
    val icon: ImageVector,
    val destination: Destination? = null,
    val action: QuickLaunchAction? = null,
) {
    init {
        require((destination == null) != (action == null))
    }
}

/** App-shell actions presented modally instead of owning a navigation route. */
internal enum class QuickLaunchAction {
    Updates,
}

internal data class QuickLaunchPage(
    @StringRes val titleRes: Int,
    val items: List<LaunchItem>,
)

/**
 * Android's platform-appropriate twin of the iOS Quick Launch catalogue. It preserves every destination
 * formerly reachable from Android's More page, while matching the iOS grouping and default favourites.
 */
internal object QuickLaunchCatalog {
    val insights = listOf(
        LaunchItem("insightsHub", R.string.nav_insights_hub, Icons.Filled.Insights, Destination.InsightsHub),
        LaunchItem("intelligence", R.string.nav_intelligence, Icons.Filled.Psychology, Destination.Intelligence),
        LaunchItem("coach", R.string.nav_coach, Icons.Filled.AutoAwesome, Destination.Coach),
        LaunchItem("insights", R.string.nav_insights, Icons.Filled.Insights, Destination.Insights),
        LaunchItem("journal", R.string.quick_launch_journal, Icons.Filled.Edit, Destination.Insights),
        LaunchItem("explore", R.string.nav_explore, Icons.Filled.Explore, Destination.Explore),
        LaunchItem("compare", R.string.nav_compare, Icons.AutoMirrored.Filled.CompareArrows, Destination.Compare),
    )

    val body = listOf(
        LaunchItem("live", R.string.nav_live, Icons.Filled.FavoriteBorder, Destination.Live),
        LaunchItem("workouts", R.string.nav_workouts, Icons.Filled.FitnessCenter, Destination.Workouts),
        LaunchItem("health", R.string.nav_health, Icons.Filled.MonitorHeart, Destination.Health),
        LaunchItem("vitalSigns", R.string.nav_vital_signs, Icons.Filled.HealthAndSafety, Destination.VitalSigns),
        LaunchItem("labBook", R.string.nav_lab_book, Icons.Filled.HealthAndSafety, Destination.LabBook),
        LaunchItem("stress", R.string.nav_stress, Icons.Filled.Spa, Destination.Stress),
        LaunchItem("breathe", R.string.nav_breathe, Icons.Filled.Air, Destination.Breathe),
        LaunchItem("intervals", R.string.nav_intervals, Icons.Filled.Timeline, Destination.Intervals),
        LaunchItem("rhythm", R.string.nav_rhythm, Icons.Filled.MonitorHeart, Destination.Rhythm),
    )

    val data = listOf(
        LaunchItem("fusedRecord", R.string.quick_launch_your_data, Icons.AutoMirrored.Filled.CompareArrows, Destination.FusedRecord),
        LaunchItem("appleHealth", R.string.nav_apple_health, Icons.Filled.HealthAndSafety, Destination.AppleHealth),
        LaunchItem("devices", R.string.nav_devices, Icons.Filled.Sensors, Destination.Devices),
        LaunchItem("dataSources", R.string.nav_data_sources, Icons.Filled.Storage, Destination.DataSources),
        LaunchItem("backupSync", R.string.nav_backup_sync, Icons.Filled.CloudSync, Destination.BackupSync),
    )

    val app = listOf(
        LaunchItem("alarms", R.string.nav_alarms, Icons.Filled.Alarm, Destination.SmartAlarm),
        LaunchItem("automations", R.string.nav_automations, Icons.Filled.Bolt, Destination.Automations),
        LaunchItem("notifications", R.string.nav_notifications, Icons.Filled.Notifications, Destination.Notifications),
        LaunchItem(
            id = "updates",
            titleRes = R.string.l10n_app_root_updates_c76d1807,
            icon = Icons.Filled.Notifications,
            action = QuickLaunchAction.Updates,
        ),
        LaunchItem("testCentre", R.string.nav_test_centre, Icons.Filled.BugReport, Destination.TestCentre),
        LaunchItem("settings", R.string.nav_settings, Icons.Filled.Settings, Destination.Settings),
    )

    val all: List<LaunchItem> = insights + body + data + app
    val byId: Map<String, LaunchItem> = all.associateBy(LaunchItem::id)
    val pages = listOf(
        QuickLaunchPage(R.string.quick_launch_insights, insights),
        QuickLaunchPage(R.string.quick_launch_body, body),
        QuickLaunchPage(R.string.quick_launch_data, data),
        QuickLaunchPage(R.string.quick_launch_app, app),
    )
}

/** Fixed-slot persistence shared in shape and defaults with iOS's `noop.launchFavourites`. */
internal object QuickLaunchPrefs {
    const val KEY = "noop.launchFavourites"
    const val SLOT_COUNT = 9
    const val DEFAULT_CSV =
        "settings,backupSync,workouts,stress,coach,journal,automations,alarms,compare"

    val defaultSlots: List<String?> get() = decode(DEFAULT_CSV)

    fun read(prefs: SharedPreferences): List<String?> =
        prefs.getString(KEY, null)?.let(::decode) ?: defaultSlots

    fun write(prefs: SharedPreferences, slots: List<String?>) {
        prefs.edit().putString(KEY, encode(slots)).apply()
    }

    fun encode(slots: List<String?>): String = normalize(slots).joinToString(",") { it.orEmpty() }

    /** Parse CSV manually so leading, interior, and trailing empty slots remain real positions. */
    fun decode(raw: String): List<String?> {
        val tokens = mutableListOf<String?>()
        var start = 0
        for (index in raw.indices) {
            if (raw[index] == ',') {
                tokens += raw.substring(start, index).trim().ifEmpty { null }
                start = index + 1
            }
        }
        tokens += raw.substring(start).trim().ifEmpty { null }
        return normalize(tokens)
    }

    fun normalize(slots: List<String?>): List<String?> =
        slots.take(SLOT_COUNT).map { it?.trim()?.ifEmpty { null } }.let { trimmed ->
            trimmed + List(SLOT_COUNT - trimmed.size) { null }
        }

    fun swap(slots: List<String?>, from: Int, to: Int): List<String?> {
        if (from !in 0 until SLOT_COUNT || to !in 0 until SLOT_COUNT || from == to) return normalize(slots)
        return normalize(slots).toMutableList().apply {
            val moving = this[from]
            this[from] = this[to]
            this[to] = moving
        }
    }

    fun remove(slots: List<String?>, index: Int): List<String?> =
        normalize(slots).toMutableList().apply { if (index in indices) this[index] = null }

    fun addFirstEmpty(slots: List<String?>, id: String): List<String?> {
        val result = normalize(slots).toMutableList()
        if (id in result) return result
        val empty = result.indexOfFirst { it == null }
        if (empty >= 0) result[empty] = id
        return result
    }
}
