package com.noop.analytics

import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopRepository
import java.util.TimeZone

/**
 * HydrationStore — the logging + read seam for the Hydration tracker (MVP, opt-in, local-only).
 *
 * Kotlin twin of the Swift hydration store calls. The day total is banked in the generic metric-series
 * store under the [KEY] series, keyed by the device's LOCAL calendar day — the SAME `metricSeries`
 * table + `WhoopRepository.upsertMetricSeries` path every other generic daily series uses (no schema
 * change). Because that table holds one row per (deviceId, day, key), a tap reads the day's running
 * total and re-upserts total + amount, so the stored value IS "the sum of today's hydration logged for
 * this local day". Everything stays on-device; nothing is synced.
 *
 * `ts` (a wall-clock unix second) selects which local day a log lands on; the goal itself comes from the
 * pure [HydrationGoal] engine, never from here.
 */
object HydrationStore {

    /**
     * #989 (Kotlin twin of Repository.hydrationSeq): bumped on every mutation ([log] / [set]; [remove]
     * routes through [set]). Hydration writes never touch the flows Today already collects (`days` only
     * changes on a data refresh), so the dashboard card sat stale until an unrelated sync. Today keys its
     * hydration re-read on this too.
     */
    val mutationSeq = kotlinx.coroutines.flow.MutableStateFlow(0)

    /** The generic metric-series key the day total is banked under (shared id; keep == the Swift key). */
    const val KEY: String = "hydration"

    /** The source/device id the hydration total is written under — its own local-only source so it is
     *  never confused with strap-imported or computed metrics. Matches the Swift source id. */
    const val SOURCE_ID: String = "hydration"

    /**
     * The series key for water IMPORTED from the platform health store — Health Connect here, Apple
     * Health on iOS (#949). Keep == the Swift `HydrationStore.importedKey`.
     *
     * Its own row rather than folded into [KEY], because the two behave differently on write: [KEY]
     * ACCUMULATES (each tap adds to it), while this one is REPLACED with the health store's recomputed
     * day sum on every import. That replacement is what makes re-importing idempotent without tracking
     * individual sample ids — Health Connect hands back every record in the window, so summing them and
     * storing the result wholesale means a second import of the same day stores the same number, and a
     * drink deleted in the source app makes the figure go DOWN next time rather than being stranded.
     *
     * Hand-logged water is never touched by an import, and imported water is not editable here — it is
     * owned by the app that logged it.
     */
    const val KEY_IMPORTED: String = "hydrationImported"

    /** Seconds EAST of UTC for the device's current zone — the offset [AnalyticsEngine.dayString] needs
     *  to bucket a timestamp on the LOCAL calendar day (matches the dashboard's local "today" read). */
    private fun localOffsetSec(atMillis: Long = System.currentTimeMillis()): Long =
        (TimeZone.getDefault().getOffset(atMillis) / 1000).toLong()

    /** The LOCAL yyyy-MM-dd day key for a unix-seconds [ts] (defaults to now). */
    fun dayKey(ts: Long = System.currentTimeMillis() / 1000L): String =
        AnalyticsEngine.dayString(ts, localOffsetSec(ts * 1000L))

    /**
     * Log [amountMl] of fluid for the local day containing [ts] (defaults to now). Reads the day's
     * current total and upserts total + amount under [SOURCE_ID]/[KEY], so repeated taps accumulate.
     * A non-positive amount is a no-op. Returns the new day total (ml). Idempotency is by design absent —
     * each tap is an additive log, matching the WHOOP-style quick-add buttons.
     */
    suspend fun log(repo: WhoopRepository, amountMl: Int, ts: Long = System.currentTimeMillis() / 1000L): Double {
        if (amountMl <= 0) return total(repo, ts)
        val day = dayKey(ts)
        // The MANUAL row, never the combined figure (#949): a quick-add stores `current + amount`, so
        // reading the combined total would copy every imported millilitre into the hand-logged row, and
        // the next import would then add the imported water on top of that copy. One tap after an import
        // would silently double the day, compounding on every tap after it.
        val current = manualTotal(repo, ts)
        val next = current + amountMl
        repo.upsertMetricSeries(listOf(MetricSeriesRow(SOURCE_ID, day, KEY, next)))
        mutationSeq.value += 1   // #989: tell Today's card directly (see mutationSeq)
        return next + importedTotal(repo, ts)
    }

