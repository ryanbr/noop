package com.noop.notif

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.provider.Settings

/**
 * Discovery of apps that can notify this phone, backing the per-app wrist-alert picker.
 *
 * Two complementary sources, because Android's package-visibility filtering (API 30+) never gives a
 * single query the full picture:
 *
 *  1. [InstalledNotifierApps] asks the [PackageManager] for apps that declare POST_NOTIFICATIONS.
 *     The manifest's `<queries><intent MAIN/LAUNCHER/></queries>` entry grants visibility to every
 *     launchable app; the filter keeps the ones declaring the notification permission. No
 *     QUERY_ALL_PACKAGES, so the app stays Play-policy-clean.
 *  2. [NotifierAppDiscovery] persists every package the notification listener actually sees post.
 *     This catches apps targeting below API 33, which post notifications WITHOUT declaring
 *     POST_NOTIFICATIONS and are therefore invisible to query (1) — the same notification-access
 *     grant that delivers [NoopNotificationListener.onNotificationPosted] also makes those packages
 *     visible here.
 *
 * The Notifications screen merges both. Everything stays on-device: we record package NAMES only —
 * never notification content, titles, senders, or text.
 */
object NotifierAppDiscovery {

    /** Same prefs file the wrist-alert settings use (see NotifPrefs in NotificationsSettingsScreen). */
    private const val FILE = "noop_notif_prefs"
    private const val KEY_DISCOVERED = "notif.discoveredPackages"

    /**
     * Remember that [packageName] posted a notification. Called from the listener on every post.
     * Cheap no-op for a known package — the write only happens the FIRST time a package is seen,
     * so a chatty app cannot hammer SharedPreferences.
     */
    fun record(ctx: Context, packageName: String) {
        val prefs = ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        val known = prefs.getStringSet(KEY_DISCOVERED, emptySet()) ?: emptySet()
        if (packageName in known) return
        prefs.edit().putStringSet(KEY_DISCOVERED, known + packageName).apply()
    }

    /** Every package the listener has ever seen post a notification on this device. */
    fun discoveredPackages(ctx: Context): Set<String> =
        ctx.applicationContext
            .getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .getStringSet(KEY_DISCOVERED, emptySet())
            ?: emptySet()

    /**
     * Resolve one package to its picker row (label included), or null when it is not installed
     * (or disabled). The App Notifications page uses this to show the opted-in apps the moment it
     * opens, ahead of the full scan. Read OFF the main thread — getApplicationInfo crosses IPC.
     */
    fun appFor(ctx: Context, packageName: String): NotifierApp? {
        val pm = ctx.packageManager
        val info = runCatching { pm.getApplicationInfo(packageName, 0) }.getOrNull() ?: return null
        if (!info.enabled) return null
        return NotifierApp(packageName, labelOf(pm, info))
    }

    /**
     * Is Notification Access granted to THIS app? The grant is per-app: a fresh install does not
     * inherit any other app's grant, and without it the listener service is never
     * bound — no wrist alert can arrive no matter what the picker has toggled. The settings screen
     * shows this so a silent dead link reads as what it is.
     */
    fun notificationAccessGranted(ctx: Context): Boolean {
        // The grant list is a ':'-separated flat of enabled listener components, readable on every
        // API level NOOP supports (the "enabled_notification_listeners" Secure setting, API 22+).
        // The API 29 NotificationManager accessor reads the same list; the flat covers minSdk 26
        // through 35 in one path.
        val flat = Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners")
            ?: return false
        val selfComponent = android.content.ComponentName(ctx, NoopNotificationListener::class.java)
            .flattenToString()
        return flat.split(":").any { it == selfComponent }
    }

