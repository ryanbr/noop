package com.noop.push

import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID

class PushProtocolException(message: String) : IllegalArgumentException(message)

/** Deterministic, bounded NDJSON encoder and acknowledgement codec for the negotiated push version. */
object PushProtocol {
    const val VERSION = "1.0"
    const val LATEST_VERSION = "1.1"
    val SUPPORTED_VERSIONS = listOf(LATEST_VERSION, VERSION)
    const val MAX_RECORDS = 5_000
    /** Hard limit for the decoded UTF-8 NDJSON entity, before optional content coding. */
    const val MAX_BODY_BYTES = 4 * 1024 * 1024
    /** Deflate framing can be slightly larger than incompressible input; keep that copy bounded too. */
    const val MAX_WIRE_BODY_BYTES = MAX_BODY_BYTES + 64 * 1024
    const val MAX_ACK_BYTES = 16 * 1024
    internal const val SNAPSHOT_PAGE_SIZE = 5_000
    // A rolling window may be multipart, but client memory use is fail-closed and independent of DB size.
    internal const val MAX_MUTABLE_SNAPSHOT_RECORDS = 1_000
    internal const val MAX_MUTABLE_SNAPSHOT_ENCODED_BYTES = 2 * 1024 * 1024
    internal val FORBIDDEN_REMOTE_CONTROL_MEMBERS = setOf(
        "command", "commands", "endpoint", "url", "cadence", "schema", "fields",
    )

    fun appendBatch(
        table: PushAppendTable,
        sourceId: String,
        deviceId: String,
        startCursor: PushCursor?,
        records: List<PushAppendRecord>,
        protocolVersion: String = VERSION,
    ): PushBatch {
        requireSupportedVersion(protocolVersion)
        validateUuid(sourceId, "sourceId")
        if (records.isEmpty()) throw PushProtocolException("append batch must contain a record")
        require(records.zipWithNext().all { (a, b) -> a.rowId < b.rowId }) {
            "append records must be strictly ordered by rowid"
        }
        records.forEach { validateRecord(table, it.key, it.data, protocolVersion) }
        val candidates = records.take(MAX_RECORDS)
        val selectedRows = ArrayList<PushAppendRecord>(candidates.size)
        val selectedLines = ArrayList<ByteArray>(candidates.size)
        var rowBytes = 0
        for (i in candidates.indices) {
            val candidate = candidates[i]
            // Encode one row at a time so rows beyond the decoded entity bound never create a
            // second page-sized collection of byte arrays in memory.
            val encodedRow = encodeRecordLine(candidate)
            val end = cursorFor(table, deviceId, candidate)
            val candidateCount = selectedRows.size + 1
            val headerSize = appendHeader(
                sourceId, table, deviceId, startCursor, end, candidateCount, UUID_PLACEHOLDER, protocolVersion,
            ).size
            if (headerSize + rowBytes + encodedRow.size > MAX_BODY_BYTES) break
            selectedRows += candidate
            selectedLines += encodedRow
            rowBytes += encodedRow.size
        }
        if (selectedRows.isEmpty()) throw PushProtocolException("first append record exceeds the 4 MiB decoded batch limit")

        val endCursor = cursorFor(table, deviceId, selectedRows.last())
        val identity = appendIdentity(sourceId, table, deviceId, startCursor, endCursor, selectedRows.size, protocolVersion)
        val batchId = stableUuid(identity, selectedLines)
        val header = appendHeader(sourceId, table, deviceId, startCursor, endCursor, selectedRows.size, batchId, protocolVersion)
        val body = concatenate(header, selectedLines)
        check(body.size <= MAX_BODY_BYTES)
        return PushBatch(
            protocolVersion = protocolVersion,
            batchId = batchId,
            sourceId = sourceId,
            table = table,
            deviceId = deviceId,
            mode = "append",
            startCursor = startCursor,
            endCursor = endCursor,
            recordCount = selectedRows.size,
            window = null,
            body = body,
        )
    }

