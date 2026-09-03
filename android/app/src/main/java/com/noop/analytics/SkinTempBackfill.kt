package com.noop.analytics

import com.noop.data.WhoopRepository
import com.noop.protocol.DeviceFamily
import com.noop.data.HrSample
import com.noop.data.SkinTempSample
import com.noop.protocol.Whoop4SkinTemp

/**
 * #1851: fill in the nightly ABSOLUTE skin temperature for nights that only ever stored a deviation.
 *
 * `skinTempC` shipped on 2026-08-27 (#1663) and is written by the scoring pass, which walks a rolling
 * 21-night window. Nights already outside that window when the column landed were never revisited, so an
 * install can hold weeks of deviations and only a handful of temperatures — which is what the Temperature
 * setting (#1846) then has to work with.
 *
 * The raw material is still there: `skinTempSample` has no age-based retention, and the only DELETE is the
 * #547 plausibility quarantine, which removes rows OUTSIDE a valid timestamp window rather than old ones.
 *
 * ## This RE-DERIVES, it does not reconstruct
 *
 * `absolute = baseline + deviation` is available arithmetic and is wrong: the baseline is a rolling value
 * that drifts over weeks, so applying one night's baseline to another night's delta manufactures numbers
 * that read as measurements. This instead re-runs [AnalyticsEngine.skinTempFunnel] — the SAME function the
 * engine uses, over the same night window — so a backfilled night and a scored night are computed by one
 * code path and cannot disagree.
 *
 * ## It cannot destroy data
 *
 * Two independent guarantees, because this writes to rows the user cannot regenerate:
 *  - the write is a single-column UPDATE (`fillSkinTempAbsolute`), never an entity upsert that would blank
 *    columns it did not carry;
 *  - that statement carries `AND skinTempC IS NULL`, so it can only fill a hole. A value the engine or an
 *    import already wrote is never overwritten, and no other column is touched.
 *
 * Nothing here nulls anything, and a night that yields no mean is simply left alone.
 *
 * ## The WHOOP 4.0 anchor
 *
 * On a 4.0 the raw→°C conversion is anchored per device (#938), and that anchor is learned window-wide.
 * The engine's own note says the offset is safe because it "cancels in the deviation" — true for a delta,
 * NOT for an absolute. Re-learning an anchor from the old window being filled would put those nights on a
 * different offset from the ones already stored, and the chart would plot two scales as one line: both
 * labelled °C, both plausible, silently wrong.
 *
 * So the caller passes the anchor the engine is currently using. When a 4.0 has none resolvable, the
 * backfill declines that device rather than writing on a guessed offset. WHOOP 5/MG carries no anchor
 * (`raw / 100`) and is unaffected.
 */
object SkinTempBackfill {

    /**
     * Nights per run — deliberately small.
     *
     * Each fillable night costs an HR read, and the engine's own note calls those "the big ~86k-row ones".
     * A years-deep history in one pass would be exactly the #836/#841 battery shape this feature exists
     * beside, so the work drains across successive scoring passes instead. Nights with no skin samples are
     * skipped BEFORE their HR read, so the unfillable ones stay cheap.
     */
    const val DEFAULT_MAX_NIGHTS = 60

    /**
     * What a run did. `filled` is nights given a temperature; `noMean` is nights whose raw samples exist
     * but did not survive the worn gate or the minimum-sample floor; `noSamples` is nights with nothing to
     * re-derive from. The three are reported separately because they need different answers — the last one
     * is unrecoverable and should not be presented as "try again".
     */
    data class Report(
        val candidates: Int = 0,
        val filled: Int = 0,
        val noMean: Int = 0,
        val noSamples: Int = 0,
        /** Nights with no stored sleep session ending on them — nothing to compute a nightly mean over. */
        val noSessions: Int = 0,
        /** The newest day this page examined; the caller's cursor for the next page. Empty when none. */
        val lastDay: String = "",
        /** True when the page came back short — every outstanding night has now been visited this sweep. */
        val sweepComplete: Boolean = false,
        val declinedNoAnchor: Boolean = false,
    ) {
        val examined: Int get() = filled + noMean + noSamples + noSessions
    }

