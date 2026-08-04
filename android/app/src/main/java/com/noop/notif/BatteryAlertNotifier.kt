package com.noop.notif

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.R
import com.noop.ui.NoopPrefs
import com.noop.ui.appLaunchIntent

/**
 * Pure battery-alert decision logic so it's JVM-testable (IllnessAlertPolicy idiom). The two
 * `*Alerted` flags are PERSISTED state (NoopPrefs), so the decision survives process death — no
 * in-memory previous-pct crossing, which would re-fire on every 15↔14 jitter and reset on restart.
 *
 * A 25% re-arm band (hysteresis) means a battery hovering near 15% fires the low alert exactly once
 * per discharge cycle; the full alert re-arms only after the cell drops back below 100%.
 */
internal object BatteryAlertPolicy {
    const val LOW_THRESHOLD = 15
    const val LOW_REARM_ABOVE = 25
    const val FULL_THRESHOLD = 100

    data class Decision(
        val fireLow: Boolean,
        val fireFull: Boolean,
        val clearFull: Boolean,
        val newLowAlerted: Boolean,
        val newFullAlerted: Boolean,
    )

    /**
     * @param pct          current strap battery percentage (rounded to Int)
     * @param charging     charging state (null = unknown)
     * @param lowAlerted   persisted: has the low alert already fired this discharge cycle?
     * @param fullAlerted  persisted: has the full alert already fired since the last drop below 100?
     *
     * `clearFull` (#514): the strap was showing a "fully charged" notification and has now dropped
     * below 100% — the standing note is stale, so cancel it. It's exactly the full re-arm
     * transition (fullAlerted && pct < FULL_THRESHOLD), surfaced so the notifier can pull the
     * delivered full-charge notification by its id.
     */
    fun evaluate(pct: Int, charging: Boolean?, lowAlerted: Boolean, fullAlerted: Boolean): Decision {
        var low = lowAlerted
        var full = fullAlerted
        // The stale 100%-full note must be cleared the moment we re-arm below the full line.
        val clearFull = fullAlerted && pct < FULL_THRESHOLD
        // Re-arm (hysteresis) so jitter near a threshold can't re-fire. #80: re-arm ONLY on genuine recovery
        // (pct >= LOW_REARM_ABOVE), NOT on charging. The strap reports its charge bit only every ~8 min, so
        // it flickers true→null; re-arming on `true` then firing on the `null` gap re-fired the low alert
        // repeatedly WHILE charging. `fireLow`'s `charging != true` still suppresses an explicit charging
        // reading, and a null-charging strap (generic/FTMS) still alerts.
        if (pct >= LOW_REARM_ABOVE) low = false
        if (pct < FULL_THRESHOLD) full = false
        // Fire at most once per genuine crossing.
        val fireLow = !low && pct <= LOW_THRESHOLD && charging != true
        val fireFull = !full && pct >= FULL_THRESHOLD
        if (fireLow) low = true
        if (fireFull) full = true
        return Decision(fireLow, fireFull, clearFull, low, full)
    }
}

/**
 * Posts battery-state alerts — low battery (≤15%) and charge-complete (100%) — as real system
 * notifications. Mirrors [IllnessAlertNotifier]'s pattern: called from WhoopConnectionService on
 * every live-state update, gated behind a user setting and the OS notification permission. The
 * once-per-crossing dedupe lives in [BatteryAlertPolicy] over two persisted NoopPrefs flags.
 *
 * Four alerts now, each with its OWN persisted gate: the 15%/100% SoC pair ([onBatteryUpdate]), the
 * 24 h predictive one ([onRuntimeEstimate]), and two ESCALATIONS ([onCriticalBattery],
 * [onBedtimeRunway]) that exist precisely because the first three latch after firing once — a strap
 * that keeps draining used to go silent exactly when the news got worse.
 *
 * With thanks to @ujix (#368) for the original notification copy and channel.
 */
object BatteryAlertNotifier {
    private const val CHANNEL_ID = "noop_battery_alert"
    // #297: each notifier posts under a DISTINCT id (notify() is tagless, so a shared id silently
    // replaces an undismissed notification). Full map: 4201 connection, 4202 illness, 4203 inactivity,
    // 4204 smart alarm, 4205/4206/4207 battery (runtime/low/full), 4208/4209 scheduled report,
    // 4210 strain target, 4211/4212 battery escalation (critical/bedtime). The two escalation alerts
    // get their own ids on purpose: they must be able to stand BESIDE an undismissed low/runtime
    // notification, since the whole point is that those two have already fired and gone quiet.
    private const val NOTIF_ID_RUNTIME = 4205
    private const val NOTIF_ID_LOW = 4206
    private const val NOTIF_ID_FULL = 4207
    private const val NOTIF_ID_CRITICAL = 4211
    private const val NOTIF_ID_BEDTIME = 4212

