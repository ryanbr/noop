package com.noop.ble

import android.content.Context
import com.noop.data.WhoopRepository
import com.noop.protocol.DeviceFamily
import com.noop.protocol.extractHistoricalStreams
import java.io.File
import java.io.FileOutputStream

/**
 * Append-only on-device archive of HISTORICAL_DATA record frames that FAILED to decode (#77 / #91).
 *
 * WHY this exists: the strap FREES history once the phone acks its trim cursor. If a chunk's records
 * can't be decoded (CRC failure, or an unmapped firmware layout the v24 plausibility gate rejects),
 * acking anyway permanently destroys the user's ONLY copy of those records while the UI says "History
 * synced". So the Backfiller archives the raw bytes HERE — durably — BEFORE acking. The archive then
 * lets a later release that maps the layout recover the data, and is itself the corpus that mapping
 * needs. Frames carry sensor payloads, not identifiers (no serials/MACs).
 *
 * Format: one JSON object per line (JSONL) in the app-private filesDir, file [REJECTED_ARCHIVE_FILE]:
 *   {"capturedAtMs":<Long>,"trim":<Long>,"family":"whoop4"|"whoop5","frameHex":"<hex>"}
 * Each [append] flushes + fsyncs before returning, so a row is durable before the caller acks.
 *
 * Size cap ([maxBytes], ~5 MB): if appending would push the file past the cap, [append] EVICTS surplus
 * lines to make room rather than refusing the write — weakest-value first, and never below a per-version
 * retention floor ([PER_VERSION_FLOOR] for informative lines, [ZERO_PAYLOAD_FLOOR] for lines whose
 * payload region is entirely zero), so a brand-new layout version is never binned merely because common
 * versions — or a 1 Hz flood of empty placeholder records — filled the file. See [evictLines] for the
 * full priority order. Only when the incoming frames alone can't fit even an empty archive does [append]
 * skip them ([AppendResult.written] = false); the caller records those as unarchived so the sync status
 * never falsely claims they were preserved. (#344)
 *
 * A genuine WRITE FAILURE (I/O error) instead throws — the caller treats that as "do NOT ack", so the
 * strap keeps the records and re-sends them on the next offload. No data is lost either way.
 */
