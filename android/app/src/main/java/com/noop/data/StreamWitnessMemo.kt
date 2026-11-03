package com.noop.data

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Where and when rows of the raw streams changed, bucketed by `(table, deviceId, ts / 3600)`.
 *
 * Each bucket keeps the hull `[lo, hi]` of the timestamps that changed in it and the newest stamp that touched
 * it. Merging into a hull can only report a change that did not reach a window, never miss one that did: a row
 * at `ts` inside `[from, to]` lands in bucket `ts / 3600`, which is one of the window's own buckets because
 * truncating division is monotonic. A false report costs one recount, never a wrong witness. Twin of Swift
 * `StreamChangeSpans`.
 */
internal class StreamChangeSpans {
    private class Span(var lo: Long, var hi: Long, var stamp: Long)
    private class PerDevice { var latest = 0L; val byHour = HashMap<Long, Span>() }
    private val tables = HashMap<String, HashMap<String, PerDevice>>()

    /** Buckets held, across every table and device. */
    var hours = 0
        private set

    fun record(table: String, deviceId: String, lo: Long, hi: Long, stamp: Long) {
        val device = tables.getOrPut(table) { HashMap() }.getOrPut(deviceId) { PerDevice() }
        device.latest = maxOf(device.latest, stamp)
        for (hour in lo / 3600..hi / 3600) {
            val span = device.byHour[hour]
            if (span == null) {
                device.byHour[hour] = Span(lo, hi, stamp)
                hours += 1
            } else {
                span.lo = minOf(span.lo, lo); span.hi = maxOf(span.hi, hi); span.stamp = maxOf(span.stamp, stamp)
            }
        }
    }

    /** Whether any of [names] changed for [deviceId] inside `[from, to]` after [stamp]. */
    fun changed(stamp: Long, names: List<String>, deviceId: String, from: Long, to: Long): Boolean {
        if (from > to) return false
        for (name in names) {
            val device = tables[name]?.get(deviceId) ?: continue
            if (device.latest <= stamp) continue
            val first = from / 3600
            val last = to / 3600
            // Walk whichever is shorter: the window's hours, or the hours this device has changed in.
            if (last - first < device.byHour.size) {
                for (hour in first..last) {
                    val span = device.byHour[hour] ?: continue
                    if (span.stamp > stamp && span.lo <= to && span.hi >= from) return true
                }
            } else {
                for ((hour, span) in device.byHour) {
                    if (hour in first..last && span.stamp > stamp && span.lo <= to && span.hi >= from) return true
                }
            }
        }
        return false
    }

    /** Drop every bucket no later than [stamp]: nothing that asks [changed] with a stamp at or past it can
     *  see them. */
    fun prune(stamp: Long) {
        val byTable = tables.values.iterator()
        while (byTable.hasNext()) {
            val devices = byTable.next()
            val byDevice = devices.values.iterator()
            while (byDevice.hasNext()) {
                val device = byDevice.next()
                val held = device.byHour.size
                device.byHour.values.removeAll { it.stamp <= stamp }
                hours -= held - device.byHour.size
                if (device.byHour.isEmpty()) byDevice.remove()
            }
            if (devices.isEmpty()) byTable.remove()
        }
    }

    fun clear() {
        tables.clear()
        hours = 0
    }

    companion object {
        /** How many buckets a holder keeps before it gives up and starts over (about two years of hours on
         *  one stream). Starting over is always safe: every memo is recounted once. */
        const val HOUR_LIMIT = 20_000
    }
}

/**
 * The stream changes a rowid frontier cannot see, noted by the code that makes them.
 *
 * [StreamWitnessMemo] learns of inserts by reading rows above each table's rowid frontier, which catches every
 * insert, a backfill of an old night included. Two kinds of change leave the frontier where it was. An in-place
 * UPDATE of a stream row (the R-R source promotion and fill flag in [WhoopRepository.insert]) keeps its rowid,
 * so it is noted here per device and span, after its transaction commits. A DELETE or re-key can also hand a
 * freed rowid to the next insert, below a frontier already read, so it runs inside [removing], which moves
 * `epoch` before AND after the write: a witness taken while it runs carries the first move, and the second
 * invalidates it again once the rows are gone.
 *
 * Process-wide rather than per repository, because the app builds more than one [WhoopRepository] over the
 * same database, and an edit made through one must invalidate the memo of another. Twin of Swift
 * `StreamEditJournal`.
 */
