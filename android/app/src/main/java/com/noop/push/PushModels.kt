package com.noop.push

import java.time.LocalDate
import java.time.ZoneId

sealed interface PushTable {
    val wireName: String
}

/** The complete v1 append registry. Database tables are never discovered reflectively. */
enum class PushAppendTable(override val wireName: String) : PushTable {
    HR_SAMPLE("hrSample"),
    RR_INTERVAL("rrInterval"),
    EVENT("event"),
    BATTERY("battery"),
    SPO2_SAMPLE("spo2Sample"),
    SKIN_TEMP_SAMPLE("skinTempSample"),
    RESP_SAMPLE("respSample"),
    GRAVITY_SAMPLE("gravitySample");
}

enum class PushMutableTable(override val wireName: String) : PushTable {
    DAILY_METRIC("dailyMetric"),
    SLEEP_SESSION("sleepSession"),
    WORKOUT("workout"),
    JOURNAL("journal");
}

/** Key excludes deviceId (which is batch-scoped); data contains only non-key registry columns. */
data class PushAppendRecord(
    val rowId: Long,
    val key: Map<String, Any?>,
    val data: Map<String, Any?>,
) {
    init {
        require(rowId > 0) { "SQLite rowid must be positive" }
        require(key.isNotEmpty()) { "natural key must not be empty" }
    }
}

data class PushMutableRecord(
    val key: Map<String, Any?>,
    val data: Map<String, Any?>,
) {
    init {
        require(key.isNotEmpty()) { "natural key must not be empty" }
    }
}

data class PushWindow(
    val fromDay: String,
    val toDay: String,
    val startTsInclusive: Long,
    val endTsExclusive: Long,
) {
    companion object {
        fun ending(today: LocalDate, zoneId: ZoneId): PushWindow {
            val from = today.minusDays(13)
            return PushWindow(
                fromDay = from.toString(),
                toDay = today.toString(),
                startTsInclusive = from.atStartOfDay(zoneId).toEpochSecond(),
                endTsExclusive = today.plusDays(1).atStartOfDay(zoneId).toEpochSecond(),
            )
        }

        fun days(from: LocalDate, to: LocalDate, zoneId: ZoneId): PushWindow {
            require(!to.isBefore(from))
            return PushWindow(
                fromDay = from.toString(),
                toDay = to.toString(),
                startTsInclusive = from.atStartOfDay(zoneId).toEpochSecond(),
                endTsExclusive = to.plusDays(1).atStartOfDay(zoneId).toEpochSecond(),
            )
        }
    }
}

/** Persisted and transmitted cursor. The fingerprint is SHA-256, never raw key material. */
data class PushCursor(val rowId: Long, val naturalKeyFingerprint: String)

data class PushWindowProgress(
    val window: PushWindow,
    val batchId: String,
    /** Canonical SHA-256 per local calendar day; absent on pre-checksum installations. */
    val dayHashes: Map<String, String> = emptyMap(),
)

/** Fully materialized bounded request; no Room transaction survives into transport. */
data class PushBatch(
    val protocolVersion: String,
    val batchId: String,
    val sourceId: String,
    val table: PushTable,
    val deviceId: String,
    val mode: String,
    val startCursor: PushCursor?,
    val endCursor: PushCursor?,
    val recordCount: Int,
    val window: PushWindow?,
    val replacementId: String? = null,
    val part: Int? = null,
    val parts: Int? = null,
    val body: ByteArray,
)

data class PushTransportResponse(val statusCode: Int, val body: ByteArray)

/** Bounded, machine-readable receiver diagnostic; arbitrary response text is never retained. */
data class PushError(val protocolVersion: String, val code: String) {
    companion object {
        private val SAFE_CODE = Regex("[a-z][a-z0-9_]{0,63}")

        fun parseCode(bytes: ByteArray, expectedVersion: String = PushProtocol.VERSION): String? {
            if (bytes.isEmpty() || bytes.size > PushProtocol.MAX_ACK_BYTES) return null
            return runCatching {
                val obj = org.json.JSONObject(bytes.toString(Charsets.UTF_8))
                val code = obj.opt("code") as? String
                if (obj.opt("type") == "error" && obj.opt("protocolVersion") == expectedVersion &&
                    code != null && code.matches(SAFE_CODE)
                ) code else null
            }.getOrNull()
        }
    }
}

interface PushTransport {
    suspend fun capabilities(): PushCapabilitiesResult =
        PushCapabilitiesResult.Available(PushCapabilities.ALL)
    suspend fun post(batch: PushBatch): PushTransportResponse
}

interface PushProgressStore {
    suspend fun knownDeviceIds(): Set<String>
    suspend fun rememberDeviceId(deviceId: String)
    suspend fun cursor(table: PushAppendTable, deviceId: String): PushCursor?
    suspend fun saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor)
    suspend fun window(table: PushMutableTable, deviceId: String): PushWindowProgress?
    suspend fun saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress)
}

/** All methods return bounded snapshots and close their database transaction before returning. */
interface PushSnapshotSource {
    suspend fun knownDeviceIds(capabilities: PushCapabilities = PushCapabilities.ALL): List<String>

    suspend fun appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Long): PushAppendRecord?

    suspend fun appendRows(
        table: PushAppendTable,
        deviceId: String,
        afterRowId: Long,
        limit: Int,
    ): List<PushAppendRecord>

    suspend fun mutableRows(
        table: PushMutableTable,
        deviceId: String,
        window: PushWindow,
        limit: Int,
    ): List<PushMutableRecord>

    /** Newer wire versions may add an explicit projection without broadening older snapshots. */
    suspend fun mutableRows(
        table: PushMutableTable,
        deviceId: String,
        window: PushWindow,
        limit: Int,
        protocolVersion: String,
    ): List<PushMutableRecord> = mutableRows(table, deviceId, window, limit)
}

sealed interface PushResult {
    data class Accepted(
        val batchId: String,
        val recordCount: Int,
        val hasMore: Boolean,
        val batchCount: Int = 1,
    ) : PushResult

    data object NoData : PushResult

    data class Rejected(
        val reason: String,
        val retryable: Boolean,
        val failure: PushFailure? = null,
    ) : PushResult
}

data class PushRunResult(
    val acceptedBatches: Int,
    val rejectedBatches: Int,
    val hasMoreAppendRows: Boolean,
    val acceptedRecords: Int = 0,
    val hasRetryableFailure: Boolean = false,
    val nextDeviceIndex: Int = 0,
    val hasMoreDevices: Boolean = false,
    val failure: PushFailure? = null,
)