    /**
     * Predictive twin of [onBatteryUpdate]: run the runtime estimate against
     * [com.noop.analytics.BatteryEstimator.runtimeAlert] (fire ≤24 h, re-arm ≥36 h — a runtime
     * threshold gives the same warning lead time on a 4.0 and a 5.0/MG, which a fixed SoC line
     * can't) and post at most one notification per discharge cycle. The 15% SoC alert stays as the
     * safety net for straps with no usable estimate (null skips here). Same gating discipline as
     * #368: persisted flag advances even when delivery is deferred; no-ops when battery alerts are
     * off. iOS/macOS twin: BatteryNotifier.onRuntimeEstimate.
     */
    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onRuntimeEstimate(context: Context, remainingHours: Double?, charging: Boolean?) {
        if (remainingHours == null) return
        if (!NoopPrefs.batteryAlerts(context)) return
        if (!NoopPrefs.predictiveBatteryAlerts(context)) return
        runCatching {
            val decision = com.noop.analytics.BatteryEstimator.runtimeAlert(
                remainingHours = remainingHours,
                charging = charging,
                alerted = NoopPrefs.batteryRuntimeAlerted(context),
            )
            // ALWAYS persist the updated gate — re-arming must stick even when nothing fired.
            NoopPrefs.setBatteryRuntimeAlerted(context, decision.newAlerted)
            if (!decision.fire) return
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            val label = com.noop.analytics.BatteryEstimator.label(remainingHours)
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(context.getString(R.string.battery_runtime_title))
                .setContentText(context.getString(R.string.battery_runtime_body, label))
                .setContentIntent(openAppIntent(context))
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()
            NotificationManagerCompat.from(context).notify(NOTIF_ID_RUNTIME, n)
        }
    }

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onBatteryUpdate(context: Context, currPct: Int?, charging: Boolean?) {
        if (currPct == null) return
        if (!NoopPrefs.batteryAlerts(context)) return
        // Defensive: never let a notify() throw (revoked POST_NOTIFICATIONS, OEM quirk) crash a collector.
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            val decision = BatteryAlertPolicy.evaluate(
                pct = currPct,
                charging = charging,
                lowAlerted = NoopPrefs.batteryLowAlerted(context),
                fullAlerted = NoopPrefs.batteryFullAlerted(context),
            )
            if (decision.fireLow) {
                val n = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_heart)
                    .setContentTitle(context.getString(R.string.battery_low_title))
                    .setContentText(context.getString(R.string.battery_low_body))
                    .setContentIntent(openAppIntent(context))
                    .setAutoCancel(true)
                    .setCategory(NotificationCompat.CATEGORY_STATUS)
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .build()
                NotificationManagerCompat.from(context).notify(NOTIF_ID_LOW, n)
            }
            if (decision.fireFull) {
                val n = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_heart)
                    .setContentTitle(context.getString(R.string.battery_full_title))
                    .setContentText(context.getString(R.string.battery_full_body))
                    .setContentIntent(openAppIntent(context))
                    .setAutoCancel(true)
                    .setCategory(NotificationCompat.CATEGORY_STATUS)
                    .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                    .build()
                NotificationManagerCompat.from(context).notify(NOTIF_ID_FULL, n)
            }
            // #514: the strap has dropped below 100% — pull the stale "fully charged" note so it
            // can't linger after the cell discharges. cancel() covers a posted notification; a
            // not-yet-shown one simply no-ops.
            if (decision.clearFull) {
                NotificationManagerCompat.from(context).cancel(NOTIF_ID_FULL)
            }
            // ALWAYS persist the updated flags — re-arming must stick even when nothing fired.
            NoopPrefs.setBatteryLowAlerted(context, decision.newLowAlerted)
            NoopPrefs.setBatteryFullAlerted(context, decision.newFullAlerted)
        }
    }

    /**
     * CRITICAL low-battery escalation — the second alert below the 15% one ([onBatteryUpdate] fires at
     * [BatteryAlertPolicy.LOW_THRESHOLD], this at [com.noop.analytics.BatteryEstimator.criticalSocPct]).
     *
     * Why a whole second alert rather than a lower first threshold: on the reference incident the
     * user's device flags show BOTH the 15% alert and the 24 h predictive alert had already fired —
     * and both then LATCHED (`lowAlerted` until 25%, `runtimeAlerted` until a 36 h estimate). So the
     * last ~3 h of the discharge, from 15% down to the ~10% cutoff, passed in total silence and cost
     * a night of biometrics. This gate is independent of both: KEY_BATTERY_CRITICAL_ALERTED is its own
     * key, so a latched low/runtime alert cannot suppress it. Same discipline as #368 otherwise —
     * self-gates on the setting, advances the persisted flag even when delivery is deferred, once per
     * cycle. iOS/macOS twin: BatteryNotifier.onCriticalBattery.
     *
     * Rides the plain battery-alerts toggle, NOT the predictive sub-gate: this is a measured SoC
     * crossing like the 15% alert, not a forecast.
     */
    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onCriticalBattery(context: Context, currPct: Int?, charging: Boolean?) {
        if (currPct == null) return
        if (!NoopPrefs.batteryAlerts(context)) return
        runCatching {
            val decision = com.noop.analytics.BatteryEstimator.criticalAlert(
                pct = currPct,
                charging = charging,
                alerted = NoopPrefs.batteryCriticalAlerted(context),
            )
            // ALWAYS persist the updated gate — re-arming must stick even when nothing fired.
            NoopPrefs.setBatteryCriticalAlerted(context, decision.newAlerted)
            if (!decision.fire) return
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            val body = context.getString(R.string.battery_critical_body, currPct)
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(context.getString(R.string.battery_critical_title))
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(openAppIntent(context))
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                // Android's nearest equivalent of the Swift `.timeSensitive` interruption level is
                // channel importance, and the shared battery channel is already IMPORTANCE_HIGH, so
                // both escalation alerts heads-up like the rest. There is no per-notification
                // time-sensitive flag: actually piercing Do Not Disturb needs channel setBypassDnd(),
                // which requires user-granted notification-policy access — not something an alert may
                // take for itself. So: same channel, PRIORITY_HIGH, no DND bypass.
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()
            NotificationManagerCompat.from(context).notify(NOTIF_ID_CRITICAL, n)
        }
    }

    /**
     * BEDTIME night-guard — "this won't last the night", delivered while there is still time to act.
     *
     * Independent of the runtime gate by design: the generic "recharge tonight" alert may well have
     * fired (and latched) many hours earlier — on the reference incident it fired ~18 h before the
     * strap died. This asks a narrower, time-anchored question at the pre-bed moment, and re-arms
     * every night rather than every charge, so it speaks even when everything else has gone quiet.
     * `runway` is null at cold-start (no learned bedtime) — the policy stays silent rather than
     * inventing one. iOS/macOS twin: BatteryNotifier.onBedtimeRunway.
     *
     * Rides the predictive sub-gate as well as the battery toggle: it IS a prediction.
     */
    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onBedtimeRunway(
        context: Context,
        nowSecOfDay: Int,
        habitualMidsleepSec: Int?,
        typicalSleepHours: Double?,
        usableRemainingHours: Double?,
        charging: Boolean?,
    ) {
        if (!NoopPrefs.batteryAlerts(context)) return
        if (!NoopPrefs.predictiveBatteryAlerts(context)) return
        runCatching {
            val decision = com.noop.analytics.BatteryEstimator.bedtimeAlert(
                nowSecOfDay = nowSecOfDay,
                habitualMidsleepSec = habitualMidsleepSec,
                typicalSleepHours = typicalSleepHours,
                usableRemainingHours = usableRemainingHours,
                charging = charging,
                alerted = NoopPrefs.batteryBedtimeAlerted(context),
            )
            // ALWAYS persist the updated gate — the nightly re-arm must stick even when nothing fired.
            NoopPrefs.setBatteryBedtimeAlerted(context, decision.newAlerted)
            val runway = decision.runway
            if (!decision.fire || runway == null) return
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            val body = context.getString(
                R.string.battery_bedtime_body,
                com.noop.analytics.BatteryEstimator.label(runway.usableHours),
                com.noop.analytics.BatteryEstimator.label(runway.requiredHours),
            )
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(context.getString(R.string.battery_bedtime_title))
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(openAppIntent(context))
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                // See onCriticalBattery: IMPORTANCE_HIGH channel is the Android stand-in for the
                // Swift `.timeSensitive` request; no DND bypass is taken.
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()
            NotificationManagerCompat.from(context).notify(NOTIF_ID_BEDTIME, n)
        }
    }

    private fun openAppIntent(context: Context): PendingIntent =
        PendingIntent.getActivity(
            context, 3,
            appLaunchIntent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            // No early return when the channel exists: createNotificationChannel is idempotent and
            // updating an existing channel is the only way its name/description follow a language
            // change. Both are user-visible in system Settings and were otherwise fixed in the
            // install-time language forever. Every caller sits behind the persisted once-per-crossing
            // gates (and #886's (SoC, charging) key), so this runs when an alert is actually posted,
            // not on the ~1 Hz live-state tick.
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, context.getString(R.string.battery_channel_name),
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = context.getString(R.string.battery_channel_desc)
                },
            )
        }
    }
}
