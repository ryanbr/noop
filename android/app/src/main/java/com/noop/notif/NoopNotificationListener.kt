package com.noop.notif

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.noop.NoopApplication
import com.noop.ui.NotifPrefs

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

    // #1115: notification keys we've already buzzed for a native timer/alarm (CATEGORY_ALARM). onNotification-
    // Posted fires on every post AND update, and a ringing alarm re-posts repeatedly — so buzz ONCE per key
    // and forget it on removal, so a re-ring buzzes again but an updating notification can't storm the strap.
    private val buzzedAlarmKeys = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val ctx = applicationContext
        val n = sbn.notification ?: return

        if (VoipCallClassifier.isKnownVoipPackage(sbn.packageName)) {
            val metadata = VoipCallClassifier.metadataOf(n, isOngoing = sbn.isOngoing)
            if (VoipCallClassifier.isIncomingCallNotification(sbn.packageName, metadata)) {
                // An incoming VoIP call is handled ONLY by the Calls path — never ALSO as a per-app
                // alert. Always return: start() is a no-op when Calls is off, but either way a call
                // notification must not fall through and double-buzz the same app's per-app alert.
                CallAlertController.start(ctx, CallAlertSource.VOIP, sbn.key)
                return
            } else {
                CallAlertController.stop(CallAlertSource.VOIP, sbn.key)
            }
        }

        // Native Clock timer/alarm → wrist buzz (#1115 follow-up, Android-only — iOS can't observe another
        // app's notifications). Matched by CATEGORY_ALARM (any clock app, no package list) so it also
        // catches a RINGING alarm, whose ONGOING notification the per-app path below deliberately skips.
        // Own opt-in (default OFF), still under the notification master + quiet-hours + only-when-worn.
        // Only INTERCEPTS when the toggle is on (then returns, so it can't also double-buzz via per-app);
        // with the toggle off a Clock notification falls through to the per-app path unchanged.
        // EXCLUDE NOOP's OWN notifications: our SmartAlarmNotifier + SmartAlarmReceiver also set
        // CATEGORY_ALARM, and this service receives its own app's posts — without this guard the toggle
        // would buzz for NOOP's OWN smart alarm (a surprise for a "phone Clock" toggle, and a double-buzz
        // with its firmware-alarm path). NOOP's alarm keeps its own settings; an app-buzz for it is a
        // separate, deliberate feature, not this.
        if (n.category == Notification.CATEGORY_ALARM &&
            sbn.packageName != ctx.packageName &&
            NotifPrefs.getBool(ctx, NotifPrefs.MASTER, false) &&
            NotifPrefs.getBool(ctx, NotifPrefs.ALARM_TIMER, false)) {
            val ble = (application as? NoopApplication)?.ble
            // Buzz at most ONCE per notification key. `add()` is the LAST term, so a key is recorded only
            // when we actually buzz (deliverable) — a re-posting/updating notification can't storm, and a
            // genuine re-ring gets a fresh key (cleared in onNotificationRemoved) so it buzzes again.
            if (ble != null && !NotifPrefs.inQuietHours(ctx) &&
                (!NotifPrefs.getBool(ctx, NotifPrefs.WORN, true) || ble.state.value.worn) &&
                buzzedAlarmKeys.add(sbn.key)) {
                ble.buzz(3)   // a strong triple cue; send() no-ops if the strap isn't connected
            }
            return
        }

        // Master gate + per-app opt-in (both default off — nothing buzzes until the user turns it on).
        // The "all other apps" catch-all (#168) lets anything outside the curated catalog through, since
        // Android package-visibility limits mean we can't list every installed app for per-app opt-in.
        if (!NotifPrefs.getBool(ctx, NotifPrefs.MASTER, false)) return
        if (!NotifPrefs.appEnabled(ctx, sbn.packageName) &&
            !NotifPrefs.getBool(ctx, NotifPrefs.ALL_OTHER, false)) return

        // Skip noise: ongoing/foreground-service notifications and group summaries aren't user-facing alerts.
        if (sbn.isOngoing) return
        if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
        if ((n.flags and Notification.FLAG_FOREGROUND_SERVICE) != 0) return

        if (NotifPrefs.inQuietHours(ctx)) return

        val ble = (application as? NoopApplication)?.ble ?: return
        // Only-when-worn (default on): don't buzz an empty strap on the desk.
        if (NotifPrefs.getBool(ctx, NotifPrefs.WORN, true) && !ble.state.value.worn) return

        // Buzz with the app's chosen pattern. send() is a safe no-op if the strap isn't connected.
        ble.buzz(NotifPrefs.appLoops(ctx, sbn.packageName))
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (VoipCallClassifier.isKnownVoipPackage(sbn.packageName)) {
            CallAlertController.stop(CallAlertSource.VOIP, sbn.key)
        }
        // #1115: the alarm/timer is dismissed → forget its key so a genuinely new alarm with a re-used key
        // (some clock apps reuse ids) buzzes again. Cheap no-op for any non-alarm key.
        buzzedAlarmKeys.remove(sbn.key)
    }
}
