package com.noop.widget

import com.noop.analytics.DaytimeStress
import com.noop.data.WhoopRepository
import com.noop.ui.stressLocalDayWindowContaining
import java.time.Instant
import java.time.ZoneId

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
 * SCORING MODE. Always the DayRelative default, never the opt-in personal-baseline lens. Resolving
 * that mode reads fourteen trailing days of heart rate to decide whether enough worn history exists,
 * and that is a cost the screen can afford on demand and a background tick cannot. The consequence is
 * worth stating plainly: with the personal-baseline toggle on, the widget shows the default lens while
 * the screen shows the refined one, so the two can differ. Honouring the toggle here would mean
 * fourteen days of reads on a repeating schedule, which is the worse of the two.
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
        val points: List<StressPoint>,
    )

    @Volatile
    private var memo: Memo? = null

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
        nowSeconds: Long = System.currentTimeMillis() / 1000L,
        zone: ZoneId = ZoneId.systemDefault(),
    ): Curve? {
        if (deviceId.isNullOrBlank()) return null
        return runCatching {
            val window = stressLocalDayWindowContaining(nowSeconds, zone)
            val day = window.day.toEpochDay()
            val from = window.fromEpochSecond

            val fingerprint = repo.hrFingerprintWindow(deviceId, from, nowSeconds)
            // Same day, same heart rate: nothing can have changed the score, so nothing is read. The day
            // is part of the check because a fingerprint that happens to match across midnight would
            // otherwise serve yesterday's curve as today's.
            memo?.let { if (it.day == day && it.fingerprint == fingerprint) return Curve(it.points, day) }

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
                DaytimeStress.analyze(
                    hr, rr, gravity, tzOffsetSeconds, DaytimeStress.ScoringMode.DayRelative,
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

            memo = Memo(fingerprint, day, points)
            Curve(points, day)
        }.getOrNull()
    }

    /** Drops the memo so a test starts from a known state. */
    fun resetForTest() {
        memo = null
    }
}
