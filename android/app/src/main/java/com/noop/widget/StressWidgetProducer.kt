package com.noop.widget

import com.noop.analytics.DaytimeStress
import com.noop.data.WhoopRepository
import com.noop.ui.selectedDaytimeStressMode
import com.noop.ui.stressLocalDayWindowContaining
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Scores today's hourly stress for the widget, and does it as rarely as it can get away with.
 *
 * THE GATE IS THE POINT. Scoring a day means reading today's heart rate, R-R and gravity, three
 * unioned reads bounded at 200 000 rows each, which is the same work the Stress screen does when you
 * open it. The screen does that once, on a deliberate act. A widget producer sits on a periodic tick,
 * and putting three reads of that size on a repeating cadence is precisely the pattern this codebase
 * has had to unpick before (the analyze-pass storm, and the 21-night re-score behind it).
 *
 * So nothing is read until [WhoopRepository.hrFingerprintWindow] says today's heart rate actually
 * moved. That fingerprint is a COUNT and a MAX over an indexed column: no rows, no decode. On an idle
 * tick, which is almost every tick, this costs one cheap query and returns the previous curve. Stress
 * is scored hourly, so even a busy day recomputes about as often as it has new hours.
 *
 * SCORING MODE. Background callers keep the DayRelative default: resolving the personal lens reads
 * trailing days of heart rate, a cost a foreground screen can afford and an unprompted tick cannot.
 * Today's hosted card passes its selected foreground lens explicitly, so it agrees with Stress detail;
 * the home-screen widget does not opt in and remains a deliberately cheaper background surface.
 */
internal object StressWidgetProducer {

    /** Today's curve and the local day it belongs to. */
    data class Curve(val points: List<StressPoint>, val epochDay: Long)

    /** What the last computation saw and produced, swapped in as ONE value.
     *
     *  Three separate fields could tear: a second caller arriving between two of the assignments would
     *  read one call's fingerprint beside another's points and serve a curve for a day it was not
     *  scored against. Only the view model calls this today, so that is a narrow window, but an
     *  immutable holder closes it for free and survives a second caller being added later. */
    private data class Memo(
        val fingerprint: Pair<Int, Long>,
        val day: Long,
        val personalBaseline: Boolean,
        val points: List<StressPoint>,
    )

    /**
     * ONE SLOT PER LENS, not one slot carrying the lens.
     *
     * The lens became part of the memo's identity so an unchanged heart-rate fingerprint could not
     * replay one surface's curve into the other. With a single slot that is correct and useless: three
     * background callers ask with the default lens and Today asks with the selected one, so when the
     * toggle is on each call evicts the other's entry and every call misses whatever the fingerprint
     * says. Today re-asks every [RESCORE_INTERVAL_MS], so the trailing-history read the fingerprint gate
     * exists to avoid was being paid on essentially every tick. Keyed by lens, each surface keeps its
     * own gate. Two entries at most, so this is a pair of slots rather than a cache that grows.
     *
     * An IMMUTABLE map republished behind `@Volatile`, which is what the single slot already was and
     * has to stay: four callers reach this producer, on a BLE connection service, the widget worker, the
     * view model and a Compose effect, so they can be inside it at once. A mutable map here would be a
     * data race on the table itself, not merely a lost entry. Copying two references on a write that
     * only happens when the fingerprint moved is not a cost worth avoiding.
     */
    @Volatile
    private var memos: Map<Boolean, Memo> = emptyMap()

    /** How soon a FAILED attempt may be retried. Short, because the widget is blank until it succeeds. */
    const val RESCORE_RETRY_MS: Long = 60L * 1000L

    /**
     * How often a live surface should ask for today's curve again.
     *
     * Lives here rather than in one caller because more than one surface has to keep step: the
     * connection service scores on it for the widget, and the Today card now refreshes on it too
     * (#2144). Before that the card scored once, when its LaunchedEffect keys last moved, and none
     * of those keys track incoming heart rate, so a card left open drifted hours behind the Stress
     * screen, which scores when you open it. Two surfaces, one producer, and the only difference
     * between them was when each last asked.
     *
     * Matched to the data rather than to the stream: the curve resolves to half-hours, so asking
     * more often than this buys nothing and costs a day of heart-rate rows every time, the memo
     * being no help while a strap is streaming into the window it fingerprints.
     */
    const val RESCORE_INTERVAL_MS: Long = 15L * 60L * 1000L

    /**
     * The stamp to keep after an attempt, given what that attempt actually produced (#2120).
     *
     * The caller stamps BEFORE it reads, deliberately: stamping inside the placement branch would leave
     * the gate open for everyone without the widget, so the placement check, which crosses into
     * GlanceAppWidgetManager, would run on every emission of a collector driven by live heart rate. The
     * cost of that choice was that an attempt producing NOTHING still spent the whole interval, so a
     * transient miss left a placed widget blank for fifteen minutes and the wearer fixed it by opening
     * the app. This decides what the stamp becomes once the outcome is known.
     *
     *  - produced a curve: keep [nowMs]. Nothing is wrong, take the full interval.
     *  - [widgetPlaced] FALSE, a settled no: also keep [nowMs]. Producing nothing is the RIGHT answer,
     *    and retrying sooner would re-run the placement check on a hot collector, which is precisely
     *    what the early stamp exists to prevent.
     *  - a placed widget whose read came back null: rewind so the next attempt is [retryMs] away rather
     *    than a full interval. Not zero, because the other half of the caller's reasoning is that a
     *    failing pass must not retry on the very next sample; a short floor honours both.
     *  - [widgetPlaced] NULL, the host did not answer: rewind as well, and this is the case the report is
     *    really about. The placement check fails closed, so a transient miss arrives as the same `false`
     *    a settled no does, and spending the interval on it leaves a placed widget blank.
     */
    fun stampAfterAttempt(
        nowMs: Long,
        producedCurve: Boolean,
        widgetPlaced: Boolean?,
        intervalMs: Long,
        retryMs: Long = RESCORE_RETRY_MS,
    ): Long {
        if (producedCurve || widgetPlaced == false) return nowMs
        // Rewind so `shouldRescore` turns true again after `retryMs`, never sooner than that floor.
        return nowMs - (intervalMs - retryMs).coerceAtLeast(0L)
    }