    /**
     * Pure clamp behind [set]: a day total can never be negative. Factored out so the correction math
     * (#798) is unit-testable without a Room/repo stand-in. Returns [totalMl] floored at 0.0.
     */
    fun clampedTotal(totalMl: Double): Double = totalMl.coerceAtLeast(0.0)

    /**
     * Pure result of removing [amountMl] from a [currentTotalMl] (#798): a non-positive amount is a no-op
     * (the current total, still clamped at 0), otherwise the difference floored at 0 so an over-subtraction
     * lands on an empty day rather than a negative total. The testable core of [remove].
     */
    fun afterRemoving(currentTotalMl: Double, amountMl: Int): Double =
        if (amountMl <= 0) clampedTotal(currentTotalMl) else clampedTotal(currentTotalMl - amountMl)

    /**
     * Set the day total directly to [totalMl] for the local day containing [ts], clamped at 0 (a negative
     * target lands on 0, never a negative total). The correction seam behind the detail screen's
     * delete/undo affordances (#798): because the schema banks ONE additive total per (source, day, key)
     * row, an entry isn't separately addressable - removing or editing a log is expressed as adjusting the
     * day total. Returns the new stored total (ml). Mirrors the iOS `setHydration`.
     */
    suspend fun set(repo: WhoopRepository, totalMl: Double, ts: Long = System.currentTimeMillis() / 1000L): Double {
        val day = dayKey(ts)
        val next = clampedTotal(totalMl)
        // Sets the HAND-LOGGED row only (#949). Imported water is not the user's to correct from here —
        // it belongs to the app that logged it, and an import would overwrite the edit on the next run.
        repo.upsertMetricSeries(listOf(MetricSeriesRow(SOURCE_ID, day, KEY, next)))
        mutationSeq.value += 1   // #989: edits/deletes route through here too
        return next + importedTotal(repo, ts)
    }

    /**
     * Remove [amountMl] from the local day's running total (the undo / delete-a-log path for the detail
     * screen, #798). Subtracts the amount and clamps at 0 so the total never goes negative; a non-positive
     * amount is a no-op. Returns the new day total (ml). Built on [set] + [afterRemoving] so the correction
     * math is shared + tested. Mirrors the iOS `removeHydration`.
     */
    suspend fun remove(repo: WhoopRepository, amountMl: Int, ts: Long = System.currentTimeMillis() / 1000L): Double {
        if (amountMl <= 0) return total(repo, ts)
        // Subtract from the MANUAL row (#949). Against the combined figure this would be badly wrong:
        // with 200 ml logged by hand and 500 ml imported, removing 100 would compute 700-100=600 and
        // store THAT as the hand-logged total — inflating the day to 1100 instead of reducing it to 600.
        return set(repo, afterRemoving(manualTotal(repo, ts), amountMl), ts)
    }

    /**
     * The total fluid (ml) for the local day containing [ts] as the user should SEE it: hand-logged plus
     * whatever was imported from the health store (#949). 0.0 when neither exists.
     *
     * Everything that DISPLAYS a day figure wants this. Everything that WRITES a hand-logged amount must
     * use [manualTotal] — see [log] and [remove].
     */
    suspend fun total(repo: WhoopRepository, ts: Long = System.currentTimeMillis() / 1000L): Double =
        manualTotal(repo, ts) + importedTotal(repo, ts)

    /** Only what the user logged by hand — the row [log] accumulates into and [set] overwrites. */
    suspend fun manualTotal(repo: WhoopRepository, ts: Long = System.currentTimeMillis() / 1000L): Double =
        dayValue(repo, KEY, dayKey(ts))

