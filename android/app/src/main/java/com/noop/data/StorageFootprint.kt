package com.noop.data

import androidx.sqlite.db.SimpleSQLiteQuery

/**
 * #1911: estimated payload bytes per decoded stream table. Swift twin: `WhoopStore.storageByteEstimates`,
 * and meta.json's `row_bytes` block beside `rows`.
 *
 * Rows alone cannot say which table holds a large store. `ppgWaveformSample` stores a BLOB whose size
 * varies, and it is both the table a per-second row model misprices worst and the one this question is
 * usually about — so the estimate MEASURES the blob rather than assuming a fixed row width.
 *
 * A hand-written class over [WhoopDatabase] rather than a method on [WhoopRepository], following
 * [com.noop.push.PushDao]: the repository takes a DAO and a transactor precisely so its writes stay
 * testable without a Room runtime, and raw per-table SQL needs the open helper. Keeping it out preserves
 * that boundary instead of quietly widening it for a diagnostic.
 */
internal class StorageFootprint(private val db: WhoopDatabase) {

    /**
     * Payload bytes per table, keyed exactly as `WhoopRepository.storageRowCounts` keys, so a maintainer
     * comparing meta.json across platforms is comparing the same two maps.
     *
     * `typeof()` at runtime rather than the declared type, and byte length via `CAST(... AS BLOB)` rather
     * than `length()`: SQLite is dynamically typed, so a column declared INTEGER can hold text, and
     * `length()` on text counts CHARACTERS while the store spends bytes. The same shape
     * `PushSnapshotPreflight.rowEstimateExpression` uses, without its JSON-expansion factors — this
     * measures the database, not a snapshot of it.
     *
     * Sampled over [sampleRows] rows and multiplied by the count, never scanned: a full sum over a
     * multi-gigabyte store is exactly the read this diagnostic exists to help someone avoid. The limit is
     * clamped because SQLite reads a NEGATIVE limit as no limit at all, which would full-scan every table
     * — the precise cost the sampling avoids, reached by a number that reads like it asks for less work.
     *
     * Payload only: no index pages, no page slack, no WAL. Read it against `db_bytes`, not as a second
     * file size. An unreadable or empty table is omitted rather than reported as zero, matching the row
     * counts — absent means "nothing to attribute here", which is not a measured zero.
     */
    fun byteEstimates(rowCounts: Map<String, Int>, sampleRows: Int = 500): Map<String, Int> = runCatching {
        val raw = db.openHelper.writableDatabase
        val limit = maxOf(1, sampleRows)
        val out = mutableMapOf<String, Int>()
        for ((key, table) in STORAGE_TABLES) {
            val rows = rowCounts[key] ?: continue
            if (rows <= 0) continue
            val cols = mutableListOf<String>()
            raw.query(SimpleSQLiteQuery("PRAGMA table_info(`$table`)")).use { c ->
                val i = c.getColumnIndex("name")
                if (i >= 0) while (c.moveToNext()) cols.add(c.getString(i))
            }
            if (cols.isEmpty()) continue
            val terms = cols.joinToString(" + ") { col -> rowSizeTerm(col) }
            val sql = "SELECT AVG(n) FROM (SELECT ($terms) AS n FROM `$table` LIMIT $limit)"
            raw.query(SimpleSQLiteQuery(sql)).use { c ->
                if (c.moveToFirst() && !c.isNull(0)) out[key] = Math.round(c.getDouble(0) * rows).toInt()
            }
        }
        out.toMap()
    }.getOrDefault(emptyMap())

    internal companion object {
        /** One column's contribution to a row's payload. Byte-true for text and blobs, nominal otherwise. */
        internal fun rowSizeTerm(column: String): String =
            "(CASE WHEN `$column` IS NULL THEN 0 " +
                "WHEN typeof(`$column`) IN ('text','blob') THEN length(CAST(`$column` AS BLOB)) " +
                "ELSE 8 END)"

        /**
         * The decoded stream tables and the key each reports under — Swift's `WhoopStore.rawTableKeys`,
         * verbatim, and the same keys `WhoopRepository.storageRowCounts` uses. Adding a stream means
         * adding it in all three, and the Apple side fails a test until it is.
         */
        internal val STORAGE_TABLES: List<Pair<String, String>> = listOf(
            "hr" to "hrSample", "rr" to "rrInterval", "events" to "event", "battery" to "battery",
            "spo2" to "spo2Sample", "skinTemp" to "skinTempSample", "resp" to "respSample",
            "gravity" to "gravitySample", "steps" to "stepSample", "ppgHr" to "ppgHrSample",
            "sleepState" to "sleepStateSample", "ppgWaveform" to "ppgWaveformSample",
            "v18Aux" to "v18AuxSample",
        )
    }
}
