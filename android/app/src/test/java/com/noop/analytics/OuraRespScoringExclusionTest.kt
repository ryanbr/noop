package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.OuraRespScale
import com.noop.data.RespSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * The 0x6A `breath` channel is a per-window RATE stored in `respSample` under the ring's own deviceId —
 * the same table that otherwise holds a WHOOP's ~1 Hz raw ADC waveform. It is INSTRUMENTATION: it is
 * stored and it is plotted, and NOTHING scores from it. Two separate refusals, pinned here:
 *  * the STAGER must never see it — a peak detector run over a rate series is a shape error, and this
 *    one would be wrong even for a value nobody doubts;
 *  * the night's `dailyMetric.respRateBpm` must never be derived from it — that is the scored slot
 *    (recovery's resp term, the illness signal), and CLAUDE.md's #194 rule keeps a channel already at
 *    its vendor ceiling out of it.
 * Plus the control that keeps the first refusal from being vacuous. Swift twin:
 * `OuraRespScoringExclusionTests`.
 */
class OuraRespScoringExclusionTest {

    private val ring = "oura-2H3B2405003655"
    private val profile = UserProfile(weightKg = 75.0, heightCm = 178.0, age = 30.0, sex = "male")

    // ── fixtures ─────────────────────────────────────────────────────────────────────────────────────

    /** A still 1 Hz gravity stream — the quiescent sleep floor, enough for the stager to stage. */
    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(ring, start + it, 0.0, 0.0, 1.0) }

    private fun sleepingHr(start: Long, durationS: Int): List<HrSample> =
        (0 until durationS).map { HrSample(ring, start + it, 52 + (it / 600) % 4) }

    private fun regularRr(start: Long, durationS: Int): List<RrInterval> =
        (0 until durationS).map {
            RrInterval(ring, start + it, 1_150 + (40.0 * sin(2.0 * PI * it / 4.0)).roundToInt())
        }

    /**
     * What a real night of 0x6A looks like once persisted: one row per ~296 s window, milli-bpm, values
     * drifting over the observed 13-16 bpm band.
     */
    private fun ringRespRows(start: Long, durationS: Int): List<RespSample> =
        (0 until durationS step 296).map { i ->
            val byte = 112 + (i / 296) % 12                      // 14.000 .. 15.375 bpm, in 0.125 steps
            RespSample(ring, start + i, byte * 125)
        }

    // ── The refusal ──────────────────────────────────────────────────────────────────────────────────

    /** The guarantee, stated where the stager can see it: the rows never arrive. */
    @Test
    fun ringRespirationNeverReachesTheStager() {
        val start = 1_754_000_000L
        val rows = ringRespRows(start, 8 * 3_600)
        assertFalse("fixture sanity: a night of 0x6A is ~100 rows", rows.isEmpty())
        assertTrue(OuraRespScale.forScoring(rows, ring).isEmpty())
    }

    /**
     * ...and that refusing them is a NO-OP on today's firmware, which is what makes this change safe to
     * land: `respRateAndRRV` needs >= 8 samples in its rolling 5-minute window, and a ~296 s cadence
     * never supplies more than two, so every epoch's RRV is NaN either way. Staging is bit-identical
     * with the rows and without them.
     *
     * This is exactly why the refusal is written by PROVENANCE rather than left to the cadence: the day
     * a decoder expands one record into per-second rows, or the record period changes, this assertion
     * stops being free — and [OuraRespScale.forScoring] is already the place that keeps the outcome the
     * same.
     */
    @Test
    fun todaysCadenceWouldNotHaveMovedStagingEitherWay() {
        val start = 1_754_000_000L
        val dur = 8 * 3_600
        val grav = stillGravity(start, dur)
        val hr = sleepingHr(start, dur)
        val rr = regularRr(start, dur)
        val rows = ringRespRows(start, dur)

        val without = SleepStager.stageSession(start, start + dur, grav, hr, rr, emptyList())
        val with = SleepStager.stageSession(start, start + dur, grav, hr, rr, rows)
        assertFalse("fixture sanity: the night must actually stage", without.isEmpty())
        assertEquals(without.map { it.start }, with.map { it.start })
        assertEquals(without.map { it.end }, with.map { it.end })
        assertEquals(without.map { it.stage }, with.map { it.stage })
    }

    /**
     * A 1 Hz stream of the SAME numbers does move the stager — the control that proves the test above is
     * measuring the cadence and not simply a stager that ignores `resp`. If this one ever stops failing
     * to match, the invariance above has become vacuous.
     */
    @Test
    fun aOneHertzStreamOfTheSameValuesWouldMoveStaging() {
        val start = 1_754_000_000L
        val dur = 8 * 3_600
        val grav = stillGravity(start, dur)
        val hr = sleepingHr(start, dur)
        val rr = regularRr(start, dur)
        // A plausible raw-ADC-shaped waveform at 1 Hz: what the stager's peak detector is built for.
        val dense = (0 until dur).map {
            RespSample(ring, start + it, 1_000 + (200.0 * sin(2.0 * PI * it / 4.0)).roundToInt())
        }
        val without = SleepStager.stageSession(start, start + dur, grav, hr, rr, emptyList())
        val withDense = SleepStager.stageSession(start, start + dur, grav, hr, rr, dense)
        assertNotEquals(
            "a dense resp stream must reach the stager — otherwise the invariance test proves nothing",
            without.map { it.stage },
            withDense.map { it.stage },
        )
    }

    // ── The scored slot ──────────────────────────────────────────────────────────────────────────────

    /**
     * The second refusal, at the level that matters to a user: a ring night's `dailyMetric.respRateBpm`
     * is NOT the ring's measured rate. `analyzeDay` has no door the rows can arrive through — they are
     * passed here verbatim as `resp`, the worst case in which a caller forgot [OuraRespScale.forScoring],
     * and the day is still byte-identical to the day with no rows at all.
     *
     * This is the regression guard on the disposition, not on the decode. The decode is good (the ring
     * computes the value; see OuraSleepPeriodInfo); what it is not is a candidate for the slot that feeds
     * recovery and the illness signal on the strength of a signal already sitting at the r = +0.680
     * ceiling any Oura-derived rate has against WHOOP. If this test ever fails, a vendor preference has
     * been reintroduced into `analyzeDay` and needs its own evidence and review.
     */
    @Test
    fun aRingNightsScoredRespRateIsNotTheRingsMeasuredRate() {
        val day = "2026-08-16"
        val sleepStart = LocalDate.parse(day).atStartOfDay(ZoneOffset.UTC).toEpochSecond() - 4 * 3_600L
        val dur = 8 * 3_600
        val hr = (sleepStart until sleepStart + dur step 30)
            .map { HrSample(ring, it, 52 + ((it / 300) % 4).toInt()) }
        var i = 0
        val rr = (sleepStart until sleepStart + dur step 2).map { RrInterval(ring, it, 1_080 + (i++ % 6) * 8) }
        // A ring night stages from the ring's OWN hypnogram (#804 Fix A): no gravity, one provided
        // session — the exact shape the persisted 0x6A rows show up on.
        var t = sleepStart
        val stages = listOf(20 to "wake", 200 to "light", 60 to "deep", 120 to "rem", 80 to "light", 0 to "wake")
            .map { (mins, stage) -> StageSegment(t, t + mins * 60L, stage).also { t += mins * 60L } }
        val provided = listOf(
            DetectedSleep(sleepStart, sleepStart + dur, 0.75, stages, restingHR = null, avgHRV = null),
        )
        val rows = ringRespRows(sleepStart, dur)
        val ringMedian = HrvAnalyzer.median(rows.map { OuraRespScale.breathsPerMin(it.raw) })

        val withRows = AnalyticsEngine.analyzeDay(
            day = day, hr = hr, rr = rr, resp = rows, profile = profile, providedSleep = provided,
        )
        val without = AnalyticsEngine.analyzeDay(
            day = day, hr = hr, rr = rr, profile = profile, providedSleep = provided,
        )
        assertTrue(
            "the ring's measured rate must never become the night's scored respRateBpm",
            withRows.daily.respRateBpm == null || abs(withRows.daily.respRateBpm!! - ringMedian) > 1e-9,
        )
        assertEquals(
            "persisting 0x6A must leave every scored field of the day untouched",
            without.daily, withRows.daily,
        )
    }
}