internal object StreamEditJournal {
    data class Mark(val epoch: Long, val clock: Long)

    private var epoch = 0L
    private var clock = 0L
    private val edits = StreamChangeSpans()

    /** Read BEFORE the reads a witness is counted from. An edit noted after this has a later stamp, so
     *  whether or not those reads saw it, the memo it guards is recounted next time. */
    @Synchronized fun mark(): Mark = Mark(epoch, clock)

    /** Call after the edit's transaction committed, never inside it. */
    @Synchronized fun noteEdit(table: String, deviceId: String, from: Long, to: Long) {
        clock += 1
        val lo = minOf(from, to)
        val hi = maxOf(from, to)
        // A span too wide to bucket, or a journal at its bound, is noted the way a removal is: every memo is
        // recounted once.
        if (hi / 3600 - lo / 3600 >= StreamChangeSpans.HOUR_LIMIT || edits.hours >= StreamChangeSpans.HOUR_LIMIT) {
            epoch += 1
            edits.clear()
            return
        }
        edits.record(table, deviceId, lo, hi, clock)
    }

    @Synchronized fun noteRemoval() {
        epoch += 1
        clock += 1
        edits.clear()
    }

    /** Runs a write that deletes or re-keys stream rows, noted before and after it. */
    inline fun <R> removing(write: () -> R): R {
        noteRemoval()
        try {
            return write()
        } finally {
            noteRemoval()
        }
    }

    @Synchronized fun edited(since: Mark, tables: List<String>, deviceId: String, from: Long, to: Long): Boolean =
        epoch != since.epoch || edits.changed(since.clock, tables, deviceId, from, to)
}

/**
 * Answers a per-window witness from memory while its window provably has not changed (#2314).
 *
 * The analyzeRecent pass asks for three witnesses per cached night ([WhoopRepository.dayHrFingerprint],
 * [WhoopRepository.dayStreamFingerprint] and [WhoopRepository.gravityFingerprintWindow]), and each is a COUNT(*)
 * over a window of 1 Hz streams. COUNT(*) walks every index entry in its range, so a pass over sixteen unchanged
 * nights walked all sixteen again. The values are not changed here: a witness is still that COUNT/MAX result,
 * byte for byte; this only decides when it has to be counted again.
 *
 * The decision comes from each stream's rowid frontier ([STREAM_LANDINGS_SQL]). Every stream inserts with
 * IGNORE, and an insert takes a rowid above every existing one, so the rows above the frontier read last time
 * are exactly what landed since, wherever in time they belong. A memo is reused while no landing, no noted
 * edit and no removal reached its tables, device and window ([StreamEditJournal]). A frontier that went
 * backwards means a delete nobody noted: the tracker re-bases and every memo is recounted.
 *
 * Room gives the landings read and the count separate transactions, so the landings are read FIRST: a row that
 * lands between the two is counted now and reported as a landing next time, which costs a recount and never
 * hides a change. Per repository and in memory only, like the day cache it serves. Twin of Swift
 * `StreamWitnessMemo`, which reads both from one snapshot.
 */
internal class StreamWitnessMemo {
    /** Which witness, which tables it counts, and so which changes can stale it. */
    enum class Kind(val tables: List<String>) {
        HR(listOf("hrSample")),
        GRAVITY(listOf("gravitySample")),
        DAY_STREAMS(listOf("ppgHrSample", "rrInterval", "respSample", "spo2Sample", "gravitySample",
            "stepSample", "skinTempSample", "sleepStateSample", "event")),
    }

    private data class Key(val kind: Kind, val deviceId: String, val from: Long, val to: Long, val variant: Any?)
    private class Entry(val value: Any, val generation: Long, val landed: Long, val journal: StreamEditJournal.Mark)