    /**
     * The picker list: installed apps that declare the notification permission, plus every
     * discovered poster that is installed — sorted by label. Discovered apps that were
     * uninstalled are dropped (their per-app prefs stay, so a reinstall keeps the user's choice).
     * Read OFF the main thread: [InstalledNotifierApps.list] walks every visible package.
     *
     * The two paths filter system packages differently, on purpose. The enumeration path drops
     * FLAG_SYSTEM so OEM agents and bundled services that never notify the user do not flood the
     * list. The discovered path does NOT: a preinstalled app that has actually posted a
     * notification (Gmail, Samsung Messages, a carrier app) is one the user demonstrably uses, and
     * hiding it would leave a real notifier unpickable. Posting is the evidence; the flag is not.
     */
    fun load(ctx: Context): List<NotifierApp> {
        val installed = InstalledNotifierApps.list(ctx)
        val known = installed.map { it.packageName }.toSet()
        val pm = ctx.packageManager
        val discovered = discoveredPackages(ctx)
            .filter { it !in known && it != ctx.packageName }
            .mapNotNull { pkg ->
                val info = runCatching { pm.getApplicationInfo(pkg, 0) }.getOrNull() ?: return@mapNotNull null
                if (!info.enabled) return@mapNotNull null
                // No FLAG_SYSTEM gate here, unlike the enumeration path: this package has actually
                // posted a notification, which is the signal the feature is built on. Preinstalled
                // mail/messaging apps carry FLAG_SYSTEM on most OEM builds and must stay pickable.
                NotifierApp(pkg, labelOf(pm, info))
            }
        return (installed + discovered).sortedBy { it.label.lowercase() }
    }
}

/** One app the picker can offer. `packageName` is the NotifPrefs persistence key (same key the
 *  notification listener gates on), `label` is the user-visible app name. */
data class NotifierApp(
    val packageName: String,
    val label: String,
)

/**
 * Enumerates installed apps that can post notifications.
 *
 * The pure filter ([filterNotifierCandidates]) is separated from the [PackageManager] plumbing so
 * the selection rule is unit-testable without a device (see NotifierAppDiscoveryTest).
 */
object InstalledNotifierApps {

    /** Permission an app must declare to be offered: the API 33 notification-posting permission. */
    const val POST_NOTIFICATIONS = "android.permission.POST_NOTIFICATIONS"

    /**
     * Installed apps that can notify, sorted by label. Excludes NOOP itself (our own notifications
     * are governed by the Daily-reports card, not the wrist-alert picker).
     */
    fun list(ctx: Context): List<NotifierApp> {
        val pm = ctx.packageManager
        val infos = runCatching { pm.getInstalledPackages(PackageManager.GET_PERMISSIONS) }
            .getOrDefault(emptyList())
        val candidates = infos.map { info ->
            NotifierCandidate(
                packageName = info.packageName,
                requestsPostNotifications = info.requestedPermissions
                    ?.contains(POST_NOTIFICATIONS) == true,
                enabled = info.applicationInfo?.enabled == true,
                systemApp = (info.applicationInfo?.flags ?: 0) and ApplicationInfo.FLAG_SYSTEM != 0,
            )
        }
        return filterNotifierCandidates(candidates, selfPackage = ctx.packageName)
            .map { candidate ->
                // getApplicationLabel can throw on some system packages; the package name is an
                // honest fallback — the picker keys on it, the label is only for reading.
                val label = runCatching {
                    pm.getApplicationLabel(
                        pm.getApplicationInfo(candidate.packageName, 0),
                    ).toString()
                }.getOrDefault(candidate.packageName)
                NotifierApp(candidate.packageName, label)
            }
            .sortedBy { it.label.lowercase() }
    }

    /**
     * Pure selection rule: keep apps that DECLARE the notification-posting permission, are
     * ENABLED, and are USER-INSTALLED (no FLAG_SYSTEM — OEM agents and bundled services are not
     * apps the user installed); drop NOOP's own package. Declaring POST_NOTIFICATIONS is the signal "
     * notify you" — apps that never declare it and never posted are not offered; apps that post
     * without declaring (pre-API-33 targets) arrive through [NotifierAppDiscovery] instead.
     */
    internal fun filterNotifierCandidates(
        candidates: List<NotifierCandidate>,
        selfPackage: String,
    ): List<NotifierCandidate> =
        candidates.filter {
            it.requestsPostNotifications && it.enabled && !it.systemApp && it.packageName != selfPackage
        }
}

/** Plain-data view of one installed package, for the pure filter. */
internal data class NotifierCandidate(
    val packageName: String,
    val requestsPostNotifications: Boolean,
    val enabled: Boolean,
    val systemApp: Boolean = false,
)

/** User-visible app name. getApplicationLabel falls back to the package name when no label
 *  resolves — an honest fallback: the picker keys on the package, the label is only for reading. */
private fun labelOf(pm: PackageManager, info: ApplicationInfo): String =
    runCatching { pm.getApplicationLabel(info).toString() }.getOrDefault(info.packageName)
