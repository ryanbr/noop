package com.noop.notif

import android.app.Notification
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.noop.NoopApplication
import com.noop.ui.NotifPrefs
import java.util.Calendar

/**
 * Wrist alerts — mirror selected app notifications to a strap buzz.
 *
 * Declaring this service (with BIND_NOTIFICATION_LISTENER_SERVICE in the manifest) is what makes NOOP
 * appear in Android's **Notification Access** list at all (issue #52 — before this, the "Open
 * Notification Access" button opened a list NOOP wasn't in). When the user grants access, Android binds
 * this service and delivers [onNotificationPosted]; we gate on the persisted [NotifPrefs] settings the
 * Notifications screen already writes (master toggle, per-app opt-in, quiet hours, only-when-worn) and
 * buzz the strap with the app's chosen pattern.
 *
 * Everything stays on-device: we never read notification CONTENT — only which package posted, to decide
 * whether to tap the wrist. The buzz uses the same RUN_HAPTICS_PATTERN path as Test buzz, so it works on
 * WHOOP 4.0; on 5/MG the haptic command isn't honoured yet (issue #48).
 */
class NoopNotificationListener : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val ctx = applicationContext

        // Master gate + per-app opt-in (both default off — nothing buzzes until the user turns it on).
        if (!NotifPrefs.getBool(ctx, NotifPrefs.MASTER, false)) return
        if (!NotifPrefs.appEnabled(ctx, sbn.packageName)) return

        // Skip noise: ongoing/foreground-service notifications and group summaries aren't user-facing alerts.
        val n = sbn.notification ?: return
        if (sbn.isOngoing) return
        if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
        if ((n.flags and Notification.FLAG_FOREGROUND_SERVICE) != 0) return

        if (inQuietHours(ctx)) return

        val ble = (application as? NoopApplication)?.ble ?: return
        // Only-when-worn (default on): don't buzz an empty strap on the desk.
        if (NotifPrefs.getBool(ctx, NotifPrefs.WORN, true) && !ble.state.value.worn) return

        // Buzz with the app's chosen pattern. send() is a safe no-op if the strap isn't connected.
        ble.buzz(NotifPrefs.appLoops(ctx, sbn.packageName))
    }

    private fun inQuietHours(ctx: Context): Boolean {
        if (!NotifPrefs.getBool(ctx, NotifPrefs.QUIET, false)) return false
        val start = NotifPrefs.getInt(ctx, NotifPrefs.QUIET_START, 22 * 60)
        val end = NotifPrefs.getInt(ctx, NotifPrefs.QUIET_END, 7 * 60)
        val cal = Calendar.getInstance()
        val now = cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)
        // Quiet window may wrap midnight (e.g. 22:00 → 07:00).
        return if (start <= end) now in start until end else (now >= start || now < end)
    }
}
