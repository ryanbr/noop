package com.noop.ble

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings

/**
 * Android background-survival helpers (#386). NOOP already runs a foreground service + exact alarms,
 * but aggressive OEM battery managers kill even those, so the reliable lever is a USER action:
 * whitelist NOOP from battery optimisation (and, on the worst vendors, enable auto-start). This
 * centralises the detection and the intents that fix it, so the Settings "Keep NOOP alive overnight"
 * toggle and the Test Centre diagnostics share ONE source of truth for the vendor set + exempt check.
 *
 * POPUP DISCIPLINE: nothing here ever fires a system dialog on its own. [batteryExemptionIntent] and
 * [oemAutostartIntent] only build Intents — the caller starts one exactly when the user taps, and the
 * toggle reflects live [isBatteryExempt] state so an already-exempt user is never prompted again.
 *
 * The whitelist adds NO battery cost of its own: it removes a premature kill, it does not add work.
 * The real cost is the existing "Keep connected in the background" / "Continuous HRV" / "Overnight only"
 * toggles; this only makes the overnight work the user already enabled actually survive the night.
 */
object BackgroundHealth {

    /**
     * Manufacturers whose proprietary battery managers kill background work regardless of the AOSP
     * foreground-service contract (the dontkillmyapp.com set). ONE canonical list — [AndroidDiagnostics]
     * and the Settings toggle both read it here so the two can never drift. Pure.
     */
    val AGGRESSIVE_VENDORS: List<String> =
        listOf("xiaomi", "oppo", "vivo", "huawei", "oneplus", "realme", "meizu")

    /** True when [manufacturer] is one whose ROM aggressively kills background apps. Pure + Context-free
     *  so it unit-tests without Robolectric. Defaults to this device's manufacturer. */
    fun isAggressiveVendor(manufacturer: String = Build.MANUFACTURER): Boolean {
        val m = manufacturer.lowercase()
        return AGGRESSIVE_VENDORS.any { m.contains(it) }
    }

    /** True when NOOP is exempt from Doze / battery optimisation — the #1 predictor of overnight survival. */
    fun isBatteryExempt(context: Context): Boolean =
        (context.getSystemService(Context.POWER_SERVICE) as? PowerManager)
            ?.isIgnoringBatteryOptimizations(context.packageName) == true

    /**
     * What the "Keep NOOP alive overnight" row's action should DO, given whether the exemption is granted.
     *
     * This row is NOT a setting: [isBatteryExempt] is read nowhere but the Settings screen itself, and the
     * thing that actually keeps NOOP alive overnight is the Background-connection preference above it. This
     * row reports an Android permission and asks for it.
     *
     * It used to be rendered as a Switch, which was reported as broken — it could be turned on but not off.
     * That was the correct read: Android has no API to revoke an app's own exemption
     * ([Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS] can only ask), so the off direction did
     * nothing and the switch sprang back. The answer is not a cleverer Switch; a bidirectional control was
     * always the wrong shape for a one-way grant. It is now a status line plus a single action, and this is
     * that action.
     */
    enum class BatteryRowAction {
        /** Not yet exempt: the one-tap system grant dialog. */
        RequestExemption,
        /** Already exempt: NOOP's system settings page, where the user can revoke it. */
        OpenAppSettings,
    }

    /** Pure; see [BatteryRowAction]. Total over the only input there is. */
    fun batteryRowAction(isExempt: Boolean): BatteryRowAction =
        if (isExempt) BatteryRowAction.OpenAppSettings else BatteryRowAction.RequestExemption

    /**
     * The one-tap system dialog to whitelist NOOP from battery optimisation. Sideload-only intent
     * (Play restricts it; NOOP doesn't ship there). Build-only — the caller starts it on a user tap and
     * falls back to [appBatterySettingsIntent] if a ROM hides this action.
     */
    fun batteryExemptionIntent(context: Context): Intent =
        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            .setData(Uri.parse("package:${context.packageName}"))

    /** Always-resolvable fallback: NOOP's per-app system settings page (Battery lives under it). */
    fun appBatterySettingsIntent(context: Context): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.parse("package:${context.packageName}"))

    /**
     * Best-effort deep-link to the OEM's proprietary auto-start / protected-app screen — the setting the
     * generic exemption can't reach on these ROMs. Component names DRIFT per ROM version, so each is tried
     * with [packageManager.resolveActivity] and the first that resolves wins; null → the caller uses the
     * generic battery screen. This is a SECOND, separate action (never chained onto the exemption dialog),
     * so a single user tap never spawns two popups. Never throws.
     */
    fun oemAutostartIntent(context: Context): Intent? {
        val m = Build.MANUFACTURER.lowercase()
        val candidates: List<Pair<String, String>> = when {
            m.contains("xiaomi") -> listOf(
                "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity")
            m.contains("oppo") || m.contains("realme") -> listOf(
                "com.coloros.safecenter" to "com.coloros.safecenter.startupapp.StartupAppListActivity",
                "com.oppo.safe" to "com.oppo.safe.permission.startup.StartupAppListActivity")
            m.contains("vivo") -> listOf(
                "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity")
            m.contains("huawei") -> listOf(
                "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity")
            m.contains("meizu") -> listOf(
                "com.meizu.safe" to "com.meizu.safe.permission.SmartBGActivity")
            // OnePlus / recent OxygenOS honours the standard exemption → no dedicated screen.
            else -> emptyList()
        }
        for ((pkg, cls) in candidates) {
            val intent = Intent().setClassName(pkg, cls)
            if (context.packageManager.resolveActivity(intent, 0) != null) return intent
        }
        return null
    }
}
