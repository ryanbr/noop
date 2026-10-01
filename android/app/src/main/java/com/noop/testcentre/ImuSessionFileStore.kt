package com.noop.testcentre

import android.content.Context
import com.noop.data.StreamPersistence
import com.noop.protocol.Whoop5RawImu
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileOutputStream
import java.util.zip.Deflater
import java.util.zip.Inflater

/** Stores decoded 100 Hz IMU in fixed UTC half-hour segments owned by one capture session. */
class ImuSessionFileStore(private val context: Context) {
    data class Stats(val bytes: Long, val coveredSeconds: Int, val firstTs: Long?)
    data class ExportSegment(val name: String, val data: ByteArray, val startTs: Long, val endTs: Long,
                             val sampleCount: Int)
    private data class Record(val ts: Long, val receivedAtMs: Long, val columns: ShortArray)
    private val prefs = context.getSharedPreferences("imu-session-windows", Context.MODE_PRIVATE)
    private val directory = File(context.filesDir, "raw-imu-sessions").apply { mkdirs() }

    fun start(id: String, deviceId: String, fromMs: Long) = synchronized(lock) {
        prefs.edit().putStringSet("ids", ids() + id).putString("$id.device", deviceId)
            .putLong("$id.from", fromMs / 1_000L).putLong("$id.fromMs", fromMs)
            .remove("$id.to").remove("$id.toMs").apply()
        sessionDir(id).mkdirs()
    }

    fun complete(id: String, toMs: Long) = synchronized(lock) {
        flushSession(id)
        if (id in ids()) prefs.edit().putLong("$id.to", toMs / 1_000L).putLong("$id.toMs", toMs).apply()
    }

    fun register(id: String, deviceId: String, fromMs: Long, toMs: Long) = synchronized(lock) {
        start(id, deviceId, fromMs); complete(id, toMs)
    }

    /** Remove routing only. Files are removed separately so callers can keep deletion retryable. */
    fun remove(id: String) = synchronized(lock) {
        pending.keys.filter { it.startsWith("$id/") }.forEach(pending::remove)
        seen.keys.filter { it.startsWith(sessionDir(id).absolutePath) }.forEach(seen::remove)
        prefs.edit().putStringSet("ids", ids() - id).remove("$id.device").remove("$id.from")
            .remove("$id.fromMs").remove("$id.to").remove("$id.toMs").apply()
    }

    /** True while a bounded capture is active or still missing seconds recoverable from strap history. */
    fun needsHighThroughput(deviceId: String): Boolean = synchronized(lock) {
        ids().any { id ->
            if (prefs.getString("$id.device", null) != deviceId) return@any false
            if (!prefs.contains("$id.to")) return@any true
            val fromMs = prefs.getLong("$id.fromMs", prefs.getLong("$id.from", 0L) * 1_000L)
            val toMs = prefs.getLong("$id.toMs", prefs.getLong("$id.to", 0L) * 1_000L)
            val baseFrom = (fromMs + 999L) / 1_000L
            val to = toMs / 1_000L - 1L
            if (baseFrom > to) return@any false
            val present = buildSet {
                segmentFiles(id).forEach { addAll(timestamps(it)) }
                pending.filterKeys { it.startsWith("$id/") }.values.flatten().forEach { add(it.ts) }
            }
            // Match export's one-second producer-start allowance, without hiding any later gap.
            val first = present.minOrNull()?.takeIf { it <= baseFrom + 1 } ?: baseFrom
            (first..to).any { it !in present }
        }
    }

    fun deleteFiles(id: String): Boolean = synchronized(lock) {
        flushSession(id)
        val dir = sessionDir(id)
        if (dir.listFiles().orEmpty().any { it.isDirectory || !it.delete() }) return@synchronized false
        !dir.exists() || dir.delete()
    }

    fun deleteDevice(deviceId: String): Boolean = synchronized(lock) {
        val owned = ids().filter { prefs.getString("$it.device", null) == deviceId }
        if (owned.any { !deleteFiles(it) }) return@synchronized false
        owned.forEach(::remove)
        true
    }

