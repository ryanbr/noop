package com.noop.push

import android.database.Cursor
import androidx.room.withTransaction
import androidx.sqlite.db.SimpleSQLiteQuery
import com.noop.data.WhoopDatabase
import java.time.LocalDate
import java.time.ZoneId

/** SQL-side upper bound evaluated before Android materializes any unrestricted TEXT value. */
internal object PushSnapshotPreflight {
    // 4 KiB per row conservatively covers maps, entries, boxed scalars and fixed JSON syntax. The
    // remaining budget covers text at 6x its UTF-8 byte length, the maximum JSON string expansion.
    const val FIXED_ROW_OVERHEAD_BYTES = 4 * 1024L
    const val MAX_ESTIMATED_SNAPSHOT_BYTES = 48 * 1024 * 1024L

    fun rowEstimateExpression(columns: List<String>): String = buildString {
        append(FIXED_ROW_OVERHEAD_BYTES)
        columns.forEach { column ->
            append(" + (CASE WHEN $column IS NULL THEN 4 ")
            append("WHEN typeof($column) = 'text' THEN length(CAST($column AS BLOB)) * 6 + 2 ")
            append("WHEN typeof($column) = 'blob' THEN ${MAX_ESTIMATED_SNAPSHOT_BYTES + 1} ")
            append("ELSE 32 END)")
        }
    }

    fun query(
        table: String,
        columns: List<String>,
        predicate: String,
        orderBy: String,
        projections: List<String> = columns,
    ): String = "SELECT COALESCE(SUM(${rowEstimateExpression(columns)}), 0) FROM " +
        "(SELECT ${projections.joinToString()} FROM $table WHERE $predicate ORDER BY $orderBy LIMIT ?)"
}

internal object PushDeviceDiscovery {
    fun query(supportedSqlTables: List<String>): String = buildString {
        append("SELECT id AS deviceId FROM device WHERE id <> ''")
        supportedSqlTables.distinct().forEach { table ->
            append(" UNION SELECT deviceId FROM $table WHERE deviceId <> ''")
        }
        append(" ORDER BY deviceId")
    }
}

/**
 * Narrow, read-only Room snapshot adapter. SQL identifiers come exclusively from the closed enums below;
 * user/config input is always a bind argument. Every cursor is consumed and closed inside [withTransaction].
 */
class PushDao internal constructor(private val db: WhoopDatabase) : PushSnapshotSource {
    override suspend fun knownDeviceIds(capabilities: PushCapabilities): List<String> = db.withTransaction {
        val supportedTables = capabilities.appendTables.map(::appendSpec) +
            capabilities.mutableTables.map { mutableSpec(it, capabilities.protocolVersion) }
        val sql = PushDeviceDiscovery.query(supportedTables.map(TableSpec::sqlName))
        db.query(SimpleSQLiteQuery(sql)).use { cursor ->
            buildList {
                while (cursor.moveToNext()) cursor.getString(0)?.takeIf { it.isNotBlank() }?.let(::add)
            }
        }
    }

    override suspend fun appendRecordAt(
        table: PushAppendTable,
        deviceId: String,
        rowId: Long,
    ): PushAppendRecord? {
        val spec = appendSpec(table)
        return db.withTransaction {
            val args = arrayOf<Any?>(deviceId, rowId, 1)
            ensureSnapshotBounded(
                PushSnapshotPreflight.query(spec.sqlName, spec.columns, "deviceId = ? AND rowid = ?", "rowid ASC"),
                args,
            )
            val sql = "SELECT rowid AS _pushRowId, ${spec.columns.joinToString()} FROM ${spec.sqlName} " +
                "WHERE deviceId = ? AND rowid = ? LIMIT 1"
            db.query(SimpleSQLiteQuery(sql, arrayOf(deviceId, rowId))).use { cursor ->
                if (cursor.moveToFirst()) cursor.appendRecord(spec) else null
            }
        }
    }

