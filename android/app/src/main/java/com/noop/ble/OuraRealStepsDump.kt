package com.noop.ble

import android.content.Context
import com.noop.oura.OuraRealStepsDumpLine
import java.io.File
import java.time.Instant

/**
 * Append-only JSONL sidecar for the Oura 0x7E/0x7F real_steps_features stream — the Kotlin twin of Swift
 * `OuraRealStepsDump`. A Tier-B RESEARCH corpus for investigation, never a datastore row (see
 * [OuraRealStepsDumpLine] for the rationale). Owns the file, the once-per-launch "here is the file" log
 * line, and a persistent ring-time high-water so records the ring re-serves across reconnects are
 * written exactly once instead of duplicating the corpus.
 *
 * Location: `<filesDir>/diagnostics/oura-real-steps-<deviceId>.jsonl` (app-private). Purely diagnostic
 * and safe to delete; nothing reads it back.
 *
 * It is NOT a step-decode corpus: ground truth closed that question (no field is a count — see
 * [OuraRealStepsFields] and OURA_PROTOCOL.md s6.13). It exists as a MOVEMENT-FEATURE corpus — f0 and f8
 * discriminate movement strongly (Cohen's d ~ +2.35), so the file is useful for activity work and for
 * cross-checking the 0x7F +2-byte offset against 0x7E on new firmware. Nothing here may be turned into
 * steps. The LINE content is byte-identical to the Swift corpus — that is the parity-relevant part.
 */
class OuraRealStepsDump(
    context: Context,
    private val deviceId: String,
    private val log: (String) -> Unit,
) {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val highWaterKey = "highwater.$deviceId"

    /** Only records with `ringTs` STRICTLY above this are written; re-served (older) records are dropped.
     *  Persisted so the dedup survives relaunches (a fresh drain re-emits old records). */
    private var highWater: Long = prefs.getLong(highWaterKey, 0L)
    private var file: File? = null
    private var resolveFailed = false
    private var announced = false

    /**
     * Append one anchored real_steps record. No-op when [ringTs] is not above the high-water (a
     * re-serve), so the corpus stays deduped. Best-effort: any file error is logged once and never
     * disrupts the BLE path. Call ONLY with an anchored [utc].
     */
    fun record(tag: Int, ringTs: Long, utc: Long, fields: List<Int>) {
        if (ringTs <= highWater) return
        var f = resolveFile() ?: return
        // Bound the corpus so it can't grow unbounded (always-on for every paired ring). At the cap, rotate
        // to a single ".1" (dropping the prior one) and continue in a fresh file — same as the other dumps.
        if (f.length() > MAX_BYTES) {
            runCatching {
                val old = File(f.parentFile, "${f.name}.1")
                old.delete()
                f.renameTo(old)
            }
            file = null
            f = resolveFile() ?: return
        }

        val tagStr = "0x" + tag.toString(16)
        val line = OuraRealStepsDumpLine.encode(
            deviceId = deviceId, tag = tagStr, ringTs = ringTs, utc = utc,
            iso = Instant.ofEpochSecond(utc).toString(), fields = fields,
        )
        try {
            f.appendText(line + "\n")
        } catch (e: Exception) {
            log("Oura: real_steps dump write failed - ${e.message}")
            return
        }

        highWater = ringTs
        prefs.edit().putLong(highWaterKey, ringTs).apply()
        if (!announced) {
            announced = true
            log("Oura: real_steps 0x7E/0x7F dump → ${f.absolutePath} [Tier-B research corpus, JSONL, deduped by ring-time]")
        }
    }

    /** Resolve (and create on first use) the sidecar file + its parent directory. Cached; a failure is
     *  logged once and latched so we never spam the strap log on a read-only volume. */
    private fun resolveFile(): File? {
        file?.let { return it }
        if (resolveFailed) return null
        return try {
            val dir = File(appContext.filesDir, "diagnostics").apply { mkdirs() }
            val safeId = deviceId.replace("/", "_")
            File(dir, "oura-real-steps-$safeId.jsonl").also {
                if (!it.exists()) it.createNewFile()
                file = it
            }
        } catch (e: Exception) {
            resolveFailed = true
            log("Oura: real_steps dump unavailable - ${e.message}")
            null
        }
    }

    private companion object {
        const val PREFS_NAME = "oura_real_steps_dump"

        /** Rotate the sidecar past this size (keeping one previous ".1"), bounding it to ~2× on disk. */
        const val MAX_BYTES = 25L * 1024 * 1024
    }
}
