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

/** Small pure policy so the once-per-day gate is JVM-testable (CallAlertPolicy idiom). */
internal object IllnessAlertPolicy {
    fun shouldNotify(alert: String?, lastNotifiedDay: String?, today: String): Boolean =
        alert != null && lastNotifiedDay != today
}

/**
 * Posts the illness early-warning as a real system notification — previously it was silent
 * unless the app was open. Called from BOTH the AppViewModel collector (app open) and
 * WhoopConnectionService (background); the persisted day gate makes the dual call sites safe.
 * The message is the on-device APPROXIMATE summary — informational, not a diagnosis.
 */
object IllnessAlertNotifier {
    private const val CHANNEL_ID = "noop_illness_watch"
    private const val NOTIF_ID = 4202   // 4201 is the ongoing connection notification

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onEvaluated(context: Context, alert: String?) {
        val today = java.time.LocalDate.now().toString()
        if (!IllnessAlertPolicy.shouldNotify(alert, NoopPrefs.illnessLastNotifiedDay(context), today)) return
        // Defensive: never let a notify() throw (revoked POST_NOTIFICATIONS, OEM quirk) crash a collector.
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            val openApp = PendingIntent.getActivity(
                context, 2,
                appLaunchIntent(context),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(context.getString(R.string.illness_alert_title))
                .setContentText(alert)
                .setStyle(
                    NotificationCompat.BigTextStyle()
                        .bigText("$alert\nOn-device estimate (approximate), not a diagnosis."),
                )
                .setContentIntent(openApp)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()
            NotificationManagerCompat.from(context).notify(NOTIF_ID, n)
            NoopPrefs.setIllnessLastNotifiedDay(context, today)
        }
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Illness early-warning",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "A heads-up when resting HR, HRV, skin temp or respiration drift together vs your baseline."
                },
            )
        }
    }
}
