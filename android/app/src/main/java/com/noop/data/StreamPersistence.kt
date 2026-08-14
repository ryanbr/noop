package com.noop.data

import com.noop.protocol.Streams
import org.json.JSONObject

/**
 * Bridge between the protocol-layer decode (`com.noop.protocol.Streams`) and the Room data layer's
 * insert shape ([StreamBatch]).
 *
 * The live persistence path decodes frames with `extractStreams(...)` (which yields a protocol
 * `Streams` of hr/rr/events/battery) and then needs a [StreamBatch] to hand to
 * [WhoopRepository.insert]. This mapper performs that conversion, including the deterministic
 * sorted-keys JSON encoding of each event's residual payload — the exact analog of Swift
 * `WhoopStore.encodePayload(_:)` (JSONEncoder with `.sortedKeys`), so the same payload always
 * serializes byte-identically (important for the event natural-key dedupe + macOS parity).
 *
 * `ts` widens Int (protocol, wall-clock unix seconds) -> Long (Room), matching every other ts in
 * the store.
 */
object StreamPersistence {

    /** Convert a decoded protocol [Streams] batch into the Room [StreamBatch] insert shape. */
    fun toBatch(streams: Streams): StreamBatch = StreamBatch(
        hr = streams.hr.map { HrRow(it.ts.toLong(), it.bpm) },
        // `srcChannel` (#1071) rides through unchanged: which optical channel measured the beat is
        // decided by the decoder and must survive to the row, or the two Oura channels become
        // indistinguishable and every night is stored twice over.
        rr = streams.rr.map { RrRow(it.ts.toLong(), it.rrMs, it.srcChannel) },
        events = streams.events.map { EventEntry(it.ts.toLong(), it.kind, encodePayload(it.payload)) },
        battery = streams.battery.map { BatteryRow(it.ts.toLong(), it.soc, it.mv, it.charging) },
        // The WHOOP REALTIME_DATA stream carries no SpO2/skinTemp (those are type-47-only and arrive
        // via the historical-offload path), so for a WHOOP batch these stay empty. A live source that
        // DOES decode them (the Oura ring) populates the protocol Streams' spo2/skinTemp, which widen
        // 1:1 onto the existing Room insert shape here.
        // `unit` is carried on the protocol Spo2Sample/SkinTempSample for fidelity but is not yet
        // persisted: Spo2Row/SkinTempRow (and the Room entities) have no unit column. The raw integers
        // follow fixed conventions (skinTemp = centi-°C, °C = raw/100; spo2 = raw_adc), documented on the
        // protocol carriers, so a missing column never causes a misread until a migration adds one.
        spo2 = streams.spo2.map { Spo2Row(it.ts.toLong(), it.red, it.ir) },
        skinTemp = streams.skinTemp.map { SkinTempRow(it.ts.toLong(), it.raw) },
        // resp is populated by a live source that decodes a respiration value itself — the Oura ring's
        // 0x6A `breath`, stored in milli-bpm under the ring's own deviceId (`OuraRespScale`). It stays
        // empty for a WHOOP live batch, whose respiration rows arrive on the historical-offload path.
        // The rows already carry the Room shape, so this is a pass-through, not a re-map.
        resp = streams.resp.map { RespRow(it.ts.toLong(), it.raw) },
        // gravity/steps/ppgHr remain type-47-only (historical offload), unchanged.
    )