    /** Only what came from the health store (#949). Replaced wholesale by each import. */
    suspend fun importedTotal(repo: WhoopRepository, ts: Long = System.currentTimeMillis() / 1000L): Double =
        dayValue(repo, KEY_IMPORTED, dayKey(ts))

    private suspend fun dayValue(repo: WhoopRepository, key: String, day: String): Double =
        repo.metricSeries(SOURCE_ID, key, day, day).firstOrNull()?.value ?: 0.0

    /**
     * Pure: sum metric rows into ml-per-day (#949). Rows for the same day ADD, which is the whole point —
     * the hand-logged and imported series are two rows on the same day, and a plain `associate { }` would
     * keep only the last one and silently drop the other from every bar in the history chart.
     */
    fun sumByDay(rows: List<MetricSeriesRow>): Map<String, Double> {
        val out = HashMap<String, Double>()
        for (r in rows) out[r.day] = (out[r.day] ?: 0.0) + r.value
        return out
    }

    /**
     * Pure: what an import should WRITE for a window (#949), given the days it covers and the ml it
     * actually found. Every day in [windowDays] gets a value — days with no water resolve to 0.0 rather
     * than being omitted, which is what makes a drink deleted in the source app disappear here instead of
     * leaving the old figure stranded forever.
     *
     * Days found outside the window are dropped: writing them would be a partial update of a day this
     * import never fully examined, so the figure could not be trusted as a replacement.
     */
    fun importWindow(windowDays: List<String>, found: Map<String, Double>): Map<String, Double> =
        windowDays.associateWith { clampedTotal(found[it] ?: 0.0) }

    /**
     * Replace the imported-water total for each (dayKey → ml) pair with the health store's recomputed day
     * sum (#949). Called by the Health Connect import; the iOS twin is `Repository.setImportedHydration`.
     *
     * REPLACES rather than adds — that is what makes re-importing idempotent (see [KEY_IMPORTED]). The
     * caller is expected to pass 0.0 for days it found no water on, so a drink deleted in the source app
     * disappears here too instead of lingering as a stale row.
     */
    suspend fun setImported(repo: WhoopRepository, mlByDay: Map<String, Double>) {
        if (mlByDay.isEmpty()) return
        repo.upsertMetricSeries(
            mlByDay.map { (day, ml) -> MetricSeriesRow(SOURCE_ID, day, KEY_IMPORTED, clampedTotal(ml)) },
        )
        mutationSeq.value += 1   // #989: Today's card reads hydration off this
    }

    /**
     * The last [days] local-day totals up to and including today, OLDEST first, as (dayKey, ml) pairs —
     * one entry per calendar day with 0.0 for days that have no log. Backs the detail screen's 7-day
     * mini bar history. [days] is clamped ≥ 1.
     */
    suspend fun history(
        repo: WhoopRepository,
        days: Int = 7,
        nowSec: Long = System.currentTimeMillis() / 1000L,
    ): List<Pair<String, Double>> {
        val n = days.coerceAtLeast(1)
        val from = nowSec - (n - 1).toLong() * 86_400L
        val fromKey = dayKey(from)
        val toKey = dayKey(nowSec)
        // Both rows, summed per day via [sumByDay] (#949) — the bars have to agree with the Today card
        // and the ring, and those read the combined [total]. Reading only [KEY] renders an imported day
        // short. Projected onto the full day grid below so empty days read as 0 rather than vanishing.
        val byDay = sumByDay(
            repo.metricSeries(SOURCE_ID, KEY, fromKey, toKey) +
                repo.metricSeries(SOURCE_ID, KEY_IMPORTED, fromKey, toKey),
        )
        return (0 until n).map { i ->
            val key = dayKey(nowSec - (n - 1 - i).toLong() * 86_400L)
            key to (byDay[key] ?: 0.0)
        }
    }
}