    override suspend fun appendRows(
        table: PushAppendTable,
        deviceId: String,
        afterRowId: Long,
        limit: Int,
    ): List<PushAppendRecord> {
        require(limit in 1..PushProtocol.MAX_RECORDS + 1)
        val spec = appendSpec(table)
        return db.withTransaction {
            val args = arrayOf<Any?>(deviceId, afterRowId, limit)
            ensureSnapshotBounded(
                PushSnapshotPreflight.query(spec.sqlName, spec.columns, "deviceId = ? AND rowid > ?", "rowid ASC"),
                args,
            )
            val sql = "SELECT rowid AS _pushRowId, ${spec.columns.joinToString()} FROM ${spec.sqlName} " +
                "WHERE deviceId = ? AND rowid > ? ORDER BY rowid ASC LIMIT ?"
            db.query(SimpleSQLiteQuery(sql, arrayOf(deviceId, afterRowId, limit))).use { cursor ->
                buildList {
                    while (cursor.moveToNext()) add(cursor.appendRecord(spec))
                }
            }
        }
    }

    override suspend fun mutableRows(
        table: PushMutableTable,
        deviceId: String,
        window: PushWindow,
        limit: Int,
    ): List<PushMutableRecord> = mutableRows(table, deviceId, window, limit, PushProtocol.VERSION)

    override suspend fun mutableRows(
        table: PushMutableTable,
        deviceId: String,
        window: PushWindow,
        limit: Int,
        protocolVersion: String,
    ): List<PushMutableRecord> {
        require(limit in 1..(PushProtocol.MAX_MUTABLE_SNAPSHOT_RECORDS + 1))
        val spec = mutableSpec(table, protocolVersion)
        return db.withTransaction {
            val (predicate, bounds) = when (table) {
                PushMutableTable.DAILY_METRIC, PushMutableTable.JOURNAL ->
                    "day >= ? AND day <= ?" to arrayOf<Any?>(window.fromDay, window.toDay)
                PushMutableTable.SLEEP_SESSION, PushMutableTable.WORKOUT ->
                    "startTs >= ? AND startTs < ?" to
                        arrayOf<Any?>(window.startTsInclusive, window.endTsExclusive)
            }
            val sql = "SELECT ${spec.projections.joinToString()} FROM ${spec.sqlName} " +
                "WHERE deviceId = ? AND $predicate ORDER BY ${spec.keyColumns.joinToString()} ASC LIMIT ?"
            val args = arrayOfNulls<Any?>(bounds.size + 2)
            args[0] = deviceId
            bounds.copyInto(args, destinationOffset = 1)
            args[args.lastIndex] = limit
            ensureSnapshotBounded(
                PushSnapshotPreflight.query(
                    spec.sqlName,
                    spec.columns,
                    "deviceId = ? AND $predicate",
                    "${spec.keyColumns.joinToString()} ASC",
                    spec.projections,
                ),
                args,
            )
            val records = db.query(SimpleSQLiteQuery(sql, args)).use { cursor ->
                buildList {
                    while (cursor.moveToNext()) add(cursor.mutableRecord(spec))
                }
            }
            if (table != PushMutableTable.DAILY_METRIC ||
                protocolVersion != PushProtocol.LATEST_VERSION || records.isEmpty()
            ) {
                records
            } else if (records.last().data["sleepConsistency"] != null) {
                // SleepModel prefers the imported consistency series as a whole when its latest day has a
                // point; don't mix imported values and the locally calculated fallback in one series.
                records
            } else {
                // When the latest day has no imported consistency score, SleepModel uses the local
                // bedtime-spread calculation for the series. Never substitute recovery or performance.
                val computedConsistency = sleepConsistencyByWakeDay(deviceId, window)
                records.map { record ->
                    val day = record.key["day"] as? String
                    record.copy(data = record.data + ("sleepConsistency" to day?.let(computedConsistency::get)))
                }
            }
        }
    }

