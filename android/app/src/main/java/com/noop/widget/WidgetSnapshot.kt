package com.noop.widget

import android.content.Context
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.updateAll

/**
 * The handful of numbers the home-screen widget shows, persisted to SharedPreferences so the
 * widget can render after a process restart (Glance recomposes from disk, not from app memory).
 */
data class WidgetSnapshot(
    /** Today's recovery / Charge 0–100, null until NOOP has scored enough nights (honest-blank). */
    val recoveryPct: Int? = null,
    /** Today's Rest 0–100 (the sleep_performance composite), null until last night is scored (#516). */
    val restPct: Int? = null,
    /** Today's Effort 0–100 (the day's strain on the 0–100 scale), null until there's a HR window (#516). */
    val effortPct: Int? = null,
    /** Heart rate to show: the live sample when streaming, else the last-known reading carried over so a
     *  momentary quiet patch (5/MG HR-profile lull, a reconnect) doesn't blank the widget. Null only when
     *  there is no recent reading at all. See [HrDisplay]. */
    val heartRate: Int? = null,
    /** True when [heartRate] is a carried-over reading rather than a fresh live sample — the widget dims it. */
    val heartRateStale: Boolean = false,
    /** Strap battery 0–100, null until the strap reports it. */
    val batteryPct: Int? = null,
    val connected: Boolean = false,
    /** Wall-clock millis of the last push, so the widget can show honest staleness. */
    val updatedAtMs: Long = 0L,
)

/**
 * Persists snapshots and tells Glance to recompose. Both producers funnel through [push]:
 * [com.noop.ble.WhoopConnectionService] (long-lived — the widget's heartbeat while the app UI is
 * closed) and [com.noop.ui.AppViewModel] (covers foreground use with the background service off).
 *
 * Throttled by [PushGate] (see its KDoc). CALLER CONTRACT (#82): collect with backpressure
 * (`conflate()` + `collect`), NEVER `collectLatest` — push suspends in Glance machinery longer than
 * the live-HR emission interval (~1/s), so collectLatest cancels every push mid-flight and the
 * widget starves on stale prefs forever while the strap streams.
 */
object WidgetSnapshotStore {
    private const val FILE = "noop_widget"

    suspend fun push(context: Context, snap: WidgetSnapshot) {
        val app = context.applicationContext
        // Cheap, non-suspending gate FIRST — at live-HR cadence (~1/s) almost every call ends here.
        if (!PushGate.admit(snap)) return

        // Persist before anything suspending, and only THEN mark the gate (#82: marking before the
        // write let a cancelled push burn the refresh window — the widget starved on stale prefs).
        // Saving even with no widget placed means a widget added later renders fresh data instantly.
        save(app, snap)
        PushGate.markPushed(snap)

        val standardIds = runCatching {
            GlanceAppWidgetManager(app).getGlanceIds(NoopGlanceWidget::class.java)
        }.getOrDefault(emptyList())
        val compactIds = runCatching {
            GlanceAppWidgetManager(app).getGlanceIds(NoopCompactGlanceWidget::class.java)
        }.getOrDefault(emptyList())
        if (standardIds.isEmpty() && compactIds.isEmpty()) return
        runCatching { NoopGlanceWidget().updateAll(app) }
        runCatching { NoopCompactGlanceWidget().updateAll(app) }
    }

    fun save(context: Context, snap: WidgetSnapshot) {
        val e = context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
            .putInt("recovery", snap.recoveryPct ?: -1)
            .putInt("rest", snap.restPct ?: -1)
            .putInt("effort", snap.effortPct ?: -1)
            .putInt("battery", snap.batteryPct ?: -1)
            .putBoolean("connected", snap.connected)
            .putLong("updatedAt", snap.updatedAtMs)
        // Retain the last live HR across a quiet patch: only overwrite `hr`/`hrAt` when this push carries a
        // live sample; a null-HR push (strap quiet / mid-reconnect) leaves the last reading in place, and
        // `hrLive` records that the retained value is now a carry-over so the widget dims it (see HrDisplay).
        val live = (snap.heartRate ?: 0) > 0
        e.putBoolean("hrLive", live)
        if (live) e.putInt("hr", snap.heartRate!!).putLong("hrAt", snap.updatedAtMs)
        e.apply()
    }