    /** Builds every bounded part of one authoritative replacement. Empty snapshots produce one part. */
    fun mutableBatches(
        table: PushMutableTable,
        sourceId: String,
        deviceId: String,
        window: PushWindow,
        records: List<PushMutableRecord>,
        protocolVersion: String = VERSION,
    ): List<PushBatch> {
        requireSupportedVersion(protocolVersion)
        validateUuid(sourceId, "sourceId")
        records.forEach { validateRecord(table, it.key, it.data, protocolVersion) }
        val duplicate = records.groupingBy { orderedObjectJson(it.key) }.eachCount().any { it.value > 1 }
        if (duplicate) throw PushProtocolException("replace_window contains a duplicate key")
        val lines = records.map(::encodeRecordLine)
        val replacementIdentity = mapOf(
            "deviceId" to deviceId,
            "delivery" to "replace_window",
            "protocolVersion" to protocolVersion,
            "sourceId" to sourceId,
            "stream" to table.wireName,
            "window" to selectorBounds(table, window),
        )
        val replacementId = stableUuid(replacementIdentity, lines)

        val chunks = mutableListOf<MutableList<ByteArray>>()
        var current = mutableListOf<ByteArray>()
        var currentBytes = 0
        for (line in lines) {
            val nextCount = current.size + 1
            val conservativeHeader = mutableHeader(
                sourceId = sourceId,
                table = table,
                deviceId = deviceId,
                window = window,
                replacementId = replacementId,
                part = Int.MAX_VALUE,
                parts = Int.MAX_VALUE,
                count = nextCount,
                batchId = UUID_PLACEHOLDER,
                protocolVersion = protocolVersion,
            )
            if (nextCount > MAX_RECORDS || conservativeHeader.size + currentBytes + line.size > MAX_BODY_BYTES) {
                if (current.isEmpty()) throw PushProtocolException("first replace_window record exceeds the 4 MiB decoded batch limit")
                chunks += current
                current = mutableListOf()
                currentBytes = 0
            }
            val oneHeader = mutableHeader(
                sourceId, table, deviceId, window, replacementId,
                Int.MAX_VALUE, Int.MAX_VALUE, 1, UUID_PLACEHOLDER, protocolVersion,
            )
            if (oneHeader.size + line.size > MAX_BODY_BYTES) {
                throw PushProtocolException("replace_window record exceeds the 4 MiB decoded batch limit")
            }
            current += line
            currentBytes += line.size
        }
        if (current.isNotEmpty() || chunks.isEmpty()) chunks += current

        val parts = chunks.size
        return chunks.mapIndexed { index, partLines ->
            val part = index + 1
            val identity = mutableIdentity(
                sourceId, table, deviceId, window, replacementId, part, parts, partLines.size, protocolVersion,
            )
            val batchId = stableUuid(identity, partLines)
            val header = mutableHeader(
                sourceId, table, deviceId, window, replacementId, part, parts, partLines.size, batchId, protocolVersion,
            )
            val body = concatenate(header, partLines)
            check(partLines.size <= MAX_RECORDS && body.size <= MAX_BODY_BYTES)
            PushBatch(
                protocolVersion = protocolVersion,
                batchId = batchId,
                sourceId = sourceId,
                table = table,
                deviceId = deviceId,
                mode = "replace_window",
                startCursor = null,
                endCursor = null,
                recordCount = partLines.size,
                window = window,
                replacementId = replacementId,
                part = part,
                parts = parts,
                body = body,
            )
        }
    }

    fun mutableBatch(
        table: PushMutableTable,
        sourceId: String,
        deviceId: String,
        window: PushWindow,
        records: List<PushMutableRecord>,
        protocolVersion: String = VERSION,
    ): PushBatch = mutableBatches(table, sourceId, deviceId, window, records, protocolVersion).singleOrNull()
        ?: throw PushProtocolException("replace_window requires multiple parts")

    /** SHA-256(stream LF device LF compact-natural-key), matching cursor invalidation contract. */
    fun keyFingerprint(table: PushAppendTable, deviceId: String, key: Map<String, Any?>): String {
        validateRecordKeys(table, key)
        return sha256Hex("${table.wireName}\n$deviceId\n${orderedObjectJson(key)}".toByteArray(Charsets.UTF_8))
    }