    fun stats(id: String, from: Long, to: Long): Stats = synchronized(lock) {
        // Coverage needs timestamps, not decoded 6-axis payloads. Reuse the per-file timestamp index
        // instead of inflating every .imus block on each one-second UI refresh.
        val covered = buildSet {
            segmentFiles(id).forEach { file -> addAll(timestamps(file).filter { it in from..to }) }
            pending.filterKeys { it.startsWith("$id/") }.values.flatten()
                .forEach { record -> if (record.ts in from..to) add(record.ts) }
        }
        val disk = segmentFiles(id).sumOf { it.length() }
        val pendingBytes = pending.filterKeys { it.startsWith("$id/") }.values.flatten()
            .sumOf { it.columns.size.toLong() * 2 + RECORD_HEADER_BYTES }
        Stats(disk + pendingBytes, covered.size, covered.minOrNull())
    }

    fun append(deviceId: String, frame: ByteArray, receivedAtMs: Long = System.currentTimeMillis()): Int = synchronized(lock) {
        val decoded = Whoop5RawImu.decode(frame) ?: return 0
        val columns = Whoop5RawImu.rawColumns(frame) ?: return 0
        val ts = decoded.baseTs
        var writes = 0
        for (id in ids()) {
            if (prefs.getString("$id.device", null) != deviceId) continue
            val from = prefs.getLong("$id.from", Long.MAX_VALUE)
            val to = if (prefs.contains("$id.to")) prefs.getLong("$id.to", Long.MIN_VALUE) else Long.MAX_VALUE
            if (ts !in from..to) continue
            val bucket = bucketStart(ts); val file = segmentFile(id, bucket)
            if (!timestamps(file).add(ts)) continue
            val key = "$id/$bucket"
            pending.getOrPut(key) { mutableListOf() } += Record(ts, receivedAtMs, columns)
            if (pending[key]!!.size >= BLOCK_SECONDS) flushKey(key)
            writes++
        }
        writes
    }

    /** Exact selected interval, still in the canonical decoded .imus format. */
    fun exportSegments(id: String, from: Long, to: Long): List<ExportSegment> = synchronized(lock) {
        flushSession(id)
        readRecords(id, from, to, includePending = false).distinctBy { it.ts }.sortedBy { it.ts }
            .groupBy { bucketStart(it.ts) }.toSortedMap().map { (bucket, records) ->
                ExportSegment("imu-${utcName(bucket)}.imus", encodeFile(bucket, records), records.first().ts,
                    records.last().ts, records.size * SAMPLE_RATE)
            }
    }

    private fun readRecords(id: String, from: Long, to: Long, includePending: Boolean): List<Record> {
        val rows = segmentFiles(id).flatMap { decodeFile(it.readBytes()) }.filter { it.ts in from..to }.toMutableList()
        if (includePending) rows += pending.filterKeys { it.startsWith("$id/") }.values.flatten().filter { it.ts in from..to }
        return rows
    }

    private fun encodeFile(bucket: Long, records: List<Record>): ByteArray {
        val output = ByteArrayOutputStream()
        DataOutputStream(output).use { out ->
            writeHeader(out, bucket); records.chunked(BLOCK_SECONDS).forEach { writeBlock(out, it) }
        }
        return output.toByteArray()
    }

    private fun decodeFile(bytes: ByteArray): List<Record> {
        if (bytes.size < FILE_HEADER_BYTES || !bytes.copyOfRange(0, MAGIC.size).contentEquals(MAGIC)) return emptyList()
        val rows = mutableListOf<Record>()
        DataInputStream(ByteArrayInputStream(bytes)).use { input ->
            input.skipBytes(MAGIC.size); input.readLong()
            if (input.readInt() != SAMPLE_RATE || input.readInt() != AXES) return emptyList()
            while (true) try {
                val count = input.readInt(); val rawSize = input.readInt(); val compressedSize = input.readInt()
                if (count !in 1..BLOCK_SECONDS || rawSize !in 1..MAX_BLOCK_BYTES || compressedSize !in 1..MAX_BLOCK_BYTES) break
                val compressed = ByteArray(compressedSize); input.readFully(compressed)
                val raw = inflate(compressed, rawSize) ?: break
                var valid = true
                DataInputStream(ByteArrayInputStream(raw)).use { block -> for (index in 0 until count) {
                    val ts = block.readLong(); val received = block.readLong(); val length = block.readInt()
                    if (length != PAYLOAD_BYTES) { valid = false; break }
                    val packed = ByteArray(length); block.readFully(packed)
                    rows += Record(ts, received, unpackColumns(packed))
                }}
                if (!valid) break
            } catch (_: EOFException) { break }
        }
        return rows
    }