    /**
     * Compute the existing trailing-14 bedtime-onset score for each local wake day in the export window.
     * Fetching the previous 13 sessions before the first in-window wake keeps the first exported score
     * identical to the Sleep screen without loading unbounded sleep history.
     */
    private fun sleepConsistencyByWakeDay(deviceId: String, window: PushWindow): Map<String, Double> {
        val zone = ZoneId.systemDefault()
        val start = LocalDate.parse(window.fromDay).atStartOfDay(zone).toEpochSecond()
        val end = LocalDate.parse(window.toDay).plusDays(1).atStartOfDay(zone).toEpochSecond()
        val inWindow = db.query(
            SimpleSQLiteQuery(
                "SELECT startTs, endTs, startTsAdjusted FROM sleepSession " +
                    "WHERE deviceId = ? AND endTs >= ? AND endTs < ? ORDER BY startTs ASC LIMIT ?",
                arrayOf(deviceId, start, end, PushProtocol.MAX_MUTABLE_SNAPSHOT_RECORDS + 1),
            ),
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    val adjusted = cursor.getColumnIndexOrThrow("startTsAdjusted")
                    add(
                        SleepConsistencySession(
                            startTs = cursor.getLong(cursor.getColumnIndexOrThrow("startTs")),
                            endTs = cursor.getLong(cursor.getColumnIndexOrThrow("endTs")),
                            startTsAdjusted = if (cursor.isNull(adjusted)) null else cursor.getLong(adjusted),
                        ),
                    )
                }
            }
        }
        if (inWindow.size > PushProtocol.MAX_MUTABLE_SNAPSHOT_RECORDS) {
            throw PushProtocolException("sleep consistency snapshot exceeds local row limit")
        }
        val firstStartTs = inWindow.firstOrNull()?.startTs ?: return emptyMap()
        val prior = db.query(
            SimpleSQLiteQuery(
                "SELECT startTs, endTs, startTsAdjusted FROM sleepSession " +
                    "WHERE deviceId = ? AND startTs < ? ORDER BY startTs DESC LIMIT 13",
                arrayOf(deviceId, firstStartTs),
            ),
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    val adjusted = cursor.getColumnIndexOrThrow("startTsAdjusted")
                    add(
                        SleepConsistencySession(
                            startTs = cursor.getLong(cursor.getColumnIndexOrThrow("startTs")),
                            endTs = cursor.getLong(cursor.getColumnIndexOrThrow("endTs")),
                            startTsAdjusted = if (cursor.isNull(adjusted)) null else cursor.getLong(adjusted),
                        ),
                    )
                }
            }
        }.asReversed()
        return SleepConsistencyPushProjection.byWakeDay(prior + inWindow, zone)
    }

    private fun ensureSnapshotBounded(sql: String, args: Array<Any?>) {
        val estimate = db.query(SimpleSQLiteQuery(sql, args)).use { cursor ->
            if (cursor.moveToFirst()) cursor.getLong(0) else 0L
        }
        if (estimate > PushSnapshotPreflight.MAX_ESTIMATED_SNAPSHOT_BYTES) {
            throw PushProtocolException("snapshot exceeds local memory limit")
        }
    }

    private fun Cursor.appendRecord(spec: TableSpec): PushAppendRecord {
        val values = values(spec)
        val rowId = getLong(getColumnIndexOrThrow("_pushRowId"))
        return PushAppendRecord(
            rowId,
            spec.keyColumns.associateWith(values::get),
            spec.dataColumns.associateWith(values::get),
        )
    }

    private fun Cursor.mutableRecord(spec: TableSpec): PushMutableRecord {
        val values = values(spec)
        return PushMutableRecord(
            spec.keyColumns.associateWith(values::get),
            spec.dataColumns.associateWith(values::get),
        )
    }

    private fun Cursor.values(spec: TableSpec): Map<String, Any?> = buildMap {
        for (name in spec.columns) {
            val index = getColumnIndexOrThrow(name)
            val value: Any? = when (getType(index)) {
                Cursor.FIELD_TYPE_NULL -> null
                Cursor.FIELD_TYPE_INTEGER -> if (name in spec.booleanColumns) getLong(index) != 0L else getLong(index)
                Cursor.FIELD_TYPE_FLOAT -> getDouble(index)
                Cursor.FIELD_TYPE_STRING -> getString(index)
                else -> throw PushProtocolException("unsupported SQLite type in ${spec.sqlName}.$name")
            }
            put(name, value)
        }
    }

    private data class TableSpec(
        val sqlName: String,
        val keyColumns: List<String>,
        val dataColumns: List<String>,
        val booleanColumns: Set<String> = emptySet(),
        val projectionOverrides: Map<String, String> = emptyMap(),
    ) {
        val columns: List<String> = keyColumns + dataColumns
        val projections: List<String> = columns.map { projectionOverrides[it] ?: it }
    }

    private fun appendSpec(table: PushAppendTable): TableSpec = when (table) {
        PushAppendTable.HR_SAMPLE -> HR
        PushAppendTable.RR_INTERVAL -> RR
        PushAppendTable.EVENT -> EVENT
        PushAppendTable.BATTERY -> BATTERY
        PushAppendTable.SPO2_SAMPLE -> SPO2
        PushAppendTable.SKIN_TEMP_SAMPLE -> SKIN_TEMP
        PushAppendTable.RESP_SAMPLE -> RESP
        PushAppendTable.GRAVITY_SAMPLE -> GRAVITY
    }

    private fun mutableSpec(
        table: PushMutableTable,
        protocolVersion: String = PushProtocol.VERSION,
    ): TableSpec = when (table) {
        PushMutableTable.DAILY_METRIC -> if (protocolVersion == PushProtocol.LATEST_VERSION) DAILY_V11 else DAILY
        PushMutableTable.SLEEP_SESSION -> SLEEP
        PushMutableTable.WORKOUT -> WORKOUT
        PushMutableTable.JOURNAL -> JOURNAL
    }

    private companion object {
        val HR = TableSpec("hrSample", listOf("ts"), listOf("bpm"))
        val RR = TableSpec(
            "rrInterval",
            listOf("ts", "rrMs", "seq"),
            listOf("ord", "srcChannel", "tsSuspect"),
        )
        val EVENT = TableSpec(
            "event", listOf("ts", "kind"), listOf("payloadJSON"),
        )
        val BATTERY = TableSpec(
            "battery", listOf("ts"), listOf("soc", "mv", "charging"),
            booleanColumns = setOf("charging"),
        )
        val SPO2 = TableSpec(
            "spo2Sample", listOf("ts"), listOf("red", "ir"),
        )
        val SKIN_TEMP = TableSpec(
            "skinTempSample", listOf("ts"), listOf("raw", "aux1Raw", "aux2Raw"),
        )
        val RESP = TableSpec("respSample", listOf("ts"), listOf("raw"))
        val GRAVITY = TableSpec(
            "gravitySample", listOf("ts"), listOf("x", "y", "z", "dynAccel"),
        )
        val DAILY = TableSpec(
            "dailyMetric",
            listOf("day"),
            listOf(
                "totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin",
                "disturbances", "restingHr", "avgHrv", "recovery", "strain", "exerciseCount", "spo2Pct",
                "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "spo2Red", "spo2Ir",
            ),
        )
        val DAILY_V11 = DAILY.copy(
            dataColumns = DAILY.dataColumns + listOf("sleepPerformance", "sleepConsistency"),
            projectionOverrides = mapOf(
                "sleepPerformance" to "(SELECT value FROM metricSeries AS pushScore " +
                    "WHERE pushScore.deviceId = dailyMetric.deviceId AND pushScore.day = dailyMetric.day " +
                    "AND pushScore.key = 'sleep_performance' LIMIT 1) AS sleepPerformance",
                "sleepConsistency" to "(SELECT value FROM metricSeries AS pushConsistency " +
                    "WHERE pushConsistency.deviceId = dailyMetric.deviceId AND pushConsistency.day = dailyMetric.day " +
                    "AND pushConsistency.key = 'sleep_consistency' LIMIT 1) AS sleepConsistency",
            ),
        )
        val SLEEP = TableSpec(
            "sleepSession",
            listOf("startTs"),
            listOf(
                "endTs", "efficiency", "restingHr", "avgHrv", "stagesJSON",
                "userEdited", "startTsAdjusted", "motionJSON", "sleepStateJSON", "stagingSparse",
            ),
            booleanColumns = setOf("userEdited", "stagingSparse"),
        )
        val WORKOUT = TableSpec(
            "workout",
            listOf("startTs", "sport"),
            listOf(
                "endTs", "source", "durationS", "energyKcal", "avgHr",
                "maxHr", "strain", "distanceM", "zonesJSON", "notes", "routePolyline", "steps",
            ),
        )
        val JOURNAL = TableSpec(
            "journal", listOf("day", "question"), listOf("answeredYes", "notes", "numericValue"),
            booleanColumns = setOf("answeredYes"),
        )
    }
}