    internal fun mutableRecordEncodedSize(
        table: PushMutableTable,
        record: PushMutableRecord,
        protocolVersion: String = VERSION,
    ): Int {
        validateRecord(table, record.key, record.data, protocolVersion)
        return encodeRecordLine(record).size
    }

    /** Stable local content identity. It is progress metadata and is never sent to the receiver. */
    internal fun mutableSnapshotHash(
        table: PushMutableTable,
        records: List<PushMutableRecord>,
        protocolVersion: String = VERSION,
    ): String {
        val lines = records.map { record ->
            validateRecord(table, record.key, record.data, protocolVersion)
            encodeRecordLine(record)
        }.sortedWith { left, right -> compareBytes(left, right) }
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update("noop-push-day-hash\n$protocolVersion\n${table.wireName}\n".toByteArray(Charsets.UTF_8))
        lines.forEach(digest::update)
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    internal fun canonicalJson(value: Any?): String = buildString { appendCanonical(value, sortMaps = true) }

    private fun orderedObjectJson(value: Map<String, Any?>): String = buildString {
        appendCanonical(value, sortMaps = false)
    }

    private fun StringBuilder.appendCanonical(value: Any?, sortMaps: Boolean) {
        when (value) {
            null -> append("null")
            is String -> appendQuoted(value)
            is Boolean -> append(if (value) "true" else "false")
            is Byte, is Short, is Int, is Long -> append((value as Number).toLong())
            is Float, is Double -> {
                val d = (value as Number).toDouble()
                if (!d.isFinite()) throw PushProtocolException("non-finite number is not valid JSON")
                append(java.lang.Double.toString(d))
            }
            is Map<*, *> -> {
                val entries = value.entries.map {
                    val key = it.key as? String ?: throw PushProtocolException("JSON object key must be a string")
                    key to it.value
                }.let { if (sortMaps) it.sortedBy { entry -> entry.first } else it }
                append('{')
                entries.forEachIndexed { index, (key, item) ->
                    if (index > 0) append(',')
                    appendQuoted(key)
                    append(':')
                    appendCanonical(item, sortMaps)
                }
                append('}')
            }
            is Iterable<*> -> {
                append('[')
                value.forEachIndexed { index, item ->
                    if (index > 0) append(',')
                    appendCanonical(item, sortMaps)
                }
                append(']')
            }
            else -> throw PushProtocolException("unsupported JSON value ${value::class.java.name}")
        }
    }

    private fun StringBuilder.appendQuoted(value: String) {
        append('"')
        for (ch in value) {
            when (ch) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\b' -> append("\\b")
                '\u000C' -> append("\\f")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (ch.code < 0x20) append("\\u%04x".format(ch.code)) else append(ch)
            }
        }
        append('"')
    }

    private fun encodeRecordLine(record: PushAppendRecord): ByteArray =
        encodeLine(mapOf("data" to record.data, "key" to record.key, "type" to "record"))

    private fun encodeRecordLine(record: PushMutableRecord): ByteArray =
        encodeLine(mapOf("data" to record.data, "key" to record.key, "type" to "record"))

    private fun encodeLine(value: Map<String, Any?>): ByteArray =
        (canonicalJson(value) + "\n").toByteArray(Charsets.UTF_8)

    private fun appendIdentity(
        sourceId: String,
        table: PushAppendTable,
        deviceId: String,
        start: PushCursor?,
        end: PushCursor,
        count: Int,
        protocolVersion: String,
    ): Map<String, Any?> = mapOf(
        "delivery" to "append",
        "deviceId" to deviceId,
        "endCursor" to cursorJson(end),
        "protocolVersion" to protocolVersion,
        "recordCount" to count,
        "sourceId" to sourceId,
        "startCursor" to start?.let(::cursorJson),
        "stream" to table.wireName,
        "type" to "batch",
    )