    /**
     * Whether a background tick should rescore, given when it last did.
     *
     * The service's collector runs on `ble.state`, which moves at the live heart-rate rate, while
     * scoring reads a day of heart-rate rows. The memo inside [todayCurve] cannot absorb that on its
     * own: its fingerprint is the day's heart rate, which is exactly what changes on every one of
     * those emissions, so a streaming strap misses the memo every time.
     *
     * [lastScoreAtMs] of 0 means "not yet this process", and any real wall clock is far past the
     * interval, so the first tick after a launch always scores rather than waiting out a window.
     */
    fun shouldRescore(nowMs: Long, lastScoreAtMs: Long, intervalMs: Long): Boolean =
        nowMs - lastScoreAtMs >= intervalMs

    /**
     * Today's curve, recomputed only when today's heart rate has moved since the last call.
     *
     * Returns null when there is no device to read, which is the one case a caller must not treat as
     * "today scored nothing": a null means "say nothing about stress in this push", and the widget
     * keeps whatever it already had.
     */
    suspend fun todayCurve(
        repo: WhoopRepository,
        deviceId: String?,
        personalBaseline: Boolean = false,
        nowSeconds: Long = System.currentTimeMillis() / 1000L,
        zone: ZoneId = ZoneId.systemDefault(),
    ): Curve? = withContext(Dispatchers.Default) {
        // OFF the caller's dispatcher, because one caller is a LaunchedEffect body and that means the
        // main thread. Room's suspend DAOs move the queries themselves, but the row merge and
        // DaytimeStress.analyze do not, so a day of heart rate was being bucketed and scored on the UI
        // thread of the Today screen. Fixed here rather than at the call site so every caller gets it:
        // the connection service, the periodic widget worker and the screen all reach this one function.
        if (deviceId.isNullOrBlank()) return@withContext null
        runCatching {
            val window = stressLocalDayWindowContaining(nowSeconds, zone)
            val day = window.day.toEpochDay()
            val from = window.fromEpochSecond

            val fingerprint = repo.hrFingerprintWindow(deviceId, from, nowSeconds)
            // Same day, same heart rate: nothing can have changed the score, so nothing is read. The day
            // is part of the check because a fingerprint that happens to match across midnight would
            // otherwise serve yesterday's curve as today's.
            // The foreground personal lens and the background widget can call this producer in either
            // order. The preference is part of the identity so one surface can never receive the other
            // lens merely because today's HR fingerprint is unchanged.
            val memoHit = memos[personalBaseline]?.takeIf {
                it.day == day && it.fingerprint == fingerprint
            }
            if (memoHit != null) return@runCatching Curve(memoHit.points, day)

            val hr = repo.hrSamplesUnion(deviceId, from, nowSeconds, limit = 200_000)
            val points = if (hr.size < DaytimeStress.minHourHrSamples) {
                // Too little signal to score honestly. An EMPTY curve, not a null: this is a real
                // answer about today, and the widget should drop yesterday's line rather than keep it.
                emptyList()
            } else {
                val rr = repo.rrIntervalsUnion(deviceId, from, nowSeconds, limit = 200_000)
                // Wrist accelerometer for the motion gate, so an ambulatory hour reads as exertion
                // rather than as stress. Empty on hardware or imports without gravity, which degrades
                // to no masking exactly as the screen does.
                val gravity = repo.gravitySamplesUnion(deviceId, from, nowSeconds, limit = 200_000)
                val tzOffsetSeconds =
                    zone.rules.getOffset(Instant.ofEpochSecond(nowSeconds)).totalSeconds.toLong()
                val mode = selectedDaytimeStressMode(
                    repo, deviceId, window.day, zone, personalBaseline,
                )
                DaytimeStress.analyze(
                    hr, rr, gravity, tzOffsetSeconds, mode,
                    includeTimeline = true,
                    // The half-step display series rather than the bare hours: same scored window,
                    // same reference, read twice as often, so the curve tracks the day instead of
                    // stepping through it. Nothing here counts hours, so the overlap is free.
                ).timeline.map {
                    // startTs is the wall-clock bucket start with the local shift already undone, so it
                    // is a true instant and formats correctly against the device's zone.
                    StressPoint(ts = it.startTs, level = it.level, moving = it.maskedForActivity)
                }
            }

            memos = memos + (personalBaseline to Memo(fingerprint, day, personalBaseline, points))
            Curve(points, day)
        }.getOrNull()
    }

    /** Drops both memo slots so a test starts from a known state. */
    fun resetForTest() {
        memos = emptyMap()
    }
}
