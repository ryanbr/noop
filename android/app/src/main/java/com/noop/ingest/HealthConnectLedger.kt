package com.noop.ingest

import android.content.Context

/**
 * What NOOP has already written to Health Connect, so it can take it back (#1677).
 *
 * The writer is idempotent by `clientRecordId` and versions each record so a later, fuller copy upserts
 * over an earlier one. That covers a record whose id STAYS THE SAME. It cannot cover a record whose id
 * stops being produced — Health Connect never removes an id you simply stop writing.
 *
 * That case is routine for sleep, not exotic. `sleepSession`'s primary key is (deviceId, startTs), so a
 * re-detection that lands on a different start is a DIFFERENT ROW, and the #1248/#1284 heal deletes the
 * stale row once a fuller copy wins — `SleepSessionDedup` exists because one night really can accumulate
 * several rows with different starts. The exporter's only cleanup path, `absorbedClientIds`, is computed
 * from rows STILL IN THE DATABASE, so the moment the heal drops that row the exporter loses all knowledge
 * that it ever wrote a Health Connect record under its id. The record then cannot be corrected or removed
 * by any later export, which is exactly what #1677 reports: re-running the export does not fix it.
 *
 * So the exporter needs a memory of its own. This is that memory: the ids written per record type, and
 * the rule for which of them a later export should retract.
 */
object HealthConnectLedger {

    /** One entry per record type whose id embeds a MUTABLE timestamp. Day-keyed ids
     *  (`noop-<metric>-<day>`) need no ledger: a day never changes its own key. */
    const val SLEEP_PREFIX = "noop-sleep-"
    const val WORKOUT_PREFIX = "noop-workout-"

    /**
     * PER STRAP, and that is load-bearing rather than tidy.
     *
     * The export is device-scoped: `sleepSessionsMerged(deviceId)` reads that strap union the canonical
     * id, so nights banked under a DIFFERENT strap are not in its result. With one shared ledger, an
     * export running as strap B would find strap A's ids absent-but-in-window and retract them —
     * deleting Health Connect records that are perfectly valid, for a user who did nothing but switch
     * which strap is active. Before any of this those records merely lingered; a global key would have
     * turned a harmless staleness into data loss.
     *
     * Keyed per strap, each export can only ever take back what that same strap put there. Nights under
     * the canonical id appear in every strap's union, so they land in every ledger and are never the odd
     * one out.
     *
     * Pure so the separation is pinned by a test rather than by this comment.
     */
    fun ledgerKey(deviceId: String, prefix: String) = "hc.written.$deviceId.$prefix"

    fun previouslyWritten(context: Context, deviceId: String, prefix: String): Set<String> =
        prefs(context).getStringSet(ledgerKey(deviceId, prefix), emptySet()) ?: emptySet()

    fun remember(context: Context, deviceId: String, prefix: String, ids: Set<String>) {
        // A COPY: SharedPreferences keeps the very set instance it was handed, and mutating or re-reading
        // it afterwards is documented as undefined. Cheap insurance against a bug that only shows up later.
        prefs(context).edit().putStringSet(ledgerKey(deviceId, prefix), HashSet(ids)).apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(com.noop.ui.NoopPrefs.NAME, Context.MODE_PRIVATE)

    /**
     * What the ledger should carry into the NEXT export.
     *
     * Not simply the ids just written. A retraction that FAILED — Health Connect unavailable, the
     * permission pulled mid-export, a transient remote error — still has a live record behind it, and
     * dropping its id here would forget it forever. That is the exact failure this whole file exists to
     * prevent, reintroduced through the error path, and the first version of this change had it.
     *
     * So a failed retraction stays on the books and is retried next time. It costs one id in a
     * SharedPreferences set until it succeeds.
     */
    fun ledgerAfterExport(current: Set<String>, unretracted: Set<String>): Set<String> =
        current + unretracted

    /**
     * Which previously-written ids should this export RETRACT?
     *
     * The obvious answer — everything we wrote before and are not writing now — is WRONG, and wrong in
     * the most expensive direction: it deletes the user's data. The export covers a rolling window, so a
     * night that simply aged out of that window is absent from [current] while its Health Connect record
     * is perfectly good. Retracting it would silently destroy history the user still has.
     *
     * So an id is retracted only when its own timestamp falls INSIDE the window this export actually
     * covered. Outside it, the export had nothing to say about that record and says nothing.
     *
     * An id whose timestamp cannot be parsed is never retracted. It is not ours to reason about, and
     * guessing costs data while abstaining costs one stale row.
     *
     * Pure so both rules are pinned without a Health Connect client or a clock.
     */
    fun staleClientIds(
        previous: Set<String>,
        current: Set<String>,
        prefix: String,
        windowStartSec: Long,
        nowSec: Long,
    ): List<String> = previous
        .asSequence()
        .filter { it !in current }
        .filter { id ->
            val ts = id.removePrefix(prefix).toLongOrNull()
            ts != null && ts in windowStartSec..nowSec
        }
        .sorted()   // deterministic, so a log line and a test read the same order
        .toList()
}