    /**
     * Whether this device can be backfilled at all, and on what anchor.
     *
     * Returns null when a WHOOP 4.0 has no resolved anchor — see the anchor note above. A null result is a
     * DECLINE, never "use the global default": the global 826 anchor maps a second real strap's worn band
     * to 47–72 °C, so writing on it would bank temperatures that are not just imprecise but outside human
     * range, into a column nothing downstream re-checks.
     */
    fun anchorFor(family: DeviceFamily, currentAnchorRaw: Double?): Double? = when (family) {
        DeviceFamily.WHOOP5 -> Whoop4SkinTemp.ANCHOR_RAW   // ignored by the 5/MG conversion; any value is inert
        DeviceFamily.WHOOP4 -> currentAnchorRaw
    }

    /** True when [family] needs a per-device anchor before any absolute may be written. */
    fun requiresAnchor(family: DeviceFamily): Boolean = family == DeviceFamily.WHOOP4

    /**
     * The night window for a day, byte-identical to the engine's: 30 h before local midnight (a night that
     * began the previous evening) through [readWindowEnd]. Taking the same bounds is what keeps a
     * backfilled night's sample set the same one the scoring pass would have used.
     */
    fun nightWindow(dayStartLocal: Long, readWindowEnd: Long): LongRange =
        (dayStartLocal - NIGHT_LOOKBACK_SECONDS)..readWindowEnd

    /** 30 h, matching `IntelligenceEngine`'s `from = dayStart - 30 * 3_600L`. */
    const val NIGHT_LOOKBACK_SECONDS: Long = 30 * 3_600L

    /**
     * Re-derive one night's absolute from its raw samples, or null when the funnel keeps nothing.
     *
     * Sessions come from the STORED `sleepSession` rows rather than fresh detection — they are that
     * detection's own persisted output, so the same nights are covered without paying to re-detect them.
     * A night edited or deleted since is the one case where the two could differ, and there the stored row
     * is the more truthful input anyway: it is what the rest of the app already shows.
     */
    fun nightlyAbsolute(
        sessions: List<DetectedSleep>,
        hr: List<HrSample>,
        skinTemp: List<SkinTempSample>,
        family: DeviceFamily,
        anchorRaw: Double?,
        wornToleranceSec: Long,
    ): Double? = AnalyticsEngine.skinTempFunnel(
        sessions = sessions,
        hr = hr,
        skinTemp = skinTemp,
        family = family,
        anchorRaw = anchorRaw,
        wornToleranceSec = wornToleranceSec,
    ).mean

    /**
     * The sessions belonging to a day, by the engine's own rule (#277):
     *
     *     val matched = allSessions.filter { tsInDay(it.end) }
     *     // Sessions attributed to `day` = those whose end falls on `day` (LOCAL day)
     *
     * The night window is 54 h wide — 30 h before local midnight through the next one — because a night
     * belonging to day D starts on the evening of D-1. That width also catches the night belonging to
     * D-1, so handing the funnel everything the window returned would average two nights into one
     * temperature and store it as D's. Attribute by END, exactly as the engine does, or the backfill
     * writes numbers that are wrong rather than merely absent.
     */
    fun sessionsEndingOnDay(
        sessions: List<Pair<Long, Long>>,
        dayStartLocal: Long,
        dayEndExclusive: Long,
    ): List<DetectedSleep> =
        sessions.filter { (_, end) -> end >= dayStartLocal && end < dayEndExclusive }
            .map { (start, end) -> sessionOf(start, end) }

    /** A stored sleep row as the funnel's session type. Only `start`/`end` are read; the rest is inert. */
    fun sessionOf(startTs: Long, endTs: Long): DetectedSleep =
        DetectedSleep(
            start = startTs,
            end = endTs,
            efficiency = 0.0,
            stages = emptyList(),
            restingHR = null,
            avgHRV = null,
        )

    /**
     * The COMPUTED namespace a scored row lives in — `<strap>-noop`, matching the engine's
     * `computedId = importedDeviceId + "-noop"`.
     *
     * This backfill straddles two namespaces and querying one for both finds nothing at all:
     *  - dailyMetric rows and sleepSession rows are written by the engine under the COMPUTED id;
     *  - raw skinTempSample / hrSample rows are banked under the STRAP id ("raw rows sit under the strap
     *    id and the ... computed rows under the -noop id").
     *
     * Idempotent on an id that is already computed, mirroring the repository's own `ownerComputed` idiom.
     */
    fun computedIdFor(deviceId: String): String =
        if (deviceId.endsWith("-noop")) deviceId else "$deviceId-noop"