    private val mutex = Mutex()
    private var frontier: Map<String, Long>? = null
    private var generation = 0L
    private var stamp = 0L
    private var epochSeen: Long? = null
    private val landings = StreamChangeSpans()
    private val entries = HashMap<Key, Entry>()

    /**
     * The witness for one window: the memo when nothing reached it since it was counted, otherwise [count].
     * [variant] is any other input the value depends on that no stream frontier sees; a different one is a
     * different key. [readLandings] runs [STREAM_LANDINGS_SQL] with the frontiers in [TRACKED] order.
     */
    suspend fun <T : Any> witness(
        kind: Kind,
        deviceId: String,
        from: Long,
        to: Long,
        variant: Any?,
        readLandings: suspend (LongArray) -> List<StreamLanding>,
        count: suspend () -> T,
    ): T = mutex.withLock {
        val mark = StreamEditJournal.mark()
        val known = frontier
        refresh(readLandings(LongArray(TRACKED.size) { known?.get(TRACKED[it].second) ?: Long.MAX_VALUE }), mark.epoch)
        val key = Key(kind, deviceId, from, to, variant)
        val entry = entries[key]
        if (entry != null && entry.generation == generation &&
            !landings.changed(entry.landed, kind.tables, deviceId, from, to) &&
            !StreamEditJournal.edited(entry.journal, kind.tables, deviceId, from, to)
        ) {
            @Suppress("UNCHECKED_CAST")
            return@withLock entry.value as T
        }
        val value = count()
        if (entries.size >= ENTRY_LIMIT) entries.clear()
        // Today's window ends at `now`, so it is a new key every pass; keep only the latest per start.
        entries.keys.removeAll { it.kind == kind && it.deviceId == deviceId && it.from == from }
        entries[key] = Entry(value, generation, stamp, mark)
        value
    }

    private fun refresh(rows: List<StreamLanding>, epoch: Long) {
        val tops = HashMap<String, Long>()
        val landed = ArrayList<StreamLanding>()
        for (row in rows) {
            val table = TABLE_OF[row.tbl] ?: continue
            if (row.deviceId != null) landed += row else tops[table] = row.top ?: 0L
        }
        val old = frontier
        val regressed = old != null && tops.any { (table, top) -> top < (old[table] ?: 0L) }
        if (old == null || regressed || epochSeen != epoch) {
            // First look, a frontier that went backwards, or a noted removal: rowids at or below the old frontier
            // may now belong to new rows, so nothing counted against it can be trusted.
            generation += 1
            landings.clear()
            entries.clear()
            frontier = tops
            epochSeen = epoch
            return
        }
        frontier = tops
        if (landed.isEmpty()) return
        stamp += 1
        for (row in landed) {
            landings.record(TABLE_OF.getValue(row.tbl), row.deviceId!!, row.lo ?: 0L, row.hi ?: 0L, stamp)
        }
        // Landings no live memo predates can never be asked about again.
        val oldest = entries.values.minOfOrNull { it.landed }
        if (oldest != null) landings.prune(oldest) else landings.clear()
        // A window nobody asks for any more pins the prune above; past the bound, start over.
        if (landings.hours >= StreamChangeSpans.HOUR_LIMIT) {
            generation += 1
            landings.clear()
            entries.clear()
        }
    }

    companion object {
        /** The raw streams in the order [STREAM_LANDINGS_SQL] binds them; the letters are its own. */
        val TRACKED = listOf(
            "h" to "hrSample", "p" to "ppgHrSample", "r" to "rrInterval", "x" to "respSample",
            "g" to "gravitySample", "s" to "sleepStateSample", "e" to "event", "o" to "spo2Sample",
            "t" to "skinTempSample", "z" to "stepSample",
        )
        private val TABLE_OF = TRACKED.toMap()

        /** Bounds the memo; a pass keeps about a hundred windows alive. Past it everything is recounted once. */
        private const val ENTRY_LIMIT = 1_024
    }
}
