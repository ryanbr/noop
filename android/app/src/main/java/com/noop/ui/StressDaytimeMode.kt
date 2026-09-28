package com.noop.ui

import com.noop.analytics.DaytimeBaselines
import com.noop.analytics.DaytimeStress
import com.noop.data.WhoopRepository
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.LocalDate
import java.time.ZoneId

/**
 * Process-level reuse of the resolved daytime-stress lens, keyed on the inputs that can change it.
 *
 * The resolver folds the THIRTY DAYS BEFORE today, so its answer is fixed for the whole local day unless a
 * backfill lands rows inside that past window. Today's own heart rate, which arrives all day, is outside it
 * and cannot move the key. Without this memo every surface paid the full fold independently: Today's
 * fifteen-minute loop, Stress detail on open, and the widget pass, each reading up to thirty days of HR.
 *
 * The drain it closes (#2535): a wearer with the personal lens on saw Today showing 09:30 at 22:20 while
 * detail showed the current curve fifteen seconds after opening. Both are the same latency. Today's loop is
 * gated on STARTED so it suspends while backgrounded, then scores on resume, and "on resume" took those
 * fifteen seconds; the card holds its previous curve meanwhile, by design, so the morning's curve stayed on
 * screen looking current. Warm from the same process, the resume is now immediate.
 *
 * In memory and per process, the same contract [com.noop.analytics.AnalyzeRecentDayCache] keeps: it never
 * persists, never crosses the backup boundary, and a miss is byte-for-byte the full path. Nothing is banked
 * from here, so there is no data-loss surface.
 *
 * ONE slot rather than a map, deliberately. Every caller resolves for the same active device and the same
 * local day, so a second slot would only ever hold a key nothing asks for again, and a map would grow for
 * the life of the process with no eviction rule worth defending.
 *
 * The key carries the device, the day, the zone and the history fingerprint, but NOT `personalBaseline`,
 * because the resolver returns before reaching here when the lens is off. That early return is what makes
 * the omission safe; move it and the key has to gain the flag.
 */
internal object StressLensCache {
    private val gate = Mutex()
    private var key: String? = null
    private var mode: DaytimeStress.ScoringMode? = null

    @Synchronized
    private fun cached(candidate: String): DaytimeStress.ScoringMode? = mode.takeIf { key == candidate }

    @Synchronized
    private fun store(candidate: String, resolved: DaytimeStress.ScoringMode) {
        key = candidate
        mode = resolved
    }

    /**
     * The lens for [candidate], folding through [fold] only if nothing has it yet.
     *
     * The lock is the half a plain memo misses. Today's loop and Stress detail resolve independently, so
     * the reported sequence (resume Today, then open detail a few seconds later) had the second caller
     * miss a cache the first was still warming and start its own thirty-day fold. It now waits for the
     * first and reads the answer, which is the difference between one fold and two on exactly the path
     * #2535 describes.
     *
     * Checked before AND after taking the lock: the first check keeps a warm hit off the lock entirely,
     * and the second is what makes the waiter reuse rather than re-fold.
     */
    suspend fun resolve(
        candidate: String,
        fold: suspend () -> DaytimeStress.ScoringMode,
    ): DaytimeStress.ScoringMode {
        cached(candidate)?.let { return it }
        return gate.withLock {
            cached(candidate) ?: fold().also { store(candidate, it) }
        }
    }

    /** For tests, and for any future caller that needs to force the fold. */
    @Synchronized
    fun clear() {
        key = null
        mode = null
    }
}

/**
 * The one foreground-surface resolver for daytime-stress scoring.
 *
 * Both Stress detail and Today's hosted Stress card call this funnel. When the personal lens is off,
 * it returns immediately without touching trailing history. When it is on, today's local day is
 * excluded and the previous 30 days are reduced one at a time into the same personal baseline.
 * Background widgets deliberately do not opt in: paying for 30 days of raw reads on an unprompted
 * periodic tick would make a display preference an always-on workload.
 */
internal suspend fun selectedDaytimeStressMode(
    repo: WhoopRepository,
    deviceId: String,
    todayLocalDay: LocalDate,
    zone: ZoneId,
    personalBaseline: Boolean,
): DaytimeStress.ScoringMode {
    if (!personalBaseline) return DaytimeStress.ScoringMode.DayRelative

    val baselineHistoryDays = 30
    // One cheap fingerprint over the whole past-30-day span, then the memo. The span ENDS yesterday, so
    // today's incoming heart rate cannot invalidate it and the lens stays warm for the day. See
    // [StressLensCache].
    val spanFrom = stressLocalDayWindow(todayLocalDay.minusDays(baselineHistoryDays.toLong()), zone).fromEpochSecond
    val spanTo = stressLocalDayWindow(todayLocalDay.minusDays(1L), zone).toEpochSecondInclusive
    val cacheKey = "$deviceId|$todayLocalDay|$zone|" +
        repo.hrUnionFingerprint(deviceId, spanFrom, spanTo)
    return StressLensCache.resolve(cacheKey) {
        val aggregates = ArrayList<DaytimeBaselines.DayAggregate>(baselineHistoryDays)
        // Oldest -> newest so the EWMA fold replays history in order. Reduce each day immediately: the
        // fold needs two Doubles per day, not 30 days of raw HR and R-R held in memory at once (#2107).
        for (back in baselineHistoryDays downTo 1) {
            val window = stressLocalDayWindow(todayLocalDay.minusDays(back.toLong()), zone)
            val dayHr = repo.hrSamplesUnion(
                deviceId,
                window.fromEpochSecond,
                window.toEpochSecondInclusive,
                limit = 200_000,
            )
            if (dayHr.isEmpty()) continue
            // The live baseline scores HR only while the RMSSD term is disabled. Reading up to
            // 200k R-R rows for each of 30 days cannot change its result and delays the card.
            val dayRr = if (DaytimeStress.daytimeRMSSDScoringEnabled) {
                repo.rrIntervalsUnion(
                    deviceId,
                    window.fromEpochSecond,
                    window.toEpochSecondInclusive,
                    limit = 200_000,
                )
            } else emptyList()
            aggregates.add(
                DaytimeBaselines.dayDaytimeAggregate(dayHr, dayRr, window.offsetSeconds.toLong()),
            )
    }
    DaytimeBaselines.scoringModeFromAggregates(aggregates)
    }
}
