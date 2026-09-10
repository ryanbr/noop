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
    /** The last [HrTrace.WINDOW_SEC] of heart rate, one point per minute, for the trace widget (#1957).
     *  Maintained by the STORE rather than by producers: `save` folds each live sample in and `load`
     *  hands back the pruned series, so nothing that pushes a snapshot had to learn about it. Empty
     *  until a live sample lands, which is also what a fresh install and a quiet strap look like. */
    val hrSeries: List<HrPoint> = emptyList(),
    /** Today's hourly stress curve for the stress widget (#2040), earliest to latest.
     *
     *  Unlike [hrSeries] this is NOT folded by the store. It arrives complete from whichever producer
     *  scored the day, so a push either carries a whole day or says nothing about stress at all, and
     *  `save` leaves the stored curve alone in the second case. That matters because the background
     *  service pushes heart rate without ever scoring stress, and a naive write would blank the curve
     *  every time the strap reported a beat. */
    val stressSeries: List<StressPoint> = emptyList(),
    /** Local epoch-day [stressSeries] was scored for, or null when this push carries no curve.
     *
     *  The nullability is the write signal, and the value is the staleness one: `load` drops a curve
     *  from any day but today, so the widget cannot show yesterday's afternoon under today's date while
     *  waiting for the first scorable hour after midnight. */
    val stressDay: Long? = null,
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

    /** Prefs key for the encoded heart-rate trace (#1957). Its own key so an older build, or a wipe of
     *  the trace, leaves every scalar the other widgets read untouched. */
    private const val KEY_SERIES = "hrSeries"

    /** Prefs keys for the stress curve and the day it belongs to (#2040). Their own keys for the same
     *  reason the trace has one: an older build, or a day with nothing scored, must leave every scalar
     *  the other widgets read untouched. */
    private const val KEY_STRESS = "stressSeries"
    private const val KEY_STRESS_DAY = "stressDay"

    suspend fun push(context: Context, snap: WidgetSnapshot) {
        val app = context.applicationContext
        // Cheap, non-suspending gate FIRST — at live-HR cadence (~1/s) almost every call ends here.
        if (!PushGate.admit(snap)) {
            WidgetTelemetry.notePushGated(snap.updatedAtMs)
            return
        }
        WidgetTelemetry.notePushAdmitted(snap.updatedAtMs)

        // Kept so a push that turns out to carry nothing new can put it back. All three widgets RENDER
        // this stamp — the HR card as a permanent "Updated <time>" line, the 2x2 and compact as their
        // disconnected "last seen" — so it is not the metadata the Apple twin can treat it as.
        val previousUpdatedAt = app.getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .getLong("updatedAt", 0L)

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
        val hrIds = runCatching {
            GlanceAppWidgetManager(app).getGlanceIds(HrGlanceWidget::class.java)
        }.getOrDefault(emptyList())
        val stressIds = runCatching {
            GlanceAppWidgetManager(app).getGlanceIds(StressGlanceWidget::class.java)
        }.getOrDefault(emptyList())
        if (standardIds.isEmpty() && compactIds.isEmpty() && hrIds.isEmpty() && stressIds.isEmpty()) {
            // Admitted, but there is nowhere for it to go. Recorded rather than returned silently: an
            // export taken with the widget removed is half of the comparison that answers whether it
            // costs anything, and counting this as a send would have made both halves look alike.
            WidgetTelemetry.notePushNoWidget()
            return
        }

        // Nothing the widgets DISPLAY changed, so there is nothing to send. Read back what they will
        // actually render rather than re-deriving it: `load` resolves staleness and prunes the trace,
        // and a guess at either would be the thing that drifts.
        val visible = runCatching { load(app) }.getOrNull()
        if (visible != null && !RenderedGate.changed(visible, WidgetTheme.isDark(app))) {
            // The stamp reads "Updated <time>", so it names when the data is FROM. A push that carried
            // nothing new must not advance it: doing so would tell the reader 14:47 while showing them
            // 14:32's reading. Putting it back also keeps what the prefs hold and what the widget shows
            // in agreement, so a recomposition for some unrelated reason — a launcher restart, a resize
            // — cannot surface a time this push declined to display.
            if (previousUpdatedAt > 0L) {
                runCatching {
                    app.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
                        .putLong("updatedAt", previousUpdatedAt).apply()
                }
            }
            WidgetTelemetry.notePushUnchanged()
            return
        }

        // Update only the providers that actually have a widget placed. The ids are already in hand, and
        // `updateAll` on a provider with none still crosses into GlanceAppWidgetManager to discover that
        // for itself. Someone running just the HR widget was paying for two of those on every push.
        if (standardIds.isNotEmpty()) runCatching { NoopGlanceWidget().updateAll(app) }
        if (compactIds.isNotEmpty()) runCatching { NoopCompactGlanceWidget().updateAll(app) }
        if (hrIds.isNotEmpty()) runCatching { HrGlanceWidget().updateAll(app) }
        if (stressIds.isNotEmpty()) runCatching { StressGlanceWidget().updateAll(app) }
    }

    /**
     * Whether a stress widget is actually on a home screen.
     *
     * Exposed so a producer can skip SCORING for a widget nobody has placed. [push] already declines to
     * send in that case, but by then the work is done, and stress is the one field whose production
     * costs a day of heart-rate rows rather than a field read.
     */
    suspend fun hasStressWidget(context: Context): Boolean = runCatching {
        GlanceAppWidgetManager(context.applicationContext)
            .getGlanceIds(StressGlanceWidget::class.java).isNotEmpty()
    }.getOrDefault(false)

    fun save(context: Context, snap: WidgetSnapshot) {
        val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        val e = prefs.edit()
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
        if (live) {
            e.putInt("hr", snap.heartRate!!).putLong("hrAt", snap.updatedAtMs)
            // #1957: fold the sample into the trace. Read-modify-write is affordable here precisely
            // because PushGate already throttles an unchanged key to once a minute, which is the same
            // cadence HrTrace buckets at — so this runs about once per point, not once per sample.
            val nowSec = snap.updatedAtMs / 1000
            val folded = HrTrace.append(
                HrTrace.decode(prefs.getString(KEY_SERIES, null)),
                ts = nowSec, bpm = snap.heartRate!!, nowSec = nowSec,
            )
            e.putString(KEY_SERIES, HrTrace.encode(folded))
        }
        // Stress is written only by a push that scored it. A null day means "this push says nothing
        // about stress", which is every push from the BLE service, and overwriting on those would leave
        // the widget blank for all the minutes between one scoring pass and the next.
        if (snap.stressDay != null) {
            e.putString(KEY_STRESS, StressTrace.encode(snap.stressSeries))
                .putLong(KEY_STRESS_DAY, snap.stressDay)
        }
        e.apply()
    }

    fun load(context: Context): WidgetSnapshot {
        val p = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        // Resolved ONCE. Asking twice let the two stress fields straddle midnight and disagree, the
        // same inconsistency the Swift twin avoids by deriving both from a single value.
        val today = java.time.LocalDate.now().toEpochDay()
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
            // Pruned on the way OUT as well as on the way in: a widget read hours after the last push
            // would otherwise draw a trace whose newest point is stale, under a header that already
            // dropped the number for being too old (see [HrDisplay.STALE_CAP_MS]).
            hrSeries = HrTrace.prune(
                HrTrace.decode(p.getString(KEY_SERIES, null)),
                nowSec = System.currentTimeMillis() / 1000,
            ),
            // Dropped on the way OUT when it belongs to a past day, the same discipline the trace
            // uses for age: a widget read at 00:30 would otherwise show yesterday's curve as today's
            // until the first hour of the new day happens to be scorable.
            stressSeries = p.getLong(KEY_STRESS_DAY, Long.MIN_VALUE)
                .takeIf { it == today }
                ?.let { StressTrace.decode(p.getString(KEY_STRESS, null)) }
                ?: emptyList(),
            // Surfaced only when it IS today, so this field can never disagree with the series above:
            // a loaded snapshot reporting yesterday's day beside an emptied curve would be a trap for
            // anything that later treated the pair as writable state.
            stressDay = p.getLong(KEY_STRESS_DAY, Long.MIN_VALUE).takeIf { it == today },
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
 * The second gate, after [PushGate]: does anything the widgets DISPLAY differ from what they were last
 * sent?
 *
 * [PushGate] deliberately does not know the heart-rate VALUE (only whether there is one), because
 * keying on it would admit a push per sample. That leaves a gap it cannot close: its 60-second timer
 * clause fires whether or not anything moved, so a strap that has gone quiet used to cost a full widget
 * update every minute — on the HR widget, a half-megabyte bitmap across a Binder transaction to draw
 * exactly what was already on screen.
 *
 * The Apple side has had this since #1957 (`WidgetPublish.saveAndReloadIfChanged` +
 * `WidgetSnapshot.renderedContentChanged`); Android did not, and was doing strictly more work per push
 * for identical data.
 *
 * Deliberately NOT the Apple rule, which also declines a reload when only the TRACE advanced. WidgetKit
 * rebuilds a timeline on its own schedule, so a point persisted without a reload still reaches the
 * screen; Glance has no such rebuild (`updatePeriodMillis="0"`), so declining there would freeze the
 * chart at rest until the number itself moved. This skips only when NOTHING changed, which is free.
 * Whether the trace-only case is worth its cost is a question for the widget cost counters.
 *
 * The key spans every field any of the three widgets renders, so "nothing changed" means none of them
 * had anything to show — a narrower per-widget gate would be a different, visible trade.
 *
 * The APPEARANCE is in the key even though it is not in the snapshot. The widgets read
 * `theme.appearance` themselves at composition, and nothing refreshes them when it changes — today a
 * theme flip reaches the screen only because every push updated unconditionally. Leaving it out would
 * have meant a widget sat in the wrong colours until something unrelated moved, which is a regression
 * this gate would have introduced rather than a cost it inherited. Resolved through [WidgetTheme] so it
 * cannot disagree with what the widgets themselves decide.
 *
 * `updatedAtMs` is the one field held OUT, and it is the reason this gate needed thought rather than a
 * port. All three widgets display it, so including it would mean the key changed on every push and the
 * gate could never fire; excluding it naively would freeze a visible clock. The resolution is that the
 * stamp names when the DATA is from, not when the app last woke: [WidgetSnapshotStore.push] restores
 * the previous value when it declines, so a frozen stamp is the truthful one. The Apple twin sidesteps
 * this entirely because no widget family there renders the timestamp.
 */