    private fun appendHeader(
        sourceId: String,
        table: PushAppendTable,
        deviceId: String,
        start: PushCursor?,
        end: PushCursor,
        count: Int,
        batchId: String,
        protocolVersion: String,
    ): ByteArray = encodeLine(
        appendIdentity(sourceId, table, deviceId, start, end, count, protocolVersion) + ("batchId" to batchId),
    )

    private fun mutableIdentity(
        sourceId: String,
        table: PushMutableTable,
        deviceId: String,
        window: PushWindow,
        replacementId: String,
        part: Int,
        parts: Int,
        count: Int,
        protocolVersion: String,
    ): Map<String, Any?> = mapOf(
        "delivery" to "replace_window",
        "deviceId" to deviceId,
        "endCursor" to null,
        "protocolVersion" to protocolVersion,
        "recordCount" to count,
        "sourceId" to sourceId,
        "startCursor" to null,
        "stream" to table.wireName,
        "type" to "batch",
        "window" to (selectorBounds(table, window) + mapOf(
            "part" to part,
            "parts" to parts,
            "replacementId" to replacementId,
        )),
    )

    private fun mutableHeader(
        sourceId: String,
        table: PushMutableTable,
        deviceId: String,
        window: PushWindow,
        replacementId: String,
        part: Int,
        parts: Int,
        count: Int,
        batchId: String,
        protocolVersion: String,
    ): ByteArray = encodeLine(
        mutableIdentity(sourceId, table, deviceId, window, replacementId, part, parts, count, protocolVersion) +
            ("batchId" to batchId),
    )

    private fun selectorBounds(table: PushMutableTable, window: PushWindow): Map<String, Any?> = when (table) {
        PushMutableTable.DAILY_METRIC, PushMutableTable.JOURNAL -> mapOf(
            "endExclusive" to java.time.LocalDate.parse(window.toDay).plusDays(1).toString(),
            "selector" to "day",
            "startInclusive" to window.fromDay,
        )
        PushMutableTable.SLEEP_SESSION, PushMutableTable.WORKOUT -> mapOf(
            "endExclusive" to window.endTsExclusive,
            "selector" to "startTs",
            "startInclusive" to window.startTsInclusive,
        )
    }

    private fun cursorFor(table: PushAppendTable, deviceId: String, record: PushAppendRecord) =
        PushCursor(record.rowId, keyFingerprint(table, deviceId, record.key))

    private fun cursorJson(cursor: PushCursor): Map<String, Any?> = mapOf(
        "keySha256" to cursor.naturalKeyFingerprint,
        "rowId" to cursor.rowId,
    )