    fun load(context: Context): WidgetSnapshot {
        val p = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        val (hr, hrStale) = HrDisplay.resolve(
            lastHr = p.getInt("hr", -1).takeIf { it > 0 },
            lastHrAtMs = p.getLong("hrAt", 0L),
            live = p.getBoolean("hrLive", false),
            nowMs = System.currentTimeMillis(),
        )
        return WidgetSnapshot(
            recoveryPct = p.getInt("recovery", -1).takeIf { it >= 0 },
            restPct = p.getInt("rest", -1).takeIf { it >= 0 },
            effortPct = p.getInt("effort", -1).takeIf { it >= 0 },
            heartRate = hr,
            heartRateStale = hrStale,
            batteryPct = p.getInt("battery", -1).takeIf { it >= 0 },
            connected = p.getBoolean("connected", false),
            updatedAtMs = p.getLong("updatedAt", 0L),
        )
    }
}

/**
 * Decides what live-HR the widget shows, extracted pure so it's unit-testable (WidgetHrDisplayTest).
 * The last reading is carried over so a brief quiet patch — the 5/MG HR-profile lull at rest, or a
 * reconnect that clears biometrics — doesn't blank the heart. It is DIMMED once it's a carry-over rather
 * than a fresh live sample, and DROPPED entirely once it's too old to stand for the wearer.
 */
internal object HrDisplay {
    /** A reading counts as a fresh live sample only if the last live push was within this window; past it
     *  (e.g. the app was killed mid-stream and never flipped `live` off) it's shown dimmed, not as live. */
    const val LIVE_MS = 2 * 60_000L

    /** Beyond this age the reading is dropped (widget shows "-") — too stale to represent HR at all. */
    const val STALE_CAP_MS = 15 * 60_000L

    /** @return (bpm to show or null, stale) — stale = shown but NOT a fresh live sample, so the widget dims it. */
    fun resolve(lastHr: Int?, lastHrAtMs: Long, live: Boolean, nowMs: Long): Pair<Int?, Boolean> {
        if (lastHr == null || lastHr <= 0) return null to false
        val age = nowMs - lastHrAtMs
        if (age > STALE_CAP_MS) return null to false          // too old regardless of the `live` flag
        val fresh = live && age <= LIVE_MS                    // a live push AND recent — not a stale carry-over
        return lastHr to !fresh
    }
}

/**
 * The push-throttle decision, extracted pure so it's unit-testable (PushGateTests). Meaningful
 * changes (recovery, battery 5%-bucket, connection, and HR presence — so the FIRST heart-rate
 * sample shows immediately, #82) admit straight away; an unchanged key re-admits once per
 * [HR_REFRESH_MS] so the displayed HR still ticks. Glance re-inflation is far heavier than a
 * notification post, hence the gate.
 */
internal object PushGate {
    private const val HR_REFRESH_MS = 60_000L

    private var lastKey: String? = null
    private var lastPushAtMs = 0L

    private fun keyOf(snap: WidgetSnapshot): String =
        // Rest + Effort join the change-key (#516) so a freshly-scored 2x2 score lands immediately, the
        // same way recovery does — not waiting out the HR refresh window.
        "${snap.recoveryPct}|${snap.restPct}|${snap.effortPct}|" +
            "${snap.batteryPct?.div(5)}|${snap.connected}|${snap.heartRate != null}"

    fun admit(snap: WidgetSnapshot): Boolean =
        keyOf(snap) != lastKey || snap.updatedAtMs - lastPushAtMs >= HR_REFRESH_MS

    fun markPushed(snap: WidgetSnapshot) {
        lastKey = keyOf(snap)
        lastPushAtMs = snap.updatedAtMs
    }

    fun resetForTest() {
        lastKey = null
        lastPushAtMs = 0L
    }
}