class RawHistoryArchive(
    private val context: Context,
    private val maxBytes: Long = REJECTED_ARCHIVE_MAX_BYTES,
    // Overridable so tests can drive eviction with a small archive instead of 5 MB of frames. (#344)
    private val perVersionFloor: Int = PER_VERSION_FLOOR,
    private val zeroPayloadFloor: Int = ZERO_PAYLOAD_FLOOR,
) {
    /**
     * Outcome of an [append]. [ok] is true whenever the offload may proceed to ack; [written] is true
     * only when the bytes were actually persisted. (ok=true, written=false) is the archive-full case:
     * the offload continues but the frames were NOT preserved — surface that honestly.
     */
    data class AppendResult(val ok: Boolean, val written: Boolean)

    private val file: File get() = File(context.filesDir, REJECTED_ARCHIVE_FILE)

    /**
     * Durably append the given undecodable record [frames] (one JSONL line each). [trim] is the
     * HISTORY_END trim cursor the frames belong to; [family] tags the firmware generation so one
     * mapping toolchain can read both WHOOP 4 and 5/MG archives.
     *
     * Returns [AppendResult] (ok=true) on success, distinguishing actually-written from
     * archive-full-skipped. Throws [java.io.IOException] (and propagates other write errors) ONLY when
     * the bytes could not be made durable — the caller must then NOT ack so the strap re-sends.
     */
    fun append(frames: List<ByteArray>, trim: Long, family: DeviceFamily): AppendResult {
        if (frames.isEmpty()) return AppendResult(ok = true, written = false)

        val f = file
        val familyTag = familyTag(family)
        val now = System.currentTimeMillis()

        // Build the new JSONL lines (each newline-terminated). The version that drives floor-aware
        // retention (#344) is re-derived per line from the stored frame inside [evictLines].
        val newLines = frames.map { frame -> encodeLine(now, trim, familyTag, frame) + "\n" }
        val incomingBytes = newLines.sumOf { it.toByteArray(Charsets.UTF_8).size.toLong() }

        // Fast path: it all fits — plain append, fsync BEFORE returning (the point of the archive).
        if (f.length() + incomingBytes <= maxBytes) {
            FileOutputStream(f, true).use { out ->
                out.write(newLines.joinToString("").toByteArray(Charsets.UTF_8))
                out.flush()
                out.fd.sync()
            }
            return AppendResult(ok = true, written = true)
        }

        // The incoming batch alone can't fit even an empty archive: nothing we can evict makes room,
        // so skip it (the offload may still ack — there is ample sample material by now). Preserves
        // the prior cap contract for this degenerate case.
        if (incomingBytes > maxBytes) return AppendResult(ok = true, written = false)

        // Over cap: rewrite with floor-aware eviction. Read existing lines (oldest first), append the
        // new lines (which sort newest), drop oldest surplus until we fit — never dropping a line within
        // the newest [PER_VERSION_FLOOR] of its version. Atomic rewrite (temp file + rename) so the
        // archive is durable BEFORE the ack. [evictLines] is the pure, unit-tested core.
        val existing = if (f.exists()) f.readLines().filter { it.isNotEmpty() }.map { "$it\n" } else emptyList()
        val kept = evictLines(existing + newLines, maxBytes, perVersionFloor, zeroPayloadFloor)
        val tmp = File(context.filesDir, "$REJECTED_ARCHIVE_FILE.tmp")
        FileOutputStream(tmp).use { out ->
            out.write(kept.joinToString("").toByteArray(Charsets.UTF_8))
            out.flush()
            out.fd.sync()
        }
        if (!tmp.renameTo(f)) {
            tmp.delete()
            throw java.io.IOException("reject-archive atomic rewrite failed (rename)")
        }
        return AppendResult(ok = true, written = true)
    }

    private fun encodeLine(capturedAtMs: Long, trim: Long, familyTag: String, frame: ByteArray): String =
        buildString {
            append("{\"capturedAtMs\":").append(capturedAtMs)
            append(",\"trim\":").append(trim)
            append(",\"family\":\"").append(familyTag).append('"')
            append(",\"frameHex\":\"").append(frame.toHex()).append("\"}")
        }

    private fun familyTag(family: DeviceFamily): String =
        if (family == DeviceFamily.WHOOP5) "whoop5" else "whoop4"

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    /**
     * Every archived frame with its strap family, oldest first — the read-back of the JSONL that
     * [append] writes. Malformed lines are skipped; an absent/empty file yields []. Mirrors the macOS
     * RawHistoryArchive.readAll (#151).
     */
    fun readAll(): List<Pair<ByteArray, DeviceFamily>> {
        val f = file
        if (!f.exists()) return emptyList()
        return f.readLines().mapNotNull { parseArchiveLine(it) }
    }

    /**
     * Re-decode every archived frame through the CURRENT decoder and insert whatever now decodes. The
     * strap freed these records when they were acked, so this archive is the ONLY way banked history
     * backfills after a newly-landed layout (e.g. WHOOP 4.0 v25). Idempotent: offloaded rows dedupe by
     * (deviceId, ts), so a re-run can't double-insert. Runs ONCE per [appVersion] (no manual
     * decoder-version constant to forget to bump — the archive is small, so the once-per-update cost is
     * negligible), and the gate advances ONLY when every insert succeeded: a failed insert leaves the
     * gate un-advanced so these records (whose only surviving copy is this archive) retry next launch.
     * Returns the rows recovered (for logging). Port of the macOS replay + BLEManager gate (#151, #152).
     */
    suspend fun replayIfNeeded(repository: WhoopRepository, deviceId: String, appVersion: String): Int {
        val prefs = context.getSharedPreferences(REPLAY_PREFS, Context.MODE_PRIVATE)
        if (prefs.getString(KEY_REPLAYED_APP_VERSION, null) == appVersion) return 0
        val archived = readAll()
        var rows = 0
        for (family in archived.map { it.second }.toSet()) {
            val frames = archived.filter { it.second == family }.map { it.first }
            // type-47 records carry their own real-unix ts (clock offset ignored), so an identity clock
            // ref is correct here — the same fallback the Backfiller uses when clockRef is nil. Thread the
            // opt-in HR-from-PPG sub-lag interpolation flag (Test Centre → Experimental algorithms) so the
            // archive replay re-derives v26 HR with the same variant the live offload uses. Default OFF.
            val decoded = extractHistoricalStreams(
                frames, 0, 0, family,
                ppgHrSubLagInterp = PuffinExperiment.from(context).ppgHrSubLagInterp,
            )
            // Count rows ACTUALLY inserted, not decoded: under the per-app-version gate the archive
            // replays every release, and dedupe makes those re-runs insert 0 — counting decoded rows
            // would log a false "retro-decoded N" success on every update. (#152)
            rows += try {
                repository.insert(decoded, deviceId).gravity
            } catch (t: Throwable) {
                // Do NOT advance the gate — retry the whole replay next launch (inserts are idempotent).
                return rows
            }
        }
        prefs.edit().putString(KEY_REPLAYED_APP_VERSION, appVersion).apply()
        return rows
    }

    companion object {
        /** Archive filename in the app-private filesDir. */
        const val REJECTED_ARCHIVE_FILE = "rejected_history.jsonl"

        /**
         * ~5 MB cap; above this [append] evicts surplus (weakest-value first, floor-aware) to make room
         * (#344). See [evictLines] for the full priority order.
         *
         * Deliberately NOT raised to survive a placeholder flood. At ~3.2 KB per hex line a 1 Hz stream of
         * 1584-byte records fills any cap in hours, so a bigger number buys a linear factor of time and
         * costs every user disk — while [ZERO_PAYLOAD_FLOOR] removes the pressure outright by evicting the
         * informationless records first. Value, not volume, is what was missing.
         */
        const val REJECTED_ARCHIVE_MAX_BYTES = 5L * 1024 * 1024

        /**
         * Per distinct layout VERSION, keep at least this many of the newest archived lines, immune to
         * cap eviction. A never-seen version (WHOOP 4 v19, WHOOP 5 v20/v21 — `frame[5]` / `frame[9]`,
         * the hist_version byte) emits only a handful of frames, so this floor guarantees those rare
         * samples survive while the most-populous versions shed their oldest surplus. Bounded: the floor
         * holds at most floor x distinctVersions lines, a tiny set. Mirrors the macOS RawHistoryArchive
         * perVersionFloor. (#344)
         */
        const val PER_VERSION_FLOOR = 64

        /**
         * Per-version retention floor for lines whose PAYLOAD REGION IS ENTIRELY ZERO — far smaller than
         * [PER_VERSION_FLOOR], because such a record carries no information beyond "the strap banked a
         * record at time T".
         *
         * Measured motivation, from a WHOOP MG offload: 1,275 consecutive type-47 records of layout
         * version 16, 1584 bytes each, every byte from offset 21 to the 4-byte CRC32 trailer zero in
         * EVERY one. The records' own frame clock advanced by 1 s across 933 of the gaps and 0 s across
         * the other 339 — a contiguous 1 Hz producer, not a burst. At ~3.2 KB per hex JSONL line the 5 MB
         * archive holds about 1,500 of them, i.e. ~21 minutes of retention: under a purely age-ordered
         * policy every informative record older than that is gone, evicted by frames that carry nothing.
         * Keeping a handful still proves the artefact exists (and dates it); keeping thousands costs the
         * evidence. Twin of the Swift `RawHistoryArchive.zeroPayloadFloor`.
         */
        const val ZERO_PAYLOAD_FLOOR = 8

        /** Bytes of the CRC32 trailer excluded from the payload region. */
        const val CRC_TRAILER_BYTES = 4

        /**
         * A payload region shorter than this is not judged at all ([hasZeroPayload] returns false): a
         * truncated or tiny frame is not evidence of an empty record, and must not lose retention
         * priority on the strength of a few zero bytes.
         */
        const val MIN_PAYLOAD_BYTES_TO_JUDGE = 32

        /**
         * First byte of a record's PAYLOAD region — everything past the record header, ending at the
         * 4-byte CRC32 trailer. 21 on WHOOP 5/MG (magic @0, seq @11, unix ts @15-18, a constant @19-20)
         * and 17 on WHOOP 4: the same +4 that shifts the type byte 4→8 and the version byte 5→9, because
         * the puffin envelope is 4 bytes longer. Starting AFTER the header is load-bearing — a region
         * that included the non-zero seq/timestamp bytes would never test as all-zero and
         * [hasZeroPayload] would never fire. Twin of the Swift `RawHistoryArchive.payloadStart`.
         */
        fun payloadStart(family: DeviceFamily): Int = if (family == DeviceFamily.WHOOP5) 21 else 17

        /**
         * True when EVERY byte of [frame]'s payload region is zero — an informationless record.
         *
         * Deliberately the STRICT test: a single non-zero byte anywhere in the region makes the frame
         * informative and gives it full retention priority. "Mostly zero" is NOT the test — a novel
         * record that carries one small populated block inside an otherwise-empty buffer is precisely the
         * thing this archive exists to catch. Twin of the Swift `RawHistoryArchive.hasZeroPayload`.
         */
        fun hasZeroPayload(frame: ByteArray, family: DeviceFamily): Boolean {
            val start = payloadStart(family)
            val end = frame.size - CRC_TRAILER_BYTES
            if (end - start < MIN_PAYLOAD_BYTES_TO_JUDGE) return false
            for (i in start until end) if (frame[i].toInt() != 0) return false
            return true
        }

        /**
         * Fraction of the cap freed once eviction has to run at all: the rewrite evicts down to
         * `maxBytes - maxBytes/LOW_WATER_DIVISOR` rather than to exactly the cap.
         *
         * Without this, an archive sitting AT the cap does a full read-parse-rewrite of the whole file on
         * EVERY subsequent batch — and the batches that matter here arrive during an offload at up to one
         * record per strap-second. Leaving an eighth of the cap free amortises that to one rewrite per
         * ~600 KB of new frames. The bytes given up are the ones eviction would have taken next anyway,
         * in the same priority order. Twin of the Swift `RawHistoryArchive.lowWaterDivisor`.
         */
        const val LOW_WATER_DIVISOR = 8

        /**
         * The hist_version byte distinguishing one historical layout from another: `frame[5]` on WHOOP
         * 4, `frame[9]` on WHOOP 5/MG (the puffin envelope is 4 bytes longer). Same indices the reject
         * filter uses. Frames too short to carry it fall back to a sentinel so they still form a bucket.
         */
        fun versionByte(frame: ByteArray, family: DeviceFamily): Int {
            val idx = if (family == DeviceFamily.WHOOP5) 9 else 5
            return if (frame.size > idx) frame[idx].toInt() and 0xFF else -1
        }

        /**
         * A per-version retention key. Family is part of the key so a WHOOP 4 v18 and a WHOOP 5 v18 are
         * kept as distinct buckets (their layouts differ despite the shared version number).
         */
        private data class VersionKey(val family: String, val version: Int)

        /**
         * How one archived line is classified for retention: which version bucket it belongs to, and
         * whether its payload region is entirely zero (informationless — see [hasZeroPayload]).
         */
        private data class LineClass(val key: VersionKey, val zeroPayload: Boolean)

        /**
         * Classify one archived JSONL line from its stored frame + family; null for a
         * malformed/unparseable line — those get NO retention floor (evict them first, never let garbage
         * occupy a floor slot a real rare version could use), and are always evictable before any real,
         * floor-protected line.
         */
        private fun lineClass(line: String): LineClass? {
            val (frame, family) = parseArchiveLine(line) ?: return null
            val tag = if (family == DeviceFamily.WHOOP5) "whoop5" else "whoop4"
            return LineClass(VersionKey(tag, versionByte(frame, family)), hasZeroPayload(frame, family))
        }

        /**
         * Floor-aware cap eviction (#344), PURE so it is JVM-unit-testable without a Context. [lines] is
         * the full newline-terminated JSONL set, oldest-first (existing ++ incoming).
         *
         * Retention priority, weakest first — everything in a band is evicted before anything in the next:
         *  1. malformed lines (unparseable — no version, no floor);
         *  2. surplus lines whose payload region is ENTIRELY ZERO ([hasZeroPayload]), oldest first;
         *  3. surplus informative lines, oldest first;
         *  4. floor-protected lines, never evicted: the newest [zeroFloor] zero-payload lines of each
         *     version and the newest [floor] informative lines of each version — so a rare never-seen
         *     layout (WHOOP 4 v19, WHOOP 5 v20/v21) always survives even when common versions fill the
         *     archive.
         *
         * Band 2 is what keeps a rare informative record recoverable. A 5/MG has been measured banking one
         * all-zero 1584-byte record per second (see [ZERO_PAYLOAD_FLOOR]); age-ordered eviction alone
         * flushes the whole archive within ~21 minutes of that, and an all-zero payload carries nothing
         * that would be worth the trade. Band 4's split floor means a version whose records are ALL empty
         * still keeps a few dated samples of the artefact, while the full [floor] stays reserved for
         * records that actually contain something.
         *
         * Once eviction has to run at all it evicts to [LOW_WATER_DIVISOR] below the cap rather than to
         * exactly the cap, so a 1 Hz stream no longer rewrites the whole file once per record.
         *
         * Bounded: if everything left is floor-protected it stops even if still over cap (the floor wins —
         * `(floor + zeroFloor) x distinctVersions` is tiny). Mirrors the macOS
         * `RawHistoryArchive.evictLines`; [zeroFloor] is defaulted for exactly the reason it is defaulted
         * on the Swift side — so existing call sites do not have to churn.
         */
        fun evictLines(
            lines: List<String>,
            maxBytes: Long,
            floor: Int,
            zeroFloor: Int = ZERO_PAYLOAD_FLOOR,
        ): List<String> {
            // Mark the newest [floor] informative and newest [zeroFloor] zero-payload indices of each
            // version as protected (scan newest -> oldest). Malformed lines (null class) are never
            // protected — evicted before any real, floor-kept line.
            val classes = lines.map { lineClass(it) }
            val protectedIdx = HashSet<Int>()
            val seenInformative = HashMap<VersionKey, Int>()
            val seenZero = HashMap<VersionKey, Int>()
            for (idx in lines.indices.reversed()) {
                val c = classes[idx] ?: continue
                if (c.zeroPayload) {
                    val n = seenZero[c.key] ?: 0
                    if (n < zeroFloor) { protectedIdx.add(idx); seenZero[c.key] = n + 1 }
                } else {
                    val n = seenInformative[c.key] ?: 0
                    if (n < floor) { protectedIdx.add(idx); seenInformative[c.key] = n + 1 }
                }
            }
            var total = lines.sumOf { it.toByteArray(Charsets.UTF_8).size.toLong() }
            if (total <= maxBytes) return lines
            val target = maxBytes - maxBytes / LOW_WATER_DIVISOR
            // Evict in weakest-first bands; within a band, oldest first (ascending index).
            val dropped = HashSet<Int>()
            fun evict(admits: (Int) -> Boolean) {
                for (idx in lines.indices) {                   // ascending = oldest first
                    if (total <= target) break
                    if (idx in protectedIdx || idx in dropped) continue
                    if (!admits(idx)) continue
                    dropped.add(idx)
                    total -= lines[idx].toByteArray(Charsets.UTF_8).size.toLong()
                }
            }
            evict { classes[it] == null }                      // 1. malformed
            evict { classes[it]?.zeroPayload == true }         // 2. zero-payload surplus
            evict { true }                                     // 3. informative surplus
            return lines.filterIndexed { idx, _ -> idx !in dropped }
        }

        /** Where the once-per-app-version replay marker lives. */
        const val REPLAY_PREFS = "noop_reject_replay"
        const val KEY_REPLAYED_APP_VERSION = "replayed_app_version"

        /**
         * Parse one archive JSONL line to (frame, family); null if malformed. Pure (no I/O) so the
         * read-back is unit-testable. Hand-parsed to match the hand-built [encodeLine] writer — the only
         * dynamic fields are `family` and the [0-9a-f] `frameHex`.
         */
        fun parseArchiveLine(line: String): Pair<ByteArray, DeviceFamily>? {
            val fam = jsonString(line, "family") ?: return null
            val hex = jsonString(line, "frameHex") ?: return null
            val family = if (fam == "whoop5") DeviceFamily.WHOOP5 else DeviceFamily.WHOOP4
            if (hex.length % 2 != 0) return null
            val bytes = try {
                ByteArray(hex.length / 2) {
                    ((hex[it * 2].digitToInt(16) shl 4) or hex[it * 2 + 1].digitToInt(16)).toByte()
                }
            } catch (e: IllegalArgumentException) { return null }
            return bytes to family
        }

        private fun jsonString(line: String, key: String): String? {
            val marker = "\"$key\":\""
            val i = line.indexOf(marker); if (i < 0) return null
            val start = i + marker.length
            val end = line.indexOf('"', start); if (end < 0) return null
            return line.substring(start, end)
        }
    }
}