    private fun stableUuid(header: Map<String, Any?>, lines: List<ByteArray>): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(canonicalJson(header).toByteArray(Charsets.UTF_8))
        digest.update('\n'.code.toByte())
        lines.forEach(digest::update)
        val bytes = digest.digest().copyOf(16)
        bytes[6] = ((bytes[6].toInt() and 0x0f) or 0x50).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3f) or 0x80).toByte()
        val buffer = java.nio.ByteBuffer.wrap(bytes)
        return UUID(buffer.long, buffer.long).toString()
    }

    private fun concatenate(header: ByteArray, lines: List<ByteArray>): ByteArray {
        val out = ByteArray(header.size + lines.sumOf { it.size })
        var offset = 0
        header.copyInto(out, offset)
        offset += header.size
        lines.forEach { line ->
            line.copyInto(out, offset)
            offset += line.size
        }
        return out
    }

    private fun compareBytes(left: ByteArray, right: ByteArray): Int {
        val common = minOf(left.size, right.size)
        for (index in 0 until common) {
            val difference = (left[index].toInt() and 0xff) - (right[index].toInt() and 0xff)
            if (difference != 0) return difference
        }
        return left.size - right.size
    }

    private fun validateRecord(
        table: PushTable,
        key: Map<String, Any?>,
        data: Map<String, Any?>,
        protocolVersion: String,
    ) {
        requireSupportedVersion(protocolVersion)
        val spec = REGISTRY.getValue(table.wireName)
        val dataMembers = dataMembers(table, protocolVersion)
        if (key.keys.toList() != spec.first) throw PushProtocolException("${table.wireName} key does not match registry")
        if (data.keys.toSet() != dataMembers.toSet() || data.size != dataMembers.size) {
            throw PushProtocolException("${table.wireName} data does not match registry")
        }
        if (table == PushMutableTable.DAILY_METRIC && protocolVersion == LATEST_VERSION) {
            for (name in listOf("sleepPerformance", "sleepConsistency")) {
                val score = data[name]
                if (score != null &&
                    (score !is Number || !score.toDouble().isFinite() || score.toDouble() !in 0.0..100.0)
                ) {
                    throw PushProtocolException("dailyMetric.$name must be null or within 0..100")
                }
            }
        }
        if ("deviceId" in key || "deviceId" in data || "synced" in data) {
            throw PushProtocolException("batch-scoped or local-only column in record")
        }
    }

    private fun dataMembers(table: PushTable, protocolVersion: String): List<String> {
        val members = REGISTRY.getValue(table.wireName).second
        return if (table == PushMutableTable.DAILY_METRIC && protocolVersion == LATEST_VERSION) {
            members + listOf("sleepPerformance", "sleepConsistency")
        } else members
    }

    private fun requireSupportedVersion(protocolVersion: String) {
        if (protocolVersion !in SUPPORTED_VERSIONS) {
            throw PushProtocolException("unsupported protocol version")
        }
    }

    private fun validateRecordKeys(table: PushAppendTable, key: Map<String, Any?>) {
        if (key.keys.toList() != REGISTRY.getValue(table.wireName).first) {
            throw PushProtocolException("${table.wireName} key does not match registry")
        }
    }

    private fun validateUuid(value: String, name: String) {
        if (runCatching { UUID.fromString(value).toString() }.getOrNull() != value) {
            throw PushProtocolException("$name must be a lowercase canonical UUID")
        }
    }

    private fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private const val UUID_PLACEHOLDER = "00000000-0000-0000-0000-000000000000"

    private val REGISTRY: Map<String, Pair<List<String>, List<String>>> = mapOf(
        "hrSample" to (listOf("ts") to listOf("bpm")),
        "rrInterval" to (listOf("ts", "rrMs", "seq") to listOf("ord", "srcChannel", "tsSuspect")),
        "event" to (listOf("ts", "kind") to listOf("payloadJSON")),
        "battery" to (listOf("ts") to listOf("soc", "mv", "charging")),
        "spo2Sample" to (listOf("ts") to listOf("red", "ir")),
        "skinTempSample" to (listOf("ts") to listOf("raw", "aux1Raw", "aux2Raw")),
        "respSample" to (listOf("ts") to listOf("raw")),
        "gravitySample" to (listOf("ts") to listOf("x", "y", "z", "dynAccel")),
        "dailyMetric" to (listOf("day") to listOf(
            "totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin", "disturbances",
            "restingHr", "avgHrv", "recovery", "strain", "exerciseCount", "spo2Pct",
            "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "spo2Red", "spo2Ir",
        )),
        "sleepSession" to (listOf("startTs") to listOf(
            "endTs", "efficiency", "restingHr", "avgHrv", "stagesJSON", "userEdited",
            "startTsAdjusted", "motionJSON", "sleepStateJSON", "stagingSparse",
        )),
        "workout" to (listOf("startTs", "sport") to listOf(
            "endTs", "source", "durationS", "energyKcal", "avgHr", "maxHr", "strain",
            "distanceM", "zonesJSON", "notes", "routePolyline", "steps",
        )),
        "journal" to (listOf("day", "question") to listOf("answeredYes", "notes", "numericValue")),
    )
}