internal object RenderedGate {
    private var last: String? = null

    /** True when [visible] differs from what was last sent. The first call after a process start always
     *  admits: the widgets may be showing something an earlier process left them. */
    @Synchronized
    fun changed(visible: WidgetSnapshot, dark: Boolean): Boolean {
        val newest = visible.hrSeries.lastOrNull()
        // The stress curve joins the key (#2040). Without it a pass that scored a fresh hour, and
        // changed nothing else, would be declined here as "nothing the widgets display changed" and the
        // curve would sit an hour behind whatever unrelated value moved next.
        val newestStress = visible.stressSeries.lastOrNull { it.level != null }
        val key = "${visible.recoveryPct}|${visible.restPct}|${visible.effortPct}|" +
            "${visible.batteryPct}|${visible.connected}|${visible.heartRate}|" +
            "${visible.heartRateStale}|${visible.hrSeries.size}|${newest?.ts}|${newest?.bpm}|" +
            "${visible.stressSeries.size}|${newestStress?.ts}|${newestStress?.level}|" +
            "$dark"
        val differs = key != last
        last = key
        return differs
    }

    @Synchronized
    fun resetForTest() { last = null }
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
        // Stress is deliberately NOT in this key. Two producers push snapshots and only one of them
        // scores stress, so keying on the curve would make the count alternate between N and 0 as the
        // BLE service and the view model took turns, flipping the key on every push and admitting all
        // of them — the exact throttle this gate exists to apply. [RenderedGate] covers the curve
        // instead, and covers it better: it reads back what was STORED, so it sees the same thing
        // whichever producer last wrote. A curve that arrives while this gate is closed waits at most
        // HR_REFRESH_MS, against an hourly score.
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