    private fun flushSession(id: String) = pending.keys.filter { it.startsWith("$id/") }.toList().forEach(::flushKey)
    private fun flushKey(key: String) {
        val records = pending.remove(key).orEmpty(); if (records.isEmpty()) return
        val id = key.substringBefore('/'); val bucket = key.substringAfter('/').toLong()
        val file = segmentFile(id, bucket); file.parentFile?.mkdirs(); val newFile = !file.exists()
        DataOutputStream(FileOutputStream(file, true).buffered()).use { out ->
            if (newFile) writeHeader(out, bucket)
            writeBlock(out, records)
        }
    }

    private fun writeHeader(out: DataOutputStream, bucket: Long) {
        out.write(MAGIC); out.writeLong(bucket); out.writeInt(SAMPLE_RATE); out.writeInt(AXES)
    }

    private fun writeBlock(out: DataOutputStream, records: List<Record>) {
        val rawBytes = ByteArrayOutputStream()
        DataOutputStream(rawBytes).use { block -> records.forEach { record ->
            val packed = StreamPersistence.packImuColumns(record.columns)
            block.writeLong(record.ts); block.writeLong(record.receivedAtMs); block.writeInt(packed.size); block.write(packed)
        }}
        val raw = rawBytes.toByteArray(); val compressed = deflate(raw)
        out.writeInt(records.size); out.writeInt(raw.size); out.writeInt(compressed.size); out.write(compressed)
    }

    private fun timestamps(file: File): MutableSet<Long> = seen.getOrPut(file.absolutePath) {
        decodeFile(file.takeIf(File::isFile)?.readBytes() ?: byteArrayOf()).mapTo(mutableSetOf()) { it.ts }
    }
    private fun ids() = prefs.getStringSet("ids", emptySet()).orEmpty()
    private fun sessionDir(id: String) = File(directory, id)
    private fun segmentFiles(id: String) = sessionDir(id).listFiles { f -> f.isFile && f.extension == "imus" }
        .orEmpty().sortedBy { it.name }
    private fun segmentFile(id: String, bucket: Long) = File(sessionDir(id), "imu-${utcName(bucket)}.imus")

    private fun deflate(raw: ByteArray): ByteArray {
        val d = Deflater(); d.setInput(raw); d.finish(); val out = ByteArray(raw.size + 128)
        val size = d.deflate(out); d.end(); return out.copyOf(size)
    }
    private fun inflate(compressed: ByteArray, size: Int): ByteArray? {
        val i = Inflater(); i.setInput(compressed); val out = ByteArray(size)
        val written = runCatching { i.inflate(out) }.getOrDefault(0); i.end(); return out.takeIf { written == size }
    }
    private fun unpackColumns(bytes: ByteArray) = ShortArray(bytes.size / 2) { index ->
        ((bytes[index * 2].toInt() and 0xff) or (bytes[index * 2 + 1].toInt() shl 8)).toShort()
    }

    companion object {
        private val lock = Any(); private val seen = mutableMapOf<String, MutableSet<Long>>()
        private val pending = mutableMapOf<String, MutableList<Record>>()
        private val MAGIC = "NOOPIMU2".toByteArray(Charsets.US_ASCII)
        const val SAMPLE_RATE = 100; const val AXES = 6; const val BLOCK_SECONDS = 30
        const val SEGMENT_SECONDS = 30 * 60L; const val PAYLOAD_BYTES = SAMPLE_RATE * AXES * 2
        private const val RECORD_HEADER_BYTES = 20L; private const val FILE_HEADER_BYTES = 24
        private const val MAX_BLOCK_BYTES = BLOCK_SECONDS * (PAYLOAD_BYTES + 20)
        internal fun bucketStart(ts: Long) = Math.floorDiv(ts, SEGMENT_SECONDS) * SEGMENT_SECONDS
        internal fun utcName(ts: Long): String = java.time.format.DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'")
            .withZone(java.time.ZoneOffset.UTC).format(java.time.Instant.ofEpochSecond(ts))
    }
}