data class PushAck(
    val protocolVersion: String,
    val batchId: String,
    val stream: String,
    val deviceId: String,
    val endCursor: PushCursor?,
    val acceptedRows: Int,
    val status: String,
) {
    fun encode(): ByteArray = PushProtocol.canonicalJson(
        mapOf(
            "acceptedRows" to acceptedRows,
            "batchId" to batchId,
            "deviceId" to deviceId,
            "endCursor" to endCursor?.let {
                mapOf("keySha256" to it.naturalKeyFingerprint, "rowId" to it.rowId)
            },
            "protocolVersion" to protocolVersion,
            "status" to status,
            "stream" to stream,
        ),
    ).toByteArray(Charsets.UTF_8)

    fun exactlyMatches(batch: PushBatch): Boolean =
        protocolVersion == batch.protocolVersion && batchId == batch.batchId &&
            stream == batch.table.wireName && deviceId == batch.deviceId &&
            endCursor == batch.endCursor && acceptedRows == batch.recordCount && status == "accepted"

    companion object {
        fun fromBatch(batch: PushBatch): PushAck = PushAck(
            batch.protocolVersion, batch.batchId, batch.table.wireName, batch.deviceId,
            batch.endCursor, batch.recordCount, "accepted",
        )

        fun parse(bytes: ByteArray, expectedVersion: String = PushProtocol.VERSION): PushAck {
            if (bytes.size > PushProtocol.MAX_ACK_BYTES) throw PushProtocolException("ack exceeds size limit")
            val obj = try {
                JSONObject(bytes.toString(Charsets.UTF_8))
            } catch (_: Throwable) {
                throw PushProtocolException("ack is not valid JSON")
            }
            val protocolVersion = (obj.opt("protocolVersion") as? String)
                ?.takeIf { it == expectedVersion }
                ?: throw PushProtocolException("ack protocolVersion does not match the negotiated version")
            val expectedMembers = setOf(
                "protocolVersion", "batchId", "stream", "deviceId", "endCursor",
                "acceptedRows", "status",
            )
            val actualMembers = obj.keys().asSequence().toSet()
            if (!actualMembers.containsAll(expectedMembers)) {
                throw PushProtocolException("ack is missing required members")
            }
            if (actualMembers.any { it in PushProtocol.FORBIDDEN_REMOTE_CONTROL_MEMBERS }) {
                throw PushProtocolException("ack contains forbidden remote-control metadata")
            }
            fun string(name: String): String = (obj.opt(name) as? String)?.takeIf { it.isNotEmpty() }
                ?: throw PushProtocolException("ack.$name must be a non-empty string")
            fun int(name: String): Int {
                val number = obj.opt(name) as? Number ?: throw PushProtocolException("ack.$name must be an integer")
                val long = number.toLong()
                if (number.toDouble() != long.toDouble() || long !in Int.MIN_VALUE..Int.MAX_VALUE) {
                    throw PushProtocolException("ack.$name must be an integer")
                }
                return long.toInt()
            }
            val cursor = when (val raw = obj.opt("endCursor")) {
                null, JSONObject.NULL -> null
                is JSONObject -> {
                    if (!raw.keys().asSequence().toSet().containsAll(setOf("rowId", "keySha256"))) {
                        throw PushProtocolException("ack.endCursor is missing required members")
                    }
                    val row = raw.opt("rowId") as? Number
                        ?: throw PushProtocolException("ack.endCursor.rowId must be an integer")
                    val rowId = row.toLong()
                    if (row.toDouble() != rowId.toDouble()) {
                        throw PushProtocolException("ack.endCursor.rowId must be an integer")
                    }
                    val sha = (raw.opt("keySha256") as? String)?.takeIf { it.matches(Regex("[0-9a-f]{64}")) }
                        ?: throw PushProtocolException("ack.endCursor.keySha256 must be lowercase SHA-256")
                    PushCursor(rowId, sha)
                }
                else -> throw PushProtocolException("ack.endCursor must be an object or null")
            }
            return PushAck(
                protocolVersion = protocolVersion,
                batchId = string("batchId"),
                stream = string("stream"),
                deviceId = string("deviceId"),
                endCursor = cursor,
                acceptedRows = int("acceptedRows"),
                status = string("status"),
            )
        }
    }
}