    /** One PAGE of candidate day keys, strictly after [afterDay]. See the DAO's note on why this pages. */
    suspend fun candidates(
        repo: WhoopRepository,
        deviceId: String,
        afterDay: String,
        max: Int = DEFAULT_MAX_NIGHTS,
    ): List<String> = repo.daysMissingSkinTempAbsolute(deviceId, afterDay, max)

    /**
     * Walk the candidate nights and fill what can be re-derived.
     *
     * [currentAnchorRaw] must be the anchor the engine is using NOW, not one learned from the window being
     * filled — see the anchor note on this object. A 4.0 without one is declined outright.
     *
     * Reads one night at a time rather than one big span: the deep-history case is exactly where a single
     * unbounded read would be worst, and a per-night read is also what lets a cancelled run leave every
     * night it already filled correctly filled.
     */
    suspend fun run(
        repo: WhoopRepository,
        /** The STRAP id. Row reads/writes use its computed twin; raw sample reads use it directly. */
        deviceId: String,
        family: DeviceFamily,
        currentAnchorRaw: Double?,
        wornToleranceSec: Long,
        zone: java.time.ZoneId = java.time.ZoneId.systemDefault(),
        nowSeconds: Long = System.currentTimeMillis() / 1000,
        afterDay: String = "",
        max: Int = DEFAULT_MAX_NIGHTS,
        limit: Int = STREAM_LIMIT,
    ): Report {
        if (requiresAnchor(family) && currentAnchorRaw == null) {
            return Report(declinedNoAnchor = true)
        }
        val anchor = anchorFor(family, currentAnchorRaw)
        val rowId = computedIdFor(deviceId)
        val days = candidates(repo, rowId, afterDay, max)
        if (days.isEmpty()) return Report(sweepComplete = true)

        val nowLocalMidnight = java.time.Instant.ofEpochSecond(nowSeconds)
            .atZone(zone).toLocalDate().atStartOfDay(zone).toEpochSecond()
        var filled = 0
        var noMean = 0
        var noSamples = 0
        var noSessions = 0
        for (day in days) {
            val dayStart = runCatching {
                java.time.LocalDate.parse(day).atStartOfDay(zone).toEpochSecond()
            }.getOrNull() ?: continue
            val window = nightWindow(dayStart, IntelligenceEngine.sleepReadWindowEnd(dayStart, nowLocalMidnight, nowSeconds))
            // Sessions FIRST, and attributed to this day, so the reads below cover one night rather than
            // the 54 h window — which also shrinks the HR read, the expensive one, from ~54 h to ~8 h.
            val sessions = sessionsEndingOnDay(
                repo.sleepSessionsForDevice(rowId, window.first, window.last, limit)
                    // Honour a user-edited start the same way every other surface does.
                    .map { (it.startTsAdjusted ?: it.startTs) to it.endTs },
                dayStartLocal = dayStart,
                dayEndExclusive = dayStart + SECONDS_PER_DAY,
            )
            if (sessions.isEmpty()) { noSessions++; continue }
            val readFrom = sessions.minOf { it.start }
            val readTo = sessions.maxOf { it.end }
            val skin = repo.skinTempSamples(deviceId, readFrom, readTo, limit)
            if (skin.isEmpty()) { noSamples++; continue }
            val hr = repo.hrSamplesForDevice(deviceId, readFrom, readTo, limit)
            val mean = nightlyAbsolute(sessions, hr, skin, family, anchor, wornToleranceSec)
            if (mean == null) { noMean++; continue }
            // Fill-only by construction; a row that gained an absolute meanwhile reports 0 and is left be.
            if (repo.fillSkinTempAbsolute(rowId, day, mean) > 0) filled++ else noMean++
        }
        return Report(
            candidates = days.size, filled = filled, noMean = noMean,
            noSamples = noSamples, noSessions = noSessions,
            lastDay = days.last(),
            // A short page means this sweep has seen every outstanding night.
            sweepComplete = days.size < max,
        )
    }

    /** Per-night read cap, matching the engine's stream limit. */
    const val STREAM_LIMIT = 200_000

    /** Seconds in a local day, for the end-of-day bound the engine attributes sessions by. */
    const val SECONDS_PER_DAY: Long = 86_400L
}