    /**
     * Pack a decoded v26 PPG waveform's samples as little-endian i16 (2 bytes/sample) — a single compact
     * BLOB per (deviceId, ts) row instead of 24 scalar rows (issue #156 follow-up, MIGRATION_19_20). Port
     * of Swift `WhoopStore.packPpgSamples`, BYTE-IDENTICAL so a `.noopbak` round-trips across platforms.
     * Any sample count is handled (a truncated frame can decode fewer than 24); each value is truncated to
     * Int16's range (`toShort()`), matching the i16 wire format the decoder read it from.
     */
    fun packPpgSamples(samples: List<Int>): ByteArray {
        val buf = ByteArray(samples.size * 2)
        for ((i, s) in samples.withIndex()) {
            val v = s.toShort().toInt()              // truncate to 16 bits, then read low/high bytes
            buf[i * 2] = (v and 0xFF).toByte()       // little-endian: low byte first
            buf[i * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        }
        return buf
    }

    /**
     * Inverse of [packPpgSamples]. A trailing odd byte (a corrupt/truncated blob) is dropped rather than
     * thrown — a read path never crashes on a malformed row. Port of Swift `WhoopStore.unpackPpgSamples`.
     */
    fun unpackPpgSamples(data: ByteArray): List<Int> {
        val out = ArrayList<Int>(data.size / 2)
        var i = 0
        while (i + 1 < data.size) {
            val u = (data[i].toInt() and 0xFF) or ((data[i + 1].toInt() and 0xFF) shl 8)
            out.add(u.toShort().toInt())             // sign-extend the 16-bit value back to Int
            i += 2
        }
        return out
    }

    /** #423: pack the raw-IMU i16 columns to a little-endian BLOB (same wire encoding as [packPpgSamples],
     *  just a [ShortArray] source — the 6×100 columns [ax…az,gx…gz]). Byte-identical to Swift's pack. */
    fun packImuColumns(cols: ShortArray): ByteArray {
        val buf = ByteArray(cols.size * 2)
        for (i in cols.indices) {
            val v = cols[i].toInt()
            buf[i * 2] = (v and 0xFF).toByte()
            buf[i * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        }
        return buf
    }

    /** Inverse of [packImuColumns]; a trailing odd byte is dropped so a malformed row never crashes a read. */
    fun unpackImuColumns(data: ByteArray): ShortArray {
        val n = data.size / 2
        val out = ShortArray(n)
        for (i in 0 until n) {
            out[i] = ((data[i * 2].toInt() and 0xFF) or ((data[i * 2 + 1].toInt() and 0xFF) shl 8)).toShort()
        }
        return out
    }

    /**
     * Deterministic sorted-keys JSON for an event payload. Port of `WhoopStore.encodePayload`.
     *
     * `org.json.JSONObject` does NOT guarantee key order, so we build the JSON manually with keys
     * sorted ascending (the same ordering `JSONEncoder.outputFormatting = [.sortedKeys]` produces),
     * quoting each value by its Kotlin type. Empty payloads encode to `{}`, matching Swift.
     *
     * Public so the historical-offload extractor (`com.noop.protocol.extractHistoricalStreams`) can
     * encode offloaded EVENT payloads through the SAME canonical encoder the live path uses.
     */
    fun encodePayload(payload: Map<String, Any?>): String {
        if (payload.isEmpty()) return "{}"
        val sb = StringBuilder("{")
        val keys = payload.keys.sorted()
        for ((i, k) in keys.withIndex()) {
            if (i > 0) sb.append(',')
            sb.append(JSONObject.quote(k)).append(':').append(encodeValue(payload[k]))
        }
        sb.append('}')
        return sb.toString()
    }

    /** Encode one JSON value by Kotlin type (numbers bare, strings/bools/null literal, lists as arrays). */
    private fun encodeValue(v: Any?): String = when (v) {
        null -> "null"
        is Boolean -> v.toString()
        is Int, is Long -> v.toString()
        is Double, is Float -> {
            val d = (v as Number).toDouble()
            // Integral doubles render without a fractional suffix would diverge from Swift, but the
            // event residual payloads here are ints/strings/lists; keep doubles JSON-canonical.
            if (d.isFinite()) d.toString() else "null"
        }
        is List<*> -> buildString {
            append('[')
            for ((i, e) in v.withIndex()) {
                if (i > 0) append(',')
                append(encodeValue(e))
            }
            append(']')
        }
        is String -> JSONObject.quote(v)
        else -> JSONObject.quote(v.toString())
    }
}
